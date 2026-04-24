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
        let storedOutputPath = defaults.string(forKey: "outputDirectoryPath")
        if let storedOutputPath, storedOutputPath != Self.legacyDefaultOutputDirectoryPath {
            outputDirectoryPath = storedOutputPath
        } else {
            let defaultOutputPath = Self.defaultOutputDirectoryPath
            outputDirectoryPath = defaultOutputPath
            defaults.set(defaultOutputPath, forKey: "outputDirectoryPath")
        }
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
        outputDirectoryPath = Self.defaultOutputDirectoryPath
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

    private static let legacyDefaultOutputDirectoryPath = NSString("~/Documents/noted/sessions").expandingTildeInPath

    private static var defaultOutputDirectoryPath: String {
        repositoryRootURL().appendingPathComponent("sessions", isDirectory: true).path
    }

    private static func repositoryRootURL() -> URL {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
        ]

        for candidate in candidates {
            if let root = findRepositoryRoot(startingAt: candidate) {
                return root
            }
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/noted", isDirectory: true)
    }

    private static func findRepositoryRoot(startingAt url: URL) -> URL? {
        let fileManager = FileManager.default
        var directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        while true {
            let repoPackage = directory.appendingPathComponent("HushScribe/Package.swift").path
            if fileManager.fileExists(atPath: repoPackage) {
                return directory
            }

            let package = directory.appendingPathComponent("Package.swift").path
            if directory.lastPathComponent == "HushScribe",
               fileManager.fileExists(atPath: package) {
                return directory.deletingLastPathComponent()
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}
