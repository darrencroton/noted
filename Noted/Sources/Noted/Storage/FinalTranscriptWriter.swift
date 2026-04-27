import Foundation

enum FinalTranscriptWriterError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Transcript has no usable segments."
        }
    }
}

struct FinalTranscriptWriter {
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func writeMetadata(for descriptor: SessionDescriptor) throws {
        let metadata: [String: String] = [
            "id": descriptor.id,
            "type": descriptor.type.rawValue,
            "started_at": Self.iso8601String(from: descriptor.startedAt),
        ]
        let data = try encoder.encode(metadata)
        try data.write(to: descriptor.runtimeDirectory.appendingPathComponent("session.json"), options: .atomic)
    }

    func writeTranscript(_ segments: [FinalTranscriptSegment], descriptor: SessionDescriptor) throws {
        guard !segments.isEmpty else { throw FinalTranscriptWriterError.emptyTranscript }

        try FileManager.default.createDirectory(at: descriptor.transcriptDirectory, withIntermediateDirectories: true)
        let orderedSegments = segments.sorted {
            if $0.startTime == $1.startTime { return $0.source.rawValue < $1.source.rawValue }
            return $0.startTime < $1.startTime
        }

        let transcript = FinalTranscriptDocument(
            schemaVersion: "1.0",
            sessionID: descriptor.id,
            segments: orderedSegments
        )
        let transcriptData = try encoder.encode(transcript)
        try transcriptData.write(to: descriptor.transcriptDirectory.appendingPathComponent("transcript.json"), options: .atomic)

        let segmentsData = try encoder.encode(orderedSegments)
        try segmentsData.write(to: descriptor.transcriptDirectory.appendingPathComponent("segments.json"), options: .atomic)

        let text = Self.renderText(descriptor: descriptor, segments: orderedSegments)
        try text.write(
            to: descriptor.transcriptDirectory.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeDiarization(_ segments: [DiarizationSegment], to directory: URL) throws {
        let diarizationDirectory = directory.appendingPathComponent("diarization", isDirectory: true)
        try FileManager.default.createDirectory(at: diarizationDirectory, withIntermediateDirectories: true)
        let url = diarizationDirectory.appendingPathComponent("diarization.json")
        let data = try encoder.encode(segments)
        try data.write(to: url, options: .atomic)
    }

    private static func renderText(descriptor: SessionDescriptor, segments: [FinalTranscriptSegment]) -> String {
        var lines = [
            "noted session \(descriptor.id)",
            "started_at: \(iso8601String(from: descriptor.startedAt))",
            "type: \(descriptor.type.rawValue)",
            "",
        ]

        for segment in segments {
            let start = timestamp(segment.startTime)
            let end = timestamp(segment.endTime)
            lines.append("[\(start)-\(end)] \(segment.speakerId): \(segment.text)")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Float) -> String {
        let totalMilliseconds = max(0, Int((seconds * 1000).rounded()))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        }
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct FinalTranscriptDocument: Codable {
    let schemaVersion: String
    let sessionID: String
    let segments: [FinalTranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case segments
    }
}
