import AVFoundation
import FluidAudio
@testable import Noted
import XCTest

@MainActor
final class PostSessionProcessorTests: XCTestCase {
    func testRoomMicDiarizationWritesSpeakerLabelledTranscript() async throws {
        let fixture = try makeSessionFixture(audioDuration: 2.5)
        let worker = MockPostSessionWorker(
            diarization: [
                DiarizationSegment(speakerId: "raw-a", startTime: 0.0, endTime: 1.1),
                DiarizationSegment(speakerId: "raw-b", startTime: 1.2, endTime: 2.3),
            ],
            transcriptTexts: ["first speaker text", "second speaker text"]
        )

        let result = await PostSessionProcessor(transcriber: worker, diarizer: worker)
            .process(manifest: fixture.manifest, descriptor: fixture.descriptor, locale: Locale(identifier: "en-AU"))

        XCTAssertTrue(result.transcriptOK)
        XCTAssertTrue(result.diarizationOK)
        XCTAssertEqual(result.errors, [])

        let transcriptText = try String(
            contentsOf: fixture.descriptor.transcriptDirectory.appendingPathComponent("transcript.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(transcriptText.contains("speaker_0: first speaker text"))
        XCTAssertTrue(transcriptText.contains("speaker_1: second speaker text"))
        XCTAssertFalse(transcriptText.contains("Microphone:"))

        let document = try loadTranscriptDocument(fixture.descriptor.transcriptDirectory.appendingPathComponent("transcript.json"))
        XCTAssertEqual(document.segments.map(\.speakerId), ["speaker_0", "speaker_1"])
        XCTAssertEqual(document.segments.map(\.source), [.microphone, .microphone])
    }

    func testDiarizationFailureStillWritesSourceLabelledTranscript() async throws {
        let fixture = try makeSessionFixture(audioDuration: 2.0)
        let worker = MockPostSessionWorker(
            diarization: nil,
            transcriptTexts: ["fallback transcript"]
        )

        let result = await PostSessionProcessor(transcriber: worker, diarizer: worker)
            .process(manifest: fixture.manifest, descriptor: fixture.descriptor, locale: Locale(identifier: "en-AU"))

        XCTAssertTrue(result.transcriptOK)
        XCTAssertFalse(result.diarizationOK)
        XCTAssertTrue(result.warnings.contains("room_diarization_failed"))

        let transcriptText = try String(
            contentsOf: fixture.descriptor.transcriptDirectory.appendingPathComponent("transcript.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(transcriptText.contains("microphone: fallback transcript"))
    }

    func testSpeakerCountHintRetriesWhenInitialDiarizationCollapsesToOneSpeaker() async throws {
        let recorder = DiarizationConfigRecorder()
        let runner = MockDiarizationRunner(
            recorder: recorder,
            outputs: [
                [DiarizationSegment(speakerId: "only", startTime: 0, endTime: 1)],
                [
                    DiarizationSegment(speakerId: "a", startTime: 0, endTime: 1),
                    DiarizationSegment(speakerId: "b", startTime: 1, endTime: 2),
                ],
            ]
        )

        let result = try await HintRetryingDiarizer(runner: runner).diarize(
            audioURL: URL(fileURLWithPath: "/tmp/mock.wav"),
            speakerCountHint: 3
        )

        XCTAssertEqual(Set(result.map(\.speakerId)).count, 2)
        let configs = recorder.configs()
        XCTAssertEqual(configs.count, 2)
        XCTAssertNil(configs[0].clustering.minSpeakers)
        XCTAssertEqual(configs[0].clustering.maxSpeakers, 3)
        XCTAssertEqual(configs[1].clustering.minSpeakers, 2)
        XCTAssertEqual(configs[1].clustering.maxSpeakers, 3)
    }

    private func makeSessionFixture(audioDuration: Double) throws -> SessionFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noted-post-session-\(UUID().uuidString)", isDirectory: true)
        let descriptor = SessionDescriptor(
            id: "test-session",
            directory: root,
            type: .meeting,
            startedAt: Date(timeIntervalSince1970: 0),
            audioStrategy: "room_mic"
        )
        try SessionStore.createCanonicalDirectories(at: root)
        try writeTestWAV(to: descriptor.microphoneAudioURL, duration: audioDuration)

        let manifest = SessionManifest(
            schemaVersion: "1.0",
            sessionID: descriptor.id,
            createdAt: "2026-04-27T10:00:00+10:00",
            meeting: .init(
                eventID: nil,
                title: "Test",
                startTime: "2026-04-27T10:00:00+10:00",
                scheduledEndTime: nil,
                timezone: "Australia/Melbourne"
            ),
            mode: .init(type: "in_person", audioStrategy: "room_mic"),
            participants: .init(
                hostName: "Host",
                attendeesExpected: 2,
                participantNames: ["Host", "Guest"],
                namesAreHintsOnly: true
            ),
            recordingPolicy: .init(
                autoStart: true,
                autoStop: false,
                defaultExtensionMinutes: 5,
                preEndPromptMinutes: 5,
                noInteractionGraceMinutes: 5
            ),
            nextMeeting: .init(exists: false, manifestPath: nil),
            paths: .init(
                sessionDir: root.path,
                outputDir: root.appendingPathComponent("outputs", isDirectory: true).path,
                notePath: root.appendingPathComponent("note.md").path
            ),
            transcription: .init(
                asrBackend: "fluidaudio-parakeet",
                diarizationEnabled: true,
                speakerCountHint: 2,
                language: "en-AU"
            ),
            hooks: .init(completionCallback: nil)
        )
        return SessionFixture(descriptor: descriptor, manifest: manifest)
    }

    private func writeTestWAV(to url: URL, duration: Double) throws {
        let sampleRate = 16_000.0
        let frameCount = Int(duration * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            channel[index] = sin(Float(index) * 0.01) * 0.1
        }
        try file.write(from: buffer)
    }

    private func loadTranscriptDocument(_ url: URL) throws -> TestTranscriptDocument {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TestTranscriptDocument.self, from: data)
    }
}

private struct SessionFixture {
    let descriptor: SessionDescriptor
    let manifest: SessionManifest
}

@MainActor
private final class MockPostSessionWorker: PostSessionTranscribing, PostSessionDiarizing {
    private let diarization: [DiarizationSegment]?
    private var transcriptTexts: [String]

    init(diarization: [DiarizationSegment]?, transcriptTexts: [String]) {
        self.diarization = diarization
        self.transcriptTexts = transcriptTexts
    }

    func diarizeAudio(audioURL: URL, speakerCountHint: Int?) async -> [DiarizationSegment]? {
        diarization
    }

    func transcribeAudio(_ samples: [Float], source: AudioSource, locale: Locale) async throws -> ASRTranscriptResult {
        ASRTranscriptResult(text: transcriptTexts.removeFirst(), confidence: 0.91)
    }
}

private final class DiarizationConfigRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OfflineDiarizerConfig] = []

    func append(_ config: OfflineDiarizerConfig) {
        lock.withLock { values.append(config) }
    }

    func configs() -> [OfflineDiarizerConfig] {
        lock.withLock { values }
    }
}

private struct MockDiarizationRunner: OfflineDiarizationRunning {
    let recorder: DiarizationConfigRecorder
    let outputs: [[DiarizationSegment]]
    private let index = LockedIndex()

    func run(audioURL: URL, config: OfflineDiarizerConfig) async throws -> [DiarizationSegment] {
        recorder.append(config)
        let current = index.next()
        return outputs[min(current, outputs.count - 1)]
    }
}

private final class LockedIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

private struct TestTranscriptDocument: Decodable {
    let segments: [FinalTranscriptSegment]
}
