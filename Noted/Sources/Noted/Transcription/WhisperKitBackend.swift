import FluidAudio
@preconcurrency import WhisperKit

/// Wraps WhisperKit for use as an ASR backend.
final class WhisperKitASRBackend: @unchecked Sendable, ASRBackend {
    private let whisperKit: WhisperKit

    init(_ whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    func transcribe(_ samples: [Float], source: AudioSource) async throws -> ASRTranscriptResult {
        let results = try await whisperKit.transcribe(audioArray: samples)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscriptResult(text: text, confidence: nil)
    }
}
