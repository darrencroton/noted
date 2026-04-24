import Foundation

enum TranscriptLoggerError: LocalizedError {
    case noActiveSession
    case cannotCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active transcript session."
        case .cannotCreateFile(let path):
            return "Cannot create transcript at \(path)."
        }
    }
}

actor TranscriptLogger {
    private var descriptor: SessionDescriptor?
    private var textHandle: FileHandle?
    private var segments: [TranscriptSegment] = []
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    func startSession(_ descriptor: SessionDescriptor) throws {
        try FileManager.default.createDirectory(at: descriptor.transcriptDirectory, withIntermediateDirectories: true)
        let transcriptURL = descriptor.transcriptDirectory.appendingPathComponent("transcript.txt")
        let header = """
        noted session \(descriptor.id)
        started_at: \(Self.iso8601String(from: descriptor.startedAt))
        type: \(descriptor.type.rawValue)

        """
        let created = FileManager.default.createFile(atPath: transcriptURL.path, contents: header.data(using: .utf8))
        guard created else { throw TranscriptLoggerError.cannotCreateFile(transcriptURL.path) }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: transcriptURL)
        } catch {
            self.descriptor = nil
            segments = []
            textHandle = nil
            throw error
        }

        do {
            self.descriptor = descriptor
            segments = []
            textHandle = handle
            try writeMetadata()
        } catch {
            try? handle.close()
            self.descriptor = nil
            segments = []
            textHandle = nil
            throw error
        }
    }

    func append(_ segment: TranscriptSegment) {
        guard let textHandle else { return }
        segments.append(segment)

        let line = "[\(Self.clockString(from: segment.timestamp))] \(segment.speaker.displayName): \(segment.text)\n"
        if let data = line.data(using: .utf8) {
            textHandle.seekToEndOfFile()
            textHandle.write(data)
        }

        try? writeSegments()
    }

    func writeDiarization(_ segments: [DiarizationSegment]) throws {
        guard let descriptor else { throw TranscriptLoggerError.noActiveSession }
        try writeDiarization(segments, to: descriptor.directory)
    }

    func writeDiarization(_ segments: [DiarizationSegment], to directory: URL) throws {
        let diarizationDirectory = directory.appendingPathComponent("diarization", isDirectory: true)
        try FileManager.default.createDirectory(at: diarizationDirectory, withIntermediateDirectories: true)
        let url = diarizationDirectory.appendingPathComponent("diarization.json")
        let data = try encoder.encode(segments)
        try data.write(to: url, options: .atomic)
    }

    func endSession() throws -> URL {
        guard let descriptor else { throw TranscriptLoggerError.noActiveSession }
        try? textHandle?.close()
        textHandle = nil
        try writeSegments()
        let output = descriptor.directory
        self.descriptor = nil
        segments = []
        return output
    }

    private func writeMetadata() throws {
        guard let descriptor else { throw TranscriptLoggerError.noActiveSession }
        let metadata: [String: String] = [
            "id": descriptor.id,
            "type": descriptor.type.rawValue,
            "started_at": Self.iso8601String(from: descriptor.startedAt),
        ]
        let data = try encoder.encode(metadata)
        try data.write(to: descriptor.runtimeDirectory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func writeSegments() throws {
        guard let descriptor else { throw TranscriptLoggerError.noActiveSession }
        let transcript = TranscriptDocument(
            schemaVersion: "1.0",
            sessionID: descriptor.id,
            segments: segments
        )
        let transcriptData = try encoder.encode(transcript)
        try transcriptData.write(to: descriptor.transcriptDirectory.appendingPathComponent("transcript.json"), options: .atomic)
        let segmentsData = try encoder.encode(segments)
        try segmentsData.write(to: descriptor.transcriptDirectory.appendingPathComponent("segments.json"), options: .atomic)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func clockString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct TranscriptDocument: Codable {
    let schemaVersion: String
    let sessionID: String
    let segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case segments
    }
}
