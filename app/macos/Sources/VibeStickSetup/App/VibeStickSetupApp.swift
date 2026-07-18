import AppKit
import Darwin
import OSLog
import SwiftUI

@main
struct VibeStickSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SetupStore.shared

    var body: some Scene {
        WindowGroup("VibeStick 安装器") {
            SetupRootView(store: store)
                .task { store.start() }
        }
        .defaultSize(width: 900, height: 680)

        Window("活动日志", id: "activity-log") {
            ActivityLogView(store: store)
                .frame(minWidth: 680, minHeight: 420)
        }

    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindowTitle = "VibeStick 安装器"
    private let logger = Logger(subsystem: "com.vibestick.setup", category: "lifecycle")
    private var terminationPending = false
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var fallbackMainWindow: NSWindow?
    private var instanceLockDescriptor: Int32 = -1

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            logger.info("Another VibeStick installer instance is already running")
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.vibestick.setup")
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                .activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application finished launching")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installTerminationSignalHandlers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showMainWindowIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SetupStore.shared.isBusy else { return .terminateNow }
        if SetupStore.shared.isFlashing {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "正在写入 StickS3"
            alert.informativeText = "现在退出可能让设备暂时无法启动。建议继续安装；即使中断，也可以稍后重新安装恢复。"
            alert.addButton(withTitle: "继续安装")
            alert.addButton(withTitle: "中断并退出")
            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await SetupStore.shared.cancelAndWaitForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources = []
        if instanceLockDescriptor >= 0 {
            flock(instanceLockDescriptor, LOCK_UN)
            close(instanceLockDescriptor)
            instanceLockDescriptor = -1
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindowIfNeeded() }
        return true
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func acquireSingleInstanceLock() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeStick", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            logger.error("Could not create the application-data directory: \(error.localizedDescription)")
            return false
        }

        let lockURL = directory.appendingPathComponent(".installer-app.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            logger.error("Could not open the single-instance lock")
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        instanceLockDescriptor = descriptor
        return true
    }

    private func showMainWindowIfNeeded() {
        logger.info("Ensuring main window; current window count: \(NSApp.windows.count)")
        if let existing = NSApp.windows.first(where: { $0.title == mainWindowTitle }) {
            logger.info("Showing SwiftUI-managed main window")
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let fallbackMainWindow {
            logger.info("Reopening fallback main window")
            fallbackMainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(
            rootView: SetupRootView(store: SetupStore.shared)
                .task { SetupStore.shared.start() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = mainWindowTitle
        window.contentViewController = controller
        window.minSize = NSSize(width: 820, height: 610)
        window.setFrameAutosaveName("VibeStickSetup.MainWindow")
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        fallbackMainWindow = window
        logger.info("Created fallback main window")
        NSApp.activate(ignoringOtherApps: true)
    }
}
