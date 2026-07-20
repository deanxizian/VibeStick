import SwiftUI
import VibeStickSetupCore

@MainActor
struct InstallSetupStepView: View {
    @Bindable var store: SetupStore
    let onBack: () -> Void
    let onInstall: (SerialDevice) -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var showDetails = true

    var body: some View {
        StableWizardScrollView(maximumContentWidth: 820) {
            VStack(alignment: .leading, spacing: 22) {
                SetupHero(
                    title: heroTitle,
                    subtitle: heroSubtitle,
                    systemImage: heroIcon
                )

                if store.recoveryRequired, !store.isBusy {
                    Label(
                        "写入曾被中断，StickS3 可能暂时无法启动。请保持 USB 连接，重新安装即可恢复。",
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if store.isInitializing {
                    initializingCard
                } else if !store.setupReady {
                    unavailableCard
                } else if store.deploymentComplete {
                    completionCard
                } else if store.isBusy {
                    progressCard
                } else {
                    readyCard
                }

                if !store.isInitializing, store.setupReady {
                    DisclosureGroup("技术详情", isExpanded: $showDetails) {
                        VStack(spacing: 0) {
                            ForEach(store.deploymentSteps) { step in
                                DeploymentStepCompactRow(step: step)
                                if step.id != store.deploymentSteps.last?.id { Divider() }
                            }
                            HStack {
                                Spacer()
                                Button("查看完整日志") { openWindow(id: "activity-log") }
                            }
                            .padding(.top, 10)
                        }
                        .padding(.top, 8)
                    }
                    .font(.callout)
                }

                actionBar
            }
        }
        .onChange(of: store.lastError) { _, error in
            if error != nil { showDetails = true }
        }
        .task {
            var pollCount = 0
            while !Task.isCancelled {
                if !store.isInitializing,
                   store.setupReady,
                   !store.isBusy,
                   !store.deploymentComplete {
                    await store.refreshDevices()
                    pollCount += 1
                    if !store.swiftToolchainReady, pollCount.isMultiple(of: 4) {
                        await store.refreshSystem()
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .task(id: store.deviceInstallModeProbeID) {
            guard !store.isBusy, !store.deploymentComplete else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            for attempt in 0..<10 {
                guard !Task.isCancelled, !store.isBusy else { return }
                await store.checkSelectedDeviceInstallMode()
                guard store.deviceInstallModeStatus == .needsInstallMode,
                      attempt < 9 else { return }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private var heroTitle: String {
        if store.isInitializing { return "正在准备安装器" }
        if store.deploymentComplete { return "安装完成" }
        if store.isBusy { return "正在安装 VibeStick" }
        if store.recoveryRequired { return "恢复 StickS3" }
        return "准备安装"
    }

    private var heroSubtitle: String {
        if store.isInitializing {
            return "正在读取已保存的配置和 Mac 环境，请稍候。"
        }
        if store.deploymentComplete {
            return "StickS3 固件、Mac 连接服务和联网检查都已完成。"
        }
        if store.isBusy {
            return "请保持 Mac 联网，请不要拔掉 USB‑C 数据线。"
        }
        return "接下来由安装器自动准备组件、写入设备并检查连接。"
    }

    private var heroIcon: String {
        if store.isInitializing { return "hourglass" }
        return store.deploymentComplete ? "checkmark.circle.fill" : "wand.and.stars"
    }

    private var initializingCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在检查安装环境…")
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var unavailableCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("安装器资源暂时没有准备好", systemImage: "folder.badge.questionmark")
                    .font(.headline)
                Text("请重新尝试；如果仍然失败，请重新下载或重新构建安装器。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重新尝试") { store.retryInitialization() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var readyCard: some View {
        GroupBox {
            VStack(spacing: 0) {
                ReadyRow(
                    title: "Wi-Fi 信息",
                    detail: "已填写",
                    ready: store.issues.allSatisfy {
                        ![ConfigurationField.wifiSSID, .wifiPassword, .bridgeHost].contains($0.field)
                    }
                )
                Divider()
                ReadyRow(
                    title: "语音输入 API",
                    detail: store.configuration.asrProvider == .disabled
                        ? "未启用"
                        : (store.asrConnectionVerified ? "检测通过" : "需要返回上一步检测"),
                    ready: store.asrConnectionVerified
                )
                Divider()
                ReadyRow(
                    title: "扬声器音量",
                    detail: "\(store.configuration.speakerVolume)%",
                    ready: !store.issues.contains { $0.field == .speakerVolume }
                )
                Divider()
                ReadyRow(
                    title: "StickS3",
                    detail: installModeDetail,
                    ready: store.installModeRequirementSatisfied
                )
                Divider()
                ReadyRow(
                    title: "安装组件",
                    detail: installationComponentsDetail,
                    ready: store.swiftToolchainReady
                )
            }
            .padding(8)
        }
    }

    private var progressCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    ProgressView().controlSize(.small)
                    Text(store.operationTitle.isEmpty ? "正在处理" : store.operationTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                ProgressView(value: progressValue)
                Text(progressHint)
                    .font(.callout)
                    .foregroundStyle(store.isFlashing || isWaitingForDevice ? .orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var completionCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("VibeStick 已经可以使用")
                    .font(.title3.weight(.semibold))
                Text("如果屏幕仍是黑的，短按一次侧面电源键即可唤醒。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    Label("Wi‑Fi", systemImage: "checkmark.circle.fill")
                    Label("StickS3", systemImage: "checkmark.circle.fill")
                    Label("Mac 服务", systemImage: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if !store.isBusy,
               !store.isInitializing,
               store.setupReady,
               !store.deploymentComplete {
                Button("返回") { onBack() }
            }
            Spacer()
            if store.isInitializing {
                ProgressView().controlSize(.small)
                Text("正在读取环境")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !store.setupReady {
                Button("重新尝试") { store.retryInitialization() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if store.isBusy {
                EmptyView()
            } else if store.deploymentComplete {
                Button("返回首页") { onBack() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else if !store.swiftToolchainReady {
                Button("准备必要组件") {
                    store.requestCommandLineToolsInstallation()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(store.recoveryRequired ? "重新安装并恢复" : "开始安装") {
                    if let device = store.selectedDevice { onInstall(device) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    store.selectedDevice?.isEspressifUSB != true
                        || !store.installModeRequirementSatisfied
                )
            }
        }
    }

    private var progressValue: Double {
        let completed = store.deploymentSteps.reduce(into: 0) { count, step in
            if step.state == .succeeded { count += 1 }
        }
        return Double(completed) / Double(max(store.deploymentSteps.count, 1))
    }

    private var installationComponentsDetail: String {
        if store.isInitializing { return "正在检查" }
        if !store.swiftToolchainReady { return "需要准备 Apple 系统组件" }
        if !store.pythonRuntimeReady { return "Mac 运行组件将在安装时自动下载" }
        if store.snapshot.idfExportPath == nil { return "设备组件将在安装时自动下载" }
        return "已经准备好"
    }

    private var installModeDetail: String {
        guard let device = store.selectedDevice else { return "尚未连接" }
        switch store.deviceInstallModeStatus {
        case .ready: return "已进入安装模式"
        case .checking: return "正在确认安装模式"
        case .needsInstallMode: return "请先长按电源键进入安装模式"
        case .unavailable: return "将在准备组件后自动确认"
        case let .failed(message): return message
        case .unknown: return device.name
        }
    }

    private var progressHint: String {
        if store.isFlashing { return "正在写入设备，请不要取消安装或拔掉数据线。" }
        if isWaitingForDevice {
            return "请短按一次侧面电源键启动 StickS3。"
        }
        if store.snapshot.idfExportPath == nil { return "首次安装下载较大，耗时取决于网络速度。" }
        return "安装器会自动继续，无需操作。"
    }

    private var isWaitingForDevice: Bool {
        store.deploymentSteps.first(where: { $0.phase == .waitForDevice })?.state == .running
    }
}
