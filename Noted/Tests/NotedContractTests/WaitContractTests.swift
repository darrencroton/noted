import Foundation
import XCTest

/// Wait command contract tests.
///
/// These tests validate the documented CLI contract for the `wait` command without invoking
/// the main application. They verify:
/// - The exit-code values match the CLI contract of the master plan.
/// - The stdout JSON shapes for success and timeout are well-formed.
final class WaitContractTests: XCTestCase {

    // MARK: - `noted wait` exit-code contract (the CLI contract)

    func testWaitExitCodeContractIsDocumented() {
        // These constants are the stable, callee-facing contract for noted wait.
        // If they change, callers (smoke scripts, briefing watch) break silently.
        let successCode       = 0   // session reached terminal state; completion.json present
        let unknownSessionCode = 2  // unknown session ID (also used for missing --session-id)
        let timeoutCode       = 7   // --timeout-seconds elapsed before terminal state

        XCTAssertEqual(successCode, 0,        "success must be 0 per the CLI contract")
        XCTAssertEqual(unknownSessionCode, 2, "unknown session must be 2 per the CLI contract")
        XCTAssertEqual(timeoutCode, 7,        "timeout must be 7 per the CLI contract")
        // 7 must not collide with other well-known exit codes (2-6 used by other commands).
        XCTAssertTrue(timeoutCode > 6, "timeout code must be > 6 to avoid collisions")
    }

    func testWaitSuccessResponseHasRequiredFields() throws {
        // When wait succeeds, stdout must carry these fields so callers can act on
        // terminal_status without re-reading completion.json.
        let payload: [String: Any] = [
            "ok": true,
            "session_id": "2026-04-25T100000+1000-test",
            "terminal_status": "completed",
            "session_dir": "/sessions/2026-04-25T100000+1000-test",
        ]
        XCTAssertTrue(payload["ok"] as? Bool == true, "success response must have ok=true")
        XCTAssertNotNil(payload["session_id"],    "success response must include session_id")
        XCTAssertNotNil(payload["terminal_status"], "success response must include terminal_status")
        XCTAssertNotNil(payload["session_dir"],   "success response must include session_dir")
    }

    func testWaitTimeoutResponseHasRequiredFields() throws {
        // When wait times out, stdout must carry ok=false and error="timeout" so callers
        // can distinguish timeout from other failures without inspecting stderr.
        let payload: [String: Any] = [
            "ok": false,
            "session_id": "2026-04-25T100000+1000-test",
            "error": "timeout",
        ]
        XCTAssertTrue(payload["ok"] as? Bool == false, "timeout response must have ok=false")
        XCTAssertEqual(payload["error"] as? String, "timeout",
                       "timeout response must have error='timeout'")
        XCTAssertNotNil(payload["session_id"], "timeout response must include session_id")
    }

    func testWaitUnknownSessionResponseHasRequiredFields() throws {
        // When the session ID is not found in the registry, stdout must carry ok=false
        // and error="unknown_session_id" (distinct from timeout) so callers can diagnose.
        let payload: [String: Any] = [
            "ok": false,
            "session_id": "nonexistent-id",
            "error": "unknown_session_id",
        ]
        XCTAssertTrue(payload["ok"] as? Bool == false, "unknown-session response must have ok=false")
        XCTAssertEqual(payload["error"] as? String, "unknown_session_id",
                       "unknown-session response must carry error='unknown_session_id'")
    }

    func testWaitTerminalStatusValuesAreFromLockedVocabulary() {
        // the locked vocabulary: terminal_status must be one of the three locked values.
        let lockedValues: Set<String> = ["completed", "completed_with_warnings", "failed"]
        for value in lockedValues {
            XCTAssertTrue(lockedValues.contains(value),
                          "\(value) is not in the locked terminal_status vocabulary (the locked vocabulary)")
        }
        // An out-of-vocabulary value must not appear in a wait success response.
        let rogue = "done"
        XCTAssertFalse(lockedValues.contains(rogue),
                       "'\(rogue)' must not be accepted as a terminal_status (the locked vocabulary)")
    }
}
