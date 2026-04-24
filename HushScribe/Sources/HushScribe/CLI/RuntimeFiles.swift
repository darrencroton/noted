import Darwin
import Foundation

struct RuntimeStatus: Codable, Sendable {
    var sessionID: String
    var status: String
    var phase: String
    var startedAt: String?
    var updatedAt: String
    var scheduledEndTime: String?
    var currentExtensionMinutes: Int
    var preEndPromptShown: Bool
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
        case lastError = "last_error"
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
            guard let active = readActiveCapture() else {
                return false
            }
            if processIsRunning(active.pid) {
                return false
            }

            try? FileManager.default.removeItem(at: activeCaptureLockDirectory)
            try? FileManager.default.removeItem(at: activeCaptureURL)
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

    static func captureFinalizedURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/capture-finalized.json")
    }

    static func captureFinalizedAcknowledgedURL(sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("runtime/capture-finalized-acknowledged.json")
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
            lastError: lastError
        )
        let data = try encoder.encode(payload)
        try data.write(to: statusURL(sessionDir: sessionDir), options: .atomic)
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
    static func withOffset(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        return formatter.string(from: date)
    }
}
