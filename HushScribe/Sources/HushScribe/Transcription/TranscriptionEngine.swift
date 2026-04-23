@preconcurrency import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import WhisperKit

func diagLog(_ message: String) {
    #if DEBUG
    let line = "\(Date()): \(message)\n"
    let path = "/tmp/noted.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
    #endif
}

enum ModelDownloadState {
    case needed
    case downloading
    case ready
}

final class FileOffsetTracker: @unchecked Sendable {
    private var samples: Int = 0
    private let lock = NSLock()

    var seconds: Double {
        lock.withLock { Double(samples) / 16_000.0 }
    }

    func set(_ samples: Int) {
        lock.withLock { self.samples = samples }
    }
}

@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var modelDownloadState: ModelDownloadState
    private(set) var downloadingModel: TranscriptionModel?
    var assetStatus = "Ready"
    var lastError: String?
    private(set) var isSpeechDetected = false

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()

    var micAudioLevel: Float { micCapture.audioLevel }
    var sysAudioLevel: Float { systemCapture.audioLevel }
    var audioLevel: Float { max(micCapture.audioLevel, systemCapture.audioLevel) }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

    private(set) var selectedModel: TranscriptionModel = .parakeet

    private var asrManager: AsrManager?
    private var micVadManager: VadManager?
    private var sysVadManager: VadManager?
    private var whisperKitBackend: WhisperKitASRBackend?
    private var sfSpeechBackend: SFSpeechBackend?

    private var currentMicDeviceID: AudioDeviceID = 0
    private var userSelectedDeviceID: AudioDeviceID = 0
    private var captureAppBundleID: String?
    private var currentRawMicrophoneAudioURL: URL?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var utteranceHandler: (@Sendable (TranscriptSegment) -> Void)?

    init() {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        modelDownloadState = AsrModels.modelsExist(at: cacheDir, version: .v3) ? .ready : .needed
    }

    func setUtteranceHandler(_ handler: @escaping @Sendable (TranscriptSegment) -> Void) {
        utteranceHandler = handler
    }

    func setModel(_ model: TranscriptionModel) {
        guard !isRunning else { return }
        selectedModel = model
        if !model.isWhisperKit { whisperKitBackend = nil }
        if !model.isAppleSpeech { sfSpeechBackend = nil }
        if model.isWhisperKit || model.isAppleSpeech { asrManager = nil }
    }

    func downloadModels() async {
        guard modelDownloadState != .ready else { return }
        modelDownloadState = .downloading
        assetStatus = "Downloading Parakeet model..."
        do {
            try await AsrModels.download(version: .v3)
            modelDownloadState = .ready
        } catch {
            lastError = "Failed to download Parakeet model: \(error.localizedDescription)"
            modelDownloadState = .needed
        }
        assetStatus = "Ready"
    }

    func isModelDownloaded(_ model: TranscriptionModel) -> Bool {
        switch model {
        case .parakeet:
            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
            return AsrModels.modelsExist(at: cacheDir, version: .v3)
        case .whisperBase, .whisperLargeV3:
            guard let modelID = model.whisperModelID else { return false }
            return FileManager.default.fileExists(atPath: Self.whisperCacheURL(for: modelID).path)
        case .appleSpeech:
            return true
        }
    }

    func downloadModel(_ model: TranscriptionModel) async {
        switch model {
        case .parakeet:
            await downloadModels()
        case .whisperBase, .whisperLargeV3:
            guard let modelID = model.whisperModelID, downloadingModel == nil else { return }
            downloadingModel = model
            assetStatus = "Downloading \(model.displayName)..."
            do {
                let whisperKit = try await WhisperKit(model: modelID)
                if selectedModel == model {
                    whisperKitBackend = WhisperKitASRBackend(whisperKit)
                }
            } catch {
                lastError = "Failed to download \(model.displayName): \(error.localizedDescription)"
            }
            downloadingModel = nil
            assetStatus = "Ready"
        case .appleSpeech:
            break
        }
    }

    func removeModel(_ model: TranscriptionModel) {
        guard !isRunning else { return }
        switch model {
        case .parakeet:
            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
            try? FileManager.default.removeItem(at: cacheDir)
            asrManager = nil
            micVadManager = nil
            sysVadManager = nil
            modelDownloadState = .needed
        case .whisperBase, .whisperLargeV3:
            guard let modelID = model.whisperModelID else { return }
            try? FileManager.default.removeItem(at: Self.whisperCacheURL(for: modelID))
            if selectedModel == model { whisperKitBackend = nil }
        case .appleSpeech:
            break
        }
    }

    func start(
        locale: Locale,
        inputDeviceID: AudioDeviceID = 0,
        appBundleID: String? = nil,
        rawMicrophoneAudioURL: URL? = nil,
        rawSystemAudioURL: URL? = nil,
        sysVadThreshold: Double = 0.92
    ) async {
        guard !isRunning else { return }
        lastError = nil
        guard await ensureMicrophonePermission() else { return }

        guard let asrBackend = await loadASRBackend(locale: locale, sysVadThreshold: sysVadThreshold),
              let micVadManager,
              let sysVadManager
        else {
            isRunning = false
            return
        }

        isRunning = true
        assetStatus = "Transcribing (\(selectedModel.displayName))"
        userSelectedDeviceID = inputDeviceID
        captureAppBundleID = appBundleID
        currentRawMicrophoneAudioURL = rawMicrophoneAudioURL

        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
        currentMicDeviceID = targetMicID ?? 0
        let micStream = micCapture.bufferStream(deviceID: targetMicID, rawAudioURL: rawMicrophoneAudioURL)
        let handler = utteranceHandler

        let micTranscriber = StreamingTranscriber(
            asrBackend: asrBackend,
            vadManager: micVadManager,
            speaker: .microphone,
            audioSource: .microphone,
            onSpeechStart: { [weak self] in Task { @MainActor in self?.isSpeechDetected = true } },
            onPartial: { _ in },
            onFinal: { [weak self] text in
                handler?(TranscriptSegment(speaker: .microphone, text: text))
                Task { @MainActor in self?.isSpeechDetected = false }
            }
        )
        micTask = Task.detached { [weak self] in
            let failed = await micTranscriber.run(stream: micStream)
            if failed {
                Task { @MainActor in self?.lastError = "Microphone transcription failed." }
            }
        }

        do {
            let sysStreams = try await systemCapture.bufferStream(
                appBundleID: appBundleID,
                rawAudioURL: rawSystemAudioURL
            )
            let sysTranscriber = StreamingTranscriber(
                asrBackend: asrBackend,
                vadManager: sysVadManager,
                speaker: .system,
                audioSource: .system,
                onSpeechStart: { [weak self] in Task { @MainActor in self?.isSpeechDetected = true } },
                onPartial: { _ in },
                onFinal: { [weak self] text in
                    handler?(TranscriptSegment(speaker: .system, text: text))
                    Task { @MainActor in self?.isSpeechDetected = false }
                }
            )
            sysTask = Task.detached { [weak self] in
                let failed = await sysTranscriber.run(stream: sysStreams.systemAudio)
                if failed {
                    Task { @MainActor in self?.lastError = "System audio transcription failed." }
                }
            }
        } catch {
            lastError = "Failed to start system audio capture: \(error.localizedDescription)"
        }

        installDefaultDeviceListener()
    }

    func stop() async -> URL? {
        removeDefaultDeviceListener()
        let systemAudioURL = systemCapture.bufferFilePath
        micTask?.cancel()
        sysTask?.cancel()
        micTask = nil
        sysTask = nil
        await systemCapture.stop()
        micCapture.stop()
        currentMicDeviceID = 0
        currentRawMicrophoneAudioURL = nil
        isSpeechDetected = false
        isRunning = false
        assetStatus = "Ready"
        return systemAudioURL
    }

    nonisolated func runPostSessionDiarization(audioURL: URL) async -> [(speakerId: String, startTime: Float, endTime: Float)]? {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            diagLog("[DIARIZE] No persisted system audio file found")
            return nil
        }

        do {
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
            let result = try await diarizer.process(audioURL)
            let segments = result.segments.map { segment in
                (speakerId: segment.speakerId, startTime: segment.startTimeSeconds, endTime: segment.endTimeSeconds)
            }
            return segments
        } catch {
            diagLog("[DIARIZE] Failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadASRBackend(locale: Locale, sysVadThreshold: Double) async -> (any ASRBackend)? {
        if selectedModel.isWhisperKit {
            guard await ensureVADLoaded(sysVadThreshold: sysVadThreshold) else { return nil }
            if let whisperKitBackend { return whisperKitBackend }
            guard let modelID = selectedModel.whisperModelID else { return nil }
            assetStatus = "Loading \(selectedModel.displayName)..."
            do {
                let whisperKit = try await WhisperKit(model: modelID)
                let backend = WhisperKitASRBackend(whisperKit)
                whisperKitBackend = backend
                return backend
            } catch {
                lastError = "Failed to load WhisperKit: \(error.localizedDescription)"
                assetStatus = "Ready"
                return nil
            }
        }

        if selectedModel.isAppleSpeech {
            guard await SFSpeechBackend.requestAuthorization() else {
                lastError = "Speech recognition permission denied."
                return nil
            }
            guard await ensureVADLoaded(sysVadThreshold: sysVadThreshold) else { return nil }
            if let sfSpeechBackend { return sfSpeechBackend }
            do {
                let backend = try SFSpeechBackend(locale: locale)
                sfSpeechBackend = backend
                return backend
            } catch {
                lastError = "Failed to initialize Apple Speech: \(error.localizedDescription)"
                return nil
            }
        }

        if asrManager == nil || micVadManager == nil || sysVadManager == nil {
            assetStatus = "Loading Parakeet model..."
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asrManager = manager
                micVadManager = try await VadManager()
                sysVadManager = try await VadManager(config: VadConfig(defaultThreshold: Float(sysVadThreshold)))
                modelDownloadState = .ready
            } catch {
                lastError = "Failed to load Parakeet model: \(error.localizedDescription)"
                assetStatus = "Ready"
                return nil
            }
        }

        guard let asrManager else { return nil }
        return FluidAudioASRBackend(manager: asrManager)
    }

    private func ensureVADLoaded(sysVadThreshold: Double) async -> Bool {
        if micVadManager != nil, sysVadManager != nil { return true }
        assetStatus = "Loading VAD model..."
        do {
            micVadManager = try await VadManager()
            sysVadManager = try await VadManager(config: VadConfig(defaultThreshold: Float(sysVadThreshold)))
            return true
        } catch {
            lastError = "Failed to load VAD: \(error.localizedDescription)"
            assetStatus = "Ready"
            return false
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    private func restartMic(inputDeviceID: AudioDeviceID) {
        guard isRunning, let micVadManager else { return }
        let backend: any ASRBackend
        if selectedModel.isWhisperKit, let whisperKitBackend {
            backend = whisperKitBackend
        } else if selectedModel.isAppleSpeech, let sfSpeechBackend {
            backend = sfSpeechBackend
        } else if let asrManager {
            backend = FluidAudioASRBackend(manager: asrManager)
        } else {
            return
        }

        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }

        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
        let resolvedTarget = targetMicID ?? 0
        guard resolvedTarget != currentMicDeviceID else { return }

        micTask?.cancel()
        micTask = nil
        micCapture.stopForSwitch()
        currentMicDeviceID = resolvedTarget

        let stream = micCapture.bufferStream(deviceID: targetMicID, rawAudioURL: currentRawMicrophoneAudioURL)
        let handler = utteranceHandler
        let transcriber = StreamingTranscriber(
            asrBackend: backend,
            vadManager: micVadManager,
            speaker: .microphone,
            audioSource: .microphone,
            onSpeechStart: { [weak self] in Task { @MainActor in self?.isSpeechDetected = true } },
            onPartial: { _ in },
            onFinal: { [weak self] text in
                handler?(TranscriptSegment(speaker: .microphone, text: text))
                Task { @MainActor in self?.isSpeechDetected = false }
            }
        )
        micTask = Task.detached {
            _ = await transcriber.run(stream: stream)
        }
    }

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                self.restartMic(inputDeviceID: 0)
            }
        }
        defaultDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    private static func whisperCacheURL(for modelID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(modelID)")
    }
}
