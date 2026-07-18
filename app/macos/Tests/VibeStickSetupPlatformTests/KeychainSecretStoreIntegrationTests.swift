import Foundation
import XCTest
@testable import VibeStickSetupCore
@testable import VibeStickSetupPlatform

final class KeychainSecretStoreIntegrationTests: XCTestCase {
    func testDefaultLoginKeychainBackendCanWriteReadAndDelete() throws {
        guard ProcessInfo.processInfo.environment["VIBESTICK_RUN_KEYCHAIN_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip(
                "Set VIBESTICK_RUN_KEYCHAIN_INTEGRATION_TESTS=1 to exercise the real macOS login keychain"
            )
        }

        let namespace = "integration-test-\(UUID().uuidString)"
        let store = KeychainSecretStore(namespace: namespace)
        let value = "integration-secret-\(UUID().uuidString)"

        // A unique service keeps the test isolated. Cleanup is also attempted on
        // every exit path so interrupted assertions do not leave credentials behind.
        defer { try? store.delete(.wifiPassword) }
        try? store.delete(.wifiPassword)

        try store.write(value, for: .wifiPassword)
        XCTAssertEqual(try store.read(.wifiPassword), value)

        try store.delete(.wifiPassword)
        XCTAssertNil(try store.read(.wifiPassword))
    }
}
