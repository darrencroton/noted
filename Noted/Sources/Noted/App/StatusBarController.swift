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
        let bridgedStatus = currentRuntimeSessionStatus()?.status

        let title = NSMenuItem(title: "noted", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let statusTitle = bridgedStatus?.status ?? "idle"
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
        let isStarting = adHocStartProcess?.isRunning == true
        let canStart = activeCapture == nil && !isStarting
        appendMenuLog("menu_built canStart=\(canStart) activeCapture=\(activeCapture != nil) isStarting=\(isStarting) stopProcess=\(stopProcess != nil)")

        if canStart {
            menu.addItem(makeItem("Start Ad Hoc Session", action: #selector(startRecording(_:))))
        } else if activeCapture != nil {
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

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // While a stop command is in flight, treat as not-recording immediately so the
        // icon reverts the instant the user clicks Stop regardless of file cleanup timing.
        let isRecording: Bool
        if stopProcess != nil {
            isRecording = false
        } else {
            isRecording = adHocStartProcess?.isRunning == true
                || RuntimeFiles.readLiveActiveCapture() != nil
        }
        if isRecording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "noted")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "noted")
            button.image?.isTemplate = true
        }
    }

    private func currentRuntimeSessionStatus() -> RuntimeSessionStatus? {
        if let active = RuntimeFiles.readLiveActiveCapture() {
            let sessionDir = URL(fileURLWithPath: active.sessionDir, isDirectory: true)
            if let status = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                return RuntimeSessionStatus(status: status, sessionDir: sessionDir)
            }
        }
        if let latest = RuntimeFiles.latestRegistryRecord() {
            let sessionDir = URL(fileURLWithPath: latest.sessionDir, isDirectory: true)
            if let status = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                return RuntimeSessionStatus(status: status, sessionDir: sessionDir)
            }
        }
        return nil
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
            try process.run()
            updateIcon()
        } catch {
            adHocStartProcess = nil
            appendMenuLog("start_ad_hoc_failed error=\(error.localizedDescription)")
            NSSound.beep()
            showAdHocStartFailure(message: error.localizedDescription)
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
        settingsWindow = showWindow(settingsWindow, title: "noted Settings", rootView: view, size: NSSize(width: 540, height: 190))
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
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private struct RuntimeSessionStatus {
    let status: RuntimeStatus
    let sessionDir: URL
}
