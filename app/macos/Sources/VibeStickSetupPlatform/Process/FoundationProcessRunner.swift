import Darwin
import Foundation
import VibeStickProcessLauncher
import VibeStickSetupCore

public final class FoundationProcessRunner: ProcessRunning, @unchecked Sendable {
    private static let proxyEnvironmentKeys = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "all_proxy",
    ]
    private static let networkEnvironmentKeys = proxyEnvironmentKeys + [
        "NO_PROXY", "no_proxy",
        "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    ]

    private let lock = NSLock()
    private var activeProcess: ActiveProcess?
    private let maximumOutputBytes: Int
    private let processEnvironment: [String: String]

    public init(maximumOutputBytes: Int = 1_000_000) {
        self.maximumOutputBytes = maximumOutputBytes
        processEnvironment = ProcessInfo.processInfo.environment
    }

    init(
        maximumOutputBytes: Int = 1_000_000,
        processEnvironment: [String: String]
    ) {
        self.maximumOutputBytes = maximumOutputBytes
        self.processEnvironment = processEnvironment
    }

    public func run(
        _ command: CommandSpec,
        redacting secrets: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        guard command.executable.isFileURL,
              command.executable.path.hasPrefix("/"),
              !command.executable.path.utf8.contains(0)
        else {
            throw SetupCoreError.unsafePath(command.executable.path)
        }
        guard command.workingDirectory.isFileURL,
              command.workingDirectory.path.hasPrefix("/"),
              !command.workingDirectory.path.utf8.contains(0)
        else {
            throw SetupCoreError.unsafePath(command.workingDirectory.path)
        }

        let environment = minimalEnvironment()
        let inheritedProxySecrets = Self.proxyEnvironmentKeys.compactMap { environment[$0] }
        let collector = OutputCollector(
            maximumBytes: maximumOutputBytes,
            redactor: SecretRedactor(secrets: secrets + inheritedProxySecrets),
            onOutput: onOutput
        )
        let active = ActiveProcess()

        guard claim(active) else {
            throw SetupCoreError.commandAlreadyRunning
        }

        return try await withTaskCancellationHandler {
            do {
                let launched = try launch(command, environment: environment)
                active.register(processGroupID: launched.processID)

                let outputHandle = FileHandle(
                    fileDescriptor: launched.outputFileDescriptor,
                    closeOnDealloc: true
                )
                let readerGroup = DispatchGroup()
                readerGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer {
                        try? outputHandle.close()
                        readerGroup.leave()
                    }
                    while true {
                        let data = outputHandle.readData(ofLength: 16_384)
                        guard !data.isEmpty else { break }
                        collector.append(data)
                    }
                }

                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        var exitCode: Int32 = 0
                        var terminationSignal: Int32 = 0
                        let waitError = vibestick_wait_process(
                            launched.processID,
                            &exitCode,
                            &terminationSignal
                        )
                        // Retire the PGID as soon as waitpid reaps the leader.
                        // This closes the window where a late cancel could hit
                        // an unrelated process group that reused the numeric ID.
                        active.markExited()

                        // Descendants inherit the output descriptor. Waiting for
                        // EOF also preserves their last buffered log lines.
                        readerGroup.wait()
                        active.waitForCancellationCleanup()
                        collector.flush()
                        self?.clearActiveProcess(active)

                        if active.wasCancellationRequested {
                            continuation.resume(throwing: SetupCoreError.cancelled)
                        } else if waitError != 0 {
                            continuation.resume(
                                throwing: makePOSIXError(waitError, operation: "等待子进程")
                            )
                        } else {
                            continuation.resume(
                                returning: CommandResult(
                                    exitCode: exitCode,
                                    outputWasTruncated: collector.wasTruncated,
                                    output: collector.output
                                )
                            )
                        }
                    }
                }
            } catch {
                clearActiveProcess(active)
                throw error
            }
        } onCancel: {
            active.requestCancellation()
        }
    }

    public func cancel() {
        currentProcess()?.requestCancellation()
    }

    private func launch(
        _ command: CommandSpec,
        environment environmentValues: [String: String]
    ) throws -> LaunchedProcess {
        let arguments = try CStringArray([command.executable.path] + command.arguments)
        let environment = try CStringArray(
            environmentValues
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        )

        var processID: pid_t = 0
        var outputFileDescriptor: Int32 = -1
        let result = command.executable.path.withCString { executable in
            command.workingDirectory.path.withCString { workingDirectory in
                vibestick_spawn_process_group(
                    executable,
                    arguments.pointer,
                    environment.pointer,
                    workingDirectory,
                    &processID,
                    &outputFileDescriptor
                )
            }
        }
        guard result == 0 else {
            throw makePOSIXError(result, operation: "启动 \(command.displayName)")
        }
        return LaunchedProcess(
            processID: processID,
            outputFileDescriptor: outputFileDescriptor
        )
    }

    private func claim(_ process: ActiveProcess) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeProcess == nil else { return false }
        activeProcess = process
        return true
    }

    private func clearActiveProcess(_ process: ActiveProcess) {
        lock.lock()
        if activeProcess === process {
            activeProcess = nil
        }
        lock.unlock()
    }

    private func currentProcess() -> ActiveProcess? {
        lock.lock()
        defer { lock.unlock() }
        return activeProcess
    }

    private func minimalEnvironment() -> [String: String] {
        let source = processEnvironment
        var environment: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": source["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": source["LC_ALL"] ?? "en_US.UTF-8",
        ]
        for key in ["TMPDIR", "SSH_AUTH_SOCK", "IDF_PATH"] {
            if let value = source[key] { environment[key] = value }
        }
        for key in Self.networkEnvironmentKeys {
            if let value = source[key] { environment[key] = value }
        }
        return environment
    }
}

private struct LaunchedProcess: Sendable {
    let processID: pid_t
    let outputFileDescriptor: Int32
}

private func makePOSIXError(_ code: Int32, operation: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [
            NSLocalizedDescriptionKey: "\(operation)失败：\(String(cString: strerror(code)))",
        ]
    )
}

private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let strings: [UnsafeMutablePointer<CChar>]

    init(_ values: [String]) throws {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(values.count)
        for value in values {
            guard !value.utf8.contains(0) else {
                allocated.forEach { free($0) }
                throw makePOSIXError(EINVAL, operation: "准备进程参数")
            }
            guard let string = strdup(value) else {
                allocated.forEach { free($0) }
                throw makePOSIXError(ENOMEM, operation: "准备进程参数")
            }
            allocated.append(string)
        }
        strings = allocated
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = string
        }
        pointer[strings.count] = nil
    }

    deinit {
        strings.forEach { free($0) }
        pointer.deallocate()
    }
}

private final class ActiveProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var leaderExited = false
    private var cancellationRequested = false
    private var cancellationWork: CancellationWork?

    var wasCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func register(processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let work = makeCancellationWorkIfNeeded()
        lock.unlock()
        work?.start()
    }

    func requestCancellation() {
        lock.lock()
        guard !leaderExited else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let work = makeCancellationWorkIfNeeded()
        lock.unlock()
        work?.start()
    }

    func markExited() {
        lock.lock()
        leaderExited = true
        // If cancellation won the lock race, its cleanup still owns this PGID
        // and must finish terminating inherited descendants. Otherwise retire
        // it now; future cancel requests must neither signal nor reclassify the
        // successfully exited command.
        if cancellationWork == nil {
            processGroupID = nil
        }
        lock.unlock()
    }

    func waitForCancellationCleanup() {
        lock.lock()
        let work = cancellationWork
        lock.unlock()
        work?.wait()
    }

    /// Must be called with `lock` held. The work is installed before it can
    /// start, keeping concurrent cancel requests idempotent.
    private func makeCancellationWorkIfNeeded() -> CancellationWork? {
        guard cancellationRequested,
              cancellationWork == nil,
              let processGroupID
        else { return nil }
        let work = CancellationWork(processGroupID: processGroupID)
        cancellationWork = work
        return work
    }
}

private final class CancellationWork: @unchecked Sendable {
    private let processGroupID: pid_t
    private let completion = DispatchGroup()
    private let startLock = NSLock()
    private var started = false

    init(processGroupID: pid_t) {
        self.processGroupID = processGroupID
        completion.enter()
    }

    func start() {
        startLock.lock()
        guard !started else {
            startLock.unlock()
            return
        }
        started = true
        startLock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completion.leave() }
            _ = vibestick_signal_process_group(processGroupID, SIGTERM)
            if waitUntilGroupExits(timeout: 1.0) { return }
            _ = vibestick_signal_process_group(processGroupID, SIGKILL)
            _ = waitUntilGroupExits(timeout: 1.0)
        }
    }

    func wait() {
        completion.wait()
    }

    private func waitUntilGroupExits(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        repeat {
            if vibestick_process_group_exists(processGroupID) == 0 {
                return true
            }
            usleep(20_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return vibestick_process_group_exists(processGroupID) == 0
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let redactor: SecretRedactor
    private let onOutput: @Sendable (String) -> Void
    private var capturedBytes = 0
    private var truncated = false
    private var pending = Data()
    private var renderedOutput = ""

    init(maximumBytes: Int, redactor: SecretRedactor, onOutput: @escaping @Sendable (String) -> Void) {
        self.maximumBytes = maximumBytes
        self.redactor = redactor
        self.onOutput = onOutput
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return renderedOutput
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let remaining = max(0, maximumBytes - capturedBytes)
        let kept = data.prefix(remaining)
        capturedBytes += kept.count
        if kept.count < data.count { truncated = true }
        pending.append(kept)
        let complete: Data
        if let newline = pending.lastIndex(of: 0x0A) {
            let boundary = pending.index(after: newline)
            complete = Data(pending[..<boundary])
            pending.removeSubrange(..<boundary)
        } else {
            complete = Data()
        }
        lock.unlock()
        emit(complete)
    }

    func flush() {
        lock.lock()
        let remainder = pending
        pending.removeAll(keepingCapacity: false)
        let didTruncate = truncated
        lock.unlock()
        emit(remainder)
        if didTruncate {
            emit(Data("\n[日志超过 \(maximumBytes) 字节，后续内容已省略]\n".utf8))
        }
    }

    private func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        let rendered = redactor.redact(String(decoding: data, as: UTF8.self))
        lock.lock()
        renderedOutput.append(rendered)
        lock.unlock()
        onOutput(rendered)
    }
}
