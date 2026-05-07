import Foundation

struct AdHocManifestWriter {
    let settings: RuntimeSettings
    var now: Date = Date()

    func writeManifest() throws -> (manifest: SessionManifest, manifestURL: URL) {
        let sessionID = makeSessionID(date: now)
        let sessionDir = settings.outputRootURL.appendingPathComponent(sessionID, isDirectory: true)
        let notePath = settings.outputRootURL.appendingPathComponent("\(sessionID).md", isDirectory: false)

        let manifest = SessionManifest(
            schemaVersion: ContractSnapshot.manifestSchemaVersion,
            sessionID: sessionID,
            createdAt: ISO8601.withOffset(now),
            meeting: SessionManifest.Meeting(
                eventID: nil,
                title: "Ad hoc session",
                startTime: ISO8601.withOffset(now),
                scheduledEndTime: nil,
                timezone: TimeZone.current.identifier
            ),
            mode: SessionManifest.Mode(type: "in_person"),
            participants: SessionManifest.Participants(
                hostName: settings.hostName,
                attendeesExpected: nil,
                participantNames: nil,
                namesAreHintsOnly: true
            ),
            recordingPolicy: SessionManifest.RecordingPolicy(
                autoStart: true,
                autoStop: false,
                defaultExtensionMinutes: settings.defaultExtensionMinutes,
                preEndPromptMinutes: settings.preEndPromptMinutes,
                noInteractionGraceMinutes: settings.noInteractionGraceMinutes
            ),
            nextMeeting: SessionManifest.NextMeeting(exists: false, manifestPath: nil),
            paths: SessionManifest.Paths(
                sessionDir: sessionDir.path,
                outputDir: sessionDir.appendingPathComponent("outputs", isDirectory: true).path,
                notePath: notePath.path
            ),
            transcription: SessionManifest.Transcription(
                asrBackend: settings.asrBackend,
                diarizationEnabled: settings.diarizationEnabled,
                speakerCountHint: nil,
                language: settings.language
            ),
            hooks: SessionManifest.Hooks(completionCallback: nil)
        )

        // Validate in a temporary location before creating any persistent session directories.
        // This prevents orphaned directories when the manifest fails schema validation.
        let data = try RuntimeFiles.encoder.encode(manifest)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempManifestURL = tempDir.appendingPathComponent("ad-hoc-manifest-validate.json")
        try data.write(to: tempManifestURL, options: .atomic)
        let validation = ManifestValidator.validate(fileURL: tempManifestURL)
        guard validation.isValid else {
            throw AdHocManifestError("ad_hoc_manifest_invalid: \(validation.errors.joined(separator: ", "))")
        }

        // Validation passed — create the real session directory and write the manifest.
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifestURL = sessionDir.appendingPathComponent("ad-hoc-manifest.json")
        try data.write(to: manifestURL, options: .atomic)

        return (manifest, manifestURL)
    }

    private func makeSessionID(date: Date) -> String {
        let raw = ISO8601.withOffset(date)
        let compact = raw
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "Z", with: "0000")
        return "\(compact)-ad-hoc"
    }
}

private struct AdHocManifestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
