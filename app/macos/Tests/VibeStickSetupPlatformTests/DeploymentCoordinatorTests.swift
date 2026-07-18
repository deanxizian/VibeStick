import Foundation
import XCTest
@testable import VibeStickSetupCore
@testable import VibeStickSetupPlatform

final class DeploymentCoordinatorTests: XCTestCase {
    func testChangedSerialIdentityStopsBeforeFlashCommand() async throws {
        let selectedDevice = device(serialNumber: "selected-serial")
        let changedDevice = device(serialNumber: "different-serial")
        let store = RecordingConfigurationStore()
        let runner = RecordingProcessRunner()
        let events = DeploymentEventRecorder()
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: store,
            runner: runner,
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: FixedSerialDiscovery(devices: [changedDevice])
        )

        do {
            _ = try await coordinator.deploy(
                configuration: configuration,
                device: selectedDevice,
                idfExportPath: "/tmp/export-idf.sh",
                onStep: { phase, state in events.append(phase, state) },
                onOutput: { _ in }
            )
            XCTFail("expected identity re-enumeration to reject the changed device")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .deviceChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(
            runner.commands().map(\.displayName),
            ["构建固件", "安装 Mac Bridge"]
        )
        XCTAssertFalse(runner.commands().contains { $0.displayName == "烧录 StickS3" })
        XCTAssertTrue(events.events().contains { event in
            guard event.phase == .flashFirmware else { return false }
            if case .failed = event.state { return true }
            return false
        })
    }

    func testSuccessfulDeploymentUsesSameNonceForSaveAndDeviceWait() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let store = RecordingConfigurationStore()
        let runner = RecordingProcessRunner()
        let events = DeploymentEventRecorder()
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: store,
            runner: runner,
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        let saved = try await coordinator.deploy(
            configuration: configuration,
            device: selectedDevice,
            idfExportPath: "/tmp/export-idf.sh",
            onStep: { phase, state in events.append(phase, state) },
            onOutput: { _ in }
        )

        XCTAssertEqual(saved, configuration)
        let deploymentNonce = try XCTUnwrap(store.savedNonces().last ?? nil)
        XCTAssertNotNil(UUID(uuidString: deploymentNonce))
        XCTAssertEqual(deploymentNonce, deploymentNonce.lowercased())

        let commands = runner.commands()
        XCTAssertEqual(
            commands.map(\.displayName),
            ["构建固件", "安装 Mac Bridge", "烧录 StickS3", "启动 StickS3", "等待 StickS3 联网", "运行 VibeStick 诊断"]
        )
        let flashCommand = try XCTUnwrap(commands.first { $0.displayName == "烧录 StickS3" })
        XCTAssertTrue(flashCommand.arguments.contains(selectedDevice.calloutPath))

        let startCommand = try XCTUnwrap(commands.first { $0.displayName == "启动 StickS3" })
        XCTAssertEqual(
            startCommand.arguments,
            [
                projectRoot.appendingPathComponent("scripts/start-device.sh").path,
                "--export",
                "/tmp/export-idf.sh",
                "--port",
                selectedDevice.calloutPath,
            ]
        )

        let waitCommand = try XCTUnwrap(commands.first { $0.displayName == "等待 StickS3 联网" })
        XCTAssertEqual(
            waitCommand.arguments,
            [
                projectRoot.appendingPathComponent("scripts/wait-for-device.sh").path,
                "--deployment-nonce",
                deploymentNonce,
                "--timeout",
                "30",
            ]
        )
        XCTAssertEqual(
            events.events(),
            DeploymentPhase.allCases.flatMap { phase in
                [DeploymentEvent(phase: phase, state: .running), DeploymentEvent(phase: phase, state: .succeeded)]
            }
        )
    }

    func testDeviceStartFailureStillWaitsForAnAlreadyRunningDevice() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let runner = RecordingProcessRunner(exitCodes: ["启动 StickS3": 1])
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: runner,
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        _ = try await coordinator.deploy(
            configuration: configuration,
            device: selectedDevice,
            idfExportPath: "/tmp/export-idf.sh",
            onStep: { _, _ in },
            onOutput: { _ in }
        )

        XCTAssertTrue(runner.commands().contains { $0.displayName == "等待 StickS3 联网" })
        XCTAssertTrue(runner.commands().contains { $0.displayName == "运行 VibeStick 诊断" })
    }

    func testTemporaryDeviceWaitTimeoutKeepsSameDeploymentUntilOnline() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let store = RecordingConfigurationStore()
        let runner = RecordingProcessRunner(
            exitCodeSequences: ["等待 StickS3 联网": [75, 75, 0]]
        )
        let events = DeploymentEventRecorder()
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: store,
            runner: runner,
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        _ = try await coordinator.deploy(
            configuration: configuration,
            device: selectedDevice,
            idfExportPath: "/tmp/export-idf.sh",
            onStep: { phase, state in events.append(phase, state) },
            onOutput: { _ in }
        )

        let deploymentNonce = try XCTUnwrap(store.savedNonces().last ?? nil)
        let waitCommands = runner.commands().filter { $0.displayName == "等待 StickS3 联网" }
        XCTAssertEqual(waitCommands.count, 3)
        XCTAssertTrue(waitCommands.allSatisfy { command in
            command.arguments.contains(deploymentNonce)
        })
        XCTAssertEqual(runner.commands().filter { $0.displayName == "烧录 StickS3" }.count, 1)
        XCTAssertEqual(runner.commands().filter { $0.displayName == "启动 StickS3" }.count, 1)
        XCTAssertEqual(runner.commands().filter { $0.displayName == "运行 VibeStick 诊断" }.count, 1)

        let waitEvents = events.events().filter { $0.phase == .waitForDevice }
        XCTAssertEqual(
            waitEvents,
            [
                DeploymentEvent(phase: .waitForDevice, state: .running),
                DeploymentEvent(phase: .waitForDevice, state: .succeeded),
            ]
        )
    }

    func testDeviceWaitFailureReturnsActionablePowerButtonMessage() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let runner = RecordingProcessRunner(exitCodes: ["等待 StickS3 联网": 1])
        let events = DeploymentEventRecorder()
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: runner,
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        do {
            _ = try await coordinator.deploy(
                configuration: configuration,
                device: selectedDevice,
                idfExportPath: "/tmp/export-idf.sh",
                onStep: { phase, state in events.append(phase, state) },
                onOutput: { _ in }
            )
            XCTFail("expected device wait to fail")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .deviceDidNotComeOnline)
            XCTAssertTrue(error.localizedDescription.contains("短按一次侧面电源键"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(runner.commands().contains { $0.displayName == "运行 VibeStick 诊断" })
        XCTAssertTrue(events.events().contains { event in
            guard event.phase == .waitForDevice else { return false }
            if case .failed = event.state { return true }
            return false
        })
    }

    func testDeviceStartAndWaitFailurePreservesInstallerFailureReason() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let runner = RecordingProcessRunner(
            exitCodes: ["启动 StickS3": 7, "等待 StickS3 联网": 1]
        )
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: runner,
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        do {
            _ = try await coordinator.deploy(
                configuration: configuration,
                device: selectedDevice,
                idfExportPath: "/tmp/export-idf.sh",
                onStep: { _, _ in },
                onOutput: { _ in }
            )
            XCTFail("expected start and wait to fail")
        } catch let error as SetupCoreError {
            guard case let .deviceStartFailed(reason) = error else {
                return XCTFail("unexpected setup error: \(error)")
            }
            XCTAssertTrue(reason.contains("退出码 7"))
            XCTAssertTrue(error.localizedDescription.contains("无法自动启动 StickS3"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInstallModeProbeReturnsTrueForReadyROMUsingDedicatedRunner() async throws {
        let selectedDevice = device(serialNumber: "14:C1:9F:D5:3D:5C")
        let deploymentRunner = RecordingProcessRunner()
        let probeRunner = RecordingProcessRunner()
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: deploymentRunner,
            probeRunner: probeRunner,
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        let ready = try await coordinator.probeInstallMode(
            device: selectedDevice,
            idfExportPath: "/tmp/export-idf.sh"
        )
        XCTAssertTrue(ready)
        XCTAssertTrue(deploymentRunner.commands().isEmpty)

        let command = try XCTUnwrap(probeRunner.commands().only)
        XCTAssertEqual(command.executable.path, "/bin/sh")
        XCTAssertEqual(command.workingDirectory, projectRoot)
        XCTAssertEqual(command.displayName, "检测 StickS3 安装模式")
        XCTAssertEqual(
            command.arguments,
            [
                projectRoot.appendingPathComponent("scripts/probe-rom-mode.sh").path,
                "--export", "/tmp/export-idf.sh",
                "--port", selectedDevice.calloutPath,
                "--serial", "14:C1:9F:D5:3D:5C",
            ]
        )
    }

    func testInstallModeProbeReturnsFalseWhenNormalFirmwareIsRunning() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let probeRunner = RecordingProcessRunner(
            exitCodes: ["检测 StickS3 安装模式": 10]
        )
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: RecordingProcessRunner(),
            probeRunner: probeRunner,
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        let ready = try await coordinator.probeInstallMode(
            device: selectedDevice,
            idfExportPath: "/tmp/export-idf.sh"
        )
        XCTAssertFalse(ready)
    }

    func testInstallModeProbeThrowsForAProbeInfrastructureFailure() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: RecordingProcessRunner(),
            probeRunner: RecordingProcessRunner(
                exitCodes: ["检测 StickS3 安装模式": 13]
            ),
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        do {
            _ = try await coordinator.probeInstallMode(
                device: selectedDevice,
                idfExportPath: "/tmp/export-idf.sh"
            )
            XCTFail("expected a busy serial port to be reported as a probe failure")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .deviceInstallModeProbeFailed(13))
            XCTAssertTrue(error.localizedDescription.contains("其他程序占用"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInstallModeProbeRejectsIdentityChangeAfterTheProbe() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let changedDevice = device(serialNumber: "different-serial")
        let discovery = SequencedSerialDiscovery(
            snapshots: [[selectedDevice], [changedDevice]]
        )
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: RecordingProcessRunner(),
            probeRunner: RecordingProcessRunner(),
            serialDiscovery: discovery
        )

        do {
            _ = try await coordinator.probeInstallMode(
                device: selectedDevice,
                idfExportPath: "/tmp/export-idf.sh"
            )
            XCTFail("expected changed USB identity to invalidate the probe")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .deviceChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDeploymentRechecksInstallModeImmediatelyBeforeFlash() async throws {
        let selectedDevice = device(serialNumber: "stable-serial")
        let deploymentRunner = RecordingProcessRunner()
        let probeRunner = RecordingProcessRunner(
            exitCodes: ["检测 StickS3 安装模式": 10]
        )
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: deploymentRunner,
            probeRunner: probeRunner,
            serialDiscovery: FixedSerialDiscovery(devices: [selectedDevice])
        )

        do {
            _ = try await coordinator.deploy(
                configuration: configuration,
                device: selectedDevice,
                idfExportPath: "/tmp/export-idf.sh",
                onStep: { _, _ in },
                onOutput: { _ in }
            )
            XCTFail("expected deployment to stop outside install mode")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .deviceNotInInstallMode)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(
            deploymentRunner.commands().contains { $0.displayName == "烧录 StickS3" }
        )
        XCTAssertEqual(probeRunner.commands().map(\.displayName), ["检测 StickS3 安装模式"])
    }

    func testPythonRuntimeInstallerUsesPinnedRepositoryScript() async throws {
        let runner = RecordingProcessRunner()
        let coordinator = DeploymentCoordinator(
            projectRoot: projectRoot,
            configurationStore: RecordingConfigurationStore(),
            runner: runner,
            serialDiscovery: FixedSerialDiscovery(devices: [])
        )

        try await coordinator.installPythonRuntime(onOutput: { _ in })

        let command = try XCTUnwrap(runner.commands().only)
        XCTAssertEqual(command.executable.path, "/bin/sh")
        XCTAssertEqual(
            command.arguments,
            [projectRoot.appendingPathComponent("scripts/install-python-runtime.sh").path]
        )
        XCTAssertEqual(command.displayName, "准备 Python 运行组件")
    }

    private let projectRoot = URL(fileURLWithPath: "/tmp/VibeStickCoordinatorTests", isDirectory: true)

    private var configuration: SetupConfiguration {
        SetupConfiguration(
            wifiSSID: "Test WiFi",
            wifiPassword: "test-password",
            bridgeHost: "192.168.1.10",
            asrProvider: .custom,
            asrBaseURL: "https://asr.example.test/v1",
            asrAPIKey: "asr-secret",
            asrModel: "whisper-test-model",
            asrLanguage: "zh"
        )
    }

    private func device(serialNumber: String) -> SerialDevice {
        SerialDevice(
            id: 42,
            calloutPath: "/dev/cu.usbmodem-test",
            name: "M5Stack StickS3",
            vendorID: 0x303A,
            productID: 0x1001,
            serialNumber: serialNumber
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private struct DeploymentEvent: Equatable, Sendable {
    let phase: DeploymentPhase
    let state: StepState
}

private final class DeploymentEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DeploymentEvent] = []

    func append(_ phase: DeploymentPhase, _ state: StepState) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(DeploymentEvent(phase: phase, state: state))
    }

    func events() -> [DeploymentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class RecordingConfigurationStore: ConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var nonces: [String?] = []

    func load() throws -> SetupConfiguration { SetupConfiguration() }

    func save(
        _ configuration: SetupConfiguration,
        deploymentNonce: String?
    ) throws -> SetupConfiguration {
        lock.lock()
        defer { lock.unlock() }
        nonces.append(deploymentNonce)
        return configuration
    }

    func resolvedASRAPIKey(for configuration: SetupConfiguration) throws -> String {
        configuration.asrAPIKey
    }

    func redactionSecrets(for configuration: SetupConfiguration) throws -> [String] {
        [configuration.wifiPassword, configuration.asrAPIKey]
    }

    func savedNonces() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return nonces
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [CommandSpec] = []
    private var remainingExitCodes: [String: [Int32]]

    init(exitCodes: [String: Int32] = [:]) {
        remainingExitCodes = exitCodes.mapValues { [$0] }
    }

    init(exitCodeSequences: [String: [Int32]]) {
        remainingExitCodes = exitCodeSequences
    }

    func run(
        _ command: CommandSpec,
        redacting secrets: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        let exitCode = lock.withLock {
            recordedCommands.append(command)
            guard var sequence = remainingExitCodes[command.displayName],
                  !sequence.isEmpty else { return Int32(0) }
            let result = sequence.removeFirst()
            remainingExitCodes[command.displayName] = sequence
            return result
        }
        return CommandResult(exitCode: exitCode)
    }

    func cancel() {}

    func commands() -> [CommandSpec] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }
}

private struct FixedSerialDiscovery: SerialDeviceDiscovering, Sendable {
    let devices: [SerialDevice]

    func discover() -> [SerialDevice] { devices }
}

private final class SequencedSerialDiscovery: SerialDeviceDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[SerialDevice]]

    init(snapshots: [[SerialDevice]]) {
        self.snapshots = snapshots
    }

    func discover() -> [SerialDevice] {
        lock.withLock {
            guard snapshots.count > 1 else { return snapshots.first ?? [] }
            return snapshots.removeFirst()
        }
    }
}
