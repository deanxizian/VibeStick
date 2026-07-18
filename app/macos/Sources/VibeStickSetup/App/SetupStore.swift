import Foundation
import Observation
import VibeStickSetupCore
import VibeStickSetupPlatform

enum DeviceInstallModeStatus: Equatable {
    case unknown
    case checking
    case ready
    case needsInstallMode
    case unavailable
    case failed(String)
}

@MainActor
@Observable
final class SetupStore {
    static let shared = SetupStore()
    static let asrVerificationRequiredMessage = "请先点击“检测 API”，确认语音输入服务可以使用。"
    private static let flashJournalKey = "VibeStickSetup.flashInProgress"

    var configuration = SetupConfiguration()
    var snapshot = SystemSnapshot.empty
    var selectedDeviceID: UInt64?
    var confirmedStickS3 = false
    var deploymentSteps = DeploymentPhase.allCases.map { DeploymentStep(phase: $0) }
    var logText = ""
    var diagnosticRecords: [DiagnosticRecord] = []
    var isInitializing = true
    private(set) var initializationFailed = false
    var isBusy = false
    var operationTitle = ""
    var lastError: String?
    var notice: String?
    var deploymentComplete = false
    var recoveryRequired = false
    var deviceInstallModeStatus: DeviceInstallModeStatus = .unknown
    private(set) var projectRoot: URL?

    private var configurationStore: RepositoryConfigurationStore?
    private var systemProbe: LocalSystemProbe?
    private var serialDiscovery: IOKitSerialDiscovery?
    private var coordinator: DeploymentCoordinator?
    private var runner: FoundationProcessRunner?
    private var operationTask: Task<Void, Never>?
    private var didStart = false
    private var systemRefreshGeneration = 0
    private var deviceRefreshGeneration = 0
    private var deviceInstallModeProbeGeneration = 0
    private var verifiedASRSignature: ASRSignature?
    private var expectedProgrammaticConfiguration: SetupConfiguration?
    private var bridgeHostWasManuallyEdited = false

    var issues: [ConfigurationIssue] {
        ConfigurationValidator.issues(for: configuration)
    }

    var asrIssues: [ConfigurationIssue] {
        let fields: Set<ConfigurationField> = [
            .asrBaseURL,
            .asrAPIKey,
            .asrModel,
            .asrLanguage,
        ]
        return issues.filter { fields.contains($0.field) }
    }

    var selectedDevice: SerialDevice? {
        snapshot.serialDevices.first { $0.id == selectedDeviceID }
    }

    var readyToDeploy: Bool {
        canBeginInstallation
            && confirmedStickS3
            && snapshot.idfExportPath != nil
    }

    var canBeginInstallation: Bool {
        setupReady
            && !isInitializing
            && issues.isEmpty
            && asrConnectionVerified
            && selectedDevice?.isEspressifUSB == true
            && installModeRequirementSatisfied
            && swiftToolchainReady
            && !isBusy
    }

    var installModeRequirementSatisfied: Bool {
        guard selectedDevice?.isEspressifUSB == true else { return false }
        guard snapshot.idfExportPath != nil else { return true }
        return deviceInstallModeStatus == .ready
    }

    var isCheckingDeviceInstallMode: Bool {
        deviceInstallModeStatus == .checking
    }

    var deviceInstallModeProbeID: String {
        let device = selectedDevice
        return [
            String(device?.id ?? 0),
            device?.calloutPath ?? "",
            device?.serialNumber ?? "",
            snapshot.idfExportPath ?? "",
        ].joined(separator: "|")
    }

    var isFlashing: Bool {
        deploymentSteps.first(where: { $0.phase == .flashFirmware })?.state == .running
    }

    var asrConnectionVerified: Bool {
        configuration.asrProvider == .disabled
            || verifiedASRSignature == ASRSignature(configuration)
    }

    var requiredRuntimeReady: Bool {
        pythonRuntimeReady && swiftToolchainReady
    }

    var servicesReady: Bool {
        projectRoot != nil
            && configurationStore != nil
            && systemProbe != nil
            && serialDiscovery != nil
            && coordinator != nil
            && runner != nil
    }

    var setupReady: Bool {
        servicesReady && !initializationFailed
    }

    var pythonRuntimeReady: Bool {
        snapshot.prerequisites.first { $0.kind == .python }?.available == true
    }

    var swiftToolchainReady: Bool {
        snapshot.prerequisites.first { $0.kind == .swift }?.available == true
    }

    init() {
        recoveryRequired = UserDefaults.standard.bool(forKey: Self.flashJournalKey)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task { [weak self] in
            await self?.initialize()
        }
    }

    func retryInitialization() {
        guard !isBusy, !isInitializing else { return }
        isInitializing = true
        initializationFailed = false
        lastError = nil
        Task { [weak self] in
            await self?.initialize()
        }
    }

    private func initialize() async {
        await prepareServices()
        guard servicesReady else {
            initializationFailed = true
            isInitializing = false
            return
        }
        guard await loadConfiguration() else {
            initializationFailed = true
            isInitializing = false
            return
        }
        await refreshSystem()
        initializationFailed = false
        isInitializing = false
    }

    private func prepareServices() async {
        guard configurationStore == nil else { return }
        do {
            let root = try await Task.detached(priority: .userInitiated) {
                try ProjectLocator.locate()
            }.value
            let configStore = RepositoryConfigurationStore(projectRoot: root)
            let processRunner = FoundationProcessRunner()
            let deviceDiscovery = IOKitSerialDiscovery()
            projectRoot = root
            configurationStore = configStore
            serialDiscovery = deviceDiscovery
            systemProbe = LocalSystemProbe(projectRoot: root, serialDiscovery: deviceDiscovery)
            runner = processRunner
            coordinator = DeploymentCoordinator(
                projectRoot: root,
                configurationStore: configStore,
                runner: processRunner
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func loadConfiguration() async -> Bool {
        guard let configurationStore else { return false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try configurationStore.load()
            }.value
            bridgeHostWasManuallyEdited = false
            assignConfiguration(loaded)
            verifiedASRSignature = recoveryRequired && loaded.asrProvider != .disabled
                ? ASRSignature(loaded)
                : nil
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func refreshSystem() async {
        guard let systemProbe else { return }
        systemRefreshGeneration &+= 1
        let generation = systemRefreshGeneration
        let devicesAtStart = deviceRefreshGeneration
        let refreshedSnapshot = await systemProbe.snapshot()
        guard generation == systemRefreshGeneration else { return }
        let previousDevice = selectedDevice
        let previousIDFExportPath = snapshot.idfExportPath
        snapshot = SystemSnapshot(
            networkAddresses: refreshedSnapshot.networkAddresses,
            serialDevices: devicesAtStart == deviceRefreshGeneration
                ? refreshedSnapshot.serialDevices
                : snapshot.serialDevices,
            prerequisites: refreshedSnapshot.prerequisites,
            idfExportPath: refreshedSnapshot.idfExportPath
        )
        reconcileDeviceSelection(previousDevice: previousDevice)
        if previousIDFExportPath != snapshot.idfExportPath {
            invalidateDeviceInstallModeStatus()
        }
        applyAutomaticBridgeHostIfNeeded()
    }

    func refreshDevices() async {
        guard let serialDiscovery else { return }
        deviceRefreshGeneration &+= 1
        let generation = deviceRefreshGeneration
        let devices = await Task.detached(priority: .utility) {
            serialDiscovery.discover()
        }.value
        guard generation == deviceRefreshGeneration else { return }
        let previousDevice = selectedDevice
        snapshot = SystemSnapshot(
            networkAddresses: snapshot.networkAddresses,
            serialDevices: devices,
            prerequisites: snapshot.prerequisites,
            idfExportPath: snapshot.idfExportPath
        )
        reconcileDeviceSelection(previousDevice: previousDevice)
    }

    func deviceSelectionDidChange(from oldValue: UInt64?, to newValue: UInt64?) {
        guard oldValue != newValue else { return }
        confirmedStickS3 = false
        deploymentComplete = false
        invalidateDeviceInstallModeStatus()
    }

    func selectDevice(_ deviceID: UInt64?) {
        let previous = selectedDeviceID
        selectedDeviceID = deviceID
        deviceSelectionDidChange(from: previous, to: deviceID)
    }

    func changeProvider(_ provider: ASRProvider) {
        configuration.applyDefaults(for: provider)
        deploymentComplete = false
        invalidateASRVerification()
    }

    func setBridgeHost(_ value: String) {
        bridgeHostWasManuallyEdited = true
        configuration.bridgeHost = value
    }

    func prepareForAnotherInstallation() {
        guard !isBusy else { return }
        deploymentComplete = false
        confirmedStickS3 = false
        deploymentSteps = DeploymentPhase.allCases.map { DeploymentStep(phase: $0) }
        lastError = nil
        notice = nil
        invalidateDeviceInstallModeStatus()
    }

    func configurationDidChange(from oldValue: SetupConfiguration, to newValue: SetupConfiguration) {
        if expectedProgrammaticConfiguration == newValue {
            expectedProgrammaticConfiguration = nil
            return
        }
        expectedProgrammaticConfiguration = nil
        deploymentComplete = false
        if ASRSignature(oldValue) != ASRSignature(newValue) {
            invalidateASRVerification()
        }
    }

    func validateConfiguration(onSuccess: @escaping @MainActor @Sendable () -> Void) {
        guard !isBusy, !isInitializing else { return }
        guard setupReady, let configurationStore else {
            lastError = "安装器资源尚未准备好，请重新尝试；仍失败时请重新下载安装器。"
            return
        }
        guard issues.isEmpty else {
            lastError = issues.first?.message
            return
        }
        guard asrConnectionVerified else {
            lastError = Self.asrVerificationRequiredMessage
            return
        }
        let configurationSnapshot = configuration
        let wasASRVerified = asrConnectionVerified
        resetOperation(title: "正在安全保存配置")

        operationTask = Task { [weak self] in
            guard let self else { return }
            var validationSucceeded = false
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    try configurationStore.save(configurationSnapshot)
                }.value
                try Task.checkCancellation()
                assignConfiguration(saved)

                if saved.asrProvider == .disabled {
                    verifiedASRSignature = nil
                } else if wasASRVerified {
                    verifiedASRSignature = ASRSignature(saved)
                }

                notice = nil
                lastError = nil
                validationSucceeded = true
            } catch is CancellationError {
                notice = "验证已取消。"
            } catch SetupCoreError.cancelled {
                notice = "验证已取消。"
            } catch {
                verifiedASRSignature = nil
                lastError = error.localizedDescription
            }
            isBusy = false
            operationTitle = ""
            if validationSucceeded { onSuccess() }
        }
    }

    func testASRConnection() {
        guard !isBusy, !isInitializing else { return }
        guard setupReady, let coordinator else {
            lastError = "安装器资源尚未准备好，请重新尝试；仍失败时请重新下载安装器。"
            return
        }
        if configuration.asrProvider == .disabled {
            verifiedASRSignature = nil
            lastError = nil
            return
        }
        guard asrIssues.isEmpty else {
            verifiedASRSignature = nil
            lastError = asrIssues.first?.message
            return
        }

        let configurationSnapshot = configuration
        let signature = ASRSignature(configurationSnapshot)
        resetOperation(title: "正在检测语音 API")

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.testASR(configuration: configurationSnapshot)
                try Task.checkCancellation()
                guard ASRSignature(configuration) == signature else {
                    verifiedASRSignature = nil
                    lastError = "语音 API 设置已变化，请重新检测。"
                    isBusy = false
                    operationTitle = ""
                    return
                }
                verifiedASRSignature = signature
                lastError = nil
                notice = nil
            } catch is CancellationError {
                verifiedASRSignature = nil
                notice = "语音 API 检测已取消。"
            } catch SetupCoreError.cancelled {
                verifiedASRSignature = nil
                notice = "语音 API 检测已取消。"
            } catch {
                verifiedASRSignature = nil
                lastError = error.localizedDescription
            }
            isBusy = false
            operationTitle = ""
        }
    }

    func checkSelectedDeviceInstallMode() async {
        guard !isBusy, !isInitializing, setupReady,
              !isCheckingDeviceInstallMode,
              let coordinator,
              let device = selectedDevice,
              device.isEspressifUSB else {
            if selectedDevice?.isEspressifUSB != true {
                deviceInstallModeStatus = .unknown
            }
            return
        }
        guard let idfExportPath = snapshot.idfExportPath else {
            deviceInstallModeStatus = .unavailable
            return
        }

        deviceInstallModeProbeGeneration &+= 1
        let generation = deviceInstallModeProbeGeneration
        deviceInstallModeStatus = .checking
        do {
            let isReady = try await coordinator.probeInstallMode(
                device: device,
                idfExportPath: idfExportPath
            )
            try Task.checkCancellation()
            guard generation == deviceInstallModeProbeGeneration,
                  selectedDevice == device,
                  snapshot.idfExportPath == idfExportPath else { return }
            deviceInstallModeStatus = isReady ? .ready : .needsInstallMode
        } catch is CancellationError {
            if generation == deviceInstallModeProbeGeneration {
                deviceInstallModeStatus = .unknown
            }
        } catch SetupCoreError.cancelled {
            if generation == deviceInstallModeProbeGeneration {
                deviceInstallModeStatus = .unknown
            }
        } catch SetupCoreError.deviceChanged {
            if generation == deviceInstallModeProbeGeneration {
                deviceInstallModeStatus = .unknown
                await refreshDevices()
            }
        } catch {
            guard generation == deviceInstallModeProbeGeneration,
                  selectedDevice == device else { return }
            deviceInstallModeStatus = .failed(error.localizedDescription)
        }
    }

    func explainInstallationBlocker() {
        if isInitializing {
            lastError = "安装器仍在读取安装环境，请稍候。"
        } else if !setupReady {
            lastError = "安装器资源尚未准备好，请重新尝试；仍失败时请重新下载安装器。"
        } else if let issue = issues.first {
            lastError = issue.message
        } else if !asrConnectionVerified {
            lastError = "请先返回上一步验证语音服务。"
        } else if !swiftToolchainReady {
            lastError = "需要先安装 Apple 命令行工具。点击“准备必要组件”，然后按系统提示完成。"
        } else if selectedDevice == nil {
            lastError = "还没有找到 StickS3，请连接 USB-C 数据线。"
        } else if selectedDevice?.isEspressifUSB != true {
            lastError = "当前设备不是可识别的 ESP32-S3，请重新连接 StickS3。"
        } else if snapshot.idfExportPath != nil, !installModeRequirementSatisfied {
            switch deviceInstallModeStatus {
            case .checking:
                lastError = "正在确认 StickS3 是否已进入安装模式，请稍候。"
            case .needsInstallMode:
                lastError = "StickS3 尚未进入安装模式。请按页面提示长按侧面电源键。"
            case let .failed(message):
                lastError = message
            case .unknown, .unavailable, .ready:
                lastError = "请先等待安装器确认 StickS3 已进入安装模式。"
            }
        } else if !confirmedStickS3 {
            lastError = "请先确认即将安装的是你的 StickS3。"
        }
    }

    func installEverything(expectedDevice: SerialDevice) {
        guard canBeginInstallation,
              confirmedStickS3,
              let coordinator,
              let device = selectedDevice,
              device == expectedDevice else {
            explainInstallationBlocker()
            if selectedDevice != expectedDevice {
                lastError = SetupCoreError.deviceChanged.localizedDescription
            }
            return
        }
        let configurationSnapshot = configuration
        resetOperation(title: "正在准备安装")
        deploymentComplete = false
        deploymentSteps = DeploymentPhase.allCases.map { DeploymentStep(phase: $0) }

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !pythonRuntimeReady {
                    operationTitle = "正在准备 Mac 运行组件"
                    appendLog("正在下载经过校验的 Python 运行组件。\n")
                    try await coordinator.installPythonRuntime(
                        onOutput: { [weak self] output in
                            Task { @MainActor in self?.appendLog(output) }
                        }
                    )
                    await refreshSystem()
                    guard selectedDevice == device else {
                        throw SetupCoreError.deviceChanged
                    }
                    guard pythonRuntimeReady else {
                        throw SetupCoreError.malformedConfiguration("Python 运行组件安装后仍不可用")
                    }
                }

                var exportPath = snapshot.idfExportPath
                if exportPath == nil {
                    operationTitle = "正在下载安装组件（约 1 GB）"
                    appendLog("首次安装需要下载 ESP32-S3 安装组件，请保持网络连接。\n")
                    try await coordinator.installToolchain(
                        onOutput: { [weak self] output in
                            Task { @MainActor in self?.appendLog(output) }
                        }
                    )
                    await refreshSystem()
                    guard selectedDevice == device else {
                        throw SetupCoreError.deviceChanged
                    }
                    guard let installedExportPath = snapshot.idfExportPath else {
                        throw SetupCoreError.malformedConfiguration("安装组件完成后仍未找到 ESP-IDF")
                    }
                    exportPath = installedExportPath
                }

                guard let exportPath else {
                    throw SetupCoreError.malformedConfiguration("缺少安装组件")
                }
                operationTitle = "正在安装 VibeStick"
                let saved = try await coordinator.deploy(
                    configuration: configurationSnapshot,
                    device: device,
                    idfExportPath: exportPath,
                    onStep: { [weak self] phase, state in
                        await self?.setStep(phase, state: state)
                    },
                    onOutput: { [weak self] output in
                        Task { @MainActor in self?.appendLog(output) }
                    }
                )
                assignConfiguration(saved)
                if saved.asrProvider != .disabled {
                    verifiedASRSignature = ASRSignature(saved)
                }
                await refreshSystem()
                deploymentComplete = true
                notice = nil
                lastError = nil
                invalidateDeviceInstallModeStatus()
            } catch is CancellationError {
                markCancelled()
            } catch SetupCoreError.cancelled {
                markCancelled()
            } catch {
                lastError = error.localizedDescription
            }
            isBusy = false
            operationTitle = ""
        }
    }

    func runDoctor() {
        guard !isBusy, !isInitializing, setupReady, let coordinator else {
            lastError = "安装环境尚未准备好，暂时不能运行检查。"
            return
        }
        resetOperation(title: "正在运行诊断")
        diagnosticRecords = []
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.runDoctor(
                    configuration: configuration,
                    onOutput: { [weak self] output in
                        Task { @MainActor in self?.appendLog(output) }
                    }
                )
                diagnosticRecords = DoctorOutputParser.parse(result.output)
                guard result.exitCode == 0 else {
                    throw SetupCoreError.commandFailed("运行 VibeStick 诊断", result.exitCode)
                }
                notice = "诊断完成。"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            isBusy = false
            operationTitle = ""
            await refreshSystem()
        }
    }

    func requestCommandLineToolsInstallation() {
        guard !isInitializing, setupReady else {
            lastError = "请先等待安装器完成环境检查。"
            return
        }
        guard !swiftToolchainReady else {
            Task { await refreshSystem() }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        do {
            try process.run()
            notice = "请在系统弹窗中完成 Apple 命令行工具安装，然后点“重新检查”。"
            lastError = nil
        } catch {
            lastError = "无法打开 Apple 命令行工具安装程序，请在终端运行 xcode-select --install。"
        }
    }

    func cancelOperation() {
        if deploymentSteps.first(where: { $0.phase == .flashFirmware })?.state == .running {
            setRecoveryRequired(true)
        }
        coordinator?.cancel()
        runner?.cancel()
        operationTask?.cancel()
    }

    func cancelAndWaitForTermination() async {
        let task = operationTask
        cancelOperation()
        await task?.value
    }

    func clearLog() {
        guard !isBusy else { return }
        logText = ""
        diagnosticRecords = []
    }

    private func resetOperation(title: String) {
        isBusy = true
        operationTitle = title
        lastError = nil
        notice = nil
        logText = ""
    }

    private func setStep(_ phase: DeploymentPhase, state: StepState) {
        guard let index = deploymentSteps.firstIndex(where: { $0.phase == phase }) else { return }
        deploymentSteps[index].state = state
        if state == .running {
            operationTitle = friendlyProgressTitle(for: phase)
        }
        if phase == .flashFirmware {
            switch state {
            case .running:
                setRecoveryRequired(true)
            case .succeeded:
                setRecoveryRequired(false)
            case .pending, .failed:
                break
            }
        }
    }

    private func appendLog(_ output: String) {
        let maximumCharacters = 1_000_000
        logText.append(output)
        if logText.count > maximumCharacters {
            logText.removeFirst(logText.count - maximumCharacters)
        }
    }

    private func markCancelled() {
        if recoveryRequired {
            lastError = "写入被中断，StickS3 可能暂时无法启动。保持 USB 连接，重新安装即可恢复。"
        } else {
            notice = "操作已取消。"
        }
    }

    private func setRecoveryRequired(_ required: Bool) {
        recoveryRequired = required
        UserDefaults.standard.set(required, forKey: Self.flashJournalKey)
    }

    private func friendlyProgressTitle(for phase: DeploymentPhase) -> String {
        switch phase {
        case .saveConfiguration: "正在准备安装"
        case .buildFirmware: "正在准备设备软件"
        case .installBridge: "正在启动 Mac 连接服务"
        case .flashFirmware: "正在写入 StickS3，请勿拔线"
        case .waitForDevice: "正在等待 StickS3 联网"
        case .verify: "正在完成最后检查"
        }
    }

    private func reconcileDeviceSelection(previousDevice: SerialDevice?) {
        let existingStillPresent = snapshot.serialDevices.contains { $0.id == selectedDeviceID }
        if !existingStillPresent {
            let supported = snapshot.serialDevices.filter(\.isEspressifUSB)
            selectedDeviceID = supported.count == 1 ? supported[0].id : nil
        }
        if previousDevice != selectedDevice {
            confirmedStickS3 = false
            deploymentComplete = false
            invalidateDeviceInstallModeStatus()
        }
    }

    private func invalidateASRVerification() {
        verifiedASRSignature = nil
    }

    private func invalidateDeviceInstallModeStatus() {
        deviceInstallModeProbeGeneration &+= 1
        deviceInstallModeStatus = .unknown
    }

    private func applyAutomaticBridgeHostIfNeeded() {
        guard !bridgeHostWasManuallyEdited,
              let preferredAddress = snapshot.networkAddresses.first,
              configuration.bridgeHost != preferredAddress.address else { return }
        var updated = configuration
        updated.bridgeHost = preferredAddress.address
        assignConfiguration(updated)
    }

    private func assignConfiguration(_ value: SetupConfiguration) {
        expectedProgrammaticConfiguration = value
        configuration = value
    }
}

private struct ASRSignature: Equatable {
    let provider: ASRProvider
    let baseURL: String
    let apiKey: String
    let hasStoredAPIKey: Bool
    let model: String
    let language: String

    init(_ configuration: SetupConfiguration) {
        provider = configuration.asrProvider
        baseURL = configuration.asrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = configuration.asrAPIKey
        hasStoredAPIKey = configuration.hasStoredAPIKey
        model = configuration.asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        language = configuration.asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
