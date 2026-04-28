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
    private var diagCheckCount = 0 // DIAG:

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForPrompt() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        dismissPopup()
    }

    // MARK: - Prompt detection

    private func checkForPrompt() {
        // DIAG: sample-log every 12 checks (~60 s) to confirm the poll timer is alive
        diagCheckCount += 1
        if diagCheckCount == 1 || diagCheckCount % 12 == 0 {
            appendDiagLog("diag_popup_alive count=\(diagCheckCount) has_active=\(RuntimeFiles.readActiveCapture() != nil)")
        }

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
            appendDiagLog("diag_popup_bad_prompt_data") // DIAG:
            return
        }
        let isFollowUp = promptInfo["is_follow_up"] as? Bool ?? false

        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = ManifestValidator.validate(data: manifestData).manifest
        else {
            appendDiagLog("diag_popup_manifest_invalid session_dir=\(active.sessionDir)") // DIAG:
            return
        }

        appendDiagLog("diag_popup_calling_show session_id=\(active.sessionID)") // DIAG:
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
        appendDiagLog("diag_popup_panel_shown session_id=\(sessionID) isFollowUp=\(isFollowUp)") // DIAG:
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

    // DIAG: diagnostic log helper - delete this function and all callers marked DIAG: when bug is resolved
    private func appendDiagLog(_ message: String) {
        let logURL = RuntimeFiles.runtimeDirectory.appendingPathComponent("popup-diag.log")
        let line = "[\(ISO8601.withOffset(Date()))] \(message)\n"
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: Data(line.utf8))
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
        VStack(alignment: .leading, spacing: 10) {
            Text(isFollowUp ? "Still recording?" : "Session ending soon")
                .font(.headline)

            Text(meetingTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = scheduledEnd.timeIntervalSince(context.date)
                Text(remaining > 0 ? formatRemaining(remaining) : "Past scheduled end")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(remaining <= 60 ? .red : .primary)
            }

            Divider()

            if isFollowUp {
                HStack {
                    Button("Still going (+\(defaultExtensionMinutes) min)") { onExtend() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Stop", role: .destructive) { onStop() }
                        .buttonStyle(.bordered)
                }
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
