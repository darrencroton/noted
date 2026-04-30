import Darwin
import Foundation

struct UIState: Codable, Sendable {
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

struct RuntimeStatus: Codable, Sendable {
    var sessionID: String
    var status: String
    var phase: String
    var startedAt: String?
    var updatedAt: String
    var scheduledEndTime: String?
    var currentExtensionMinutes: Int
    var preEndPromptShown: Bool
    var isPaused: Bool
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case phase
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case scheduledEndTime = "scheduled_end_time"
        case currentExtensionMinutes = "current_extension_minutes"
        case preEndPromptShown = "pre_end_prompt_shown"
        case isPaused = "is_paused"
        case lastError = "last_error"
    }

    init(
        sessionID: String,
        status: String,
        phase: String,
        startedAt: String?,
        updatedAt: String,
        scheduledEndTime: String?,
        currentExtensionMinutes: Int,
        preEndPromptShown: Bool,
        isPaused: Bool = false,
        lastError: String?
    ) {
        self.sessionID = sessionID
        self.status = status
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.scheduledEndTime = scheduledEndTime
        self.currentExtensionMinutes = currentExtensionMinutes
        self.preEndPromptShown = preEndPromptShown
        self.isPaused = isPaused
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        status = try container.decode(String.self, forKey: .status)
        phase = try container.decode(String.self, forKey: .phase)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        scheduledEndTime = try container.decodeIfPresent(String.self, forKey: .scheduledEndTime)
        currentExtensionMinutes = try container.decodeIfPresent(Int.self, forKey: .currentExtensionMinutes) ?? 0
        preEndPromptShown = try container.decodeIfPresent(Bool.self, forKey: .preEndPromptShown) ?? false
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct CompletionFile: Codable, Sendable {
    let schemaVersion: String
    let sessionID: String
    let manifestSchemaVersion: String
    let terminalStatus: String
    let stopReason: String
    let audioCaptureOK: Bool
    let transcriptOK: Bool
    let diarizationOK: Bool
    let warnings: [String]
    let errors: [String]
    let completedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case manifestSchemaVersion = "manifest_schema_version"
        case terminalStatus = "terminal_status"
        case stopReason = "stop_reason"
        case audioCaptureOK = "audio_capture_ok"
        case transcriptOK = "transcript_ok"
        case diarizationOK = "diarization_ok"
        case warnings
        case errors
        case completedAt = "completed_at"
    }
}

struct SessionRegistryRecord: Codable, Sendable {
    let sessionID: String
    let sessionDir: String
    let pid: Int32?
    let manifestPath: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionDir = "session_dir"
        case pid
        case manifestPath = "manifest_path"
    }
}

struct ActiveCaptureRecord: Codable, Sendable {
    let sessionID: String
    let sessionDir: String
    let pid: Int32

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionDir = "session_dir"
        case pid
    }
}

enum RuntimeFiles {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/noted", isDirectory: true)
    }

    static var runtimeDirectory: URL {
        supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    static var registryDirectory: URL {
        supportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    static var activeCaptureURL: URL {
        runtimeDirectory.appendingPathComponent("active-capture.json")
    }

    static var activeCaptureLockDirectory: URL {
        runtimeDirectory.appendingPathComponent("active-capture.lock", isDirectory: true)
    }

    static func prepareSupportDirectories() throws {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
    }

    static func registryURL(sessionID: String) -> URL {
        registryDirectory.appendingPathComponent("\(sessionID).json")
    }

    static func writeRegistry(_ record: SessionRegistryRecord) throws {
        try prepareSupportDirectories()
        let data = try encoder.encode(record)
        try data.write(to: registryURL(sessionID: record.sessionID), options: .atomic)
    }

    static func readRegistry(sessionID: String) -> SessionRegistryRecord? {
        let url = registryURL(sessionID: sessionID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionRegistryRecord.self, from: data)
    }

    static func latestRegistryRecord() -> SessionRegistryRecord? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: registryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        let latest = files
            .filter { $0.pathExtension == "json" }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
        guard let latest, let data = try? Data(contentsOf: latest) else { return nil }
        return try? decoder.decode(SessionRegistryRecord.self, from: data)
    }

    static func tryAcquireActiveCapture(sessionID: String, sessionDir: URL) throws -> Bool {
        try prepareSupportDirectories()

        if let active = readActiveCapture() {
            if processIsRunning(active.pid) {
                return false
            }
            try? FileManager.default.removeItem(at: activeCaptureURL)
            try? FileManager.default.removeItem(at: activeCaptureLockDirectory)
        }

        do {
            try FileManager.default.createDirectory(at: activeCaptureLockDirectory, withIntermediateDirectories: false)
        } catch {
            if let active = readActiveCapture() {
                if processIsRunning(active.pid) {
                    return false
                }
                // Stale capture from a dead process — clean up and re-acquire.
                try? FileManager.default.removeItem(at: activeCaptureURL)
            }
            // Lock directory exists without a valid capture record — orphaned from a prior
            // crash or interrupted releaseActiveCapture. Force-remove and retry.
            try? FileManager.default.removeItem(at: activeCaptureLockDirectory)
            try FileManager.default.createDirectory(at: activeCaptureLockDirectory, withIntermediateDirectories: false)
        }

        let record = ActiveCaptureRecord(
            sessionID: sessionID,
            sessionDir: sessionDir.path,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let data = try encoder.encode(record)
        try data.write(to: activeCaptureURL, options: .atomic)
        return true
    }

    static func updateActiveCapturePID(_ pid: Int32, sessionID: String, sessionDir: URL) throws {
        let record = ActiveCaptureRecord(sessionID: sessionID, sessionDir: sessionDir.path, pid: pid)
        let data = try encoder.encode(record)
        try data.write(to: activeCaptureURL, options: .atomic)
    }

    static func readActiveCapture() -> ActiveCaptureRecord? {
        guard let data = try? Data(contentsOf: activeCaptureURL) else { return nil }
        return try? decoder.decode(ActiveCaptureRecord.self, from: data)
    }

    static func readLiveActiveCapture() -> ActiveCaptureRecord? {
        guard let active = readActiveCapture(), processIsRunning(active.pid) else { return nil }
        return active
    }

    static func releaseActiveCapture(sessionID: String) {
        guard let active = readActiveCapture(), active.sessionID == sessionID else { return }
        try? FileManager.default.removeItem(at: activeCaptureURL)
        try? FileManager.default.removeItem(at: activeCaptureLockDirectory)
    }

    static func statusURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/status.json")
    }

    static func stopRequestURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/stop-request.json")
    }

    static func pauseStateRequestURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/pause-state-request.json")
    }

    static func captureFinalizedURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/capture-finalized.json")
    }

    static func captureFinalizedAcknowledgedURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/capture-finalized-acknowledged.json")
    }

    static func preEndPromptURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/pre-end-prompt.json")
    }

    static func uiStateURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/ui_state.json")
    }

    static func nextManifestMissingURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/next-manifest-missing.json")
    }

    static func writePreEndPrompt(sessionDir: URL, promptAt: Date, isFollowUp: Bool) throws {
        let payload: [String: Any] = [
            "prompt_at": ISO8601.withOffset(promptAt),
            "is_follow_up": isFollowUp,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: preEndPromptURL(sessionDir: sessionDir), options: .atomic)
    }

    static func clearPreEndPrompt(sessionDir: URL) {
        try? FileManager.default.removeItem(at: preEndPromptURL(sessionDir: sessionDir))
    }

    static func readUIState(sessionDir: URL) -> UIState? {
        guard let data = try? Data(contentsOf: uiStateURL(sessionDir: sessionDir)) else { return nil }
        return try? decoder.decode(UIState.self, from: data)
    }

    static func writeUIState(_ state: UIState, to sessionDir: URL) throws {
        let data = try encoder.encode(state)
        try data.write(to: uiStateURL(sessionDir: sessionDir), options: .atomic)
    }

    static func writeNextManifestMissing(sessionDir: URL) throws {
        let payload: [String: Any] = ["recorded_at": ISO8601.withOffset(Date())]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: nextManifestMissingURL(sessionDir: sessionDir), options: .atomic)
    }

    static func readStatus(sessionDir: URL) -> RuntimeStatus? {
        guard let data = try? Data(contentsOf: statusURL(sessionDir: sessionDir)) else { return nil }
        return try? decoder.decode(RuntimeStatus.self, from: data)
    }

    static func writeStatus(
        sessionID: String,
        sessionDir: URL,
        status: String,
        phase: String,
        startedAt: String?,
        scheduledEndTime: String?,
        currentExtensionMinutes: Int = 0,
        preEndPromptShown: Bool = false,
        isPaused: Bool = false,
        lastError: String? = nil
    ) throws {
        let payload = RuntimeStatus(
            sessionID: sessionID,
            status: status,
            phase: phase,
            startedAt: startedAt,
            updatedAt: ISO8601.withOffset(Date()),
            scheduledEndTime: scheduledEndTime,
            currentExtensionMinutes: currentExtensionMinutes,
            preEndPromptShown: preEndPromptShown,
            isPaused: isPaused,
            lastError: lastError
        )
        let data = try encoder.encode(payload)
        try data.write(to: statusURL(sessionDir: sessionDir), options: .atomic)
    }

    static func writePauseStateRequest(sessionDir: URL, paused: Bool) throws {
        let payload: [String: Any] = [
            "is_paused": paused,
            "requested_at": ISO8601.withOffset(Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: pauseStateRequestURL(sessionDir: sessionDir), options: .atomic)
    }

    static func readRequestedPauseState(sessionDir: URL) -> Bool? {
        guard let data = try? Data(contentsOf: pauseStateRequestURL(sessionDir: sessionDir)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paused = object["is_paused"] as? Bool
        else {
            return nil
        }
        return paused
    }

    static func clearPauseStateRequest(sessionDir: URL) {
        try? FileManager.default.removeItem(at: pauseStateRequestURL(sessionDir: sessionDir))
    }

    static func writeStopRequest(sessionDir: URL, reason: String = "manual_stop") throws {
        let payload: [String: Any] = [
            "stop_reason": reason,
            "requested_at": ISO8601.withOffset(Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stopRequestURL(sessionDir: sessionDir), options: .atomic)
    }

    static func readStopReason(sessionDir: URL) -> String {
        guard let data = try? Data(contentsOf: stopRequestURL(sessionDir: sessionDir)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["stop_reason"] as? String
        else {
            return "manual_stop"
        }
        return reason
    }

    static func writeCaptureFinalized(sessionID: String, sessionDir: URL) throws {
        let payload: [String: Any] = [
            "session_id": sessionID,
            "finalized_at": ISO8601.withOffset(Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: captureFinalizedURL(sessionDir: sessionDir), options: .atomic)
    }

    static func acknowledgeCaptureFinalized(sessionID: String, sessionDir: URL) throws {
        let payload: [String: Any] = [
            "session_id": sessionID,
            "acknowledged_at": ISO8601.withOffset(Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: captureFinalizedAcknowledgedURL(sessionDir: sessionDir), options: .atomic)
    }

    static func processIsRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

enum ISO8601 {
    // ISO8601DateFormatter is thread-safe for concurrent reads; nonisolated(unsafe) lets us
    // share the instances across actors without allocating a new formatter on every call.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return f
    }()

    private nonisolated(unsafe) static let wholeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func withOffset(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func parseDate(_ string: String) -> Date? {
        if let d = fractionalFormatter.date(from: string) { return d }
        return wholeFormatter.date(from: string)
    }
}
