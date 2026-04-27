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

    init() {
        let runtimeSettings = RuntimeSettings.load()
        transcriptionLocale = runtimeSettings.language
        inputDeviceID = runtimeSettings.defaultInputDevice
        outputDirectoryPath = runtimeSettings.outputRoot
        transcriptionModel = runtimeSettings.transcriptionModel
        sysVadThreshold = runtimeSettings.sysVadThreshold
    }

    func reset() {
        transcriptionLocale = "en-US"
        inputDeviceID = 0
        outputDirectoryPath = RuntimeSettings.defaultOutputRoot
        transcriptionModel = .parakeet
        sysVadThreshold = 0.92
    }

    func applyScreenShareVisibility() {
        for window in NSApp.windows {
            window.sharingType = .none
        }
    }

    func openOutputDirectory() {
        do {
            try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(outputDirectoryURL)
        } catch {
            NSSound.beep()
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
        settings.hideFromScreenShare = true
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
