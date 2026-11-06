import Darwin
import Foundation
import OmarchyAppleInstallerTrustCore

@main struct InstallerReadinessCheck {
  static func main() async {
    do { try await check() } catch {
      FileHandle.standardError.write(Data("NOT READY: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func check() async throws {
    if CommandLine.arguments == [CommandLine.arguments[0], "--identity-only"] {
      let identity = try AppleSiliconHostInspector().inspectIdentity()
      let data = try JSONSerialization.data(
        withJSONObject: [
          "schema_version": 1,
          "model": identity.model,
          "chip": identity.chip,
          "device_identifier": identity.deviceIdentifier,
          "installation_readiness": "not_assessed",
        ], options: [.prettyPrinted, .sortedKeys])
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
      return
    }
    guard CommandLine.arguments.count == 2,
      let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    else { throw NSError(domain: "readiness", code: 64) }
    let host = try AppleSiliconHostInspector().inspect()
    let archive = try ValidationEngineArtifactLocator().locate(in: bundle)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let transcript = try await PinnedAsahiEngineExecutor().inspect(archive, in: scratch)
    let engine = try AppleInstallerTrustCore().validateEngineTranscript(transcript)
    guard engine.deviceIdentifier == host.identity.deviceIdentifier, engine.support == .supported,
      host.eligibility == .requiresSignedCatalog
    else { throw NSError(domain: "readiness", code: 1) }
    print(
      "READY: \(host.identity.deviceIdentifier), engine \(ValidationEngineArtifactLocator.version)")
  }
}
