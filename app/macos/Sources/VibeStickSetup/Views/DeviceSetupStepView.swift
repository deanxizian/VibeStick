import SwiftUI
import VibeStickSetupCore

struct DeviceSetupStepView: View {
    @Bindable var store: SetupStore
    let onBack: () -> Void
    let onInstall: (SerialDevice) -> Void

    var body: some View {
        StableWizardScrollView(maximumContentWidth: 720) {
            VStack(alignment: .leading, spacing: 22) {
                SetupHero(
                    title: "连接 StickS3",
                    subtitle: "接好数据线并进入安装模式。安装器会自动寻找兼容设备，最后由你确认它就是 StickS3。",
                    systemImage: "cable.connector"
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 17) {
                        InstructionRow(
                            number: 1,
                            title: "连接数据线",
                            detail: "使用支持数据传输的 USB‑C 线连接 StickS3 和 Mac。"
                        )
                        InstructionRow(
                            number: 2,
                            title: "进入安装模式",
                            detail: "长按侧面电源键，看到指示灯闪烁两次且屏幕熄灭后松开。"
                        )
                        InstructionRow(
                            number: 3,
                            title: "等待自动识别",
                            detail: "通常几秒内就会显示“已进入安装模式”。"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        deviceStatus

                        if supportedDevices.count > 1 {
                            Picker("选择设备", selection: deviceBinding) {
                                ForEach(supportedDevices) { device in
                                    Text(device.name).tag(device.id as UInt64?)
                                }
                            }
                        }

                        HStack {
                            Button("重新检测") {
                                Task {
                                    await store.refreshDevices()
                                    await store.checkSelectedDeviceInstallMode()
                                }
                            }
                            .disabled(
                                store.isBusy
                                    || store.isInitializing
                                    || !store.setupReady
                                    || store.isCheckingDeviceInstallMode
                            )
                            Spacer()
                            Text(environmentSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                if !store.swiftToolchainReady {
                    GroupBox {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("还需要一个 Apple 系统组件")
                                    .fontWeight(.medium)
                                Text("点击准备后，按 macOS 弹窗完成安装；安装器会自动重新检查。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("准备必要组件") {
                                store.requestCommandLineToolsInstallation()
                            }
                            Button("重新检查") {
                                Task { await store.refreshSystem() }
                            }
                            .disabled(store.isInitializing || !store.setupReady)
                        }
                        .padding(8)
                    }
                } else if !store.pythonRuntimeReady {
                    Label("Mac 运行组件会在安装时自动下载，无需手动配置。", systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("返回") { onBack() }
                        .disabled(store.isBusy || store.isInitializing)
                    Spacer()
                    Button("安装到 StickS3") {
                        if let device = store.selectedDevice { onInstall(device) }
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            store.isBusy
                                || store.isInitializing
                                || !store.setupReady
                                || store.selectedDevice?.isEspressifUSB != true
                                || !store.installModeRequirementSatisfied
                                || !store.swiftToolchainReady
                        )
                }

                if store.snapshot.idfExportPath == nil {
                    Text("首次安装会自动下载约 1 GB 的设备组件，可能需要几分钟。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .task {
            var pollCount = 0
            while !Task.isCancelled {
                if !store.isInitializing, store.setupReady, !store.isBusy {
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
            try? await Task.sleep(nanoseconds: 400_000_000)
            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                await store.checkSelectedDeviceInstallMode()
                switch store.deviceInstallModeStatus {
                case .ready, .unavailable, .failed:
                    return
                case .needsInstallMode:
                    if attempt < 9 {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                case .unknown, .checking:
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var deviceStatus: some View {
        if let device = store.selectedDevice, device.isEspressifUSB {
            HStack(spacing: 13) {
                Image(systemName: deviceStatusIcon)
                    .font(.title2)
                    .foregroundStyle(deviceStatusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(deviceStatusTitle)
                        .font(.headline)
                    Text(deviceStatusDetail(for: device))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isCheckingDeviceInstallMode {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            HStack(spacing: 13) {
                Image(systemName: "cable.connector.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在等待 StickS3")
                        .font(.headline)
                    Text("如果一直找不到，请换一根支持数据传输的 USB‑C 线。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    private var supportedDevices: [SerialDevice] {
        store.snapshot.serialDevices.filter(\.isEspressifUSB)
    }

    private var deviceBinding: Binding<UInt64?> {
        Binding(
            get: { store.selectedDeviceID },
            set: { store.selectDevice($0) }
        )
    }

    private var environmentSummary: String {
        if !store.swiftToolchainReady { return "等待 Apple 系统组件" }
        if !store.pythonRuntimeReady { return "Mac 运行组件将自动准备" }
        return store.snapshot.idfExportPath == nil ? "设备组件将在下一步自动准备" : "安装组件已准备好"
    }

    private var deviceStatusIcon: String {
        switch store.deviceInstallModeStatus {
        case .ready: "checkmark.circle.fill"
        case .needsInstallMode: "exclamationmark.circle.fill"
        case .checking: "magnifyingglass.circle"
        case .unavailable: "shippingbox.circle"
        case .failed: "xmark.circle.fill"
        case .unknown: "cable.connector"
        }
    }

    private var deviceStatusColor: Color {
        switch store.deviceInstallModeStatus {
        case .ready: .green
        case .needsInstallMode: .orange
        case .failed: .red
        case .checking, .unavailable: .blue
        case .unknown: .secondary
        }
    }

    private var deviceStatusTitle: String {
        switch store.deviceInstallModeStatus {
        case .ready: "已进入安装模式"
        case .needsInstallMode: "设备已连接，尚未进入安装模式"
        case .checking: "正在确认安装模式"
        case .unavailable: "已找到兼容设备"
        case .failed: "暂时无法确认安装模式"
        case .unknown: "已找到兼容设备"
        }
    }

    private func deviceStatusDetail(for device: SerialDevice) -> String {
        switch store.deviceInstallModeStatus {
        case .ready:
            "已通过 ESP32-S3 安装模式握手：\(device.name)"
        case .needsInstallMode:
            "请长按侧面电源键，看到指示灯闪烁两次且屏幕熄灭后松开。"
        case .checking:
            "正在通过只读握手确认 \(device.name)。"
        case .unavailable:
            "首次安装会在准备好设备组件后自动确认安装模式。"
        case let .failed(message):
            message
        case .unknown:
            "正在准备确认它是否已进入安装模式。"
        }
    }
}
