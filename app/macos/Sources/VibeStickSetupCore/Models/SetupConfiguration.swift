import Foundation

public enum ASRProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case siliconFlow = "siliconflow"
    case custom
    case disabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .siliconFlow: "SiliconFlow"
        case .custom: "OpenAI 兼容服务"
        case .disabled: "暂不配置"
        }
    }

    public var detail: String {
        switch self {
        case .siliconFlow: "中国大陆网络推荐"
        case .custom: "填写自定义 API 地址与模型"
        case .disabled: "语音录制可用，但不会转写"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .custom, .disabled: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .siliconFlow: "FunAudioLLM/SenseVoiceSmall"
        case .custom, .disabled: ""
        }
    }
}

public struct SetupConfiguration: Equatable, Sendable {
    public var wifiSSID: String
    public var wifiPassword: String
    public var hasStoredWiFiPassword: Bool
    public var bridgeHost: String
    public var asrProvider: ASRProvider
    public var asrBaseURL: String
    public var asrAPIKey: String
    public var hasStoredAPIKey: Bool
    public var asrModel: String
    public var asrLanguage: String

    public init(
        wifiSSID: String = "",
        wifiPassword: String = "",
        hasStoredWiFiPassword: Bool = false,
        bridgeHost: String = "",
        asrProvider: ASRProvider = .siliconFlow,
        asrBaseURL: String = ASRProvider.siliconFlow.defaultBaseURL,
        asrAPIKey: String = "",
        hasStoredAPIKey: Bool = false,
        asrModel: String = ASRProvider.siliconFlow.defaultModel,
        asrLanguage: String = "zh"
    ) {
        self.wifiSSID = wifiSSID
        self.wifiPassword = wifiPassword
        self.hasStoredWiFiPassword = hasStoredWiFiPassword
        self.bridgeHost = bridgeHost
        self.asrProvider = asrProvider
        self.asrBaseURL = asrBaseURL
        self.asrAPIKey = asrAPIKey
        self.hasStoredAPIKey = hasStoredAPIKey
        self.asrModel = asrModel
        self.asrLanguage = asrLanguage
    }

    public mutating func applyDefaults(for provider: ASRProvider) {
        asrProvider = provider
        asrBaseURL = provider.defaultBaseURL
        asrModel = provider.defaultModel
    }

    public func normalizedForStorage() -> SetupConfiguration {
        var result = self
        result.bridgeHost = bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        result.asrBaseURL = asrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.asrModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.asrLanguage = asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

public enum ConfigurationField: String, Hashable, Sendable {
    case wifiSSID
    case wifiPassword
    case bridgeHost
    case asrBaseURL
    case asrAPIKey
    case asrModel
    case asrLanguage
}

public struct ConfigurationIssue: Identifiable, Equatable, Sendable {
    public let field: ConfigurationField
    public let message: String

    public var id: String { "\(field.rawValue):\(message)" }

    public init(field: ConfigurationField, message: String) {
        self.field = field
        self.message = message
    }
}

public enum ConfigurationValidator {
    public static func issues(for configuration: SetupConfiguration) -> [ConfigurationIssue] {
        var result: [ConfigurationIssue] = []
        let ssid = configuration.wifiSSID
        let host = configuration.bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)

        if ssid.isEmpty {
            result.append(.init(field: .wifiSSID, message: "请输入 2.4 GHz Wi‑Fi 名称"))
        } else if ssid.utf8.count > 31 {
            result.append(.init(field: .wifiSSID, message: "Wi‑Fi 名称最多 31 个 UTF‑8 字节"))
        }
        if containsControlCharacter(configuration.wifiSSID) {
            result.append(.init(field: .wifiSSID, message: "Wi‑Fi 名称不能包含控制字符"))
        }

        if configuration.wifiPassword.isEmpty {
            if !configuration.hasStoredWiFiPassword {
                result.append(.init(field: .wifiPassword, message: "请输入 Wi‑Fi 密码"))
            }
        } else if !isValidWiFiPassword(configuration.wifiPassword) {
            result.append(.init(field: .wifiPassword, message: "WPA2 密码应为 8–63 字节，或 64 位十六进制密钥"))
        }

        if host.isEmpty {
            result.append(.init(field: .bridgeHost, message: "请选择或填写 Mac 的局域网地址"))
        } else if containsControlCharacter(configuration.bridgeHost) || !isValidBridgeHost(host) {
            result.append(.init(field: .bridgeHost, message: "请输入 IPv4 或主机名，不要包含 http://、端口或路径"))
        }

        if configuration.asrProvider != .disabled {
            if configuration.asrAPIKey.isEmpty && !configuration.hasStoredAPIKey {
                result.append(.init(field: .asrAPIKey, message: "请输入语音转写 API Key"))
            } else if !configuration.asrAPIKey.isEmpty,
                      configuration.asrAPIKey.utf8.count > 4_096 || containsControlCharacter(configuration.asrAPIKey) {
                result.append(.init(field: .asrAPIKey, message: "API Key 不能包含控制字符，且最多 4096 字节"))
            }
            if containsControlCharacter(configuration.asrBaseURL) || !isValidASRURL(configuration.asrBaseURL) {
                result.append(.init(field: .asrBaseURL, message: "API 地址必须是 HTTPS；仅本机服务可使用 HTTP"))
            }
            let model = configuration.asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.isEmpty {
                result.append(.init(field: .asrModel, message: "请输入转写模型名称"))
            } else if model.utf8.count > 256 || containsControlCharacter(configuration.asrModel) {
                result.append(.init(field: .asrModel, message: "转写模型名称无效"))
            }
            let language = configuration.asrLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if language.isEmpty || language.utf8.count > 16 || containsControlCharacter(configuration.asrLanguage) {
                result.append(.init(field: .asrLanguage, message: "语言代码无效"))
            }
        }

        return result
    }

    public static func isValidBridgeHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, !containsControlCharacter(host) else { return false }
        guard !host.contains("://"), !host.contains("/"), !host.contains(":"), !host.contains(" ") else { return false }
        guard host != "0.0.0.0", host != "127.0.0.1", host.lowercased() != "localhost" else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard !label.isEmpty, label.utf8.count <= 63 else { return false }
            let firstIsAlphanumeric = label.first.map { $0.isLetter || $0.isNumber } == true
            let lastIsAlphanumeric = label.last.map { $0.isLetter || $0.isNumber } == true
            return firstIsAlphanumeric
                && lastIsAlphanumeric
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return false }
        return true
    }

    public static func isValidASRURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              components.user == nil,
              components.password == nil else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }
        return false
    }

    private static func isValidWiFiPassword(_ value: String) -> Bool {
        guard !containsControlCharacter(value) else { return false }
        let count = value.utf8.count
        if (8...63).contains(count) { return true }
        return count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
