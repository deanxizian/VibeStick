import XCTest
@testable import VibeStickSetupCore

final class ConfigurationValidatorTests: XCTestCase {
    func testAcceptsCompleteConfiguration() {
        let configuration = SetupConfiguration(
            wifiSSID: "家庭 WiFi",
            wifiPassword: "correct-horse",
            bridgeHost: "192.168.1.10",
            asrProvider: .siliconFlow,
            asrBaseURL: "https://api.siliconflow.cn/v1",
            asrAPIKey: "test-key",
            asrModel: "FunAudioLLM/SenseVoiceSmall",
            asrLanguage: "zh"
        )

        XCTAssertEqual(ConfigurationValidator.issues(for: configuration), [])
    }

    func testRejectsSSIDLongerThanFirmwareBuffer() {
        var configuration = validConfiguration()
        configuration.wifiSSID = String(repeating: "界", count: 11)

        XCTAssertTrue(ConfigurationValidator.issues(for: configuration).contains { $0.field == .wifiSSID })
    }

    func testRejectsSpeakerVolumeOutsideCodecRange() {
        var configuration = validConfiguration()
        configuration.speakerVolume = -1
        XCTAssertTrue(ConfigurationValidator.issues(for: configuration).contains { $0.field == .speakerVolume })

        configuration.speakerVolume = 101
        XCTAssertTrue(ConfigurationValidator.issues(for: configuration).contains { $0.field == .speakerVolume })

        configuration.speakerVolume = 0
        XCTAssertFalse(ConfigurationValidator.issues(for: configuration).contains { $0.field == .speakerVolume })

        configuration.speakerVolume = 100
        XCTAssertFalse(ConfigurationValidator.issues(for: configuration).contains { $0.field == .speakerVolume })
    }

    func testAllowsExistingSecretsToRemainUntouched() {
        var configuration = validConfiguration()
        configuration.wifiPassword = ""
        configuration.hasStoredWiFiPassword = true
        configuration.asrAPIKey = ""
        configuration.hasStoredAPIKey = true

        XCTAssertEqual(ConfigurationValidator.issues(for: configuration), [])
    }

    func testOnlyAllowsHTTPForLoopbackASR() {
        XCTAssertTrue(ConfigurationValidator.isValidASRURL("http://127.0.0.1:8080/v1"))
        XCTAssertTrue(ConfigurationValidator.isValidASRURL("http://localhost:8080/v1"))
        XCTAssertFalse(ConfigurationValidator.isValidASRURL("http://192.168.1.8:8080/v1"))
        XCTAssertFalse(ConfigurationValidator.isValidASRURL("https://user:pass@example.com/v1"))
    }

    func testRejectsBridgeURLAndLoopback() {
        XCTAssertFalse(ConfigurationValidator.isValidBridgeHost("http://192.168.1.8"))
        XCTAssertFalse(ConfigurationValidator.isValidBridgeHost("127.0.0.1"))
        XCTAssertFalse(ConfigurationValidator.isValidBridgeHost("host.local:8765"))
        XCTAssertTrue(ConfigurationValidator.isValidBridgeHost("macbook.local"))
    }

    func testRejectsMultilineAPIKeyAndModel() {
        var configuration = validConfiguration()
        configuration.asrAPIKey = "secret\nVIBE_STICK_OTHER=value"
        configuration.asrModel = "model\nname"

        let issues = ConfigurationValidator.issues(for: configuration)
        XCTAssertTrue(issues.contains { $0.field == .asrAPIKey })
        XCTAssertTrue(issues.contains { $0.field == .asrModel })
    }

    func testDoesNotTrimUnsafeSSIDBeforeValidation() {
        var configuration = validConfiguration()
        configuration.wifiSSID = String(repeating: "a", count: 31) + " "
        XCTAssertTrue(ConfigurationValidator.issues(for: configuration).contains { $0.field == .wifiSSID })

        configuration.wifiSSID = "Home\n"
        XCTAssertTrue(ConfigurationValidator.issues(for: configuration).contains { $0.field == .wifiSSID })
    }

    func testRejectsControlCharactersThatTrimmingWouldHide() {
        var configuration = validConfiguration()
        configuration.bridgeHost = "192.168.1.10\n"
        configuration.asrBaseURL = "https://example.com/v1\n"
        configuration.asrLanguage = "zh\n"

        let issues = ConfigurationValidator.issues(for: configuration)
        XCTAssertTrue(issues.contains { $0.field == .bridgeHost })
        XCTAssertTrue(issues.contains { $0.field == .asrBaseURL })
        XCTAssertTrue(issues.contains { $0.field == .asrLanguage })
    }

    func testSelectingCustomProviderClearsPresetAddressAndModel() {
        var configuration = validConfiguration()
        configuration.asrBaseURL = ASRProvider.siliconFlow.defaultBaseURL
        configuration.asrModel = ASRProvider.siliconFlow.defaultModel

        configuration.applyDefaults(for: .custom)

        XCTAssertEqual(configuration.asrProvider, .custom)
        XCTAssertEqual(configuration.asrBaseURL, "")
        XCTAssertEqual(configuration.asrModel, "")
    }

    private func validConfiguration() -> SetupConfiguration {
        SetupConfiguration(
            wifiSSID: "VibeWiFi",
            wifiPassword: "password123",
            bridgeHost: "192.168.1.10",
            asrProvider: .custom,
            asrBaseURL: "https://api.example.com/v1",
            asrAPIKey: "test-key",
            asrModel: "whisper-large-v3",
            asrLanguage: "zh"
        )
    }
}
