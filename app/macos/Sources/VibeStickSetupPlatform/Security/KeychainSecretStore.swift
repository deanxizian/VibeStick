import CryptoKit
import Foundation
import LocalAuthentication
import Security
import VibeStickSetupCore

public enum KeychainBackend: Sendable {
    /// The traditional macOS login keychain. This works for unsigned and ad-hoc
    /// signed development builds without requiring a Keychain entitlement.
    case login

    /// The Data Protection keychain. A distributed app must be signed with the
    /// appropriate Keychain entitlement before selecting this backend.
    case dataProtection
}

public struct KeychainSecretStore: SecretStoring {
    public static let defaultService = "com.vibestick.setup.secrets.v2"

    private let service: String
    private let namespace: String
    private let backend: KeychainBackend

    public init(
        service: String = Self.defaultService,
        namespace: String = "default",
        backend: KeychainBackend = .login
    ) {
        self.service = service
        self.namespace = namespace
        self.backend = backend
    }

    public init(
        projectRoot: URL,
        service: String = Self.defaultService,
        backend: KeychainBackend = .login
    ) {
        self.service = service
        self.backend = backend
        let path = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        self.namespace = SHA256.hash(data: Data(path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func read(_ secret: SetupSecret) throws -> String? {
        var query = nonInteractiveQuery(for: secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || authenticationWasNotAvailable(status) {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return value
    }

    public func write(_ value: String, for secret: SetupSecret) throws {
        let data = Data(value.utf8)
        let query = nonInteractiveQuery(for: secret)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var addition = baseQuery(for: secret)
        attributes.forEach { addition[$0.key] = $0.value }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete(_ secret: SetupSecret) throws {
        let status = SecItemDelete(nonInteractiveQuery(for: secret) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for secret: SetupSecret) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(namespace):\(secret.rawValue)",
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func nonInteractiveQuery(for secret: SetupSecret) -> [String: Any] {
        var query = baseQuery(for: secret)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private func authenticationWasNotAvailable(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "无法安全保存密码，请重新打开应用后重试。"
    }
}
