import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    private var settings: AppSettings?
    private var runtimePollTimer: Timer?
    private var adHocStartProcess: Process?
    private var stopProcess: Process?
    private var captureControlProcess: Process?
    private var optimisticPauseTarget: OptimisticPauseTarget?

    private struct OptimisticPauseTarget {
        let sessionID: String
        let isPaused: Bool
    }

    func setup(settings: AppSettings) {
        guard statusItem == nil else { return }
        self.settings = settings

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item

        updateIcon()
        startRuntimePolling()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenuItems(into: menu)
    }

    private func buildMenuItems(into menu: NSMenu) {
        clearFinishedControlProcesses()

        let title = NSMenuItem(title: "noted", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let activeCapture = RuntimeFiles.readLiveActiveCapture()
        let recording = isRecording
        let activeStatus = activeCapture.flatMap { readActiveStatus(activeCapture: $0) }
        let paused = displayedPauseState(activeCapture: activeCapture, activeStatus: activeStatus)
        let statusText = paused ? "paused" : (activeStatus?.status ?? "recording")
        let stateTitle = recording ? "Status: \(statusText)" : "Status: ready"
        let state = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if recording, let activeCapture, let details = activeSessionDetails(activeCapture: activeCapture) {
            addDisabledMenuItem("Meeting: \(details.title)", tooltip: details.title, to: menu)
            addDisabledMenuItem("Note: \(details.noteDisplay)", tooltip: details.notePath, to: menu)
        }
        menu.addItem(.separator())

        let isStarting = adHocStartProcess?.isRunning == true
        let canStart = activeCapture == nil && !isStarting
        appendMenuLog("menu_built canStart=\(canStart) activeCapture=\(activeCapture != nil) isStarting=\(isStarting) stopProcessRunning=\(stopProcess?.isRunning == true) paused=\(paused)")

        if canStart {
            menu.addItem(makeItem("Start Ad Hoc Session", action: #selector(startRecording(_:))))
        } else if activeCapture != nil {
            if activeStatus?.status == "recording" {
                menu.addItem(makeItem(paused ? "Continue Recording" : "Pause Recording", action: #selector(togglePauseActiveCapture(_:))))
            }
            menu.addItem(makeItem("Stop Recording", action: #selector(stopActiveCapture(_:))))
        }

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

    private func addDisabledMenuItem(_ title: String, tooltip: String?, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tooltip
        menu.addItem(item)
    }

    private struct ActiveSessionDetails {
        let title: String
        let noteDisplay: String
        let notePath: String
    }

    private func activeSessionDetails(activeCapture: ActiveCaptureRecord) -> ActiveSessionDetails? {
        let sessionDir = URL(fileURLWithPath: activeCapture.sessionDir, isDirectory: true)
        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        guard let manifest = ManifestValidator.validate(fileURL: manifestURL).manifest else {
            return nil
        }
        let noteURL = URL(fileURLWithPath: manifest.paths.notePath)
        let noteDisplay = noteURL.lastPathComponent.isEmpty ? manifest.paths.notePath : noteURL.lastPathComponent
        return ActiveSessionDetails(
            title: manifest.meeting.title.isEmpty ? activeCapture.sessionID : manifest.meeting.title,
            noteDisplay: noteDisplay,
            notePath: manifest.paths.notePath
        )
    }

    private func isPaused(activeCapture: ActiveCaptureRecord) -> Bool {
        readActiveStatus(activeCapture: activeCapture)?.isPaused == true
    }

    private func readActiveStatus(activeCapture: ActiveCaptureRecord) -> RuntimeStatus? {
        let sessionDir = URL(fileURLWithPath: activeCapture.sessionDir, isDirectory: true)
        return RuntimeFiles.readStatus(sessionDir: sessionDir)
    }

    // Returns true when an active capture is registered and no stop is actively in flight.
    // A finished stop Process can remain assigned briefly if AppKit delivery races the
    // polling tick, so only a running stop process should suppress the recording icon.
    private var isRecording: Bool {
        stopProcess?.isRunning != true &&
        (adHocStartProcess?.isRunning == true || RuntimeFiles.readLiveActiveCapture() != nil)
    }

    private func clearFinishedControlProcesses() {
        if adHocStartProcess?.isRunning == false {
            adHocStartProcess = nil
        }
        if stopProcess?.isRunning == false {
            stopProcess = nil
        }
        if captureControlProcess?.isRunning == false {
            captureControlProcess = nil
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        clearFinishedControlProcesses()
        if isRecording {
            let activeCapture = RuntimeFiles.readLiveActiveCapture()
            let activeStatus = activeCapture.flatMap { readActiveStatus(activeCapture: $0) }
            let paused = displayedPauseState(activeCapture: activeCapture, activeStatus: activeStatus)
            if paused {
                button.image = makePauseButtonImage()
            } else {
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                // isTemplate must be set before assignment; mutating button.image after assignment does not trigger re-render.
                let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "noted")
                    .flatMap { $0.withSymbolConfiguration(config) }
                    ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "noted")
                image?.isTemplate = false
                button.image = image
            }
        } else {
            let image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "noted")
            image?.isTemplate = true
            button.image = image
        }
    }

    private func makePauseButtonImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setFill()

        let leftBar = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 2.6, width: 4.0, height: 12.8), xRadius: 0.9, yRadius: 0.9)
        let rightBar = NSBezierPath(roundedRect: NSRect(x: 9.8, y: 2.6, width: 4.0, height: 12.8), xRadius: 0.9, yRadius: 0.9)
        leftBar.fill()
        rightBar.fill()

        image.isTemplate = false
        image.accessibilityDescription = "noted paused"
        return image
    }

    private func displayedPauseState(activeCapture: ActiveCaptureRecord?, activeStatus: RuntimeStatus?) -> Bool {
        guard let activeCapture else { return false }
        if optimisticPauseTarget?.sessionID != activeCapture.sessionID {
            optimisticPauseTarget = nil
        }
        return optimisticPauseTarget?.isPaused ?? (activeStatus?.isPaused == true)
    }

    private func startRuntimePolling() {
        runtimePollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.updateIcon()
            }
        }
        timer.tolerance = 0.5
        runtimePollTimer = timer
    }

    @objc private func startRecording(_ sender: NSMenuItem) {
        appendMenuLog("start_ad_hoc_clicked")
        guard RuntimeFiles.readLiveActiveCapture() == nil,
              adHocStartProcess?.isRunning != true else {
            appendMenuLog("start_ad_hoc_ignored busy_or_active")
            NSSound.beep()
            updateIcon()
            return
        }

        do {
            optimisticPauseTarget = nil
            let settings = RuntimeSettings.load()
            let writer = AdHocManifestWriter(settings: settings)
            let written = try writer.writeManifest()
            appendMenuLog("start_ad_hoc_manifest_written session_id=\(written.manifest.sessionID) manifest=\(written.manifestURL.path)")
            let process = try makeLoggedCLIProcess(
                arguments: ["start", "--manifest", written.manifestURL.path],
                logName: "ad-hoc-start.log"
            )
            process.terminationHandler = { [weak self] terminatedProcess in
                DispatchQueue.main.async { [weak self] in
                    if self?.adHocStartProcess === terminatedProcess {
                        self?.adHocStartProcess = nil
                    }
                    self?.appendMenuLog("start_ad_hoc_completed session_id=\(written.manifest.sessionID) exit_code=\(terminatedProcess.terminationStatus)")
                    self?.updateIcon()
                    if terminatedProcess.terminationStatus != 0 && terminatedProcess.terminationReason == .exit {
                        self?.showAdHocStartFailure(
                            status: Int(terminatedProcess.terminationStatus),
                            sessionDir: URL(fileURLWithPath: written.manifest.paths.sessionDir)
                        )
                    }
                }
            }
            adHocStartProcess = process
            stopProcess = nil  // a new session takes ownership; prior stop is no longer relevant
            optimisticPauseTarget = nil
            try process.run()
            updateIcon()
        } catch {
            adHocStartProcess = nil
            optimisticPauseTarget = nil
            appendMenuLog("start_ad_hoc_failed error=\(error.localizedDescription)")
            NSSound.beep()
            showAdHocStartFailure(message: error.localizedDescription)
        }
    }

    @objc private func togglePauseActiveCapture(_ sender: NSMenuItem) {
        guard captureControlProcess?.isRunning != true else {
            appendMenuLog("pause_toggle_ignored control_process_in_flight")
            return
        }
        guard let active = RuntimeFiles.readLiveActiveCapture() else {
            appendMenuLog("pause_toggle_ignored no_active_capture")
            NSSound.beep()
            updateIcon()
            return
        }

        let paused = isPaused(activeCapture: active)
        let command = paused ? "continue" : "pause"
        appendMenuLog("\(command)_recording_clicked session_id=\(active.sessionID)")

        do {
            let process = try makeLoggedCLIProcess(
                arguments: [command, "--session-id", active.sessionID],
                logName: "menu-\(command).log"
            )
            process.terminationHandler = { [weak self] terminatedProcess in
                DispatchQueue.main.async { [weak self] in
                    if self?.captureControlProcess === terminatedProcess {
                        self?.captureControlProcess = nil
                    }
                    if self?.optimisticPauseTarget?.sessionID == active.sessionID {
                        self?.optimisticPauseTarget = nil
                    }
                    self?.appendMenuLog("\(command)_recording_completed session_id=\(active.sessionID) exit_code=\(terminatedProcess.terminationStatus)")
                    self?.updateIcon()
                }
            }
            captureControlProcess = process
            optimisticPauseTarget = OptimisticPauseTarget(sessionID: active.sessionID, isPaused: !paused)
            try process.run()
            updateIcon()
        } catch {
            captureControlProcess = nil
            if optimisticPauseTarget?.sessionID == active.sessionID {
                optimisticPauseTarget = nil
            }
            appendMenuLog("\(command)_recording_failed session_id=\(active.sessionID) error=\(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func stopActiveCapture(_ sender: NSMenuItem) {
        appendMenuLog("stop_recording_clicked")
        guard let active = RuntimeFiles.readLiveActiveCapture() else {
            appendMenuLog("stop_recording_ignored no_active_capture")
            NSSound.beep()
            updateIcon()
            return
        }

        if optimisticPauseTarget?.sessionID == active.sessionID {
            optimisticPauseTarget = nil
        }

        // Kill the start process if it is still waiting for startup. The session runner
        // child is independent and will detect the stop-request on its own. This unblocks
        // the startRecording guard so a new session can be started once this one is done.
        if adHocStartProcess?.isRunning == true {
            adHocStartProcess?.terminate()
        }

        do {
            let process = try makeLoggedCLIProcess(
                arguments: ["stop", "--session-id", active.sessionID],
                logName: "menu-stop.log"
            )
            process.terminationHandler = { [weak self] terminatedProcess in
                DispatchQueue.main.async { [weak self] in
                    if self?.stopProcess === terminatedProcess {
                        self?.stopProcess = nil
                    }
                    self?.appendMenuLog("stop_recording_completed session_id=\(active.sessionID) exit_code=\(terminatedProcess.terminationStatus)")
                    // Defensive cleanup: if the session runner didn't release the capture
                    // before noted-stop returned (e.g. model still loading at stop time),
                    // remove it here so the menu and icon reflect the stopped state.
                    RuntimeFiles.releaseActiveCapture(sessionID: active.sessionID)
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
        process.environment = IntegrationProcessEnvironment.environment()
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

    @objc private func showSettings(_ sender: NSMenuItem) {
        guard let settings else { return }
        let view = SettingsView(settings: settings)
        settingsWindow = showWindow(settingsWindow, title: "noted Settings", rootView: view, size: NSSize(width: 660, height: 360))
    }

    private func showWindow<V: View>(_ existing: NSWindow?, title: String, rootView: V, size: NSSize) -> NSWindow {
        if let existing {
            existing.contentViewController = NSHostingController(rootView: rootView)
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
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settings?.applyScreenShareVisibility()
        return window
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let active = RuntimeFiles.readLiveActiveCapture() else {
            NSApplication.shared.terminate(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = "noted is currently recording. Stop the session before quitting."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let process = try? makeLoggedCLIProcess(
                arguments: ["stop", "--session-id", active.sessionID],
                logName: "menu-quit-stop.log"
            ) {
                try? process.run()
                process.waitUntilExit()
                RuntimeFiles.releaseActiveCapture(sessionID: active.sessionID)
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
