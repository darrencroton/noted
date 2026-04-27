import CoreAudio
import Foundation

struct RuntimeSettings: Sendable {
    var hostName: String
    var language: String
    var asrBackend: String
    var asrModelVariant: String
    var defaultInputDevice: AudioDeviceID
    var outputRoot: String
    var adHocNoteDirectory: String
    var sysVadThreshold: Double
    var hideFromScreenShare: Bool
    var briefingCommand: String
    var ingestAfterCompletion: Bool
    var diarizationEnabled: Bool
    var defaultExtensionMinutes: Int
    var preEndPromptMinutes: Int
    var noInteractionGraceMinutes: Int

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/noted/settings.toml")
    }

    static var defaultOutputRoot: String {
        repositoryRootURL().appendingPathComponent("sessions", isDirectory: true).path
    }

    static func load() -> RuntimeSettings {
        let defaults = RuntimeSettings(
            hostName: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName(),
            language: "en-US",
            asrBackend: "fluidaudio-parakeet",
            asrModelVariant: "parakeet-v3",
            defaultInputDevice: 0,
            outputRoot: defaultOutputRoot,
            adHocNoteDirectory: defaultOutputRoot + "/ad-hoc-notes",
            sysVadThreshold: 0.92,
            hideFromScreenShare: true,
            briefingCommand: "briefing",
            ingestAfterCompletion: true,
            diarizationEnabled: true,
            defaultExtensionMinutes: 5,
            preEndPromptMinutes: 5,
            noInteractionGraceMinutes: 5
        )

        guard let contents = try? String(contentsOf: settingsURL, encoding: .utf8) else {
            try? defaults.save()
            return defaults
        }

        let values = parseTOML(contents)
        return RuntimeSettings(
            hostName: values["host_name"] ?? defaults.hostName,
            language: values["language"] ?? defaults.language,
            asrBackend: values["asr_backend"] ?? defaults.asrBackend,
            asrModelVariant: values["asr_model_variant"] ?? defaults.asrModelVariant,
            defaultInputDevice: AudioDeviceID(Int(values["default_input_device"] ?? "") ?? Int(defaults.defaultInputDevice)),
            outputRoot: values["output_root"] ?? defaults.outputRoot,
            adHocNoteDirectory: values["ad_hoc_note_directory"] ?? defaults.adHocNoteDirectory,
            sysVadThreshold: Double(values["sys_vad_threshold"] ?? "") ?? defaults.sysVadThreshold,
            hideFromScreenShare: Bool(values["hide_from_screen_share"] ?? "") ?? defaults.hideFromScreenShare,
            briefingCommand: values["briefing_command"] ?? defaults.briefingCommand,
            ingestAfterCompletion: Bool(values["ingest_after_completion"] ?? "") ?? defaults.ingestAfterCompletion,
            diarizationEnabled: Bool(values["diarization_enabled"] ?? "") ?? defaults.diarizationEnabled,
            defaultExtensionMinutes: Int(values["default_extension_minutes"] ?? "") ?? defaults.defaultExtensionMinutes,
            preEndPromptMinutes: Int(values["pre_end_prompt_minutes"] ?? "") ?? defaults.preEndPromptMinutes,
            noInteractionGraceMinutes: Int(values["no_interaction_grace_minutes"] ?? "") ?? defaults.noInteractionGraceMinutes
        )
    }

    func save() throws {
        let directory = Self.settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
        host_name = "\(Self.escape(hostName))"
        language = "\(Self.escape(language))"
        asr_backend = "\(Self.escape(asrBackend))"
        asr_model_variant = "\(Self.escape(asrModelVariant))"
        default_input_device = \(Int(defaultInputDevice))
        output_root = "\(Self.escape(outputRoot))"
        ad_hoc_note_directory = "\(Self.escape(adHocNoteDirectory))"
        sys_vad_threshold = \(sysVadThreshold)
        hide_from_screen_share = \(hideFromScreenShare)
        briefing_command = "\(Self.escape(briefingCommand))"
        ingest_after_completion = \(ingestAfterCompletion)
        diarization_enabled = \(diarizationEnabled)
        default_extension_minutes = \(defaultExtensionMinutes)
        pre_end_prompt_minutes = \(preEndPromptMinutes)
        no_interaction_grace_minutes = \(noInteractionGraceMinutes)
        """
        try contents.write(to: Self.settingsURL, atomically: true, encoding: .utf8)
    }

    var outputRootURL: URL {
        URL(fileURLWithPath: NSString(string: outputRoot).expandingTildeInPath, isDirectory: true)
    }

    var adHocNoteDirectoryURL: URL {
        URL(fileURLWithPath: NSString(string: adHocNoteDirectory).expandingTildeInPath, isDirectory: true)
    }

    var transcriptionModel: TranscriptionModel {
        switch asrBackend {
        case "sfspeech":
            return .appleSpeech
        case "whisperkit":
            return asrModelVariant.contains("large") ? .whisperLargeV3 : .whisperBase
        default:
            return .parakeet
        }
    }

    private static func parseTOML(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
                value = value.replacingOccurrences(of: #"\""#, with: #"""#)
                    .replacingOccurrences(of: #"\\ "#, with: #"\ "#)
            }
            values[key] = value
        }
        return values
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }

    private static func repositoryRootURL() -> URL {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
        ]

        for candidate in candidates {
            if let root = findRepositoryRoot(startingAt: candidate) {
                return root
            }
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/noted", isDirectory: true)
    }

    private static func findRepositoryRoot(startingAt url: URL) -> URL? {
        let fileManager = FileManager.default
        var directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        while true {
            let repoPackage = directory.appendingPathComponent("Noted/Package.swift").path
            if fileManager.fileExists(atPath: repoPackage) {
                return directory
            }

            let package = directory.appendingPathComponent("Package.swift").path
            if directory.lastPathComponent == "Noted",
               fileManager.fileExists(atPath: package) {
                return directory.deletingLastPathComponent()
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}
