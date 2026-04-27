import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var statusWindow: NSWindow?

    private var settings: AppSettings?
    private var recordingState: RecordingState?
    private var sessionController: SessionController?
    private var runtimePollTimer: Timer?
    private var adHocStartInProgress = false
    private var adHocStartProcess: Process?
    private var stopProcess: Process?

    func setup(
        settings: AppSettings,
        recordingState: RecordingState,
        sessionController: SessionController
    ) {
        guard statusItem == nil else { return }
        self.settings = settings
        self.recordingState = recordingState
        self.sessionController = sessionController

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item

        updateIcon()
        observeIcon()
        startRuntimePolling()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenuItems(into: menu)
    }

    private func buildMenuItems(into menu: NSMenu) {
        guard let recordingState else { return }
        let bridgedStatus = currentRuntimeStatus()

        let title = NSMenuItem(title: "noted", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let statusTitle = bridgedStatus?.status ?? (recordingState.isBusy ? recordingState.phase.menuTitle.lowercased() : "idle")
        let state = NSMenuItem(title: "Status: \(statusTitle)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let bridgedStatus {
            let phase = NSMenuItem(title: "Phase: \(bridgedStatus.phase)", action: nil, keyEquivalent: "")
            phase.isEnabled = false
            menu.addItem(phase)
        }
        menu.addItem(.separator())

        let activeCapture = RuntimeFiles.readLiveActiveCapture()

        let start = makeItem("Start Ad Hoc Session", action: #selector(startRecording(_:)))
        start.isEnabled = activeCapture == nil && !adHocStartInProgress
        menu.addItem(start)

        if activeCapture != nil {
            let stop = makeItem("Stop Recording", action: #selector(stopActiveCapture(_:)))
            stop.isEnabled = true
            menu.addItem(stop)
        }

        menu.addItem(makeItem("Status", action: #selector(showStatus(_:))))
        menu.addItem(.separator())

        let settingsItem = makeItem("Settings...", action: #selector(showSettings(_:)))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = makeItem("Quit noted", action: #selector(quitApp(_:)))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch currentRuntimeStatus()?.status {
        case "recording":
            symbol = "record.circle.fill"
        case "processing":
            symbol = "gearshape.2.fill"
        case "completed", "completed_with_warnings":
            symbol = "checkmark.circle.fill"
        case "failed":
            symbol = "exclamationmark.triangle.fill"
        default:
            switch recordingState?.phase ?? .idle {
            case .idle:
                symbol = "waveform"
            case .starting, .recording:
                symbol = "record.circle.fill"
            case .stopping, .processing:
                symbol = "gearshape.2.fill"
            case .failed:
                symbol = "exclamationmark.triangle.fill"
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "noted")
        button.image?.isTemplate = symbol != "record.circle.fill"
    }

    private func currentRuntimeStatus() -> RuntimeStatus? {
        if let active = RuntimeFiles.readLiveActiveCapture() {
            return RuntimeFiles.readStatus(sessionDir: URL(fileURLWithPath: active.sessionDir, isDirectory: true))
        }
        return nil
    }

    private func observeIcon() {
        withObservationTracking {
            _ = recordingState?.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeIcon()
            }
        }
    }

    private func startRuntimePolling() {
        runtimePollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateIcon()
            }
        }
        timer.tolerance = 0.5
        runtimePollTimer = timer
    }

    @objc private func startRecording(_ sender: NSMenuItem) {
        appendMenuLog("start_ad_hoc_clicked")
        guard RuntimeFiles.readLiveActiveCapture() == nil,
              !adHocStartInProgress,
              adHocStartProcess?.isRunning != true else {
            appendMenuLog("start_ad_hoc_ignored busy_or_active")
            NSSound.beep()
            updateIcon()
            return
        }

        do {
            let settings = RuntimeSettings.load()
            let writer = AdHocManifestWriter(settings: settings)
            let written = try writer.writeManifest()
            appendMenuLog("start_ad_hoc_manifest_written session_id=\(written.manifest.sessionID) manifest=\(written.manifestURL.path)")
            let process = try makeLoggedCLIProcess(
                arguments: ["start", "--manifest", written.manifestURL.path],
                logName: "ad-hoc-start.log"
            )
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { [weak self] in
                    self?.adHocStartInProgress = false
                    self?.adHocStartProcess = nil
                    self?.appendMenuLog("start_ad_hoc_completed session_id=\(written.manifest.sessionID) exit_code=\(process.terminationStatus)")
                    self?.updateIcon()
                    if process.terminationStatus != 0 {
                        self?.showAdHocStartFailure(
                            status: Int(process.terminationStatus),
                            sessionDir: URL(fileURLWithPath: written.manifest.paths.sessionDir)
                        )
                    }
                }
            }
            adHocStartInProgress = true
            adHocStartProcess = process
            try process.run()
            updateIcon()
        } catch {
            adHocStartInProgress = false
            adHocStartProcess = nil
            appendMenuLog("start_ad_hoc_failed error=\(error.localizedDescription)")
            NSSound.beep()
            showAdHocStartFailure(message: error.localizedDescription)
        }
    }

    @objc private func stopRecording(_ sender: NSMenuItem) {
        Task { await sessionController?.stopSession() }
    }

    @objc private func stopActiveCapture(_ sender: NSMenuItem) {
        appendMenuLog("stop_recording_clicked")
        guard let active = RuntimeFiles.readLiveActiveCapture() else {
            appendMenuLog("stop_recording_ignored no_active_capture")
            NSSound.beep()
            updateIcon()
            return
        }

        do {
            let process = try makeLoggedCLIProcess(
                arguments: ["stop", "--session-id", active.sessionID],
                logName: "menu-stop.log"
            )
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { [weak self] in
                    self?.stopProcess = nil
                    self?.appendMenuLog("stop_recording_completed session_id=\(active.sessionID) exit_code=\(process.terminationStatus)")
                    self?.updateIcon()
                }
            }
            stopProcess = process
            try process.run()
            updateIcon()
        } catch {
            stopProcess = nil
            appendMenuLog("stop_recording_failed session_id=\(active.sessionID) error=\(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func makeLoggedCLIProcess(arguments: [String], logName: String) throws -> Process {
        try RuntimeFiles.prepareSupportDirectories()
        let logURL = RuntimeFiles.runtimeDirectory.appendingPathComponent(logName)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()

        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        return process
    }

    private func appendMenuLog(_ message: String) {
        do {
            try RuntimeFiles.prepareSupportDirectories()
            let logURL = RuntimeFiles.runtimeDirectory.appendingPathComponent("menu-actions.log")
            let line = "[\(ISO8601.withOffset(Date()))] \(message)\n"
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
        } catch {
            // Menu diagnostics must not interfere with recording controls.
        }
    }

    private func showAdHocStartFailure(status: Int? = nil, sessionDir: URL? = nil, message: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Ad hoc session could not start"
        if let message {
            alert.informativeText = message
        } else if let status, let sessionDir {
            alert.informativeText = "noted start exited with status \(status). Check \(sessionDir.appendingPathComponent("logs/noted.log").path) for details."
        } else {
            alert.informativeText = "Check noted status for details."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showStatus(_ sender: NSMenuItem) {
        guard let recordingState else { return }
        let view = StatusPanelView(recordingState: recordingState)
        statusWindow = showWindow(statusWindow, title: "noted Status", rootView: view, size: NSSize(width: 360, height: 180))
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        guard let settings else { return }
        let view = SettingsView(settings: settings)
        settingsWindow = showWindow(settingsWindow, title: "noted Settings", rootView: view, size: NSSize(width: 480, height: 300))
    }

    private func showWindow<V: View>(_ existing: NSWindow?, title: String, rootView: V, size: NSSize) -> NSWindow {
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settings?.applyScreenShareVisibility()
        return window
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard recordingState?.isRecording == true else {
            NSApplication.shared.terminate(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = "noted is currently recording. Stop the session before quitting."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await sessionController?.stopSession()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private struct StatusPanelView: View {
    @Bindable var recordingState: RecordingState

    var body: some View {
        Form {
            LabeledContent("Phase", value: recordingState.phase.menuTitle)
            LabeledContent("Session", value: recordingState.currentSessionID ?? "-")
            LabeledContent("Output", value: recordingState.currentSessionDirectory?.path ?? "-")
            if let error = recordingState.lastError {
                LabeledContent("Last Error", value: error)
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 160)
    }
}
