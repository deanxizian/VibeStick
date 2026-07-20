import Foundation
import XCTest
@testable import VibeStickSetupCore
@testable import VibeStickSetupPlatform

final class RepositoryConfigurationStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var secrets: MemorySecretStore!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("firmware/sticks3/include", isDirectory: true),
            withIntermediateDirectories: true
        )
        try envTemplate.write(
            to: temporaryRoot.appendingPathComponent(".env.example"),
            atomically: true,
            encoding: .utf8
        )
        try headerTemplate.write(
            to: temporaryRoot.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.example.h"),
            atomically: true,
            encoding: .utf8
        )
        secrets = MemorySecretStore()
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testSaveWritesEscapedFilesAndReturnsRedactedModel() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        let saved = try store.save(configuration())

        XCTAssertEqual(saved.wifiPassword, "")
        XCTAssertEqual(saved.asrAPIKey, "")
        XCTAssertTrue(saved.hasStoredWiFiPassword)
        XCTAssertTrue(saved.hasStoredAPIKey)
        XCTAssertEqual(try secrets.read(.wifiPassword), "wifi'password")
        XCTAssertEqual(try secrets.read(.asrAPIKey), "api-secret")

        let env = try String(contentsOf: temporaryRoot.appendingPathComponent(".env"), encoding: .utf8)
        let header = try String(
            contentsOf: temporaryRoot.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.h"),
            encoding: .utf8
        )
        XCTAssertTrue(env.contains("VIBE_STICK_ASR_API_KEY='api-secret'"))
        XCTAssertTrue(header.contains("#define VIBE_STICK_WIFI_PASSWORD \"wifi'password\""))
        XCTAssertTrue(header.contains("#define VIBE_STICK_SPEAKER_VOLUME 65"))
        XCTAssertFalse(header.contains("#define VIBE_STICK_SPEAKER_VOLUME \"65\""))
        XCTAssertFalse(header.contains("api-secret"))
        XCTAssertEqual(fileMode(temporaryRoot.appendingPathComponent(".env")), 0o600)
        XCTAssertEqual(fileMode(temporaryRoot.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.h")), 0o600)
    }

    func testLoadDoesNotReturnSecretValues() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        _ = try store.save(configuration())
        let loaded = try store.load()

        XCTAssertEqual(loaded.wifiSSID, "Home WiFi")
        XCTAssertEqual(loaded.bridgeHost, "192.168.50.5")
        XCTAssertEqual(loaded.speakerVolume, 65)
        XCTAssertEqual(loaded.wifiPassword, "")
        XCTAssertEqual(loaded.asrAPIKey, "")
        XCTAssertTrue(loaded.hasStoredWiFiPassword)
        XCTAssertTrue(loaded.hasStoredAPIKey)
    }

    func testTemplatePlaceholdersLoadAsEmptyFields() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)

        let loaded = try store.load()

        XCTAssertEqual(loaded.wifiSSID, "")
        XCTAssertEqual(loaded.bridgeHost, "")
        XCTAssertEqual(loaded.speakerVolume, SetupConfiguration.defaultSpeakerVolume)
        XCTAssertFalse(loaded.hasStoredWiFiPassword)
        XCTAssertFalse(loaded.hasStoredAPIKey)
    }

    func testPlaceholderKeychainValuesDoNotHideStoredProjectSecrets() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        _ = try store.save(configuration())
        try secrets.write(" your-password ", for: .wifiPassword)
        try secrets.write("your-api-key", for: .asrAPIKey)

        let loaded = try store.load()

        XCTAssertTrue(loaded.hasStoredWiFiPassword)
        XCTAssertTrue(loaded.hasStoredAPIKey)
    }

    func testLegacyGroqConfigurationLoadsAsCustomAndSavesGenericProvider() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        var legacy = configuration()
        legacy.asrProvider = .custom
        legacy.asrBaseURL = "https://legacy.example.com/openai/v1"
        legacy.asrModel = "legacy-whisper-model"
        _ = try store.save(legacy)

        let envURL = temporaryRoot.appendingPathComponent(".env")
        let genericEnv = try String(contentsOf: envURL, encoding: .utf8)
        let legacyEnv = genericEnv.replacingOccurrences(
            of: "VIBE_STICK_ASR_PROVIDER='openai-compatible'",
            with: "VIBE_STICK_ASR_PROVIDER='groq'"
        )
        try legacyEnv.write(to: envURL, atomically: true, encoding: .utf8)

        let loaded = try store.load()
        XCTAssertEqual(loaded.asrProvider, .custom)
        XCTAssertEqual(loaded.asrBaseURL, "https://legacy.example.com/openai/v1")
        XCTAssertEqual(loaded.asrModel, "legacy-whisper-model")
        _ = try store.save(loaded)

        let migratedEnv = try String(contentsOf: envURL, encoding: .utf8)
        XCTAssertTrue(migratedEnv.contains("VIBE_STICK_ASR_PROVIDER='openai-compatible'"))
        XCTAssertFalse(migratedEnv.contains("VIBE_STICK_ASR_PROVIDER='groq'"))
    }

    func testRejectsSymlinkDestination() throws {
        let outside = temporaryRoot.appendingPathComponent("outside")
        try "sentinel".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: temporaryRoot.appendingPathComponent(".env"),
            withDestinationURL: outside
        )
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)

        XCTAssertThrowsError(try store.save(configuration())) { error in
            guard case SetupCoreError.unsafePath = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "sentinel")
    }

    func testKeychainFailureRollsFilesAndSecretsBack() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        _ = try store.save(configuration())
        let envURL = temporaryRoot.appendingPathComponent(".env")
        let headerURL = temporaryRoot.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.h")
        let originalEnv = try Data(contentsOf: envURL)
        let originalHeader = try Data(contentsOf: headerURL)

        var changed = configuration()
        changed.wifiPassword = "different-wifi-password"
        changed.asrAPIKey = "different-api-key"
        secrets.successfulWritesBeforeFailure = 1

        XCTAssertThrowsError(try store.save(changed))
        secrets.successfulWritesBeforeFailure = nil
        XCTAssertEqual(try Data(contentsOf: envURL), originalEnv)
        XCTAssertEqual(try Data(contentsOf: headerURL), originalHeader)
        XCTAssertEqual(try secrets.read(.wifiPassword), "wifi'password")
        XCTAssertEqual(try secrets.read(.asrAPIKey), "api-secret")
    }

    func testSaveNormalizesNonSecretTextFields() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        var input = configuration()
        input.bridgeHost = " 192.168.50.5 "
        input.asrBaseURL = " https://api.siliconflow.cn/v1 "
        input.asrModel = " FunAudioLLM/SenseVoiceSmall "
        input.asrLanguage = " zh "

        let saved = try store.save(input)

        XCTAssertEqual(saved.bridgeHost, "192.168.50.5")
        XCTAssertEqual(saved.asrBaseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(saved.asrModel, "FunAudioLLM/SenseVoiceSmall")
        XCTAssertEqual(saved.asrLanguage, "zh")
    }

    func testCurrentProjectFilesWinOverStaleKeychainValues() throws {
        let store = RepositoryConfigurationStore(projectRoot: temporaryRoot, secretStore: secrets)
        _ = try store.save(configuration())
        try secrets.write("stale-wifi-password", for: .wifiPassword)
        try secrets.write("stale-api-key", for: .asrAPIKey)

        let loaded = try store.load()
        _ = try store.save(loaded)

        XCTAssertEqual(try secrets.read(.wifiPassword), "wifi'password")
        XCTAssertEqual(try secrets.read(.asrAPIKey), "api-secret")
        let env = try String(contentsOf: temporaryRoot.appendingPathComponent(".env"), encoding: .utf8)
        XCTAssertFalse(env.contains("stale-api-key"))
    }

    private func configuration() -> SetupConfiguration {
        SetupConfiguration(
            wifiSSID: "Home WiFi",
            wifiPassword: "wifi'password",
            bridgeHost: "192.168.50.5",
            speakerVolume: 65,
            asrProvider: .siliconFlow,
            asrBaseURL: "https://api.siliconflow.cn/v1",
            asrAPIKey: "api-secret",
            asrModel: "FunAudioLLM/SenseVoiceSmall",
            asrLanguage: "zh"
        )
    }

    private func fileMode(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private let envTemplate = """
    VIBE_STICK_ASR_PROVIDER=
    VIBE_STICK_ASR_BASE_URL=
    VIBE_STICK_ASR_API_KEY=
    VIBE_STICK_ASR_MODEL=
    VIBE_STICK_ASR_LANGUAGE=zh
    VIBE_STICK_BRIDGE_TOKEN=paste-generated-token-here
    VIBE_STICK_PROJECT_ROOT=
    """

    private let headerTemplate = """
    #pragma once
    #define VIBE_STICK_WIFI_SSID "your-wifi"
    #define VIBE_STICK_WIFI_PASSWORD "your-password"
    #define VIBE_STICK_BRIDGE_HOST "192.168.1.10"
    #define VIBE_STICK_BRIDGE_TOKEN "paste-generated-token-here"
    """
}

private final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private var values: [SetupSecret: String] = [:]
    private let lock = NSLock()
    var successfulWritesBeforeFailure: Int?

    func read(_ secret: SetupSecret) throws -> String? {
        lock.withLock { values[secret] }
    }

    func write(_ value: String, for secret: SetupSecret) throws {
        try lock.withLock {
            if let remaining = successfulWritesBeforeFailure {
                guard remaining > 0 else {
                    successfulWritesBeforeFailure = nil
                    throw MemorySecretError.writeFailed
                }
                successfulWritesBeforeFailure = remaining - 1
            }
            values[secret] = value
        }
    }

    func delete(_ secret: SetupSecret) throws {
        _ = lock.withLock { values.removeValue(forKey: secret) }
    }
}

private enum MemorySecretError: Error {
    case writeFailed
}
