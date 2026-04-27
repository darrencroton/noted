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
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyScreenShareVisibility()
        statusBarController.setup(settings: settings)
        popupController.start()

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
        popupController.stop()
    }
}
