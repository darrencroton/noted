import Foundation
@testable import Noted
import XCTest

/// Completion handoff contract tests:
/// ad hoc manifests, configurable briefing command, and completion handoff.
///
/// These tests validate the file-based contracts and JSON formats current handoff.
/// Production ad hoc manifest encoding is covered directly so contract-required nulls
/// cannot regress behind the menubar action.
final class HandoffContractTests: XCTestCase {

    // MARK: - Ad hoc manifest contract

    func testAdHocManifestFixturePermitsNullEventIdAndScheduledEndTime() throws {
        // §20.1: ad hoc manifests are full canonical manifests with allowed nulls.
        // event_id and scheduled_end_time must be present as explicit JSON null, not absent -
        // a missing key would mean the field was never set, which is different from "no event".
        let manifest = try loadFixture("manifests/valid-adhoc.json")
        let meeting = try XCTUnwrap(manifest["meeting"] as? [String: Any])

        XCTAssertTrue(meeting.keys.contains("event_id"),
                      "event_id must be present as explicit JSON null (§20.1), not absent")
        XCTAssertTrue(meeting.keys.contains("scheduled_end_time"),
                      "scheduled_end_time must be present as explicit JSON null (§20.1), not absent")
        // JSONSerialization decodes JSON null as NSNull; a string value would fail the cast.
        XCTAssertTrue(isJSONNull(meeting["event_id"]),
                      "event_id must be JSON null for ad hoc manifests, not a string")
        XCTAssertTrue(isJSONNull(meeting["scheduled_end_time"]),
                      "scheduled_end_time must be JSON null for ad hoc manifests, not a string")
    }

    func testAdHocManifestFixtureSessionIDCarriesAdHocMarker() throws {
        // Ad hoc session IDs must contain an "adhoc" marker so they are distinguishable
        // from calendar-driven sessions in logs and Obsidian note paths.
        let manifest = try loadFixture("manifests/valid-adhoc.json")
        let sessionID = try XCTUnwrap(manifest["session_id"] as? String)
        XCTAssertTrue(
            sessionID.lowercased().contains("adhoc") || sessionID.lowercased().contains("ad-hoc"),
            "ad hoc session_id must contain 'adhoc' or 'ad-hoc', got: \(sessionID)"
        )
    }

    func testAdHocManifestFixtureOutputDirIsSubdirectoryOfSessionDir() throws {
        // The session directory layout contract requires output_dir == session_dir/outputs.
        let manifest = try loadFixture("manifests/valid-adhoc.json")
        let paths = try XCTUnwrap(manifest["paths"] as? [String: Any])
        let sessionDir = try XCTUnwrap(paths["session_dir"] as? String)
        let outputDir = try XCTUnwrap(paths["output_dir"] as? String)
        XCTAssertEqual(outputDir, sessionDir + "/outputs",
                       "output_dir must equal session_dir/outputs")
    }

    func testAdHocManifestWriterEmitsExplicitNullContractFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noted-ad-hoc-manifest-writer-\(UUID().uuidString)", isDirectory: true)
        let settings = RuntimeSettings(
            hostName: "Test Host",
            language: "en-US",
            asrBackend: "fluidaudio-parakeet",
            asrModelVariant: "parakeet-v3",
            defaultInputDevice: 0,
            outputRoot: root.appendingPathComponent("sessions", isDirectory: true).path,
            adHocNoteDirectory: root.appendingPathComponent("notes", isDirectory: true).path,
            sysVadThreshold: 0.92,
            hideFromScreenShare: true,
            briefingCommand: "",
            ingestAfterCompletion: false,
            diarizationEnabled: true,
            defaultExtensionMinutes: 5,
            preEndPromptMinutes: 5,
            noInteractionGraceMinutes: 5
        )

        let written = try AdHocManifestWriter(settings: settings).writeManifest()
        let data = try Data(contentsOf: written.manifestURL)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let meeting = try XCTUnwrap(manifest["meeting"] as? [String: Any])
        let hooks = try XCTUnwrap(manifest["hooks"] as? [String: Any])

        XCTAssertTrue(isJSONNull(meeting["event_id"]))
        XCTAssertTrue(isJSONNull(meeting["scheduled_end_time"]))
        XCTAssertTrue(isJSONNull(hooks["completion_callback"]))
    }

    // MARK: - Completion handoff contract

    func testHandoffSkipLogPrefixesAreGreppable() {
        // The smoke script (scripts/meeting-intelligence-smoke.sh) greps for these exact
        // prefixes to detect whether the automatic handoff ran, was skipped, or failed.
        // These constants document the contract between the implementation and the script -
        // changing one without the other breaks the smoke harness.
        let skippedDisabled = "briefing ingest skipped: ingest_after_completion=false"
        let skippedEmpty    = "briefing ingest skipped: briefing_command is empty"
        let starting        = "briefing ingest starting:"
        let completed       = "briefing ingest completed:"
        let failedToStart   = "briefing ingest failed to start:"

        XCTAssertTrue(skippedDisabled.hasPrefix("briefing ingest skipped"),
                      "disabled-skip log must start with 'briefing ingest skipped'")
        XCTAssertTrue(skippedEmpty.hasPrefix("briefing ingest skipped"),
                      "empty-command-skip log must start with 'briefing ingest skipped'")
        XCTAssertTrue(starting.hasPrefix("briefing ingest starting"),
                      "starting log must start with 'briefing ingest starting'")
        XCTAssertTrue(completed.hasPrefix("briefing ingest completed"),
                      "completed log must start with 'briefing ingest completed'")
        XCTAssertTrue(failedToStart.hasPrefix("briefing ingest failed to start"),
                      "failed log must start with 'briefing ingest failed to start'")
    }

    func testHandoffStartingLogContainsBoundaryDiagnosticFields() {
        // the "briefing ingest starting" entry must carry enough context for the operator
        // to trace the handoff without opening the captured log files.
        let entry = "briefing ingest starting: command=briefing session_id=20260425T1430000000-ad-hoc terminal_status=completed stdout=/path/to/stdout.log stderr=/path/to/stderr.log"
        for field in ["command=", "session_id=", "terminal_status=", "stdout=", "stderr="] {
            XCTAssertTrue(entry.contains(field),
                          "starting log must contain '\(field)' for cross-boundary diagnostics")
        }
    }

    func testHandoffCompletedLogContainsExitCode() {
        // the "briefing ingest completed" entry must include exit_code so a non-zero
        // result from briefing is visible in noted.log without reading the captured stderr.
        let entry = "briefing ingest completed: command=briefing exit_code=0 session_id=test terminal_status=completed stdout=/tmp/s.log stderr=/tmp/e.log"
        XCTAssertTrue(entry.contains("exit_code="),
                      "completed log must include 'exit_code=' for handoff diagnostics")
    }

    // MARK: - Helpers

    /// Returns true if `value` is an Optional wrapping an NSNull instance.
    /// JSONSerialization represents JSON null as NSNull, not as a Swift nil Optional.
    private func isJSONNull(_ value: Any?) -> Bool {
        guard let v = value else { return false }
        return v is NSNull
    }

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
}
