import Darwin
import Foundation
import Security
import VibeStickSetupCore

public final class RepositoryConfigurationStore: ConfigurationStoring, @unchecked Sendable {
    private struct FileSnapshot {
        let data: Data?
        let permissions: NSNumber?
    }

    private enum Managed {
        static let wifiSSID = "VIBE_STICK_WIFI_SSID"
        static let wifiPassword = "VIBE_STICK_WIFI_PASSWORD"
        static let bridgeHost = "VIBE_STICK_BRIDGE_HOST"
        static let bridgeToken = "VIBE_STICK_BRIDGE_TOKEN"
        static let deploymentNonce = "VIBE_STICK_DEPLOYMENT_NONCE"
        static let asrProvider = "VIBE_STICK_ASR_PROVIDER"
        static let asrBaseURL = "VIBE_STICK_ASR_BASE_URL"
        static let asrAPIKey = "VIBE_STICK_ASR_API_KEY"
        static let asrModel = "VIBE_STICK_ASR_MODEL"
        static let asrLanguage = "VIBE_STICK_ASR_LANGUAGE"
        static let python = "VIBE_STICK_PYTHON"
    }

    public let projectRoot: URL
    private let secretStore: any SecretStoring
    private let fileManager: FileManager
    private let lock = NSLock()

    private var envURL: URL { projectRoot.appendingPathComponent(".env") }
    private var envTemplateURL: URL { projectRoot.appendingPathComponent(".env.example") }
    private var headerURL: URL { projectRoot.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.h") }
    private var headerTemplateURL: URL { projectRoot.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.example.h") }

    public init(
        projectRoot: URL,
        secretStore: (any SecretStoring)? = nil,
        fileManager: FileManager = .default
    ) {
        self.projectRoot = projectRoot
        self.secretStore = secretStore ?? KeychainSecretStore(projectRoot: projectRoot)
        self.fileManager = fileManager
    }

    public func load() throws -> SetupConfiguration {
        lock.lock()
        defer { lock.unlock() }
        let env = try readDotenv()
        let header = try readHeader()
        let provider = providerFrom(env: env)
        let storedWiFi = firstStoredSecret([
            try secretStore.read(.wifiPassword),
            header[Managed.wifiPassword],
        ])
        let storedAPIKey = firstStoredSecret([
            try secretStore.read(.asrAPIKey),
            env[Managed.asrAPIKey],
        ])

        return SetupConfiguration(
            wifiSSID: displaySSID(header[Managed.wifiSSID]),
            wifiPassword: "",
            hasStoredWiFiPassword: storedWiFi != nil,
            bridgeHost: displayBridgeHost(header[Managed.bridgeHost]),
            asrProvider: provider,
            asrBaseURL: env[Managed.asrBaseURL] ?? provider.defaultBaseURL,
            asrAPIKey: "",
            hasStoredAPIKey: storedAPIKey != nil,
            asrModel: env[Managed.asrModel] ?? provider.defaultModel,
            asrLanguage: env[Managed.asrLanguage] ?? "zh"
        )
    }

    public func save(
        _ configuration: SetupConfiguration,
        deploymentNonce requestedDeploymentNonce: String?
    ) throws -> SetupConfiguration {
        let issues = ConfigurationValidator.issues(for: configuration)
        if let first = issues.first {
            throw SetupCoreError.malformedConfiguration(first.message)
        }
        let configuration = configuration.normalizedForStorage()

        lock.lock()
        defer { lock.unlock() }

        let currentEnv = try readDotenv()
        let currentHeader = try readHeader()
        let envSnapshot = try snapshotFile(at: envURL)
        let headerSnapshot = try snapshotFile(at: headerURL)
        let previousWiFiSecret = try secretStore.read(.wifiPassword)
        let previousAPISecret = try secretStore.read(.asrAPIKey)
        let wifiPassword = try resolvedSecret(
            input: configuration.wifiPassword,
            keychainKey: .wifiPassword,
            fallback: currentHeader[Managed.wifiPassword],
            displayName: "Wi‑Fi 密码"
        )
        let apiKey: String
        if configuration.asrProvider == .disabled {
            apiKey = ""
        } else {
            apiKey = try resolvedSecret(
                input: configuration.asrAPIKey,
                keychainKey: .asrAPIKey,
                fallback: currentEnv[Managed.asrAPIKey],
                displayName: "API Key"
            )
        }

        let token = try resolvedBridgeToken(env: currentEnv, header: currentHeader)
        let deploymentNonce = try resolvedDeploymentNonce(
            requested: requestedDeploymentNonce,
            current: currentHeader[Managed.deploymentNonce]
        )
        let providerValue: String
        switch configuration.asrProvider {
        case .siliconFlow, .custom: providerValue = "openai-compatible"
        case .disabled: providerValue = ""
        }

        let envValues = [
            Managed.asrProvider: providerValue,
            Managed.asrBaseURL: configuration.asrProvider == .disabled ? "" : configuration.asrBaseURL,
            Managed.asrAPIKey: apiKey,
            Managed.asrModel: configuration.asrProvider == .disabled ? "" : configuration.asrModel,
            Managed.asrLanguage: configuration.asrProvider == .disabled ? "" : configuration.asrLanguage,
            Managed.bridgeToken: token,
            Managed.python: resolvedPythonPath(currentEnv: currentEnv),
            "VIBE_STICK_PROJECT_ROOT": projectRoot.path,
        ]
        let headerValues = [
            Managed.wifiSSID: configuration.wifiSSID,
            Managed.wifiPassword: wifiPassword,
            Managed.bridgeHost: configuration.bridgeHost,
            Managed.bridgeToken: token,
            Managed.deploymentNonce: deploymentNonce,
        ]

        do {
            try writeDotenv(values: envValues)
            try writeHeader(values: headerValues)
            try secretStore.write(wifiPassword, for: .wifiPassword)
            if apiKey.isEmpty {
                try secretStore.delete(.asrAPIKey)
            } else {
                try secretStore.write(apiKey, for: .asrAPIKey)
            }
        } catch {
            // A failed save must not leave firmware, Bridge, and Keychain values out of sync.
            try? restoreFile(envSnapshot, at: envURL)
            try? restoreFile(headerSnapshot, at: headerURL)
            try? restoreSecret(previousWiFiSecret, for: .wifiPassword)
            try? restoreSecret(previousAPISecret, for: .asrAPIKey)
            throw error
        }

        var saved = configuration
        saved.wifiPassword = ""
        saved.hasStoredWiFiPassword = true
        saved.asrAPIKey = ""
        saved.hasStoredAPIKey = !apiKey.isEmpty
        return saved
    }

    public func redactionSecrets(for configuration: SetupConfiguration) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let env = try readDotenv()
        let header = try readHeader()
        return [
            configuration.wifiPassword,
            configuration.asrAPIKey,
            try secretStore.read(.wifiPassword) ?? header[Managed.wifiPassword] ?? "",
            try secretStore.read(.asrAPIKey) ?? env[Managed.asrAPIKey] ?? "",
            env[Managed.bridgeToken] ?? header[Managed.bridgeToken] ?? "",
        ].filter { !$0.isEmpty }
    }

    public func resolvedASRAPIKey(for configuration: SetupConfiguration) throws -> String {
        guard configuration.asrProvider != .disabled else { return "" }
        lock.lock()
        defer { lock.unlock() }
        let env = try readDotenv()
        return try resolvedSecret(
            input: configuration.asrAPIKey,
            keychainKey: .asrAPIKey,
            fallback: env[Managed.asrAPIKey],
            displayName: "API Key"
        )
    }

    private func providerFrom(env: [String: String]) -> ASRProvider {
        let raw = (env[Managed.asrProvider] ?? "").lowercased()
        if raw.isEmpty { return .disabled }
        let base = (env[Managed.asrBaseURL] ?? "").lowercased()
        if base.contains("siliconflow.cn") { return .siliconFlow }
        return .custom
    }

    private func resolvedSecret(
        input: String,
        keychainKey: SetupSecret,
        fallback: String?,
        displayName: String
    ) throws -> String {
        if !input.isEmpty {
            guard !isPlaceholder(input) else {
                throw SetupCoreError.malformedConfiguration("\(displayName)不能使用示例占位值")
            }
            return input
        }
        if let fallback, !fallback.isEmpty, !isPlaceholder(fallback) { return fallback }
        if let keychain = try secretStore.read(keychainKey),
           !keychain.isEmpty,
           !isPlaceholder(keychain) {
            return keychain
        }
        throw SetupCoreError.missingSecret(displayName)
    }

    private func firstStoredSecret(_ candidates: [String?]) -> String? {
        candidates.lazy.compactMap { candidate in
            guard let candidate, !self.isPlaceholder(candidate) else { return nil }
            return candidate
        }.first
    }

    private func resolvedBridgeToken(env: [String: String], header: [String: String]) throws -> String {
        let envToken = env[Managed.bridgeToken] ?? ""
        let headerToken = header[Managed.bridgeToken] ?? ""
        if isValidToken(envToken), envToken == headerToken { return envToken }
        if isValidToken(envToken) { return envToken }
        if isValidToken(headerToken) { return headerToken }
        return try randomToken()
    }

    private func resolvedDeploymentNonce(requested: String?, current: String?) throws -> String {
        if let requested {
            guard isValidToken(requested) else {
                throw SetupCoreError.malformedConfiguration("部署标识无效")
            }
            return requested
        }
        if let current, isValidToken(current) { return current }
        return try randomToken()
    }

    private func resolvedPythonPath(currentEnv: [String: String]) -> String {
        if let configured = currentEnv[Managed.python],
           !configured.isEmpty,
           fileManager.isExecutableFile(atPath: configured) {
            return configured
        }

        #if arch(arm64)
        let architecture = "aarch64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        let managed = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/vibestick/python/cpython-3.12-macos-\(architecture)-none/bin/python3.12")
            .path
        return fileManager.isExecutableFile(atPath: managed) ? managed : (currentEnv[Managed.python] ?? "")
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SetupCoreError.malformedConfiguration("无法生成 Bridge token")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func isValidToken(_ value: String) -> Bool {
        (32...256).contains(value.count)
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._~-".contains($0) }
            && !isPlaceholder(value)
    }

    private func isPlaceholder(_ value: String?) -> Bool {
        guard let value else { return true }
        return [
            "",
            "your-password",
            "your-key",
            "your-api-key",
            "your-groq-key",
            "paste-api-key-here",
            "paste-generated-token-here",
            "changeme",
            "change-me",
        ].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func displaySSID(_ value: String?) -> String {
        guard let value else { return "" }
        return ["your-wifi", "your-ssid", "wifi-ssid"].contains(value.lowercased()) ? "" : value
    }

    private func displayBridgeHost(_ value: String?) -> String {
        guard let value else { return "" }
        return ["192.168.1.10", "192.168.0.10", "10.0.0.10", "your-mac-ip"]
            .contains(value.lowercased()) ? "" : value
    }

    private func readDotenv() throws -> [String: String] {
        let sourceURL = try readableSource(primary: envURL, fallback: envTemplateURL)
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        var result: [String: String] = [:]
        for (index, sourceLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                throw SetupCoreError.malformedConfiguration("第 \(index + 1) 行缺少 =")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw SetupCoreError.malformedConfiguration("第 \(index + 1) 行字段为空") }
            if result[key] != nil { throw SetupCoreError.duplicateKey(key) }
            let raw = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            result[key] = decodeDotenv(raw)
        }
        return result
    }

    private func readHeader() throws -> [String: String] {
        let sourceURL = try readableSource(primary: headerURL, fallback: headerTemplateURL)
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, parts[0] == "#define" else { continue }
            let key = String(parts[1])
            if result[key] != nil { throw SetupCoreError.duplicateKey(key) }
            let literal = String(parts[2]).trimmingCharacters(in: .whitespaces)
            if literal.hasPrefix("\"") {
                result[key] = try decodeCString(literal)
            }
        }
        return result
    }

    private func writeDotenv(values: [String: String]) throws {
        let sourceURL = try readableSource(primary: envURL, fallback: envTemplateURL)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let updated = try updateLines(
            source,
            values: values,
            keyForLine: dotenvKey,
            render: { key, value in "\(key)=\(shellQuote(value))" }
        )
        try secureAtomicWrite(updated, to: envURL)
    }

    private func writeHeader(values: [String: String]) throws {
        let sourceURL = try readableSource(primary: headerURL, fallback: headerTemplateURL)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let updated = try updateLines(
            source,
            values: values,
            keyForLine: headerKey,
            render: { key, value in "#define \(key) \(try self.cStringLiteral(value))" }
        )
        try secureAtomicWrite(updated, to: headerURL)
    }

    private func updateLines(
        _ source: String,
        values: [String: String],
        keyForLine: (String) -> String?,
        render: (String, String) throws -> String
    ) throws -> String {
        var seen: Set<String> = []
        var lines: [String] = []
        for line in source.components(separatedBy: .newlines) {
            guard let key = keyForLine(line), let value = values[key] else {
                lines.append(line)
                continue
            }
            if !seen.insert(key).inserted { throw SetupCoreError.duplicateKey(key) }
            lines.append(try render(key, value))
        }
        for key in values.keys.sorted() where !seen.contains(key) {
            lines.append(try render(key, values[key] ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private func dotenvKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    }

    private func headerKey(_ line: String) -> String? {
        let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2, parts[0] == "#define" else { return nil }
        return String(parts[1])
    }

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func decodeDotenv(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.first == "'", raw.last == "'" {
            let inner = String(raw.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "'\\''", with: "'")
        }
        if raw.first == "\"", raw.last == "\"" {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return raw
    }

    private func cStringLiteral(_ value: String) throws -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0: throw SetupCoreError.malformedConfiguration("C 字符串不能包含 NUL")
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 1...31, 127: throw SetupCoreError.malformedConfiguration("C 字符串不能包含控制字符")
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private func decodeCString(_ literal: String) throws -> String {
        guard literal.first == "\"", literal.last == "\"" else {
            throw SetupCoreError.malformedConfiguration("无效的 C 字符串")
        }
        var result = ""
        var escaping = false
        for character in literal.dropFirst().dropLast() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { throw SetupCoreError.malformedConfiguration("C 字符串以转义符结尾") }
        return result
    }

    private func secureAtomicWrite(_ content: String, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateContainedParent(of: url)
        _ = try regularFileExists(at: url)
        let data = Data((content.hasSuffix("\n") ? content : content + "\n").utf8)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func snapshotFile(at url: URL) throws -> FileSnapshot {
        guard try regularFileExists(at: url) else {
            return FileSnapshot(data: nil, permissions: nil)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return FileSnapshot(
            data: try Data(contentsOf: url),
            permissions: attributes[.posixPermissions] as? NSNumber
        )
    }

    private func restoreFile(_ snapshot: FileSnapshot, at url: URL) throws {
        try validateContainedParent(of: url)
        if let data = snapshot.data {
            let parent = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try regularFileExists(at: url)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: snapshot.permissions ?? NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } else if try regularFileExists(at: url) {
            try fileManager.removeItem(at: url)
        }
    }

    private func restoreSecret(_ value: String?, for secret: SetupSecret) throws {
        if let value {
            try secretStore.write(value, for: secret)
        } else {
            try secretStore.delete(secret)
        }
    }

    private func readableSource(primary: URL, fallback: URL) throws -> URL {
        let primaryExists = try regularFileExists(at: primary)
        let source = primaryExists ? primary : fallback
        try validateContainedParent(of: source)
        guard try regularFileExists(at: source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        return source
    }

    private func regularFileExists(at url: URL) throws -> Bool {
        var info = stat()
        let status = url.path.withCString { lstat($0, &info) }
        if status == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw SetupCoreError.unsafePath(url.path)
            }
            return true
        }
        if errno == ENOENT { return false }
        throw SetupCoreError.unsafePath(url.path)
    }

    private func validateContainedParent(of url: URL) throws {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/") else {
            throw SetupCoreError.unsafePath(url.path)
        }
    }
}
