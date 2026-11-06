#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class MacHostInspectionTests: XCTestCase {
    func testUnavailableTargetTypeFallsBackToPlatformCompatibility() throws {
      let reader = MacHardwarePropertyReader(
        sysctl: FixtureHardwarePropertyReader(values: ["hw.model": "Mac17,8"]),
        platform: FixturePlatformCompatibilityReader(
          data: Data("J716sAP\0Mac17,8\0AppleARM\0".utf8)))

      XCTAssertEqual(try reader.string(named: "hw.targettype"), "j716s")
      XCTAssertEqual(try reader.string(named: "hw.model"), "Mac17,8")
      XCTAssertThrowsError(try reader.string(named: "missing.property"))
    }

    func testAvailableSysctlTargetDoesNotUseRegistryFallback() throws {
      let reader = MacHardwarePropertyReader(
        sysctl: FixtureHardwarePropertyReader(values: ["hw.targettype": "J314s"]),
        platform: FixturePlatformCompatibilityReader(data: Data()))
      XCTAssertEqual(try reader.string(named: "hw.targettype"), "J314s")
    }

    func testRegistryFallbackPreservesBlockedModelCheck() throws {
      let inspector = AppleSiliconHostInspector(
        hardware: MacHardwarePropertyReader(
          sysctl: FixtureHardwarePropertyReader(values: [
            "hw.model": "Mac16,8", "machdep.cpu.brand_string": "Apple M4 Pro",
          ]),
          platform: FixturePlatformCompatibilityReader(data: Data("J614sAP\0Mac16,8\0".utf8))),
        commands: FixtureReadOnlyCommandRunner(root: Data(), limits: Data(), power: Data()),
        operatingSystem: FixtureOperatingSystemVersionReader())

      XCTAssertTrue(try inspector.isBlockedModel())
    }

    func testCompatibilityFallbackRejectsMissingMalformedAndAmbiguousBoards() {
      for data in [
        Data(), Data("J716sAP".utf8), Data("Mac17,8\0AppleARM\0".utf8),
        Data("J716sAP\0J717sAP\0".utf8), Data("J716sAP;erase\0".utf8), Data("J716sAP\n\0".utf8),
        Data([0xFF, 0]),
      ] {
        XCTAssertThrowsError(try MacHardwarePropertyReader.targetType(from: data)) {
          XCTAssertEqual(
            $0 as? AppleSiliconHostInspectionError, .invalidHardwareProperty("hw.targettype"))
        }
      }
    }

    func testM5ProIdentityDoesNotRequireStorageOrPowerCommands() throws {
      // Empty command responses make any accidental full inspection fail.
      let inspector = AppleSiliconHostInspector(
        hardware: FixtureHardwarePropertyReader(values: [
          "hw.model": "Mac17,8", "machdep.cpu.brand_string": "Apple M5 Pro",
          "hw.targettype": "J716s",
        ]),
        commands: FixtureReadOnlyCommandRunner(root: Data(), limits: Data(), power: Data()),
        operatingSystem: FixtureOperatingSystemVersionReader())

      let identity = try inspector.inspectIdentity()

      XCTAssertEqual(identity.model, "Mac17,8")
      XCTAssertEqual(identity.chip, "Apple M5 Pro")
      XCTAssertEqual(identity.deviceIdentifier, "apple,j716s")
    }

    func testTheModelCheckAloneRefusesOnlyTheBlockedModel() throws {
      let unused = FixtureReadOnlyCommandRunner(root: Data(), limits: Data(), power: Data())
      let cases = [("J614s", true), ("apple,j614s", true), ("J613", false), ("J314s", false)]
      for (target, blocked) in cases {
        let inspector = AppleSiliconHostInspector(
          hardware: FixtureHardwarePropertyReader(values: [
            "hw.model": "Mac", "machdep.cpu.brand_string": "Apple", "hw.targettype": target,
          ]),
          commands: unused,
          operatingSystem: ProcessInfoOperatingSystemVersionReader())
        XCTAssertEqual(try inspector.isBlockedModel(), blocked, target)
      }
    }

    func testSupportedM1InspectionRemainsCatalogGated() throws {
      let inspector = makeInspector(target: "J314s")

      let result = try inspector.inspect()

      XCTAssertEqual(result.identity.model, "MacBookPro18,3")
      XCTAssertEqual(result.identity.chip, "Apple M1 Pro")
      XCTAssertEqual(result.identity.deviceIdentifier, "apple,j314s")
      XCTAssertEqual(result.eligibility, .requiresSignedCatalog)
      XCTAssertEqual(result.macOSVersion, "Version 15.6 (Build 24G84)")
      XCTAssertEqual(result.powerSource, .ac)
      XCTAssertTrue(result.fileVaultEnabled)
      XCTAssertEqual(result.storage.containerIdentifier, "disk3")
      XCTAssertEqual(result.storage.physicalStoreIdentifier, "disk0s2")
      XCTAssertEqual(result.storage.shrinkableBytes, 400)
    }

    func testNeoInspectionRemainsCatalogGated() throws {
      let result = try makeInspector(model: "Mac17,5", chip: "Apple A18 Pro", target: "J700")
        .inspect()
      XCTAssertEqual(result.identity.deviceIdentifier, "apple,j700")
      XCTAssertEqual(result.identity.chip, "Apple A18 Pro")
      XCTAssertEqual(result.eligibility, .requiresSignedCatalog)
    }

    func testM4InspectionIsBlockedBeforeCatalogOrAuthorization() throws {
      let inspector = makeInspector(
        model: "Mac16,8",
        chip: "Apple M4 Pro",
        target: "J614s"
      )

      let result = try inspector.inspect()

      XCTAssertEqual(result.identity.deviceIdentifier, "apple,j614s")
      XCTAssertEqual(
        result.eligibility,
        .blocked(
          reason: "This installer doesn’t support this Mac model yet."
        )
      )
    }

    func testUnsafeContainerIdentifierStopsBeforeLimitsQuery() {
      let commands = FixtureReadOnlyCommandRunner(
        root: propertyList([
          "APFSContainerReference": "disk3;eraseDisk"
        ]),
        limits: Data(),
        power: Data("Now drawing from 'AC Power'\n".utf8)
      )
      let inspector = AppleSiliconHostInspector(
        hardware: FixtureHardwarePropertyReader(values: [
          "hw.model": "MacBookPro18,3",
          "machdep.cpu.brand_string": "Apple M1 Pro",
          "hw.targettype": "J314s",
        ]),
        commands: commands,
        operatingSystem: FixtureOperatingSystemVersionReader()
      )

      XCTAssertThrowsError(try inspector.inspect()) {
        XCTAssertEqual(
          $0 as? AppleSiliconHostInspectionError,
          .unsafeContainerIdentifier("disk3;eraseDisk")
        )
      }
    }

    func testInvalidTargetTypeFailsClosed() {
      let inspector = makeInspector(target: "J314s;touch")

      XCTAssertThrowsError(try inspector.inspect()) {
        XCTAssertEqual(
          $0 as? AppleSiliconHostInspectionError,
          .invalidHardwareProperty("hw.targettype")
        )
      }
    }

    func testLiveInspectionIsReadOnlyAndReturnsCoherentHostState() throws {
      let model = try SysctlHardwarePropertyReader().string(named: "hw.model")
      try XCTSkipIf(
        model.hasPrefix("VirtualMac"),
        "Physical Mac identity and internal-storage checks require real Apple Silicon hardware."
      )
      let result = try AppleSiliconHostInspector().inspect()

      XCTAssertTrue(result.identity.model.hasPrefix("Mac"))
      if result.identity.deviceIdentifier == "apple,j700" {
        XCTAssertEqual(result.identity.chip, "Apple A18 Pro")
      } else {
        XCTAssertTrue(result.identity.chip.hasPrefix("Apple M"))
      }
      XCTAssertTrue(result.identity.deviceIdentifier.hasPrefix("apple,j"))
      XCTAssertFalse(result.macOSVersion.isEmpty)
      XCTAssertTrue(result.storage.isInternal)
      XCTAssertGreaterThan(result.storage.containerSizeBytes, 0)
      XCTAssertLessThanOrEqual(
        result.storage.minimumPreferredSizeBytes,
        result.storage.containerSizeBytes
      )
    }

    private func makeInspector(
      model: String = "MacBookPro18,3",
      chip: String = "Apple M1 Pro",
      target: String
    ) -> AppleSiliconHostInspector {
      AppleSiliconHostInspector(
        hardware: FixtureHardwarePropertyReader(values: [
          "hw.model": model,
          "machdep.cpu.brand_string": chip,
          "hw.targettype": target,
        ]),
        commands: FixtureReadOnlyCommandRunner(
          root: propertyList([
            "APFSContainerReference": "disk3",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
            "APFSContainerSize": 1_000,
            "APFSContainerFree": 500,
            "Internal": true,
            "FileVault": true,
          ]),
          limits: propertyList(["MinimumSizePreferred": 600]),
          power: Data("Now drawing from 'AC Power'\n".utf8)
        ),
        operatingSystem: FixtureOperatingSystemVersionReader()
      )
    }
  }

  private struct FixturePlatformCompatibilityReader: PlatformCompatibilityReading {
    let data: Data
    func compatible() throws -> Data { data }
  }

  final class APFSSnapshotInspectorTests: XCTestCase {
    func testLimitingTimeMachineSnapshotSurvivesAnotherVolumeQueryFailure() {
      let commands = snapshotRunner(
        volumes: ["disk9s1", "disk9s5"],
        snapshots: [
          "disk9s5": propertyList([
            "Snapshots": [
              [
                "SnapshotName": "com.apple.TimeMachine.2000-01-01-000000.local",
                "LimitingContainerShrink": true,
                "Purgeable": true,
              ]
            ]
          ])
        ]
      )

      XCTAssertEqual(
        APFSSnapshotInspector(commands: commands).constraint(in: storage()),
        .timeMachine
      )
    }

    func testSystemConstraintDoesNotBlameUnrelatedTimeMachineSnapshot() {
      let commands = snapshotRunner(snapshots: [
        "disk9s5": propertyList([
          "Snapshots": [
            [
              "SnapshotName": "com.apple.TimeMachine.2000-01-01-000000.local",
              "LimitingContainerShrink": false,
            ],
            [
              "SnapshotName": "com.apple.os.update-synthetic",
              "LimitingContainerShrink": true,
            ],
          ]
        ])
      ])

      XCTAssertEqual(
        APFSSnapshotInspector(commands: commands).constraint(in: storage()),
        .other
      )
    }

    func testSnapshotPresenceOrMalformedLimitFlagDoesNotProveAConstraint() {
      let commands = snapshotRunner(snapshots: [
        "disk9s5": propertyList([
          "Snapshots": [
            ["SnapshotName": "com.apple.TimeMachine.2000-01-01-000000.local"],
            [
              "SnapshotName": "com.apple.TimeMachine.2000-01-02-000000.local",
              "LimitingContainerShrink": 1,
            ],
            [
              "SnapshotName": "com.apple.TimeMachine.2000-01-03-000000.local",
              "LimitingContainerShrink": "true",
            ],
          ]
        ])
      ])

      XCTAssertNil(APFSSnapshotInspector(commands: commands).constraint(in: storage()))
    }

    func testLimitingSnapshotWithUnknownNameUsesGeneralDiagnosis() {
      let commands = snapshotRunner(snapshots: [
        "disk9s5": propertyList([
          "Snapshots": [
            [
              "SnapshotName": "com.apple.TimeMachine.synthetic.backup",
              "LimitingContainerShrink": true,
            ]
          ]
        ])
      ])

      XCTAssertEqual(
        APFSSnapshotInspector(commands: commands).constraint(in: storage()),
        .other
      )
    }

    func testFailedOrUnsupportedQueriesLeaveDiagnosisUnknown() {
      let runners = [
        SnapshotCommandRunner(volumes: nil, snapshots: [:]),
        SnapshotCommandRunner(volumes: Data("unsupported".utf8), snapshots: [:]),
        snapshotRunner(snapshots: [:]),
        snapshotRunner(snapshots: ["disk9s5": Data("invalid plist".utf8)]),
        snapshotRunner(snapshots: ["disk9s5": propertyList([:])]),
      ]

      for commands in runners {
        XCTAssertNil(APFSSnapshotInspector(commands: commands).constraint(in: storage()))
      }
    }

    func testExternalOrDifferentContainerCannotSupplySnapshotEvidence() {
      let snapshots = [
        "disk9s5": propertyList([
          "Snapshots": [["LimitingContainerShrink": true]]
        ])
      ]
      let commands = snapshotRunner(snapshots: snapshots)
      XCTAssertNil(
        APFSSnapshotInspector(commands: commands).constraint(in: storage(isInternal: false))
      )
      let otherContainer = snapshotRunner(container: "disk8", snapshots: snapshots)
      XCTAssertNil(
        APFSSnapshotInspector(commands: otherContainer).constraint(in: storage())
      )
    }

    func testUnsafeVolumeIdentifierIsRejectedBeforeSnapshotQuery() {
      for unsafe in ["disk", "disk9", "disk9s", "diskss5", "disk9s5;eraseDisk"] {
        let commands = snapshotRunner(
          volumes: [unsafe],
          snapshots: [
            unsafe: propertyList(["Snapshots": [["LimitingContainerShrink": true]]])
          ]
        )

        XCTAssertNil(APFSSnapshotInspector(commands: commands).constraint(in: storage()))
      }

    }

    private func storage(isInternal: Bool = true) -> APFSStorageInspection {
      APFSStorageInspection(
        containerIdentifier: "disk9",
        physicalStoreIdentifier: "disk0s2",
        isInternal: isInternal,
        containerSizeBytes: 1_000,
        containerFreeBytes: 200,
        minimumPreferredSizeBytes: 1_000
      )
    }

    private func snapshotRunner(
      container: String = "disk9",
      volumes: [String] = ["disk9s5"],
      snapshots: [String: Data]
    ) -> SnapshotCommandRunner {
      SnapshotCommandRunner(
        volumes: propertyList([
          "Containers": [
            [
              "ContainerReference": container,
              "Volumes": volumes.map { ["DeviceIdentifier": $0] },
            ]
          ]
        ]),
        snapshots: snapshots
      )
    }
  }

  private struct SnapshotCommandRunner: ReadOnlyMacCommandRunning {
    let volumes: Data?
    let snapshots: [String: Data]

    func run(_ command: ReadOnlyMacCommand) throws -> Data {
      let response: Data?
      switch command {
      case .apfsVolumes:
        response = volumes
      case .apfsSnapshots(let volume):
        response = snapshots[volume.rawValue]
      default:
        XCTFail("Snapshot diagnostics must use only APFS list and listSnapshots.")
        response = nil
      }
      guard let response else {
        throw AppleSiliconHostInspectionError.commandFailed(command.auditName, 1)
      }
      return response
    }
  }

  private struct FixtureHardwarePropertyReader: HardwarePropertyReading {
    let values: [String: String]

    func string(named name: String) throws -> String {
      guard let value = values[name] else {
        throw AppleSiliconHostInspectionError.hardwarePropertyUnavailable(name)
      }
      return value
    }
  }

  private struct FixtureReadOnlyCommandRunner: ReadOnlyMacCommandRunning {
    let root: Data
    let limits: Data
    let power: Data

    func run(_ command: ReadOnlyMacCommand) throws -> Data {
      switch command {
      case .rootDiskInfo:
        root
      case .apfsResizeLimits:
        limits
      case .apfsVolumes, .apfsSnapshots:
        throw AppleSiliconHostInspectionError.commandFailed(command.auditName, 1)
      case .powerSource:
        power
      }
    }
  }

  private struct FixtureOperatingSystemVersionReader:
    OperatingSystemVersionReading
  {
    func versionString() -> String {
      "Version 15.6 (Build 24G84)"
    }
  }

  private func propertyList(_ values: [String: Any]) -> Data {
    try! PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
  }
#endif
