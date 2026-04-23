import Foundation

@MainActor
final class SessionController {
    private let settings: AppSettings
    private let recordingState: RecordingState
    private let transcriptionEngine: TranscriptionEngine
    private let transcriptLogger: TranscriptLogger
    private var sessionStore: SessionStore

    init(
        settings: AppSettings,
        recordingState: RecordingState,
        transcriptionEngine: TranscriptionEngine,
        transcriptLogger: TranscriptLogger
    ) {
        self.settings = settings
        self.recordingState = recordingState
        self.transcriptionEngine = transcriptionEngine
        self.transcriptLogger = transcriptLogger
        self.sessionStore = SessionStore(rootDirectory: settings.outputDirectoryURL)
    }

    func startAdHocSession(type: SessionType) async {
        guard !recordingState.isBusy else { return }
        recordingState.phase = .starting
        recordingState.lastError = nil
        transcriptionEngine.setModel(settings.transcriptionModel)
        sessionStore = SessionStore(rootDirectory: settings.outputDirectoryURL)

        var descriptor: SessionDescriptor?

        do {
            descriptor = try await sessionStore.createSession(type: type)
            guard let descriptor else { throw RuntimeError("Unable to create session.") }
            try await transcriptLogger.startSession(descriptor)
            recordingState.currentSessionID = descriptor.id
            recordingState.currentSessionDirectory = descriptor.directory
            recordingState.startedAt = descriptor.startedAt

            await transcriptionEngine.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                rawMicrophoneAudioURL: descriptor.microphoneAudioURL,
                rawSystemAudioURL: descriptor.systemAudioURL,
                sysVadThreshold: settings.sysVadThreshold
            )

            if !transcriptionEngine.isRunning, let error = transcriptionEngine.lastError {
                throw RuntimeError(error)
            }

            recordingState.phase = .recording
        } catch {
            recordingState.phase = .failed
            recordingState.lastError = error.localizedDescription
            _ = try? await transcriptLogger.endSession()
            _ = await transcriptionEngine.stop()
            if let descriptor {
                try? await sessionStore.discardSession(descriptor)
            }
            recordingState.currentSessionID = nil
            recordingState.currentSessionDirectory = nil
            recordingState.startedAt = nil
        }
    }

    func stopSession() async {
        guard recordingState.isRecording else { return }
        let stoppedSessionID = recordingState.currentSessionID
        let stoppedDirectory = recordingState.currentSessionDirectory
        recordingState.phase = .stopping
        let systemAudioURL = await transcriptionEngine.stop()

        do {
            let output = try await transcriptLogger.endSession()
            recordingState.currentSessionDirectory = output
            recordingState.phase = .processing
        } catch {
            recordingState.phase = .failed
            recordingState.lastError = error.localizedDescription
            return
        }

        guard let stoppedDirectory else {
            recordingState.phase = .idle
            return
        }

        Task.detached { [transcriptionEngine, transcriptLogger, recordingState] in
            if let systemAudioURL,
               let diarization = await transcriptionEngine.runPostSessionDiarization(audioURL: systemAudioURL) {
                let segments = diarization.map {
                    DiarizationSegment(speakerId: $0.speakerId, startTime: $0.startTime, endTime: $0.endTime)
                }
                try? await transcriptLogger.writeDiarization(segments, to: stoppedDirectory)
            }

            await MainActor.run {
                guard recordingState.phase == .processing,
                      recordingState.currentSessionID == stoppedSessionID else { return }
                recordingState.phase = .idle
            }
        }
    }
}

private struct RuntimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
