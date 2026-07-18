import XCTest
@testable import VibeStickSetupCore

final class SecretRedactorTests: XCTestCase {
    func testRedactsLiteralAndEncodedSecrets() {
        let redactor = SecretRedactor(secrets: ["a key/+value"])
        let result = redactor.redact("raw=a key/+value encoded=a%20key%2F%2Bvalue")

        XCTAssertFalse(result.contains("a key/+value"))
        XCTAssertFalse(result.contains("a%20key%2F%2Bvalue"))
        XCTAssertTrue(result.contains("••••••"))
    }

    func testRedactsCommonCredentialFormatsWithoutKnownSecret() {
        let input = "Authorization: Bearer abc123\npassword=hunter2\nx-vibe-stick-token: token123"
        let result = SecretRedactor(secrets: []).redact(input)

        XCTAssertFalse(result.contains("abc123"))
        XCTAssertFalse(result.contains("hunter2"))
        XCTAssertFalse(result.contains("token123"))
    }

    func testRemovesTerminalControlCharacters() {
        let result = SecretRedactor(secrets: []).redact("safe\u{001B}[31m\nnext")

        XCTAssertFalse(result.unicodeScalars.contains("\u{001B}"))
        XCTAssertTrue(result.contains("\n"))
    }
}
