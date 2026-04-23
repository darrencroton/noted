import AppKit
import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    var outputDirectoryPath: String {
        didSet { UserDefaults.standard.set(outputDirectoryPath, forKey: "outputDirectoryPath") }
    }

    var transcriptionModel: TranscriptionModel {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcriptionModel") }
    }

    var sysVadThreshold: Double {
        didSet { UserDefaults.standard.set(sysVadThreshold, forKey: "sysVadThreshold") }
    }

    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        outputDirectoryPath = defaults.string(forKey: "outputDirectoryPath")
            ?? NSString("~/Documents/noted/sessions").expandingTildeInPath
        transcriptionModel = TranscriptionModel(rawValue: defaults.string(forKey: "transcriptionModel") ?? "")
            ?? .parakeet
        let storedThreshold = defaults.double(forKey: "sysVadThreshold")
        sysVadThreshold = storedThreshold > 0 ? storedThreshold : 0.92
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            hideFromScreenShare = true
        } else {
            hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }
    }

    func reset() {
        transcriptionLocale = "en-US"
        inputDeviceID = 0
        outputDirectoryPath = NSString("~/Documents/noted/sessions").expandingTildeInPath
        transcriptionModel = .parakeet
        sysVadThreshold = 0.92
        hideFromScreenShare = true
    }

    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: NSString(string: outputDirectoryPath).expandingTildeInPath, isDirectory: true)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }
}
