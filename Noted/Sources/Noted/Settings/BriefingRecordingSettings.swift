import AppKit
import Foundation

enum BriefingRecordingSettings {
    static var disabledMarkerURL: URL {
        RuntimeSettings.settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("scheduled-recordings.disabled")
    }

    static func load() -> Bool {
        !FileManager.default.fileExists(atPath: disabledMarkerURL.path)
    }

    static func set(enabled: Bool) {
        let fileManager = FileManager.default
        let markerURL = disabledMarkerURL
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if enabled {
                try? fileManager.removeItem(at: markerURL)
            } else {
                let payload = "Scheduled meeting recording is disabled from Noted settings.\n"
                try payload.write(to: markerURL, atomically: true, encoding: .utf8)
            }
        } catch {
            NSSound.beep()
        }
    }
}
