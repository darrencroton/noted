import FluidAudio

struct ASRTranscriptResult: Sendable {
    let text: String
    let confidence: Float?
}

/// Abstraction over ASR engines (FluidAudio / WhisperKit / Apple Speech).
protocol ASRBackend: Sendable {
    func transcribe(_ samples: [Float], source: AudioSource) async throws -> ASRTranscriptResult
}

/// Wraps FluidAudio's AsrManager.
struct FluidAudioASRBackend: ASRBackend {
    let manager: AsrManager

    func transcribe(_ samples: [Float], source: AudioSource) async throws -> ASRTranscriptResult {
        let result = try await manager.transcribe(samples, source: source)
        return ASRTranscriptResult(text: result.text, confidence: result.confidence)
    }
}
