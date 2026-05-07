import Foundation
import XCTest

final class FixtureContractTests: XCTestCase {
    private var fixturesRoot: URL {
        contractsSnapshotRoot.appendingPathComponent("contracts").appendingPathComponent("fixtures")
    }

    private var contractsSnapshotRoot: URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = packageRoot.deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("vendor")
            .appendingPathComponent("contracts")
    }

    func testContractsSnapshotIsPinnedToExpectedTag() throws {
        let tagURL = contractsSnapshotRoot.appendingPathComponent("CONTRACTS_TAG")
        let tag = try String(contentsOf: tagURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(tag, "v2.0.0")
    }

    func testValidManifestFixturesContainInputsNotedRequiresToStartCapture() throws {
        let filenames = [
            "valid-inperson.json",
            "valid-adhoc.json",
            "valid-with-next-meeting.json",
        ]
        let allowedBackends = Set(["whisperkit", "fluidaudio-parakeet", "sfspeech"])

        for filename in filenames {
            let manifest = try loadObject("manifests/\(filename)")
            XCTAssertEqual(manifest["schema_version"] as? String, "2.0", filename)

            let meeting = try XCTUnwrap(manifest["meeting"] as? [String: Any], filename)
            XCTAssertNotNil(meeting["start_time"], filename)
            XCTAssertNotNil(meeting["timezone"], filename)

            let participants = try XCTUnwrap(manifest["participants"] as? [String: Any], filename)
            XCTAssertEqual(participants["names_are_hints_only"] as? Bool, true, filename)

            let mode = try XCTUnwrap(manifest["mode"] as? [String: Any], filename)
            XCTAssertNil(mode["audio_strategy"], filename)

            let paths = try XCTUnwrap(manifest["paths"] as? [String: Any], filename)
            XCTAssertFalse(try XCTUnwrap(paths["session_dir"] as? String, filename).isEmpty, filename)
            XCTAssertFalse(try XCTUnwrap(paths["output_dir"] as? String, filename).isEmpty, filename)

            let transcription = try XCTUnwrap(manifest["transcription"] as? [String: Any], filename)
            XCTAssertTrue(allowedBackends.contains(try XCTUnwrap(transcription["asr_backend"] as? String, filename)), filename)
        }
    }

    func testNextMeetingFixtureProvidesManifestPathForSwitchNext() throws {
        let manifest = try loadObject("manifests/valid-with-next-meeting.json")
        let nextMeeting = try XCTUnwrap(manifest["next_meeting"] as? [String: Any])

        XCTAssertEqual(nextMeeting["exists"] as? Bool, true)
        XCTAssertFalse(try XCTUnwrap(nextMeeting["manifest_path"] as? String).isEmpty)
    }

    func testInvalidManifestFixturesExerciseRequiredFieldsAndNaiveTimestamps() throws {
        let missingRequired = try loadObject("manifests/invalid-missing-required.json")
        XCTAssertNil(missingRequired["schema_version"])

        let badTimezone = try loadObject("manifests/invalid-bad-timezone.json")
        XCTAssertEqual(badTimezone["created_at"] as? String, "2026-04-24T08:45:00")

        let meeting = try XCTUnwrap(badTimezone["meeting"] as? [String: Any])
        XCTAssertEqual(meeting["start_time"] as? String, "2026-04-24T09:30:00")

        let naiveScheduledEnd = try loadObject("manifests/invalid-naive-scheduled-end-time.json")
        let scheduledEndMeeting = try XCTUnwrap(naiveScheduledEnd["meeting"] as? [String: Any])
        XCTAssertEqual(scheduledEndMeeting["scheduled_end_time"] as? String, "2026-04-24T10:00:00")
    }

    func testCompletionFixturesEncodeCaptureOutcomeForPostProcessing() throws {
        let completed = try loadObject("completions/completed.json")
        XCTAssertEqual(completed["terminal_status"] as? String, "completed")
        XCTAssertEqual(completed["audio_capture_ok"] as? Bool, true)
        XCTAssertEqual(completed["transcript_ok"] as? Bool, true)

        let warning = try loadObject("completions/completed-with-warnings.json")
        XCTAssertEqual(warning["terminal_status"] as? String, "completed_with_warnings")
        XCTAssertEqual(warning["transcript_ok"] as? Bool, true)
        XCTAssertEqual(warning["diarization_ok"] as? Bool, false)

        let failedStartup = try loadObject("completions/failed-startup.json")
        XCTAssertEqual(failedStartup["stop_reason"] as? String, "startup_failure")
        XCTAssertEqual(failedStartup["audio_capture_ok"] as? Bool, false)

        let failedCapture = try loadObject("completions/failed-capture.json")
        XCTAssertEqual(failedCapture["stop_reason"] as? String, "capture_failure")
        XCTAssertEqual(failedCapture["audio_capture_ok"] as? Bool, true)
    }

    private func loadObject(_ relativePath: String) throws -> [String: Any] {
        let url = fixturesRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], relativePath)
    }
}
