@preconcurrency import AVFoundation
import FluidAudio
import Foundation

struct PostSessionProcessingResult: Sendable {
    let transcriptOK: Bool
    let diarizationOK: Bool
    let warnings: [String]
    let errors: [String]
    let diagnostics: [String]
}

struct PostSessionRetryPolicy: Sendable {
    let transcriptionAttempts: Int
    let retryDelayNanoseconds: UInt64

    static let production = PostSessionRetryPolicy(
        transcriptionAttempts: 2,
        retryDelayNanoseconds: 60_000_000_000
    )

    static let immediate = PostSessionRetryPolicy(
        transcriptionAttempts: 2,
        retryDelayNanoseconds: 0
    )
}

@MainActor
protocol PostSessionTranscribing: AnyObject {
    func transcribeAudio(_ samples: [Float], source: AudioSource, locale: Locale) async throws -> ASRTranscriptResult
}

@MainActor
protocol PostSessionTranscriptionRecovering: AnyObject {
    func resetASRBackendForRetry()
}

@MainActor
protocol PostSessionDiarizing: AnyObject {
    func diarizeAudio(audioURL: URL, speakerCountHint: Int?) async -> [DiarizationSegment]?
}

extension TranscriptionEngine: PostSessionTranscribing, PostSessionTranscriptionRecovering, PostSessionDiarizing {}

struct PostSessionProcessor {
    private let transcriber: any PostSessionTranscribing
    private let diarizer: any PostSessionDiarizing
    private let writer: FinalTranscriptWriter
    private let retryPolicy: PostSessionRetryPolicy
    private let sampleRate = 16_000

    init(
        transcriber: any PostSessionTranscribing,
        diarizer: any PostSessionDiarizing,
        writer: FinalTranscriptWriter = FinalTranscriptWriter(),
        retryPolicy: PostSessionRetryPolicy = .production
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.writer = writer
        self.retryPolicy = retryPolicy
    }

    @MainActor
    func process(manifest: SessionManifest, descriptor: SessionDescriptor, locale: Locale) async -> PostSessionProcessingResult {
        var warnings: [String] = []
        var errors: [String] = []
        var diagnostics: [String] = []
        var finalSegments: [FinalTranscriptSegment] = []
        var finalDiarizationSegments: [DiarizationSegment] = []
        var anyDiarizationSucceeded = false
        var allDiarizedSourcesSucceeded = true
        var allPresentSourcesTranscribed = true

        do {
            try writer.writeMetadata(for: descriptor)
        } catch {
            warnings.append("session_metadata_write_failed")
        }

        for source in sources(for: descriptor) {
            guard FileManager.default.fileExists(atPath: source.url.path) else {
                warnings.append("\(source.warningPrefix)_audio_missing")
                allDiarizedSourcesSucceeded = false
                continue
            }

            let diarization: [DiarizationSegment]?
            if manifest.transcription.diarizationEnabled {
                diarization = await diarizer.diarizeAudio(
                    audioURL: source.url,
                    speakerCountHint: manifest.transcription.speakerCountHint
                )
                if diarization == nil {
                    warnings.append("\(source.warningPrefix)_diarization_failed")
                    allDiarizedSourcesSucceeded = false
                }
            } else {
                diarization = nil
                allDiarizedSourcesSucceeded = false
            }

            do {
                let audio = try loadAudio(url: source.url)
                defer { audio.source.cleanup() }
                let normalizedDiarization = normalize(
                    diarization ?? [],
                    prefix: source.speakerPrefix
                )
                if !normalizedDiarization.isEmpty {
                    anyDiarizationSucceeded = true
                    finalDiarizationSegments.append(contentsOf: normalizedDiarization)
                }

                let transcriptRanges = normalizedDiarization.isEmpty
                    ? fallbackRanges(sampleCount: audio.source.sampleCount, source: source)
                    : coalescedRanges(normalizedDiarization, source: source)

                let transcriptionResult = await transcribeSource(
                    ranges: transcriptRanges,
                    audio: audio,
                    source: source,
                    locale: locale
                )
                finalSegments.append(contentsOf: transcriptionResult.segments)
                diagnostics.append(contentsOf: transcriptionResult.diagnostics)
                if !transcriptionResult.succeeded {
                    allPresentSourcesTranscribed = false
                    errors.append("\(source.warningPrefix)_transcription_failed")
                }
            } catch {
                allPresentSourcesTranscribed = false
                errors.append("\(source.warningPrefix)_transcription_failed")
            }
        }

        if !finalDiarizationSegments.isEmpty {
            do {
                try writer.writeDiarization(finalDiarizationSegments, to: descriptor.directory)
            } catch {
                warnings.append("diarization_write_failed")
                allDiarizedSourcesSucceeded = false
            }
        }

        var transcriptWriteOK = false
        do {
            try writer.writeTranscript(finalSegments, descriptor: descriptor)
            transcriptWriteOK = true
        } catch {
            errors.append("transcript_write_failed")
        }

        let transcriptOK = transcriptWriteOK && allPresentSourcesTranscribed
        let diarizationOK = manifest.transcription.diarizationEnabled
            && anyDiarizationSucceeded
            && allDiarizedSourcesSucceeded

        return PostSessionProcessingResult(
            transcriptOK: transcriptOK,
            diarizationOK: diarizationOK,
            warnings: Array(Set(warnings)).sorted(),
            errors: Array(Set(errors)).sorted(),
            diagnostics: diagnostics
        )
    }

    private func sources(for descriptor: SessionDescriptor) -> [AudioProcessingSource] {
        if descriptor.capturesSystemAudio {
            return [
                AudioProcessingSource(
                    url: descriptor.microphoneAudioURL,
                    transcriptSource: .microphone,
                    audioSource: .microphone,
                    speakerPrefix: "mic",
                    fallbackSpeakerId: "microphone",
                    warningPrefix: "microphone"
                ),
                AudioProcessingSource(
                    url: descriptor.systemAudioURL,
                    transcriptSource: .system,
                    audioSource: .system,
                    speakerPrefix: "system",
                    fallbackSpeakerId: "system",
                    warningPrefix: "system"
                ),
            ]
        }

        return [
            AudioProcessingSource(
                url: descriptor.microphoneAudioURL,
                transcriptSource: .microphone,
                audioSource: .microphone,
                speakerPrefix: nil,
                fallbackSpeakerId: "microphone",
                warningPrefix: "room"
            ),
        ]
    }

    private func loadAudio(url: URL) throws -> LoadedAudio {
        let factory = AudioSourceFactory()
        let result = try factory.makeDiskBackedSource(from: url, targetSampleRate: sampleRate)
        return LoadedAudio(source: result.source)
    }

    private func normalize(_ segments: [DiarizationSegment], prefix: String?) -> [DiarizationSegment] {
        var ids: [String: String] = [:]
        var nextIndex = 0
        return segments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
            .map { segment in
                let mapped = ids[segment.speakerId] ?? {
                    let id = prefix.map { "\($0)_speaker_\(nextIndex)" } ?? "speaker_\(nextIndex)"
                    ids[segment.speakerId] = id
                    nextIndex += 1
                    return id
                }()
                return DiarizationSegment(
                    speakerId: mapped,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
    }

    private func coalescedRanges(
        _ diarization: [DiarizationSegment],
        source: AudioProcessingSource
    ) -> [TranscriptRange] {
        var ranges: [TranscriptRange] = []
        for segment in diarization {
            if let last = ranges.last,
               last.speakerId == segment.speakerId,
               segment.startTime - last.endTime <= 0.5 {
                ranges[ranges.count - 1] = TranscriptRange(
                    speakerId: last.speakerId,
                    source: last.source,
                    audioSource: last.audioSource,
                    startTime: last.startTime,
                    endTime: max(last.endTime, segment.endTime)
                )
            } else {
                ranges.append(
                    TranscriptRange(
                        speakerId: segment.speakerId,
                        source: source.transcriptSource,
                        audioSource: source.audioSource,
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    )
                )
            }
        }
        return ranges
    }

    private func fallbackRanges(sampleCount: Int, source: AudioProcessingSource) -> [TranscriptRange] {
        let duration = Float(sampleCount) / Float(sampleRate)
        guard duration > 0 else { return [] }
        var ranges: [TranscriptRange] = []
        var start: Float = 0
        while start < duration {
            let end = min(duration, start + 30)
            ranges.append(
                TranscriptRange(
                    speakerId: source.fallbackSpeakerId,
                    source: source.transcriptSource,
                    audioSource: source.audioSource,
                    startTime: start,
                    endTime: end
                )
            )
            start = end
        }
        return ranges
    }

    @MainActor
    private func transcribe(range: TranscriptRange, audio: LoadedAudio, locale: Locale) async throws -> FinalTranscriptSegment? {
        let startSample = max(0, Int((range.startTime * Float(sampleRate)).rounded(.down)))
        let endSample = min(audio.source.sampleCount, Int((range.endTime * Float(sampleRate)).rounded(.up)))
        guard endSample > startSample else { return nil }

        var samples = [Float](repeating: 0, count: endSample - startSample)
        let sampleCount = samples.count
        try samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try audio.source.copySamples(into: baseAddress, offset: startSample, count: sampleCount)
        }
        if samples.count < sampleRate {
            samples.append(contentsOf: repeatElement(0, count: sampleRate - samples.count))
        }

        let result = try await transcriber.transcribeAudio(samples, source: range.audioSource, locale: locale)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        return FinalTranscriptSegment(
            speakerId: range.speakerId,
            source: range.source,
            startTime: range.startTime,
            endTime: range.endTime,
            text: text,
            confidence: result.confidence
        )
    }

    @MainActor
    private func transcribeSource(
        ranges: [TranscriptRange],
        audio: LoadedAudio,
        source: AudioProcessingSource,
        locale: Locale
    ) async -> SourceTranscriptionResult {
        let attempts = max(1, retryPolicy.transcriptionAttempts)
        var diagnostics: [String] = []
        var bestSegments: [FinalTranscriptSegment] = []

        for attempt in 1...attempts {
            if attempt > 1 {
                diagnostics.append(
                    "\(source.warningPrefix)_transcription_retry attempt=\(attempt) delay_seconds=\(retryPolicy.retryDelayNanoseconds / 1_000_000_000)"
                )
                (transcriber as? any PostSessionTranscriptionRecovering)?.resetASRBackendForRetry()
                if retryPolicy.retryDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: retryPolicy.retryDelayNanoseconds)
                }
            }

            var attemptSegments: [FinalTranscriptSegment] = []
            do {
                for range in ranges {
                    guard let segment = try await transcribe(range: range, audio: audio, locale: locale) else { continue }
                    attemptSegments.append(segment)
                }
                diagnostics.append(
                    "\(source.warningPrefix)_transcription_succeeded attempt=\(attempt) ranges=\(ranges.count) segments=\(attemptSegments.count)"
                )
                return SourceTranscriptionResult(
                    segments: attemptSegments,
                    succeeded: true,
                    diagnostics: diagnostics
                )
            } catch {
                if attemptSegments.count > bestSegments.count {
                    bestSegments = attemptSegments
                }
                diagnostics.append(
                    "\(source.warningPrefix)_transcription_failed attempt=\(attempt) ranges=\(ranges.count) partial_segments=\(attemptSegments.count) error=\(error.localizedDescription)"
                )
            }
        }

        return SourceTranscriptionResult(
            segments: bestSegments,
            succeeded: false,
            diagnostics: diagnostics
        )
    }
}

private struct AudioProcessingSource {
    let url: URL
    let transcriptSource: TranscriptAudioSource
    let audioSource: AudioSource
    let speakerPrefix: String?
    let fallbackSpeakerId: String
    let warningPrefix: String
}

private struct LoadedAudio {
    let source: DiskBackedAudioSampleSource
}

private struct TranscriptRange {
    let speakerId: String
    let source: TranscriptAudioSource
    let audioSource: AudioSource
    let startTime: Float
    let endTime: Float
}

private struct SourceTranscriptionResult {
    let segments: [FinalTranscriptSegment]
    let succeeded: Bool
    let diagnostics: [String]
}
