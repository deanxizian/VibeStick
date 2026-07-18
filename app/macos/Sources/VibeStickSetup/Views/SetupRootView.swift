import SwiftUI
import VibeStickSetupCore

struct SetupRootView: View {
    @Bindable var store: SetupStore

    @Environment(\.openWindow) private var openWindow
    @State private var step: SetupFlowStep
    @State private var pendingInstallDevice: SerialDevice?
    @State private var showInstallConfirmation = false
    @State private var showFlashCancelConfirmation = false

    init(store: SetupStore) {
        self.store = store
        _step = State(initialValue: store.recoveryRequired ? .install : .network)
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupFlowProgressView(
                current: step,
                installationComplete: store.deploymentComplete
            )
            Divider()

            switch step {
            case .network:
                NetworkSetupStepView(store: store) {
                    store.validateConfiguration {
                        step = .device
                    }
                }
            case .device:
                DeviceSetupStepView(
                    store: store,
                    onBack: { step = .network },
                    onInstall: requestInstallation(on:)
                )
            case .install:
                InstallSetupStepView(
                    store: store,
                    onBack: {
                        if store.deploymentComplete {
                            store.prepareForAnotherInstallation()
                            step = .network
                        } else {
                            step = store.asrConnectionVerified ? .device : .network
                        }
                    },
                    onInstall: requestInstallation(on:)
                )
            }
        }
        .frame(minWidth: 820, minHeight: 610)
        .background(WindowCloseButtonGuard(disabled: store.isBusy))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.operationTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .allowsTightening(true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(width: 280, alignment: .center)

                    Button("取消") {
                        if store.isFlashing {
                            showFlashCancelConfirmation = true
                        } else {
                            store.cancelOperation()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Menu {
                    Button("查看技术日志") { openWindow(id: "activity-log") }
                    Button("运行完整检查") { store.runDoctor() }
                        .disabled(store.isBusy || store.isInitializing || !store.setupReady)
                } label: {
                    Label("帮助与日志", systemImage: "ellipsis.circle")
                }
            }
        }
        .onChange(of: store.configuration) { oldValue, newValue in
            store.configurationDidChange(from: oldValue, to: newValue)
        }
        .alert("确认安装到这台设备？", isPresented: $showInstallConfirmation) {
            Button("取消", role: .cancel) {
                pendingInstallDevice = nil
            }
            Button("开始安装", role: .destructive) {
                beginConfirmedInstallation()
            }
        } message: {
            Text(installConfirmationMessage)
        }
        .alert("要中断写入设备吗？", isPresented: $showFlashCancelConfirmation) {
            Button("继续安装", role: .cancel) {}
            Button("仍然取消", role: .destructive) {
                store.cancelOperation()
            }
        } message: {
            Text("中断后 StickS3 可能暂时无法启动，但可以通过重新安装恢复。")
        }
    }

    private func requestInstallation(on device: SerialDevice) {
        guard store.canBeginInstallation else {
            store.explainInstallationBlocker()
            if !store.issues.isEmpty || !store.asrConnectionVerified {
                step = .network
            }
            return
        }
        pendingInstallDevice = device
        showInstallConfirmation = true
    }

    private func beginConfirmedInstallation() {
        guard let device = pendingInstallDevice,
              store.selectedDevice == device else {
            pendingInstallDevice = nil
            store.lastError = SetupCoreError.deviceChanged.localizedDescription
            step = .device
            return
        }
        pendingInstallDevice = nil
        store.confirmedStickS3 = true
        step = .install
        store.installEverything(expectedDevice: device)
    }

    private var installConfirmationMessage: String {
        let name = pendingInstallDevice?.name ?? "所选设备"
        let download = store.snapshot.idfExportPath == nil
            ? "首次安装还会下载约 1 GB 的组件。"
            : ""
        return "即将重写 \(name) 的固件。请确认它是 M5Stack StickS3，并在安装期间不要拔线。\(download)"
    }
}
