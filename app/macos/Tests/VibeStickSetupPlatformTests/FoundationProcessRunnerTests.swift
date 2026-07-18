import Foundation
import XCTest
@testable import VibeStickSetupCore
@testable import VibeStickSetupPlatform

final class FoundationProcessRunnerTests: XCTestCase {
    func testInheritsOnlyAllowlistedNetworkEnvironment() async throws {
        let runner = FoundationProcessRunner(processEnvironment: [
            "LANG": "zh_CN.UTF-8",
            "HTTP_PROXY": "http://proxy.example:8080",
            "https_proxy": "http://lower-proxy.example:8081",
            "NO_PROXY": "localhost,127.0.0.1",
            "SSL_CERT_FILE": "/tmp/custom-ca.pem",
            "REQUESTS_CA_BUNDLE": "/tmp/requests-ca.pem",
            "CURL_CA_BUNDLE": "/tmp/curl-ca.pem",
            "VIBE_STICK_UNRELATED_SECRET": "must-not-be-inherited",
        ])
        let script = """
        test "$HTTP_PROXY" = 'http://proxy.example:8080' &&
        test "$https_proxy" = 'http://lower-proxy.example:8081' &&
        test "$NO_PROXY" = 'localhost,127.0.0.1' &&
        test "$SSL_CERT_FILE" = '/tmp/custom-ca.pem' &&
        test "$REQUESTS_CA_BUNDLE" = '/tmp/requests-ca.pem' &&
        test "$CURL_CA_BUNDLE" = '/tmp/curl-ca.pem' &&
        test -z "$VIBE_STICK_UNRELATED_SECRET" &&
        printf 'network environment ok\\n'
        """
        let command = CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory,
            displayName: "network environment test"
        )

        let result = try await runner.run(command, redacting: [], onOutput: { _ in })

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, "network environment ok\n")
    }

    func testAutomaticallyRedactsInheritedProxyValues() async throws {
        let proxy = "http://proxy-user:proxy-password@proxy.example:8080"
        let runner = FoundationProcessRunner(processEnvironment: [
            "HTTPS_PROXY": proxy,
        ])
        let command = CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$HTTPS_PROXY\""],
            workingDirectory: FileManager.default.temporaryDirectory,
            displayName: "proxy redaction test"
        )

        let result = try await runner.run(command, redacting: [], onOutput: { _ in })

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.output.contains(proxy))
        XCTAssertFalse(result.output.contains("proxy-password"))
        XCTAssertEqual(result.output, "••••••\n")
    }

    func testRedactsSecretSplitAcrossPipeReads() async throws {
        let runner = FoundationProcessRunner()
        let command = CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf super; sleep 0.05; printf 'secret\\n'"],
            workingDirectory: FileManager.default.temporaryDirectory,
            displayName: "redaction test"
        )

        let result = try await runner.run(command, redacting: ["supersecret"], onOutput: { _ in })

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.output.contains("supersecret"))
        XCTAssertTrue(result.output.contains("••••••"))
    }

    func testCancellationTerminatesDirectProcess() async throws {
        let runner = FoundationProcessRunner()
        let command = CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            workingDirectory: FileManager.default.temporaryDirectory,
            displayName: "cancellation test"
        )
        let task = Task {
            try await runner.run(command, redacting: [], onOutput: { _ in })
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        runner.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .cancelled)
        }

        let followUp = try await runner.run(
            CommandSpec(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                workingDirectory: FileManager.default.temporaryDirectory,
                displayName: "reuse after cancellation"
            ),
            redacting: [],
            onOutput: { _ in }
        )
        XCTAssertEqual(followUp.exitCode, 0)
    }

    func testCancellationTerminatesEntireProcessGroup() async throws {
        let runner = FoundationProcessRunner()
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibestick-descendant-\(UUID().uuidString).pid")
        let survivalFile = pidFile.appendingPathExtension("survived")
        defer {
            try? FileManager.default.removeItem(at: pidFile)
            try? FileManager.default.removeItem(at: survivalFile)
        }

        // Both shells ignore TERM to exercise the one-second KILL fallback.
        // The shell snippet is test-owned; production commands still use the
        // fixed executable + argv API without interpolating form input.
        let script = """
        trap '' TERM
        (trap '' TERM; /bin/sleep 3; printf survived > '\(survivalFile.path)') &
        child=$!
        printf '%s\\n' "$child" > '\(pidFile.path)'
        wait "$child"
        """
        let command = CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory,
            displayName: "process-group cancellation test"
        )
        let task = Task {
            try await runner.run(command, redacting: [], onOutput: { _ in })
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let contents = try? String(contentsOf: pidFile, encoding: .utf8),
              let descendantPID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            runner.cancel()
            _ = try? await task.value
            return XCTFail("descendant did not start")
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .cancelled)
        }

        for _ in 0..<100 where processExists(descendantPID) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(processExists(descendantPID), "descendant survived process-group cancellation")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: survivalFile.path),
            "descendant kept running after its group leader was cancelled"
        )
    }

    func testLateCancelAfterLeaderExitDoesNotReclassifySuccessfulCommand() async throws {
        let runner = FoundationProcessRunner()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibestick-late-cancel-\(UUID().uuidString)")
        let leaderPIDFile = base.appendingPathExtension("leader")
        let descendantMarker = base.appendingPathExtension("descendant")
        defer {
            try? FileManager.default.removeItem(at: leaderPIDFile)
            try? FileManager.default.removeItem(at: descendantMarker)
        }

        // The leader exits successfully at once, while its background child
        // deliberately retains stdout so run() remains suspended in pipe EOF.
        let script = """
        printf '%s\\n' "$$" > '\(leaderPIDFile.path)'
        (/bin/sleep 0.5; printf survived > '\(descendantMarker.path)') &
        exit 0
        """
        let task = Task {
            try await runner.run(
                CommandSpec(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script],
                    workingDirectory: FileManager.default.temporaryDirectory,
                    displayName: "late cancellation test"
                ),
                redacting: [],
                onOutput: { _ in }
            )
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: leaderPIDFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let contents = try? String(contentsOf: leaderPIDFile, encoding: .utf8),
              let leaderPID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            runner.cancel()
            _ = try? await task.value
            return XCTFail("leader PID was not recorded")
        }
        for _ in 0..<100 where processExists(leaderPID) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(processExists(leaderPID), "leader was not reaped")

        // Give the waitpid completion block time to execute markExited while
        // the descendant still holds the pipe open.
        try await Task.sleep(nanoseconds: 30_000_000)
        runner.cancel()

        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: descendantMarker.path),
            "late cancellation signalled a descendant of an already successful command"
        )
    }

    func testRejectsRelativeExecutable() async {
        let runner = FoundationProcessRunner()
        let command = CommandSpec(
            executable: URL(string: "bin/tool")!,
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory,
            displayName: "unsafe command"
        )

        do {
            _ = try await runner.run(command, redacting: [], onOutput: { _ in })
            XCTFail("expected unsafe path rejection")
        } catch let error as SetupCoreError {
            guard case .unsafePath = error else { return XCTFail("unexpected error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func processExists(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno != ESRCH
    }
}
