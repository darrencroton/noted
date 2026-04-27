import AppKit
import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    var transcriptionLocale: String {
        didSet { saveRuntimeSettings() }
    }

    var inputDeviceID: AudioDeviceID {
        didSet { saveRuntimeSettings() }
    }

    var outputDirectoryPath: String {
        didSet { saveRuntimeSettings() }
    }

    var transcriptionModel: TranscriptionModel {
        didSet { saveRuntimeSettings() }
    }

    var sysVadThreshold: Double {
        didSet { saveRuntimeSettings() }
    }

    var hideFromScreenShare: Bool {
        didSet {
            saveRuntimeSettings()
            applyScreenShareVisibility()
        }
    }

    init() {
        let runtimeSettings = RuntimeSettings.load()
        transcriptionLocale = runtimeSettings.language
        inputDeviceID = runtimeSettings.defaultInputDevice
        outputDirectoryPath = runtimeSettings.outputRoot
        transcriptionModel = runtimeSettings.transcriptionModel
        sysVadThreshold = runtimeSettings.sysVadThreshold
        hideFromScreenShare = runtimeSettings.hideFromScreenShare
    }

    func reset() {
        transcriptionLocale = "en-US"
        inputDeviceID = 0
        outputDirectoryPath = RuntimeSettings.defaultOutputRoot
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

    private func saveRuntimeSettings() {
        var settings = RuntimeSettings.load()
        settings.language = transcriptionLocale
        settings.defaultInputDevice = inputDeviceID
        settings.outputRoot = outputDirectoryPath
        settings.sysVadThreshold = sysVadThreshold
        settings.hideFromScreenShare = hideFromScreenShare
        switch transcriptionModel {
        case .parakeet:
            settings.asrBackend = "fluidaudio-parakeet"
            settings.asrModelVariant = "parakeet-v3"
        case .whisperBase:
            settings.asrBackend = "whisperkit"
            settings.asrModelVariant = "base"
        case .whisperLargeV3:
            settings.asrBackend = "whisperkit"
            settings.asrModelVariant = "large-v3"
        case .appleSpeech:
            settings.asrBackend = "sfspeech"
            settings.asrModelVariant = "apple-speech"
        }
        try? settings.save()
    }
}
