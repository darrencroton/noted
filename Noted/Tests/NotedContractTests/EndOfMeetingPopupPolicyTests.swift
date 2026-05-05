import Foundation
@testable import Noted
import XCTest

final class EndOfMeetingPopupPolicyTests: XCTestCase {
    func testNextMeetingOfferDependsOnlyOnManifestNextMeetingFlag() {
        // Prompt cycle count is intentionally not an input. The popup re-reads the manifest
        // for every prompt, so initial and extension prompts use the same decision path.
        let withNextMeeting = makeManifest(nextMeetingExists: true)
        let withoutNextMeeting = makeManifest(nextMeetingExists: false)

        XCTAssertTrue(EndOfMeetingPopupController.shouldOfferNextMeeting(manifest: withNextMeeting))
        XCTAssertFalse(EndOfMeetingPopupController.shouldOfferNextMeeting(manifest: withoutNextMeeting))
    }

    func testPromptFileClearingAllowsNextPromptCycle() throws {
        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noted-popup-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        try FileManager.default.createDirectory(
            at: sessionDir.appendingPathComponent("runtime", isDirectory: true),
            withIntermediateDirectories: true
        )

        try RuntimeFiles.writePreEndPrompt(sessionDir: sessionDir, promptAt: Date())
        let promptURL = RuntimeFiles.preEndPromptURL(sessionDir: sessionDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptURL.path))

        let data = try Data(contentsOf: promptURL)
        let loaded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(loaded["prompt_at"] as? String)
        XCTAssertNil(loaded["is_follow_up"], "prompt cycle state must not be written to popup IPC")

        RuntimeFiles.clearPreEndPrompt(sessionDir: sessionDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: promptURL.path))
    }

    private func makeManifest(nextMeetingExists: Bool) -> SessionManifest {
        SessionManifest(
            schemaVersion: "1.0",
            sessionID: "test-session",
            createdAt: "2026-04-27T10:00:00+10:00",
            meeting: .init(
                eventID: "event-1",
                title: "Current Meeting",
                startTime: "2026-04-27T10:00:00+10:00",
                scheduledEndTime: "2026-04-27T11:00:00+10:00",
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
                autoStop: true,
                defaultExtensionMinutes: 5,
                preEndPromptMinutes: 5,
                noInteractionGraceMinutes: 5
            ),
            nextMeeting: .init(
                exists: nextMeetingExists,
                manifestPath: nextMeetingExists ? "/tmp/next-manifest.json" : nil
            ),
            paths: .init(
                sessionDir: "/tmp/current-session",
                outputDir: "/tmp/current-session/outputs",
                notePath: "/tmp/current-session/note.md"
            ),
            transcription: .init(
                asrBackend: "fluidaudio-parakeet",
                diarizationEnabled: true,
                speakerCountHint: 2,
                language: "en-AU"
            ),
            hooks: .init(completionCallback: nil)
        )
    }
}
