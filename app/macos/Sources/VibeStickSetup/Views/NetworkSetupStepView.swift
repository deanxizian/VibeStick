import SwiftUI
import VibeStickSetupCore

struct NetworkSetupStepView: View {
    @Bindable var store: SetupStore
    let onContinue: () -> Void

    @State private var showValidationError = false

    var body: some View {
        StableWizardScrollView(maximumContentWidth: 720) {
            VStack(alignment: .leading, spacing: 22) {
                SetupHero(
                    title: "连接网络",
                    subtitle: "填写 StickS3 要使用的 Wi‑Fi，再选择语音输入服务。其余设置会自动完成。",
                    systemImage: "wifi"
                )

                if store.isInitializing {
                    initializingCard
                } else if !store.setupReady {
                    unavailableCard
                } else {
                    configurationContent
                }
            }
        }
    }

    private var initializingCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在准备安装器")
                        .fontWeight(.medium)
                    Text("正在读取已保存的配置和 Mac 环境。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    @ViewBuilder
    private var configurationContent: some View {
        GroupBox("StickS3 Wi-Fi") {
            Form {
                TextField("Wi‑Fi 名称", text: $store.configuration.wifiSSID)
                    .textContentType(.username)
                SecureField(
                    "Wi‑Fi 密码",
                    text: $store.configuration.wifiPassword,
                    prompt: Text(
                        store.configuration.hasStoredWiFiPassword
                            ? "已有保存的密码；留空沿用"
                            : "请输入 Wi‑Fi 密码"
                    )
                )
                .textContentType(.password)
                TextField(
                    "Mac 局域网地址（默认自动获取）",
                    text: bridgeHostBinding,
                    prompt: Text("正在自动获取")
                )
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .disabled(store.isBusy)

        GroupBox("语音输入 API") {
            VStack(alignment: .leading, spacing: 10) {
                Form {
                    Picker("语音输入", selection: providerBinding) {
                        Text("SiliconFlow（推荐）").tag(ASRProvider.siliconFlow)
                        Text("自定义服务").tag(ASRProvider.custom)
                        Text("暂不使用语音输入").tag(ASRProvider.disabled)
                    }

                    if store.configuration.asrProvider != .disabled {
                        SecureField(
                            "API Key",
                            text: $store.configuration.asrAPIKey,
                            prompt: Text(
                                store.configuration.hasStoredAPIKey
                                    ? "已有保存的 API Key；留空沿用"
                                    : "请输入语音服务 API Key"
                            )
                        )
                        .textContentType(.password)
                        TextField("API 地址", text: $store.configuration.asrBaseURL)
                        TextField("语音模型", text: $store.configuration.asrModel)
                        LabeledContent("语言") {
                            TextField("", text: $store.configuration.asrLanguage)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 180)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)

                HStack(spacing: 10) {
                    voiceAPIStatus
                    Spacer()
                    if store.configuration.asrProvider != .disabled {
                        Button("检测 API") {
                            showValidationError = true
                            store.testASRConnection()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .disabled(store.isBusy)

        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
        }

        HStack(alignment: .center) {
            Spacer()
            Button(primaryButtonTitle) { continueTapped() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isBusy)
        }
    }

    private var providerBinding: Binding<ASRProvider> {
        Binding(
            get: { store.configuration.asrProvider },
            set: { provider in
                store.changeProvider(provider)
            }
        )
    }

    private var bridgeHostBinding: Binding<String> {
        Binding(
            get: { store.configuration.bridgeHost },
            set: { store.setBridgeHost($0) }
        )
    }

    @ViewBuilder
    private var voiceAPIStatus: some View {
        if store.configuration.asrProvider == .disabled {
            Label("未启用语音转写", systemImage: "mic.slash")
                .foregroundStyle(.secondary)
        } else if store.operationTitle == "正在检测语音 API" {
            ProgressView()
                .controlSize(.small)
            Text("正在检测")
                .foregroundStyle(.secondary)
        } else if store.asrConnectionVerified {
            Label("检测通过", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if store.lastError == SetupStore.asrVerificationRequiredMessage {
            Label(
                SetupStore.asrVerificationRequiredMessage,
                systemImage: "exclamationmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("尚未检测", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private var primaryButtonTitle: String {
        "下一步"
    }

    private func continueTapped() {
        showValidationError = true
        onContinue()
    }

    private var validationMessage: String? {
        if let lastError = store.lastError, !lastError.isEmpty {
            if lastError == SetupStore.asrVerificationRequiredMessage {
                return nil
            }
            return lastError
        }
        if showValidationError {
            return store.issues.first?.message
        }
        return nil
    }
}
