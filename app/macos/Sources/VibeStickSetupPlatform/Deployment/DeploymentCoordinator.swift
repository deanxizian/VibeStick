import Foundation
import VibeStickSetupCore

public final class DeploymentCoordinator: @unchecked Sendable {
    private let projectRoot: URL
    private let configurationStore: any ConfigurationStoring
    private let runner: any ProcessRunning
    private let probeRunner: any ProcessRunning
    private let serialDiscovery: any SerialDeviceDiscovering
    private let asrTester: ASRConnectionTester

    public init(
        projectRoot: URL,
        configurationStore: any ConfigurationStoring,
        runner: any ProcessRunning,
        probeRunner: (any ProcessRunning)? = nil,
        serialDiscovery: any SerialDeviceDiscovering = IOKitSerialDiscovery(),
        asrTester: ASRConnectionTester = ASRConnectionTester()
    ) {
        self.projectRoot = projectRoot
        self.configurationStore = configurationStore
        self.runner = runner
        self.probeRunner = probeRunner ?? FoundationProcessRunner()
        self.serialDiscovery = serialDiscovery
        self.asrTester = asrTester
    }

    public func deploy(
        configuration: SetupConfiguration,
        device: SerialDevice,
        idfExportPath: String,
        onStep: @escaping @Sendable (DeploymentPhase, StepState) async -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> SetupConfiguration {
        var currentPhase = DeploymentPhase.saveConfiguration
        do {
            await onStep(currentPhase, .running)
            let deploymentNonce = UUID().uuidString.lowercased()
            let saved = try configurationStore.save(
                configuration,
                deploymentNonce: deploymentNonce
            )
            let secrets = try configurationStore.redactionSecrets(for: configuration)
            await onStep(currentPhase, .succeeded)

            currentPhase = .buildFirmware
            try await run(
                command: shellCommand(
                    script: "scripts/run-idf.sh",
                    arguments: ["--export", idfExportPath, "build"],
                    workingDirectory: projectRoot.appendingPathComponent("firmware/sticks3"),
                    displayName: "构建固件"
                ),
                phase: currentPhase,
                secrets: secrets,
                onStep: onStep,
                onOutput: onOutput
            )

            currentPhase = .installBridge
            try await run(
                command: shellCommand(
                    script: "scripts/install.sh",
                    arguments: [],
                    workingDirectory: projectRoot,
                    displayName: "安装 Mac Bridge"
                ),
                phase: currentPhase,
                secrets: secrets,
                onStep: onStep,
                onOutput: onOutput
            )

            currentPhase = .flashFirmware
            guard serialDiscovery.discover().contains(device) else {
                throw SetupCoreError.deviceChanged
            }
            guard try await probeInstallMode(device: device, idfExportPath: idfExportPath) else {
                throw SetupCoreError.deviceNotInInstallMode
            }
            try await run(
                command: shellCommand(
                    script: "scripts/run-idf.sh",
                    arguments: ["--export", idfExportPath, "-p", device.calloutPath, "flash"],
                    workingDirectory: projectRoot.appendingPathComponent("firmware/sticks3"),
                    displayName: "烧录 StickS3"
                ),
                phase: currentPhase,
                secrets: secrets,
                onStep: onStep,
                onOutput: onOutput
            )

            currentPhase = .waitForDevice
            try await startAndWaitForDevice(
                device: device,
                idfExportPath: idfExportPath,
                deploymentNonce: deploymentNonce,
                phase: currentPhase,
                secrets: secrets,
                onStep: onStep,
                onOutput: onOutput
            )

            currentPhase = .verify
            try await run(
                command: shellCommand(
                    script: "scripts/doctor.sh",
                    arguments: [],
                    workingDirectory: projectRoot,
                    displayName: "运行 VibeStick 诊断"
                ),
                phase: currentPhase,
                secrets: secrets,
                onStep: onStep,
                onOutput: onOutput
            )
            return saved
        } catch {
            await onStep(currentPhase, .failed(error.localizedDescription))
            throw error
        }
    }

    public func runDoctor(
        configuration: SetupConfiguration,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        let secrets = try configurationStore.redactionSecrets(for: configuration)
        let command = shellCommand(
            script: "scripts/doctor.sh",
            arguments: [],
            workingDirectory: projectRoot,
            displayName: "运行 VibeStick 诊断"
        )
        let result = try await runner.run(command, redacting: secrets, onOutput: onOutput)
        return result
    }

    public func testASR(configuration: SetupConfiguration) async throws {
        let apiKey = try configurationStore.resolvedASRAPIKey(for: configuration)
        try await asrTester.test(configuration: configuration, apiKey: apiKey)
    }

    /// Performs a read-only ROM sync against the exact USB device selected by
    /// the user. `false` means the StickS3 is present but running normal
    /// firmware; identity, security, and transport failures are thrown.
    public func probeInstallMode(
        device: SerialDevice,
        idfExportPath: String
    ) async throws -> Bool {
        guard let serialNumber = device.serialNumber,
              !normalizedSerialNumber(serialNumber).isEmpty,
              device.vendorID == 0x303A,
              device.productID == 0x1001,
              rediscoveredDeviceMatches(device)
        else {
            throw SetupCoreError.deviceChanged
        }

        let command = shellCommand(
            script: "scripts/probe-rom-mode.sh",
            arguments: [
                "--export", idfExportPath,
                "--port", device.calloutPath,
                "--serial", serialNumber,
            ],
            workingDirectory: projectRoot,
            displayName: "检测 StickS3 安装模式"
        )
        let result = try await probeRunner.run(command, redacting: [], onOutput: { _ in })

        guard rediscoveredDeviceMatches(device) else {
            throw SetupCoreError.deviceChanged
        }
        switch result.exitCode {
        case 0:
            return true
        case 10:
            return false
        default:
            throw SetupCoreError.deviceInstallModeProbeFailed(result.exitCode)
        }
    }

    public func installToolchain(onOutput: @escaping @Sendable (String) -> Void) async throws {
        let command = shellCommand(
            script: "scripts/install-esp-idf.sh",
            arguments: [],
            workingDirectory: projectRoot,
            displayName: "安装 ESP-IDF 5.5.1"
        )
        let result = try await runner.run(command, redacting: [], onOutput: onOutput)
        guard result.exitCode == 0 else { throw SetupCoreError.commandFailed(command.displayName, result.exitCode) }
    }

    public func installPythonRuntime(onOutput: @escaping @Sendable (String) -> Void) async throws {
        let command = shellCommand(
            script: "scripts/install-python-runtime.sh",
            arguments: [],
            workingDirectory: projectRoot,
            displayName: "准备 Python 运行组件"
        )
        let result = try await runner.run(command, redacting: [], onOutput: onOutput)
        guard result.exitCode == 0 else {
            throw SetupCoreError.commandFailed(command.displayName, result.exitCode)
        }
    }

    public func cancel() {
        runner.cancel()
    }

    private func rediscoveredDeviceMatches(_ expected: SerialDevice) -> Bool {
        let expectedSerial = normalizedSerialNumber(expected.serialNumber ?? "")
        return serialDiscovery.discover().contains { candidate in
            candidate.calloutPath == expected.calloutPath
                && candidate.vendorID == expected.vendorID
                && candidate.productID == expected.productID
                && normalizedSerialNumber(candidate.serialNumber ?? "") == expectedSerial
        }
    }

    private func normalizedSerialNumber(_ serialNumber: String) -> String {
        serialNumber
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map { String($0).lowercased() }
            .joined()
    }

    private func run(
        command: CommandSpec,
        phase: DeploymentPhase,
        secrets: [String],
        onStep: @escaping @Sendable (DeploymentPhase, StepState) async -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        await onStep(phase, .running)
        onOutput("\n▶︎ \(command.displayName)\n")
        let result = try await runner.run(command, redacting: secrets, onOutput: onOutput)
        guard result.exitCode == 0 else { throw SetupCoreError.commandFailed(command.displayName, result.exitCode) }
        await onStep(phase, .succeeded)
    }

    private func startAndWaitForDevice(
        device: SerialDevice,
        idfExportPath: String,
        deploymentNonce: String,
        phase: DeploymentPhase,
        secrets: [String],
        onStep: @escaping @Sendable (DeploymentPhase, StepState) async -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        await onStep(phase, .running)

        let startCommand = shellCommand(
            script: "scripts/start-device.sh",
            arguments: ["--export", idfExportPath, "--port", device.calloutPath],
            workingDirectory: projectRoot.appendingPathComponent("firmware/sticks3"),
            displayName: "启动 StickS3"
        )
        onOutput("\n▶︎ \(startCommand.displayName)\n")
        var startFailureDescription: String?
        do {
            let result = try await runner.run(startCommand, redacting: secrets, onOutput: onOutput)
            if result.exitCode != 0 {
                startFailureDescription = SetupCoreError
                    .commandFailed(startCommand.displayName, result.exitCode)
                    .localizedDescription
                onOutput("自动启动没有得到确认，将继续等待设备联网。\n")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch SetupCoreError.cancelled {
            throw SetupCoreError.cancelled
        } catch {
            startFailureDescription = error.localizedDescription
            onOutput("自动启动没有得到确认，将继续等待设备联网。\n")
        }

        let waitCommand = shellCommand(
            script: "scripts/wait-for-device.sh",
            arguments: [
                "--deployment-nonce", deploymentNonce,
                "--timeout", "30",
            ],
            workingDirectory: projectRoot,
            displayName: "等待 StickS3 联网"
        )
        onOutput("\n▶︎ \(waitCommand.displayName)\n")
        while true {
            try Task.checkCancellation()
            let result = try await runner.run(waitCommand, redacting: secrets, onOutput: onOutput)
            if result.exitCode == 0 {
                break
            }
            if result.exitCode == 75 {
                onOutput("设备暂未联网，安装器会继续等待；若屏幕未亮，可短按一次侧面电源键。\n")
                continue
            }
            if let startFailureDescription {
                throw SetupCoreError.deviceStartFailed(startFailureDescription)
            }
            throw SetupCoreError.deviceDidNotComeOnline
        }
        await onStep(phase, .succeeded)
    }

    private func shellCommand(
        script: String,
        arguments: [String],
        workingDirectory: URL,
        displayName: String
    ) -> CommandSpec {
        CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [projectRoot.appendingPathComponent(script).path] + arguments,
            workingDirectory: workingDirectory,
            displayName: displayName
        )
    }
}
