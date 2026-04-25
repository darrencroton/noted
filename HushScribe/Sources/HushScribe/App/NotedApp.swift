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
final class AppServices {
    static let shared = AppServices()

    let settings = AppSettings()
    let recordingState = RecordingState()
    let transcriptionEngine = TranscriptionEngine()
    let transcriptLogger = TranscriptLogger()
    lazy var sessionController = SessionController(
        settings: settings,
        recordingState: recordingState,
        transcriptionEngine: transcriptionEngine,
        transcriptLogger: transcriptLogger
    )

    private init() {
        transcriptionEngine.setModel(settings.transcriptionModel)
        transcriptionEngine.setUtteranceHandler { [transcriptLogger] segment in
            Task {
                await transcriptLogger.append(segment)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private let popupController = EndOfMeetingPopupController()
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = AppServices.shared
        services.settings.applyScreenShareVisibility()
        statusBarController.setup(
            settings: services.settings,
            recordingState: services.recordingState,
            sessionController: services.sessionController
        )
        popupController.start()

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppServices.shared.settings.applyScreenShareVisibility()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        popupController.stop()
    }
}
