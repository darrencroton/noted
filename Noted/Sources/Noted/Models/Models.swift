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

struct DiarizationSegment: Codable, Sendable {
    let speakerId: String
    let startTime: Float
    let endTime: Float
}

enum TranscriptAudioSource: String, Codable, Sendable {
    case microphone
    case system
}

struct FinalTranscriptSegment: Codable, Sendable {
    let speakerId: String
    let source: TranscriptAudioSource
    let startTime: Float
    let endTime: Float
    let text: String
    let confidence: Float?

    enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case source
        case startTime = "start_time"
        case endTime = "end_time"
        case text
        case confidence
    }
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
