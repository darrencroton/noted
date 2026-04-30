import AppKit
import Darwin

@main
struct NotedApplication {
    @MainActor
    private static var delegate: AppDelegate?

    @MainActor
    static func runApp() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static func main() async {
        if CommandLine.arguments.count > 1 {
            let exitCode = await NotedCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
            Darwin.exit(Int32(exitCode))
        }

        await MainActor.run {
            runApp()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let statusBarController = StatusBarController()
    private let popupController = EndOfMeetingPopupController()
    private var modelPrefetchTask: Task<Void, Never>?
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyScreenShareVisibility()
        statusBarController.setup(settings: settings)
        popupController.start()
        startModelPrefetch()

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settings.applyScreenShareVisibility()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelPrefetchTask?.cancel()
        popupController.stop()
    }

    private func startModelPrefetch() {
        modelPrefetchTask = Task.detached {
            let failures = await ModelCache.prefetchStartupModels()
            guard !failures.isEmpty else { return }
            Self.writeModelPrefetchLog(failures: failures)
        }
    }

    private nonisolated static func writeModelPrefetchLog(failures: [String]) {
        do {
            try RuntimeFiles.prepareSupportDirectories()
            let url = RuntimeFiles.runtimeDirectory.appendingPathComponent("model-prefetch.log")
            let body = failures.map { "[\(Date())] \($0)" }.joined(separator: "\n") + "\n"
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(body.utf8))
                try handle.close()
            } else {
                try body.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            return
        }
    }
}
