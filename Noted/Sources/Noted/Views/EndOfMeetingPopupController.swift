import AppKit
import SwiftUI

/// Polls for `runtime/pre-end-prompt.json` in the active session directory and shows a floating
/// panel when found.  Button actions invoke the corresponding `noted` CLI commands as subprocesses
/// so that the popup and the CLI share one canonical code path (§9.8).
@MainActor
final class EndOfMeetingPopupController {
    private var pollTimer: Timer?
    private var popupWindow: NSPanel?
    private var popupDelegate: PopupCloseDelegate?
    private var currentPromptSessionDir: URL?

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.checkForPrompt() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        dismissPopup()
    }

    // MARK: - Prompt detection

    private func checkForPrompt() {
        guard let active = RuntimeFiles.readActiveCapture() else {
            dismissPopup()
            return
        }

        let sessionDir = URL(fileURLWithPath: active.sessionDir, isDirectory: true)
        let promptURL = RuntimeFiles.preEndPromptURL(sessionDir: sessionDir)

        guard FileManager.default.fileExists(atPath: promptURL.path) else {
            if currentPromptSessionDir == sessionDir { dismissPopup() }
            return
        }

        // Already showing for this session.
        if currentPromptSessionDir == sessionDir { return }

        guard let promptData = try? Data(contentsOf: promptURL),
              let promptInfo = try? JSONSerialization.jsonObject(with: promptData) as? [String: Any]
        else {
            return
        }
        let isFollowUp = promptInfo["is_follow_up"] as? Bool ?? false

        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = ManifestValidator.validate(data: manifestData).manifest
        else {
            return
        }

        showPopup(sessionID: active.sessionID, sessionDir: sessionDir, manifest: manifest, isFollowUp: isFollowUp)
    }

    // MARK: - Popup lifecycle

    private func showPopup(sessionID: String, sessionDir: URL, manifest: SessionManifest, isFollowUp: Bool) {
        currentPromptSessionDir = sessionDir

        // scheduledEndTime is always non-nil here: the session runner suppresses pre-end-prompt.json
        // for ad hoc sessions (null scheduledEndTime), so this path is never reached for ad hoc.
        let scheduledEnd = manifest.meeting.scheduledEndTime.flatMap(ISO8601.parseDate(_:)) ?? Date()
        let extensionMinutes = manifest.recordingPolicy.defaultExtensionMinutes
        // §12.4: Next Meeting is never re-offered in the follow-up notification.
        let offerNextMeeting = !isFollowUp && manifest.nextMeeting.exists

        let view = EndOfMeetingView(
            meetingTitle: manifest.meeting.title,
            scheduledEnd: scheduledEnd,
            defaultExtensionMinutes: extensionMinutes,
            offerNextMeeting: offerNextMeeting,
            isFollowUp: isFollowUp,
            onStop: { [weak self] in
                self?.dismissPopup()
                self?.invokeCLI(["stop", "--session-id", sessionID])
            },
            onExtend: { [weak self] in
                self?.dismissPopup()
                self?.invokeCLI(["extend", "--session-id", sessionID, "--minutes", "\(extensionMinutes)"])
            },
            onSwitchNext: { [weak self] in
                self?.dismissPopup()
                self?.invokeCLI(["switch-next", "--session-id", sessionID])
            }
        )

        let height: CGFloat = isFollowUp ? 150 : 190
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: height),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "noted"
        panel.contentViewController = NSHostingController(rootView: view)
        panel.level = .floating
        panel.center()

        let delegate = PopupCloseDelegate { [weak self] in self?.handlePopupClose() }
        panel.delegate = delegate
        popupDelegate = delegate

        // Without activation, an LSUIElement app's floating panel renders behind the foreground app.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        popupWindow = panel
    }

    private func dismissPopup() {
        popupWindow?.orderOut(nil)
        popupWindow = nil
        popupDelegate = nil
        currentPromptSessionDir = nil
    }

    private func handlePopupClose() {
        // User closed the panel without pressing a button — no-interaction rules in §12.3
        // continue to apply; the session runner's grace timer handles auto-stop/auto-switch.
        currentPromptSessionDir = nil
        popupWindow = nil
        popupDelegate = nil
    }

    // MARK: - CLI invocation

    private func invokeCLI(_ arguments: [String]) {
        guard let executableURL = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}

// MARK: - NSWindowDelegate bridge

private final class PopupCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - SwiftUI popup view

struct EndOfMeetingView: View {
    let meetingTitle: String
    let scheduledEnd: Date
    let defaultExtensionMinutes: Int
    let offerNextMeeting: Bool
    let isFollowUp: Bool
    let onStop: () -> Void
    let onExtend: () -> Void
    let onSwitchNext: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Text(isFollowUp ? "Still recording?" : "Session ending soon")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(meetingTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = scheduledEnd.timeIntervalSince(context.date)
                Text(remaining > 0 ? formatRemaining(remaining) : "Past scheduled end")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(remaining <= 60 ? .red : .primary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            if isFollowUp {
                HStack(spacing: 8) {
                    Button("Still going (+\(defaultExtensionMinutes) min)") { onExtend() }
                        .buttonStyle(.bordered)
                    Button("Stop", role: .destructive) { onStop() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    Button("Stop", role: .destructive) { onStop() }
                    Button("+\(defaultExtensionMinutes) min") { onExtend() }
                    if offerNextMeeting {
                        Button("Next Meeting") { onSwitchNext() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(18)
        .frame(width: 304)
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(abs(seconds))
        let m = s / 60
        let sec = s % 60
        return m > 0 ? String(format: "%d:%02d remaining", m, sec) : String(format: "0:%02d remaining", sec)
    }
}
