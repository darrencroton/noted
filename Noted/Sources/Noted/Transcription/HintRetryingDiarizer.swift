import FluidAudio
import Foundation

protocol OfflineDiarizationRunning: Sendable {
    func run(audioURL: URL, config: OfflineDiarizerConfig) async throws -> [DiarizationSegment]
}

struct FluidAudioDiarizationRunner: OfflineDiarizationRunning {
    func run(audioURL: URL, config: OfflineDiarizerConfig) async throws -> [DiarizationSegment] {
        let diarizer = OfflineDiarizerManager(config: config)
        try await diarizer.prepareModels()
        let result = try await diarizer.process(audioURL)
        return result.segments.map { segment in
            DiarizationSegment(
                speakerId: segment.speakerId,
                startTime: segment.startTimeSeconds,
                endTime: segment.endTimeSeconds
            )
        }
    }
}

struct HintRetryingDiarizer<Runner: OfflineDiarizationRunning>: Sendable {
    let runner: Runner

    init(runner: Runner) {
        self.runner = runner
    }

    func diarize(audioURL: URL, speakerCountHint: Int?) async throws -> [DiarizationSegment] {
        var firstConfig = OfflineDiarizerConfig.default
        if let speakerCountHint, speakerCountHint > 0 {
            firstConfig.clustering.maxSpeakers = speakerCountHint
        }

        let first = try await runner.run(audioURL: audioURL, config: firstConfig)
        let firstSpeakerCount = speakerCount(in: first)
        guard let speakerCountHint, speakerCountHint > 1, firstSpeakerCount <= 1 else {
            return first
        }

        var retryConfig = OfflineDiarizerConfig.default
        retryConfig.clustering.minSpeakers = 2
        retryConfig.clustering.maxSpeakers = speakerCountHint
        let retry = try await runner.run(audioURL: audioURL, config: retryConfig)
        return speakerCount(in: retry) > firstSpeakerCount ? retry : first
    }

    private func speakerCount(in segments: [DiarizationSegment]) -> Int {
        Set(segments.map(\.speakerId)).count
    }
}

extension HintRetryingDiarizer where Runner == FluidAudioDiarizationRunner {
    init() {
        self.init(runner: FluidAudioDiarizationRunner())
    }
}
