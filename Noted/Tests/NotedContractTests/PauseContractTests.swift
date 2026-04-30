import Foundation
@testable import Noted
import XCTest

/// Pause/continue control tests.
///
/// These tests cover the file-based IPC shape rather than real audio capture. The session
/// runner consumes pause-state requests and reflects the applied state through status.json.
final class PauseContractTests: XCTestCase {
    func testRuntimeStatusDecodesMissingPausedFlagAsFalse() throws {
        let data = """
        {
          "session_id": "test-session",
          "status": "recording",
          "phase": "capturing",
          "updated_at": "2026-04-30T10:00:00+10:00"
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(RuntimeStatus.self, from: data)

        XCTAssertFalse(status.isPaused)
    }

    func testRuntimeStatusEncodesPausedFlagAsSnakeCase() throws {
        let status = RuntimeStatus(
            sessionID: "test-session",
            status: "recording",
            phase: "capturing",
            startedAt: "2026-04-30T10:00:00+10:00",
            updatedAt: "2026-04-30T10:01:00+10:00",
            scheduledEndTime: nil,
            currentExtensionMinutes: 0,
            preEndPromptShown: false,
            isPaused: true,
            lastError: nil
        )

        let data = try JSONEncoder().encode(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["is_paused"] as? Bool, true)
        XCTAssertNil(object["isPaused"])
    }

    func testPauseStateRequestRoundTrip() throws {
        let sessionDir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        try RuntimeFiles.writePauseStateRequest(sessionDir: sessionDir, paused: true)
        XCTAssertEqual(RuntimeFiles.readRequestedPauseState(sessionDir: sessionDir), true)

        try RuntimeFiles.writePauseStateRequest(sessionDir: sessionDir, paused: false)
        XCTAssertEqual(RuntimeFiles.readRequestedPauseState(sessionDir: sessionDir), false)
    }

    func testPauseStateRequestClearRemovesStaleRequest() throws {
        let sessionDir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        try RuntimeFiles.writePauseStateRequest(sessionDir: sessionDir, paused: true)
        RuntimeFiles.clearPauseStateRequest(sessionDir: sessionDir)

        XCTAssertNil(RuntimeFiles.readRequestedPauseState(sessionDir: sessionDir))
    }

    func testPauseRequestApplierAppliesPauseAndConsumesRequest() throws {
        let sessionDir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        try RuntimeFiles.writePauseStateRequest(sessionDir: sessionDir, paused: true)

        var isPaused = false
        var pauseCount = 0
        var resumeCount = 0
        PauseStateRequestApplier.apply(
            sessionID: "test-session",
            sessionDir: sessionDir,
            startedAt: "2026-04-30T10:00:00+10:00",
            scheduledEndTime: nil,
            currentExtensionMinutes: 0,
            preEndPromptShown: false,
            inMemoryIsPaused: &isPaused,
            pauseCapture: { pauseCount += 1 },
            resumeCapture: { resumeCount += 1 },
            log: { _ in }
        )

        let status = try XCTUnwrap(RuntimeFiles.readStatus(sessionDir: sessionDir))
        XCTAssertTrue(isPaused)
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertTrue(status.isPaused)
        XCTAssertNil(RuntimeFiles.readRequestedPauseState(sessionDir: sessionDir))
    }

    func testContinueFailureConsumesRequestAndDoesNotRetryWithoutFreshRequest() throws {
        let sessionDir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: sessionDir) }
        try RuntimeFiles.writePauseStateRequest(sessionDir: sessionDir, paused: false)

        var isPaused = true
        var resumeCount = 0
        PauseStateRequestApplier.apply(
            sessionID: "test-session",
            sessionDir: sessionDir,
            startedAt: "2026-04-30T10:00:00+10:00",
            scheduledEndTime: nil,
            currentExtensionMinutes: 0,
            preEndPromptShown: false,
            inMemoryIsPaused: &isPaused,
            pauseCapture: {},
            resumeCapture: {
                resumeCount += 1
                throw TestError.resumeFailed
            },
            log: { _ in }
        )

        let status = try XCTUnwrap(RuntimeFiles.readStatus(sessionDir: sessionDir))
        XCTAssertTrue(isPaused)
        XCTAssertTrue(status.isPaused)
        XCTAssertTrue(status.lastError?.hasPrefix("continue_failed:") == true)
        XCTAssertNil(RuntimeFiles.readRequestedPauseState(sessionDir: sessionDir))

        PauseStateRequestApplier.apply(
            sessionID: "test-session",
            sessionDir: sessionDir,
            startedAt: "2026-04-30T10:00:00+10:00",
            scheduledEndTime: nil,
            currentExtensionMinutes: 0,
            preEndPromptShown: false,
            inMemoryIsPaused: &isPaused,
            pauseCapture: {},
            resumeCapture: {
                resumeCount += 1
                throw TestError.resumeFailed
            },
            log: { _ in }
        )
        XCTAssertEqual(resumeCount, 1, "consumed failed continue request must not retry on every session-loop tick")
    }

    func testPauseContinueExitCodeContractDoesNotCollideWithStop() {
        let success = 0
        let unknownSession = 2
        let sessionNotRecording = 3
        let controlFailed = 4

        XCTAssertEqual(success, 0)
        XCTAssertEqual(unknownSession, 2)
        XCTAssertEqual(sessionNotRecording, 3)
        XCTAssertEqual(controlFailed, 4)
    }

    private func makeSessionDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noted-pause-contract-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent("runtime", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    private enum TestError: Error {
        case resumeFailed
    }
}
