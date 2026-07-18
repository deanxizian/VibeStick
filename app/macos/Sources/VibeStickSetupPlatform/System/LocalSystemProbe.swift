import Foundation
import VibeStickSetupCore

public final class LocalSystemProbe: SystemProbing, @unchecked Sendable {
    private let projectRoot: URL
    private let serialDiscovery: IOKitSerialDiscovery
    private let addressResolver: LANAddressResolver
    private let fileManager: FileManager

    public init(
        projectRoot: URL,
        serialDiscovery: IOKitSerialDiscovery = .init(),
        addressResolver: LANAddressResolver = .init(),
        fileManager: FileManager = .default
    ) {
        self.projectRoot = projectRoot
        self.serialDiscovery = serialDiscovery
        self.addressResolver = addressResolver
        self.fileManager = fileManager
    }

    public func snapshot() async -> SystemSnapshot {
        let task = Task.detached(priority: .utility) { [self] in
            let addresses = addressResolver.resolve()
            let devices = serialDiscovery.discover()
            let python = findPython()
            let swift = findSwift()
            let idf = findIDFExport()
            let bridgePlist = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.vibestick.bridge.plist")
            let bridgeAvailable = fileManager.fileExists(atPath: bridgePlist.path)

            return SystemSnapshot(
                networkAddresses: addresses,
                serialDevices: devices,
                prerequisites: [
                    python,
                    swift,
                    Prerequisite(
                        kind: .espIDF,
                        available: idf != nil,
                        detail: idf.map { "ESP-IDF \($0.version)" } ?? "未找到 ESP-IDF 5.5.x；首次安装约需下载 1 GB",
                        path: idf?.url.path
                    ),
                    Prerequisite(
                        kind: .bridge,
                        available: bridgeAvailable,
                        detail: bridgeAvailable ? "LaunchAgent 已安装" : "尚未安装 Mac Bridge",
                        path: bridgeAvailable ? bridgePlist.path : nil
                    ),
                ],
                idfExportPath: idf?.url.path
            )
        }
        return await task.value
    }

    private func findPython() -> Prerequisite {
        var candidates: [String] = []
        if let configured = configuredPython(), !configured.isEmpty { candidates.append(configured) }
        candidates.append(managedPythonPath())
        candidates += [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        for candidate in unique(candidates) where fileManager.isExecutableFile(atPath: candidate) {
            let check = run(candidate, ["-c", "import sys; print('.'.join(map(str, sys.version_info[:3]))); raise SystemExit(0 if sys.version_info >= (3, 11) else 1)"])
            if check.status == 0 {
                return Prerequisite(kind: .python, available: true, detail: "Python \(check.output.trimmingCharacters(in: .whitespacesAndNewlines))", path: candidate)
            }
        }
        return Prerequisite(kind: .python, available: false, detail: "需要 Python 3.11 或更新版本")
    }

    private func managedPythonPath() -> String {
        #if arch(arm64)
        let architecture = "aarch64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/vibestick/python/cpython-3.12-macos-\(architecture)-none/bin/python3.12")
            .path
    }

    private func findSwift() -> Prerequisite {
        let lookup = run("/usr/bin/xcrun", ["--find", "swiftc"])
        let path = lookup.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.status == 0, !path.isEmpty else {
            return Prerequisite(kind: .swift, available: false, detail: "需要 Xcode Command Line Tools")
        }
        let version = run(path, ["--version"]).output.split(separator: "\n").first.map(String.init) ?? "swiftc"
        return Prerequisite(kind: .swift, available: true, detail: version, path: path)
    }

    private func findIDFExport() -> (url: URL, version: String)? {
        var candidates: [URL] = []
        if let idfPath = ProcessInfo.processInfo.environment["IDF_PATH"] {
            candidates.append(URL(fileURLWithPath: idfPath).appendingPathComponent("export.sh"))
        }
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("esp/vibestick-esp-idf-v5.5.1/export.sh"))
        candidates.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("esp/esp-idf/export.sh"))
        for exportURL in candidates {
            let root = exportURL.deletingLastPathComponent()
            guard fileManager.isReadableFile(atPath: exportURL.path),
                  let version = idfVersion(at: root),
                  version.hasPrefix("5.5.") else { continue }
            return (exportURL, "v\(version)")
        }
        return nil
    }

    private func idfVersion(at root: URL) -> String? {
        let url = root.appendingPathComponent("tools/cmake/version.cmake")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func component(_ name: String) -> String? {
            let pattern = #"set\(IDF_VERSION_"# + name + #"\s+([0-9]+)\)"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: content,
                      range: NSRange(content.startIndex..., in: content)
                  ),
                  let range = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[range])
        }
        guard let major = component("MAJOR"),
              let minor = component("MINOR"),
              let patch = component("PATCH") else { return nil }
        return "\(major).\(minor).\(patch)"
    }

    private func configuredPython() -> String? {
        let envURL = projectRoot.appendingPathComponent(".env")
        guard let content = try? String(contentsOf: envURL, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            guard line.hasPrefix("VIBE_STICK_PYTHON=") else { continue }
            var value = String(line.dropFirst("VIBE_STICK_PYTHON=".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == value.last, value.first == "'" || value.first == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data.prefix(16_384), as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
