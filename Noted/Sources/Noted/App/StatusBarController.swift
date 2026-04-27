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

        let statusTitle = bridgedStatus?.status ?? recordingState.phase.menuTitle.lowercased()
        let state = NSMenuItem(title: "Status: \(statusTitle)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let bridgedStatus {
            let phase = NSMenuItem(title: "Phase: \(bridgedStatus.phase)", action: nil, keyEquivalent: "")
            phase.isEnabled = false
            menu.addItem(phase)
        }
        menu.addItem(.separator())

        let start = makeItem("Start Ad Hoc Session", action: #selector(startRecording))
        start.isEnabled = RuntimeFiles.readLiveActiveCapture() == nil
        menu.addItem(start)

        menu.addItem(makeItem("Status", action: #selector(showStatus)))
        menu.addItem(.separator())

        let settingsItem = makeItem("Settings...", action: #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = makeItem("Quit noted", action: #selector(quitApp))
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
        if let latest = RuntimeFiles.latestRegistryRecord() {
            return RuntimeFiles.readStatus(sessionDir: URL(fileURLWithPath: latest.sessionDir, isDirectory: true))
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

    @objc private func startRecording() {
        Task {
            let settings = RuntimeSettings.load()
            do {
                let writer = AdHocManifestWriter(settings: settings)
                let written = try writer.writeManifest()
                let executableURL = Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
                let process = Process()
                process.executableURL = executableURL
                process.arguments = ["start", "--manifest", written.manifestURL.path]
                process.standardOutput = FileHandle.standardError
                process.standardError = FileHandle.standardError
                try process.run()
            } catch {
                NSSound.beep()
            }
        }
    }

    @objc private func stopRecording() {
        Task { await sessionController?.stopSession() }
    }

    @objc private func showStatus() {
        guard let recordingState else { return }
        let view = StatusPanelView(recordingState: recordingState)
        statusWindow = showWindow(statusWindow, title: "noted Status", rootView: view, size: NSSize(width: 360, height: 180))
    }

    @objc private func showSettings() {
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

    @objc private func quitApp() {
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
