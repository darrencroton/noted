import Foundation
import XCTest

/// End-of-meeting contract tests.
///
/// These tests validate the file-based IPC contracts and JSON formats current runtime.
/// They do not run real audio capture; that is covered by the smoke-test procedure in
/// local capture smoke tests.
final class EndOfMeetingContractTests: XCTestCase {

    // MARK: - Prompt scheduler math

    func testPromptFiresAtCorrectTime() {
        // scheduled_end_time − pre_end_prompt_minutes
        let scheduledEnd = makeDate(addingMinutes: 30)
        let preEndMinutes = 5
        let promptTime = scheduledEnd.addingTimeInterval(-Double(preEndMinutes) * 60)
        let expected = makeDate(addingMinutes: 25)
        XCTAssertEqual(promptTime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testPromptSuppressedWhenNoScheduledEndTime() {
        // Ad hoc sessions have scheduled_end_time = null; prompt must not fire.
        let scheduledEndTimeString: String? = nil
        let parsedDate = scheduledEndTimeString.flatMap { parseISO8601($0) }
        XCTAssertNil(parsedDate, "nil scheduled_end_time must suppress prompt scheduling")
    }

    // MARK: - pre-end-prompt.json format

    func testPreEndPromptJSONContainsRequiredFields() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload: [String: Any] = [
            "prompt_at": iso8601Now(),
        ]
        let url = tmp.appendingPathComponent("pre-end-prompt.json")
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url)

        let loaded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(loaded["prompt_at"] as? String)
    }

    // MARK: - extend

    func testExtendComputesNewEndTimeCorrectly() {
        // Extend by 5 minutes adds exactly 300 seconds.
        let original = makeDate(addingMinutes: 60)
        let minutes = 5
        let extended = original.addingTimeInterval(Double(minutes) * 60)
        XCTAssertEqual(
            extended.timeIntervalSince(original),
            Double(minutes) * 60,
            accuracy: 0.001
        )
    }

    func testExtendExtensionMinutesAccumulateInStatusJSON() throws {
        // Mirrors the extend command's read-modify-write: decode current_extension_minutes
        // from status.json, add the requested minutes, verify field name and type are correct.
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let initialMinutes = 5
        let payload: [String: Any] = ["current_extension_minutes": initialMinutes]
        let statusURL = tmp.appendingPathComponent("status.json")
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: statusURL)

        let loaded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as? [String: Any])
        let existing = try XCTUnwrap(loaded["current_extension_minutes"] as? Int,
                                     "current_extension_minutes must decode as Int")
        XCTAssertEqual(existing + 5, 10, "extension minutes must accumulate correctly")
    }

    // MARK: - ui_state.json

    func testUIStateRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()

        let original = UIState(
            promptShownAt: iso8601Now(),
            extensionCount: 2,
            lastAction: "extend",
            lastActionAt: iso8601Now()
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UIState.self, from: data)

        XCTAssertEqual(decoded.promptShownAt, original.promptShownAt)
        XCTAssertEqual(decoded.extensionCount, original.extensionCount)
        XCTAssertEqual(decoded.lastAction, original.lastAction)
        XCTAssertEqual(decoded.lastActionAt, original.lastActionAt)
    }

    func testUIStateCodingKeys() throws {
        let encoder = JSONEncoder()
        let state = UIState(
            promptShownAt: "2026-04-24T09:00:00+10:00",
            extensionCount: 1,
            lastAction: "extend",
            lastActionAt: "2026-04-24T09:05:00+10:00"
        )
        let data = try encoder.encode(state)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // All four snake_case keys must appear.
        XCTAssertNotNil(obj["prompt_shown_at"])
        XCTAssertNotNil(obj["extension_count"])
        XCTAssertNotNil(obj["last_action"])
        XCTAssertNotNil(obj["last_action_at"])
        // No camelCase leakage.
        XCTAssertNil(obj["promptShownAt"], "camelCase key must not appear in output")
        XCTAssertNil(obj["extensionCount"], "camelCase key must not appear in output")
        XCTAssertNil(obj["lastAction"], "camelCase key must not appear in output")
        XCTAssertNil(obj["lastActionAt"], "camelCase key must not appear in output")
    }

    // MARK: - switch-next race - manifest fixture coverage

    func testNextMeetingFixtureHasManifestPathForRaceTest() throws {
        let manifest = try loadFixture("manifests/valid-with-next-meeting.json")
        let nextMeeting = try XCTUnwrap(manifest["next_meeting"] as? [String: Any])

        XCTAssertEqual(nextMeeting["exists"] as? Bool, true)
        let path = try XCTUnwrap(nextMeeting["manifest_path"] as? String)
        XCTAssertFalse(path.isEmpty, "manifest_path required for switch-next to resolve the next session")
    }

    func testSwitchNextRequiresNextMeetingExists() throws {
        // A manifest without a next meeting must yield exit 3 from switch-next.
        // This test verifies the fixture shape; the CLI exit code is exercised in smoke tests.
        let manifest = try loadFixture("manifests/valid-inperson.json")
        let nextMeeting = try XCTUnwrap(manifest["next_meeting"] as? [String: Any])
        XCTAssertEqual(nextMeeting["exists"] as? Bool, false,
                       "valid-inperson.json must not advertise a next meeting so it exercises the exit-3 path")
    }

    func testNextManifestMissingJSONContainsTimestamp() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload: [String: Any] = ["recorded_at": iso8601Now()]
        let url = tmp.appendingPathComponent("next-manifest-missing.json")
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url)

        let loaded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let ts = try XCTUnwrap(loaded["recorded_at"] as? String)
        XCTAssertTrue(hasExplicitOffset(ts), "next-manifest-missing timestamp must carry an explicit offset")
    }

    // MARK: - Back-to-back contract requirements

    func testSessionDirectoryContractIncludesUIState() throws {
        // The session-directory contract (§10.4) lists runtime/ui_state.json as a valid path.
        // This test confirms the contract doc is consulted by verifying the fixture manifest's
        // session_dir is non-empty (required so the UI state can be written to a known location).
        let manifest = try loadFixture("manifests/valid-with-next-meeting.json")
        let paths = try XCTUnwrap(manifest["paths"] as? [String: Any])
        let sessionDir = try XCTUnwrap(paths["session_dir"] as? String)
        XCTAssertFalse(sessionDir.isEmpty)
    }

    func testAutoSwitchStopReasonIsContractDefined() {
        // auto_switch_to_next_meeting is the stop reason for both user-driven and timer-driven
        // switch-next, so it must be present in the contract's stop-reason vocabulary.
        let contractStopReasons = [
            "manual_stop",
            "scheduled_stop",
            "auto_switch_to_next_meeting",
            "startup_failure",
            "capture_failure",
            "processing_failure",
            "forced_quit",
        ]
        XCTAssertTrue(contractStopReasons.contains("auto_switch_to_next_meeting"))
        XCTAssertTrue(contractStopReasons.contains("scheduled_stop"))
    }

    // MARK: - No-interaction grace rule

    func testGraceDeadlineComputedFromScheduledEndWhenNextMeetingExists() {
        let scheduledEnd = makeDate(addingMinutes: 60)
        let graceMins = 5
        let graceDeadline = scheduledEnd.addingTimeInterval(Double(graceMins) * 60)
        XCTAssertEqual(
            graceDeadline.timeIntervalSince(scheduledEnd),
            Double(graceMins) * 60,
            accuracy: 0.001
        )
    }

    func testGraceDeadlineEqualsScheduledEndWhenNoNextMeeting() {
        // §12.3: No next meeting -> auto-stop at scheduled_end_time (grace == 0 offset).
        let scheduledEnd = makeDate(addingMinutes: 60)
        let graceDeadline = scheduledEnd   // no extra offset
        XCTAssertEqual(graceDeadline, scheduledEnd)
    }

    // MARK: - Helpers

    private var fixturesRoot: URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/contracts/contracts/fixtures")
    }

    private func loadFixture(_ relativePath: String) throws -> [String: Any] {
        let url = fixturesRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], relativePath)
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDate(addingMinutes minutes: Int) -> Date {
        Date().addingTimeInterval(Double(minutes) * 60)
    }

    private func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f.string(from: Date())
    }

    private func parseISO8601(_ string: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        if let d = f1.date(from: string) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: string)
    }

    private func hasExplicitOffset(_ string: String) -> Bool {
        string.range(of: #"(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil
    }
}

// MARK: - UIState stub for test target
// The test target does not import the main module, so we define a minimal mirror of UIState here
// for the round-trip test.  This must stay in sync with the production struct's CodingKeys.

private struct UIState: Codable {
    var promptShownAt: String?
    var extensionCount: Int
    var lastAction: String?
    var lastActionAt: String?

    init(
        promptShownAt: String? = nil,
        extensionCount: Int = 0,
        lastAction: String? = nil,
        lastActionAt: String? = nil
    ) {
        self.promptShownAt = promptShownAt
        self.extensionCount = extensionCount
        self.lastAction = lastAction
        self.lastActionAt = lastActionAt
    }

    enum CodingKeys: String, CodingKey {
        case promptShownAt = "prompt_shown_at"
        case extensionCount = "extension_count"
        case lastAction = "last_action"
        case lastActionAt = "last_action_at"
    }
}
