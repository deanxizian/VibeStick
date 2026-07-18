import Foundation

public enum SetupSecret: String, CaseIterable, Sendable {
    case wifiPassword = "wifi-password"
    case asrAPIKey = "asr-api-key"
}

public protocol SecretStoring: Sendable {
    func read(_ secret: SetupSecret) throws -> String?
    func write(_ value: String, for secret: SetupSecret) throws
    func delete(_ secret: SetupSecret) throws
}

public protocol ConfigurationStoring: Sendable {
    func load() throws -> SetupConfiguration
    func save(
        _ configuration: SetupConfiguration,
        deploymentNonce: String?
    ) throws -> SetupConfiguration
    func resolvedASRAPIKey(for configuration: SetupConfiguration) throws -> String
    func redactionSecrets(for configuration: SetupConfiguration) throws -> [String]
}

public extension ConfigurationStoring {
    func save(_ configuration: SetupConfiguration) throws -> SetupConfiguration {
        try save(configuration, deploymentNonce: nil)
    }
}

public protocol SystemProbing: Sendable {
    func snapshot() async -> SystemSnapshot
}

public protocol ProcessRunning: Sendable {
    func run(
        _ command: CommandSpec,
        redacting secrets: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult

    func cancel()
}

public enum SetupCoreError: LocalizedError, Equatable {
    case projectNotFound
    case unsafePath(String)
    case malformedConfiguration(String)
    case duplicateKey(String)
    case missingSecret(String)
    case commandAlreadyRunning
    case commandFailed(String, Int32)
    case deviceStartFailed(String)
    case deviceDidNotComeOnline
    case deviceChanged
    case deviceNotInInstallMode
    case deviceInstallModeProbeFailed(Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .projectNotFound:
            "安装包缺少 VibeStick 项目资源，请重新下载或重新构建安装器。"
        case let .unsafePath(path):
            "拒绝访问不安全的路径：\(path)"
        case let .malformedConfiguration(message):
            "配置文件格式错误：\(message)"
        case let .duplicateKey(key):
            "配置中存在重复字段：\(key)"
        case let .missingSecret(name):
            "缺少 \(name)，请重新输入"
        case .commandAlreadyRunning:
            "已有部署任务正在运行"
        case let .commandFailed(name, code):
            "\(name)失败（退出码 \(code)）"
        case let .deviceStartFailed(reason):
            "固件已经烧录成功，但安装器无法自动启动 StickS3：\(reason)。请短按一次侧面电源键后重试联网检查。"
        case .deviceDidNotComeOnline:
            "固件已经烧录成功，但 StickS3 没有启动联网。请短按一次侧面电源键；若仍未连接，请确认 StickS3 与 Mac 使用同一 Wi‑Fi 后重试。"
        case .deviceChanged:
            "烧录前设备身份发生变化。请重新选择并确认 StickS3，避免烧录到错误设备。"
        case .deviceNotInInstallMode:
            "StickS3 尚未进入安装模式。请按住侧面电源键，看到指示灯闪烁两次且屏幕熄灭后再重新检测。"
        case let .deviceInstallModeProbeFailed(code):
            switch code {
            case 11:
                "连接的 USB 设备不是 ESP32-S3。请确认当前选择的是 StickS3。"
            case 12:
                "设备正在运行临时烧录程序，并非 ROM 安装模式。请重新让 StickS3 进入安装模式后检测。"
            case 13:
                "StickS3 串口正被其他程序占用。请关闭串口监视器或其他烧录工具后重新检测。"
            case 14:
                "检测期间 StickS3 已断开或 USB 身份发生变化。请保持数据线连接并重新检测。"
            case 15:
                "这台 ESP32-S3 已启用安全下载模式，安装器无法安全写入普通 VibeStick 固件。"
            default:
                "安装模式检测组件异常（退出码 \(code)）。请确认 ESP-IDF 组件完整后重试。"
            }
        case .cancelled:
            "操作已取消"
        }
    }
}
