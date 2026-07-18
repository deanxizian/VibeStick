import Darwin
import Foundation
import VibeStickSetupCore

public enum ProjectLocator {
    private static let markerPaths = [
        "firmware/sticks3/CMakeLists.txt",
        "scripts/install.sh",
        "bridge/src/vibe_stick/__init__.py",
    ]
    private static let templateVersionPath = ".vibestick-template-version"
    private static let managedProjectPath = "VibeStick/InstallerProject"
    private static let preservedPaths = [
        ".env",
        "firmware/sticks3/include/vibe_stick_secrets.h",
    ]
    private static let maximumPreservedFileSize = 1_048_576

    public static func locate(
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        if bundleURL.pathExtension != "app",
           let override = environment["VIBE_STICK_PROJECT_ROOT"],
           !override.isEmpty {
            let explicitRoot = URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if isProjectRoot(explicitRoot, fileManager: fileManager) {
                return explicitRoot
            }
        }

        let managedRoot = applicationSupportDirectory
            .appendingPathComponent(managedProjectPath, isDirectory: true)
            .standardizedFileURL
        let templateRoot = bundleURL
            .appendingPathComponent("Contents/Resources/VibeStickProject", isDirectory: true)
            .standardizedFileURL

        if isProjectRoot(templateRoot, fileManager: fileManager) {
            return try installOrUpdateManagedProject(
                from: templateRoot,
                to: managedRoot,
                fileManager: fileManager
            )
        }
        if isProjectRoot(managedRoot, fileManager: fileManager) {
            return managedRoot.resolvingSymlinksInPath()
        }

        // A packaged installer must be self-contained. Falling back to the
        // bundle's ancestors would make an app in Documents trigger TCC and
        // silently depend on a nearby source checkout.
        if bundleURL.pathExtension == "app" {
            throw SetupCoreError.projectNotFound
        }

        var candidates = [currentDirectory]
        var cursor = bundleURL
        for _ in 0..<6 {
            candidates.append(cursor)
            cursor.deleteLastPathComponent()
        }

        for candidate in candidates {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            if isProjectRoot(resolved, fileManager: fileManager) {
                return resolved
            }
        }
        throw SetupCoreError.projectNotFound
    }

    public static func isProjectRoot(_ root: URL, fileManager: FileManager = .default) -> Bool {
        markerPaths.allSatisfy { relativePath in
            var isDirectory: ObjCBool = false
            let path = root.appendingPathComponent(relativePath).path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private static func installOrUpdateManagedProject(
        from templateRoot: URL,
        to managedRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        try rejectSymbolicLink(at: managedRoot, fileManager: fileManager)

        let parent = managedRoot.deletingLastPathComponent()
        try rejectSymbolicLink(at: parent, fileManager: fileManager)
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let lockURL = parent.appendingPathComponent(".installer-project.lock")
        return try withExclusiveLock(at: lockURL) {
            let templateVersion = try version(at: templateRoot)
            let managedVersion = try? version(at: managedRoot)
            if isProjectRoot(managedRoot, fileManager: fileManager),
               managedVersion == templateVersion {
                return managedRoot.resolvingSymlinksInPath()
            }

            return try replaceManagedProject(
                from: templateRoot,
                templateVersion: templateVersion,
                at: managedRoot,
                parent: parent,
                fileManager: fileManager
            )
        }
    }

    private static func replaceManagedProject(
        from templateRoot: URL,
        templateVersion: String,
        at managedRoot: URL,
        parent: URL,
        fileManager: FileManager
    ) throws -> URL {
        let stagingRoot = parent.appendingPathComponent(
            ".InstallerProject-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.copyItem(at: templateRoot, to: stagingRoot)

        for relativePath in preservedPaths {
            guard let data = try preservedData(
                at: managedRoot.appendingPathComponent(relativePath),
                fileManager: fileManager
            ) else { continue }
            let destination = stagingRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }

        guard isProjectRoot(stagingRoot, fileManager: fileManager),
              try version(at: stagingRoot) == templateVersion else {
            throw SetupCoreError.projectNotFound
        }

        if fileManager.fileExists(atPath: managedRoot.path) {
            _ = try fileManager.replaceItemAt(
                managedRoot,
                withItemAt: stagingRoot,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingRoot, to: managedRoot)
        }
        return managedRoot.resolvingSymlinksInPath()
    }

    private static func withExclusiveLock<T>(at url: URL, body: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SetupCoreError.unsafePath(url.path) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SetupCoreError.unsafePath(url.path)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func version(at root: URL) throws -> String {
        let url = root.appendingPathComponent(templateVersionPath)
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SetupCoreError.projectNotFound }
        return value
    }

    private static func preservedData(at url: URL, fileManager: FileManager) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= maximumPreservedFileSize else {
            throw SetupCoreError.unsafePath(url.path)
        }
        return try Data(contentsOf: url)
    }

    private static func rejectSymbolicLink(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw SetupCoreError.unsafePath(url.path)
        }
    }
}
