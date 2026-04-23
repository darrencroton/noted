import Foundation

enum SessionType: String, CaseIterable, Codable, Sendable {
    case meeting
    case voiceMemo

    var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .voiceMemo: return "Voice Memo"
        }
    }
}

enum Speaker: String, Codable, Sendable {
    case microphone
    case system

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .system: return "System"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Sendable {
    let id: UUID
    let speaker: Speaker
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), speaker: Speaker, text: String, timestamp: Date = .now) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

struct DiarizationSegment: Codable, Sendable {
    let speakerId: String
    let startTime: Float
    let endTime: Float
}

enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case parakeet = "parakeet"
    case whisperBase = "whisperBase"
    case whisperLargeV3 = "whisperLargeV3"
    case appleSpeech = "appleSpeech"

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet-TDT v3"
        case .whisperBase: return "Whisper Base"
        case .whisperLargeV3: return "Whisper Large v3"
        case .appleSpeech: return "Apple Speech"
        }
    }

    var whisperModelID: String? {
        switch self {
        case .parakeet, .appleSpeech:
            return nil
        case .whisperBase:
            return "openai_whisper-base"
        case .whisperLargeV3:
            return "openai_whisper-large-v3"
        }
    }

    var isWhisperKit: Bool { whisperModelID != nil }
    var isAppleSpeech: Bool { self == .appleSpeech }
}
