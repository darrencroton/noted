import AppKit
import CoreAudio
import Foundation
import Observation

struct InputDeviceOption: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

@Observable
@MainActor
final class AppSettings {
    var transcriptionLocale: String {
        didSet { saveRuntimeSettings() }
    }

    var outputDirectoryPath: String {
        didSet { saveRuntimeSettings() }
    }

    var inputDeviceID: AudioDeviceID {
        didSet { saveRuntimeSettings() }
    }

    var ingestAfterCompletion: Bool {
        didSet { saveRuntimeSettings() }
    }

    var transcriptionModel: TranscriptionModel {
        didSet { saveRuntimeSettings() }
    }

    private(set) var inputDevices: [InputDeviceOption]

    init() {
        let runtimeSettings = RuntimeSettings.load()
        transcriptionLocale = runtimeSettings.language
        outputDirectoryPath = runtimeSettings.outputRoot
        inputDeviceID = runtimeSettings.defaultInputDevice
        ingestAfterCompletion = runtimeSettings.ingestAfterCompletion
        transcriptionModel = runtimeSettings.transcriptionModel
        inputDevices = Self.loadInputDevices(selectedDeviceID: runtimeSettings.defaultInputDevice)
    }

    func reset() {
        transcriptionLocale = "en-US"
        outputDirectoryPath = RuntimeSettings.defaultOutputRoot
        inputDeviceID = 0
        ingestAfterCompletion = true
        transcriptionModel = .parakeet
    }

    func refreshInputDevices() {
        inputDevices = Self.loadInputDevices(selectedDeviceID: inputDeviceID)
    }

    var selectedModelCacheStatus: ModelCacheStatus {
        ModelCache.status(for: transcriptionModel)
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
        settings.outputRoot = outputDirectoryPath
        settings.defaultInputDevice = inputDeviceID
        settings.ingestAfterCompletion = ingestAfterCompletion
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

    private static func loadInputDevices(selectedDeviceID: AudioDeviceID) -> [InputDeviceOption] {
        var options = [InputDeviceOption(id: 0, name: "System Default")]
        for device in MicCapture.availableInputDevices() {
            options.append(InputDeviceOption(id: device.id, name: device.name.isEmpty ? "Input \(device.id)" : device.name))
        }
        if selectedDeviceID != 0, !options.contains(where: { $0.id == selectedDeviceID }) {
            let name = MicCapture.deviceName(for: selectedDeviceID) ?? "Input \(selectedDeviceID)"
            options.append(InputDeviceOption(id: selectedDeviceID, name: name))
        }
        return options
    }
}
