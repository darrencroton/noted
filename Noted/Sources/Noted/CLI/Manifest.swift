import Foundation

struct SessionManifest: Codable, Sendable {
    let schemaVersion: String
    let sessionID: String
    let createdAt: String
    let meeting: Meeting
    let mode: Mode
    let participants: Participants
    let recordingPolicy: RecordingPolicy
    let nextMeeting: NextMeeting
    let paths: Paths
    let transcription: Transcription
    let hooks: Hooks?

    var resolvedAudioStrategy: String {
        if let audioStrategy = mode.audioStrategy {
            return audioStrategy
        }
        return mode.type == "online" ? "mic_plus_system" : "room_mic"
    }

    struct Meeting: Codable, Sendable {
        let eventID: String?
        let title: String
        let startTime: String
        let scheduledEndTime: String?
        let timezone: String

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case title
            case startTime = "start_time"
            case scheduledEndTime = "scheduled_end_time"
            case timezone
        }
    }

    struct Mode: Codable, Sendable {
        let type: String
        let audioStrategy: String?

        enum CodingKeys: String, CodingKey {
            case type
            case audioStrategy = "audio_strategy"
        }
    }

    struct Participants: Codable, Sendable {
        let hostName: String
        let attendeesExpected: Int?
        let participantNames: [String]?
        let namesAreHintsOnly: Bool

        enum CodingKeys: String, CodingKey {
            case hostName = "host_name"
            case attendeesExpected = "attendees_expected"
            case participantNames = "participant_names"
            case namesAreHintsOnly = "names_are_hints_only"
        }
    }

    struct RecordingPolicy: Codable, Sendable {
        let autoStart: Bool
        let autoStop: Bool
        let defaultExtensionMinutes: Int
        let preEndPromptMinutes: Int
        let noInteractionGraceMinutes: Int

        enum CodingKeys: String, CodingKey {
            case autoStart = "auto_start"
            case autoStop = "auto_stop"
            case defaultExtensionMinutes = "default_extension_minutes"
            case preEndPromptMinutes = "pre_end_prompt_minutes"
            case noInteractionGraceMinutes = "no_interaction_grace_minutes"
        }
    }

    struct NextMeeting: Codable, Sendable {
        let exists: Bool
        let manifestPath: String?

        enum CodingKeys: String, CodingKey {
            case exists
            case manifestPath = "manifest_path"
        }
    }

    struct Paths: Codable, Sendable {
        let sessionDir: String
        let outputDir: String
        let notePath: String

        enum CodingKeys: String, CodingKey {
            case sessionDir = "session_dir"
            case outputDir = "output_dir"
            case notePath = "note_path"
        }
    }

    struct Transcription: Codable, Sendable {
        let asrBackend: String
        let diarizationEnabled: Bool
        let speakerCountHint: Int?
        let language: String?

        enum CodingKeys: String, CodingKey {
            case asrBackend = "asr_backend"
            case diarizationEnabled = "diarization_enabled"
            case speakerCountHint = "speaker_count_hint"
            case language
        }
    }

    struct Hooks: Codable, Sendable {
        let completionCallback: String?

        enum CodingKeys: String, CodingKey {
            case completionCallback = "completion_callback"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case createdAt = "created_at"
        case meeting
        case mode
        case participants
        case recordingPolicy = "recording_policy"
        case nextMeeting = "next_meeting"
        case paths
        case transcription
        case hooks
    }
}

struct ManifestValidationResult: Sendable {
    let schemaVersion: String?
    let manifest: SessionManifest?
    let errors: [String]

    var isValid: Bool { errors.isEmpty && manifest != nil }
}

enum ManifestValidator {
    static func validate(fileURL: URL) -> ManifestValidationResult {
        do {
            let data = try Data(contentsOf: fileURL)
            return validate(data: data)
        } catch {
            return ManifestValidationResult(schemaVersion: nil, manifest: nil, errors: ["cannot_read_manifest: \(error.localizedDescription)"])
        }
    }

    static func validate(data: Data) -> ManifestValidationResult {
        var schemaVersion: String?
        var errors: [String] = []
        let object: [String: Any]

        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ManifestValidationResult(schemaVersion: nil, manifest: nil, errors: ["manifest_must_be_json_object"])
            }
            object = parsed
        } catch {
            return ManifestValidationResult(schemaVersion: nil, manifest: nil, errors: ["invalid_json: \(error.localizedDescription)"])
        }

        schemaVersion = object["schema_version"] as? String
        requireString("schema_version", in: object, errors: &errors)
        if let schemaVersion, !isMajorOneSchemaVersion(schemaVersion) {
            errors.append("unsupported_schema_version: \(schemaVersion)")
        }

        requireString("session_id", in: object, errors: &errors)
        requireOffsetTimestamp("created_at", in: object, allowNull: false, errors: &errors)

        guard let meeting = requireObject("meeting", in: object, errors: &errors) else {
            return finish(data: data, schemaVersion: schemaVersion, errors: errors)
        }
        requireKey("event_id", in: meeting, errors: &errors)
        requireString("title", in: meeting, errors: &errors)
        requireOffsetTimestamp("start_time", in: meeting, allowNull: false, errors: &errors)
        requireOffsetTimestamp("scheduled_end_time", in: meeting, allowNull: true, errors: &errors)
        requireString("timezone", in: meeting, errors: &errors)

        if let mode = requireObject("mode", in: object, errors: &errors) {
            requireEnum("type", in: mode, allowed: ["in_person", "online", "hybrid"], errors: &errors)
            if mode["audio_strategy"] != nil {
                requireEnum("audio_strategy", in: mode, allowed: ["room_mic", "mic_plus_system"], errors: &errors)
            }
        }

        if let participants = requireObject("participants", in: object, errors: &errors) {
            requireString("host_name", in: participants, errors: &errors)
            if participants["names_are_hints_only"] as? Bool != true {
                errors.append("participants.names_are_hints_only_must_be_true")
            }
        }

        if let policy = requireObject("recording_policy", in: object, errors: &errors) {
            requireBool("auto_start", in: policy, errors: &errors)
            requireBool("auto_stop", in: policy, errors: &errors)
            requireNonNegativeInt("default_extension_minutes", in: policy, errors: &errors)
            requireNonNegativeInt("pre_end_prompt_minutes", in: policy, errors: &errors)
            requireNonNegativeInt("no_interaction_grace_minutes", in: policy, errors: &errors)
        }

        if let nextMeeting = requireObject("next_meeting", in: object, errors: &errors) {
            requireBool("exists", in: nextMeeting, errors: &errors)
            if nextMeeting["start_time"] != nil {
                requireOffsetTimestamp("start_time", in: nextMeeting, allowNull: false, errors: &errors)
            }
        }

        if let paths = requireObject("paths", in: object, errors: &errors) {
            requireString("session_dir", in: paths, errors: &errors)
            requireString("output_dir", in: paths, errors: &errors)
            requireString("note_path", in: paths, errors: &errors)
        }

        if let transcription = requireObject("transcription", in: object, errors: &errors) {
            requireEnum("asr_backend", in: transcription, allowed: ["whisperkit", "fluidaudio-parakeet", "sfspeech"], errors: &errors)
            requireBool("diarization_enabled", in: transcription, errors: &errors)
        }

        if let hooks = object["hooks"] as? [String: Any],
           let callback = hooks["completion_callback"],
           !(callback is NSNull) {
            errors.append("hooks.completion_callback_must_be_null")
        }

        return finish(data: data, schemaVersion: schemaVersion, errors: errors)
    }

    private static func finish(data: Data, schemaVersion: String?, errors: [String]) -> ManifestValidationResult {
        guard errors.isEmpty else {
            return ManifestValidationResult(schemaVersion: schemaVersion, manifest: nil, errors: errors)
        }

        do {
            let decoder = JSONDecoder()
            let manifest = try decoder.decode(SessionManifest.self, from: data)
            return ManifestValidationResult(schemaVersion: schemaVersion, manifest: manifest, errors: [])
        } catch {
            return ManifestValidationResult(schemaVersion: schemaVersion, manifest: nil, errors: ["decode_failed: \(error.localizedDescription)"])
        }
    }

    private static func requireKey(_ key: String, in object: [String: Any], errors: inout [String]) {
        if object[key] == nil {
            errors.append("missing_required_field: \(key)")
        }
    }

    private static func requireObject(_ key: String, in object: [String: Any], errors: inout [String]) -> [String: Any]? {
        guard let value = object[key] else {
            errors.append("missing_required_field: \(key)")
            return nil
        }
        guard let result = value as? [String: Any] else {
            errors.append("invalid_object: \(key)")
            return nil
        }
        return result
    }

    private static func requireString(_ key: String, in object: [String: Any], errors: inout [String]) {
        guard let value = object[key] else {
            errors.append("missing_required_field: \(key)")
            return
        }
        guard let string = value as? String, !string.isEmpty else {
            errors.append("invalid_string: \(key)")
            return
        }
    }

    private static func requireBool(_ key: String, in object: [String: Any], errors: inout [String]) {
        guard let value = object[key] else {
            errors.append("missing_required_field: \(key)")
            return
        }
        if !(value is Bool) {
            errors.append("invalid_bool: \(key)")
        }
    }

    private static func requireNonNegativeInt(_ key: String, in object: [String: Any], errors: inout [String]) {
        guard let value = object[key] else {
            errors.append("missing_required_field: \(key)")
            return
        }
        guard let intValue = value as? Int, intValue >= 0 else {
            errors.append("invalid_non_negative_int: \(key)")
            return
        }
    }

    private static func requireEnum(_ key: String, in object: [String: Any], allowed: Set<String>, errors: inout [String]) {
        guard let value = object[key] else {
            errors.append("missing_required_field: \(key)")
            return
        }
        guard let string = value as? String, allowed.contains(string) else {
            errors.append("invalid_enum: \(key)")
            return
        }
    }

    private static func requireOffsetTimestamp(_ key: String, in object: [String: Any], allowNull: Bool, errors: inout [String]) {
        guard let value = object[key] else {
            errors.append("missing_required_field: \(key)")
            return
        }
        if allowNull, value is NSNull {
            return
        }
        guard let string = value as? String, isISO8601TimestampWithExplicitOffset(string) else {
            errors.append("invalid_offset_timestamp: \(key)")
            return
        }
    }

    private static func isISO8601TimestampWithExplicitOffset(_ value: String) -> Bool {
        guard value.range(of: #"(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else {
            return false
        }

        let wholeSecondFormatter = ISO8601DateFormatter()
        wholeSecondFormatter.formatOptions = [.withInternetDateTime]
        if wholeSecondFormatter.date(from: value) != nil {
            return true
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) != nil
    }

    private static func isMajorOneSchemaVersion(_ value: String) -> Bool {
        value.range(of: #"^1\.[0-9]+$"#, options: .regularExpression) != nil
    }
}
