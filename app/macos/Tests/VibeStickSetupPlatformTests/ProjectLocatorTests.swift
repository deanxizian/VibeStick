import Foundation
import XCTest
@testable import VibeStickSetupCore
@testable import VibeStickSetupPlatform

final class ProjectLocatorTests: XCTestCase {
    func testFindsExplicitValidProjectRoot() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")

        XCTAssertEqual(
            try ProjectLocator.locate(
                bundleURL: URL(fileURLWithPath: "/tmp/.build/debug/VibeStickSetup"),
                currentDirectory: URL(fileURLWithPath: "/"),
                environment: ["VIBE_STICK_PROJECT_ROOT": root.path],
                applicationSupportDirectory: support
            ),
            root.resolvingSymlinksInPath()
        )
    }

    func testRejectsDirectoryWithMissingMarkers() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickSupport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        XCTAssertThrowsError(
            try ProjectLocator.locate(
                bundleURL: URL(fileURLWithPath: "/Applications/VibeStickSetup.app"),
                currentDirectory: FileManager.default.temporaryDirectory,
                environment: [:],
                applicationSupportDirectory: support
            )
        )
    }

    func testInstallsBundledTemplateIntoApplicationSupport() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bundle = fixture.appendingPathComponent("VibeStickSetup.app")
        let template = bundle.appendingPathComponent("Contents/Resources/VibeStickProject")
        try makeProject(at: template, version: "template-v1", bridgeMarker: "bundled")
        let support = fixture.appendingPathComponent("Support")

        let located = try ProjectLocator.locate(
            bundleURL: bundle,
            currentDirectory: URL(fileURLWithPath: "/"),
            environment: [:],
            applicationSupportDirectory: support
        )

        XCTAssertEqual(located, support.appendingPathComponent("VibeStick/InstallerProject"))
        XCTAssertEqual(
            try String(
                contentsOf: located.appendingPathComponent("bridge/src/vibe_stick/__init__.py"),
                encoding: .utf8
            ),
            "bundled"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: located.appendingPathComponent(".env").path))
    }

    func testTemplateUpdatePreservesConfigurationFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let bundle = fixture.appendingPathComponent("VibeStickSetup.app")
        let template = bundle.appendingPathComponent("Contents/Resources/VibeStickProject")
        try makeProject(at: template, version: "template-v2", bridgeMarker: "new")
        let support = fixture.appendingPathComponent("Support")
        let managed = support.appendingPathComponent("VibeStick/InstallerProject")
        try makeProject(at: managed, version: "template-v1", bridgeMarker: "old")
        let env = managed.appendingPathComponent(".env")
        let secrets = managed.appendingPathComponent("firmware/sticks3/include/vibe_stick_secrets.h")
        try "ENV_SECRET=preserve-me\n".write(to: env, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: secrets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#define SECRET \"preserve-me\"\n".write(to: secrets, atomically: true, encoding: .utf8)

        let located = try ProjectLocator.locate(
            bundleURL: bundle,
            currentDirectory: URL(fileURLWithPath: "/"),
            environment: [:],
            applicationSupportDirectory: support
        )

        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "ENV_SECRET=preserve-me\n")
        XCTAssertEqual(try String(contentsOf: secrets, encoding: .utf8), "#define SECRET \"preserve-me\"\n")
        XCTAssertEqual(
            try String(
                contentsOf: located.appendingPathComponent("bridge/src/vibe_stick/__init__.py"),
                encoding: .utf8
            ),
            "new"
        )
        XCTAssertEqual(
            try String(contentsOf: located.appendingPathComponent(".vibestick-template-version"), encoding: .utf8),
            "template-v2"
        )
        let envAttributes = try FileManager.default.attributesOfItem(atPath: env.path)
        XCTAssertEqual((envAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPackagedAppDoesNotSearchItsParentCheckout() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let checkout = fixture.appendingPathComponent("Checkout")
        try makeProject(at: checkout)
        let bundle = checkout.appendingPathComponent("dist/VibeStickSetup.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ProjectLocator.locate(
                bundleURL: bundle,
                currentDirectory: URL(fileURLWithPath: "/"),
                environment: [:],
                applicationSupportDirectory: fixture.appendingPathComponent("Support")
            )
        )
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickProject-\(UUID().uuidString)", isDirectory: true)
        try makeProject(at: root)
        return root
    }

    private func makeProject(
        at root: URL,
        version: String? = nil,
        bridgeMarker: String = "marker"
    ) throws {
        for path in [
            "firmware/sticks3/CMakeLists.txt",
            "scripts/install.sh",
            "bridge/src/vibe_stick/__init__.py",
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = path.hasSuffix("__init__.py") ? bridgeMarker : "marker"
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        if let version {
            try version.write(
                to: root.appendingPathComponent(".vibestick-template-version"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickLocatorFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
