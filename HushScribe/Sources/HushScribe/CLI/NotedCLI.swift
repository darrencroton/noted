import AppKit
import Foundation

struct NotedCLI {
    func run(arguments: [String]) async -> Int {
        guard let command = arguments.first else {
            writeError("missing command")
            return 6
        }

        let options = parseOptions(Array(arguments.dropFirst()))

        switch command {
        case "validate-manifest":
            return validateManifest(options: options)
        case "version":
            return version()
        case "start":
            return await start(options: options)
        case "stop":
            return stop(options: options)
        case "status":
            return status(options: options)
        case "extend", "switch-next":
            writeError("\(command) is reserved for Phase 3 and is not implemented in this runtime.")
            writeJSON(["ok": false, "error": "not_implemented"])
            return 6
        case "__run-session":
            return await runSession(options: options)
        default:
            writeError("unknown command: \(command)")
            writeJSON(["ok": false, "error": "unknown_command"])
            return 6
        }
    }

    private func validateManifest(options: [String: String]) -> Int {
        guard let manifestPath = options["manifest"] else {
            writeError("missing --manifest <path>")
            writeJSON(["ok": false, "errors": ["missing_manifest_path"]])
            return 2
        }

        let result = ManifestValidator.validate(fileURL: URL(fileURLWithPath: manifestPath))
        if result.isValid {
            writeJSON(["ok": true, "schema_version": result.schemaVersion ?? ""])
            return 0
        }

        writeJSON([
            "ok": false,
            "schema_version": result.schemaVersion as Any,
            "errors": result.errors,
        ])
        return 2
    }

    private func version() -> Int {
        writeJSON([
            "ok": true,
            "version": ContractSnapshot.appVersion,
            "manifest_schema_version": ContractSnapshot.manifestSchemaVersion,
            "completion_schema_version": ContractSnapshot.completionSchemaVersion,
        ])
        return 0
    }

    private func start(options: [String: String]) async -> Int {
        guard let manifestPath = options["manifest"] else {
            writeError("missing --manifest <path>")
            writeJSON(["ok": false, "errors": ["missing_manifest_path"]])
            return 2
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let validation = ManifestValidator.validate(fileURL: manifestURL)
        guard validation.isValid, let manifest = validation.manifest else {
            writeJSON([
                "ok": false,
                "schema_version": validation.schemaVersion as Any,
                "errors": validation.errors,
            ])
            return 2
        }

        let sessionDir = URL(fileURLWithPath: manifest.paths.sessionDir, isDirectory: true)
        do {
            guard try RuntimeFiles.tryAcquireActiveCapture(sessionID: manifest.sessionID, sessionDir: sessionDir) else {
                writeJSON(["ok": false, "session_id": manifest.sessionID, "error": "session_already_running"])
                return 5
            }

            try prepareSessionDirectory(manifest: manifest, sourceManifestURL: manifestURL, sessionDir: sessionDir)
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "starting",
                phase: "acquiring_audio_resources",
                startedAt: nil,
                scheduledEndTime: manifest.meeting.scheduledEndTime
            )
            try RuntimeFiles.writeRegistry(SessionRegistryRecord(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir.path,
                pid: nil,
                manifestPath: sessionDir.appendingPathComponent("manifest.json").path
            ))

            let child = try spawnSessionRunner(manifestPath: sessionDir.appendingPathComponent("manifest.json").path, sessionDir: sessionDir)
            try RuntimeFiles.updateActiveCapturePID(child.processIdentifier, sessionID: manifest.sessionID, sessionDir: sessionDir)
            try RuntimeFiles.writeRegistry(SessionRegistryRecord(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir.path,
                pid: child.processIdentifier,
                manifestPath: sessionDir.appendingPathComponent("manifest.json").path
            ))

            let startupResult = await waitForStartup(sessionID: manifest.sessionID, sessionDir: sessionDir)
            switch startupResult {
            case .recording:
                writeJSON([
                    "ok": true,
                    "session_id": manifest.sessionID,
                    "status": "recording",
                    "pid": Int(child.processIdentifier),
                    "session_dir": sessionDir.path,
                ])
                return 0
            case .permission:
                return startupFailure(sessionID: manifest.sessionID, sessionDir: sessionDir, code: 3)
            case .audio:
                return startupFailure(sessionID: manifest.sessionID, sessionDir: sessionDir, code: 4)
            case .internal:
                if child.isRunning {
                    child.terminate()
                }
                if RuntimeFiles.readStatus(sessionDir: sessionDir)?.phase != "failed_startup" {
                    try? await writeStartupFailure(
                        manifest: manifest,
                        sessionDir: sessionDir,
                        message: "startup_timeout"
                    )
                }
                return startupFailure(sessionID: manifest.sessionID, sessionDir: sessionDir, code: 6)
            }
        } catch {
            RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
            writeError(error.localizedDescription)
            writeJSON(["ok": false, "session_id": manifest.sessionID, "error": "startup_failed"])
            return 6
        }
    }

    private func stop(options: [String: String]) -> Int {
        guard let sessionID = options["session-id"] else {
            writeError("missing --session-id <id>")
            writeJSON(["ok": false, "error": "missing_session_id"])
            return 2
        }

        guard let record = RuntimeFiles.readRegistry(sessionID: sessionID) else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "unknown_session_id"])
            return 2
        }

        let sessionDir = URL(fileURLWithPath: record.sessionDir, isDirectory: true)
        guard let currentStatus = RuntimeFiles.readStatus(sessionDir: sessionDir) else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "unknown_session_id"])
            return 2
        }
        guard currentStatus.status == "recording" || currentStatus.status == "stopping" else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "session_not_running"])
            return 3
        }

        do {
            try RuntimeFiles.writeStopRequest(sessionDir: sessionDir)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: RuntimeFiles.captureFinalizedURL(sessionDir: sessionDir).path) {
                    if FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("outputs/completion.json").path) {
                        writeJSON(["ok": false, "session_id": sessionID, "error": "completion_written_before_stop_return"])
                        return 4
                    }
                    try RuntimeFiles.acknowledgeCaptureFinalized(sessionID: sessionID, sessionDir: sessionDir)
                    writeJSON([
                        "ok": true,
                        "session_id": sessionID,
                        "status": "processing",
                        "audio_finalised": true,
                    ])
                    return 0
                }
                if let status = RuntimeFiles.readStatus(sessionDir: sessionDir),
                   status.status == "completed" || status.status == "completed_with_warnings" || status.status == "failed" {
                    writeJSON(["ok": false, "session_id": sessionID, "error": "terminal_before_capture_finalized_ack"])
                    return 4
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            writeJSON(["ok": false, "session_id": sessionID, "error": "stop_capture_timeout"])
            return 4
        } catch {
            writeError(error.localizedDescription)
            writeJSON(["ok": false, "session_id": sessionID, "error": "stop_capture_failed"])
            return 4
        }
    }

    private func status(options: [String: String]) -> Int {
        guard let sessionID = options["session-id"] else {
            writeError("missing --session-id <id>")
            writeJSON(["ok": false, "error": "missing_session_id"])
            return 2
        }
        guard let record = RuntimeFiles.readRegistry(sessionID: sessionID),
              let status = RuntimeFiles.readStatus(sessionDir: URL(fileURLWithPath: record.sessionDir, isDirectory: true))
        else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "unknown_session_id"])
            return 2
        }

        writeJSON([
            "ok": true,
            "session_id": status.sessionID,
            "status": status.status,
            "phase": status.phase,
            "started_at": status.startedAt as Any,
            "scheduled_end_time": status.scheduledEndTime as Any,
            "current_extension_minutes": status.currentExtensionMinutes,
            "pre_end_prompt_shown": status.preEndPromptShown,
            "next_meeting_available": nextMeetingAvailable(sessionDir: URL(fileURLWithPath: record.sessionDir, isDirectory: true)),
            "output_dir": record.sessionDir,
        ])
        return 0
    }

    @MainActor
    private func runSession(options: [String: String]) async -> Int {
        guard let manifestPath = options["manifest"] else { return 6 }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let validation = ManifestValidator.validate(fileURL: manifestURL)
        guard validation.isValid, let manifest = validation.manifest else { return 2 }

        let sessionDir = URL(fileURLWithPath: manifest.paths.sessionDir, isDirectory: true)
        let startedAt = Date()
        let descriptor = SessionDescriptor(
            id: manifest.sessionID,
            directory: sessionDir,
            type: .meeting,
            startedAt: startedAt,
            audioStrategy: manifest.resolvedAudioStrategy
        )
        let settings = RuntimeSettings.load()
        let transcriptionEngine = TranscriptionEngine()
        transcriptionEngine.setModel(transcriptionModel(for: manifest, settings: settings))
        let transcriptLogger = TranscriptLogger()
        transcriptionEngine.setUtteranceHandler { segment in
            Task {
                await transcriptLogger.append(segment)
            }
        }

        var startedAtString: String?
        do {
            try await transcriptLogger.startSession(descriptor)
            // Write status before model loading so the parent process knows the child is
            // alive during CoreML compilation (~30 s on first run after a code-signature change).
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "starting",
                phase: "loading_models",
                startedAt: nil,
                scheduledEndTime: manifest.meeting.scheduledEndTime
            )
            appendLog(sessionDir: sessionDir, "loading ASR models")
            await transcriptionEngine.start(
                locale: Locale(identifier: manifest.transcription.language ?? settings.language),
                inputDeviceID: settings.defaultInputDevice,
                rawMicrophoneAudioURL: descriptor.microphoneAudioURL,
                rawSystemAudioURL: descriptor.systemAudioURL,
                captureSystemAudio: manifest.resolvedAudioStrategy == "mic_plus_system",
                sysVadThreshold: settings.sysVadThreshold
            )

            if !transcriptionEngine.isRunning {
                let message = transcriptionEngine.lastError ?? "Capture did not start."
                try await writeStartupFailure(manifest: manifest, sessionDir: sessionDir, message: message)
                return 4
            }

            playRecordingBell()
            startedAtString = ISO8601.withOffset(startedAt)
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "recording",
                phase: "capturing",
                startedAt: startedAtString,
                scheduledEndTime: manifest.meeting.scheduledEndTime
            )
            appendLog(sessionDir: sessionDir, "capture started")

            while !FileManager.default.fileExists(atPath: RuntimeFiles.stopRequestURL(sessionDir: sessionDir).path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let stopReason = RuntimeFiles.readStopReason(sessionDir: sessionDir)
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "stopping",
                phase: "flushing_audio",
                startedAt: startedAtString,
                scheduledEndTime: manifest.meeting.scheduledEndTime
            )
            _ = await transcriptionEngine.stop()
            fsyncIfPossible(descriptor.microphoneAudioURL)
            fsyncIfPossible(descriptor.systemAudioURL)
            _ = try await transcriptLogger.endSession()
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "processing",
                phase: "running_asr",
                startedAt: startedAtString,
                scheduledEndTime: manifest.meeting.scheduledEndTime
            )
            try RuntimeFiles.writeCaptureFinalized(sessionID: manifest.sessionID, sessionDir: sessionDir)
            RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
            await waitForCaptureFinalizedAcknowledgement(sessionDir: sessionDir)

            try await postProcess(
                manifest: manifest,
                descriptor: descriptor,
                transcriptionEngine: transcriptionEngine,
                startedAt: startedAtString,
                stopReason: stopReason
            )
            return 0
        } catch {
            appendLog(sessionDir: sessionDir, "session runner failed: \(error.localizedDescription)")
            try? await writeProcessingFailure(
                manifest: manifest,
                sessionDir: sessionDir,
                startedAt: startedAtString,
                error: error.localizedDescription
            )
            RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
            return 6
        }
    }

    @MainActor
    private func postProcess(
        manifest: SessionManifest,
        descriptor: SessionDescriptor,
        transcriptionEngine: TranscriptionEngine,
        startedAt: String?,
        stopReason: String
    ) async throws {
        var warnings: [String] = []
        var errors: [String] = []
        let audioOK = FileManager.default.fileExists(atPath: descriptor.microphoneAudioURL.path)
            || FileManager.default.fileExists(atPath: descriptor.systemAudioURL.path)
        let transcriptOK = FileManager.default.fileExists(atPath: descriptor.transcriptDirectory.appendingPathComponent("transcript.txt").path)
            && FileManager.default.fileExists(atPath: descriptor.transcriptDirectory.appendingPathComponent("transcript.json").path)

        var diarizationOK = false
        if manifest.transcription.diarizationEnabled {
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: descriptor.directory,
                status: "processing",
                phase: "running_diarization",
                startedAt: startedAt,
                scheduledEndTime: manifest.meeting.scheduledEndTime
            )
            let diarizationAudio = FileManager.default.fileExists(atPath: descriptor.systemAudioURL.path)
                ? descriptor.systemAudioURL
                : descriptor.microphoneAudioURL
            if let diarization = await transcriptionEngine.runPostSessionDiarization(audioURL: diarizationAudio) {
                let segments = diarization.map {
                    DiarizationSegment(speakerId: $0.speakerId, startTime: $0.startTime, endTime: $0.endTime)
                }
                try await TranscriptLogger().writeDiarization(segments, to: descriptor.directory)
                diarizationOK = true
            } else {
                warnings.append("diarization_failed")
            }
        }

        if !audioOK { errors.append("audio_capture_missing") }
        if !transcriptOK { errors.append("transcript_missing") }

        try RuntimeFiles.writeStatus(
            sessionID: manifest.sessionID,
            sessionDir: descriptor.directory,
            status: "processing",
            phase: "writing_outputs",
            startedAt: startedAt,
            scheduledEndTime: manifest.meeting.scheduledEndTime
        )

        let terminalStatus: String
        if !audioOK {
            terminalStatus = "failed"
        } else if !errors.isEmpty || !warnings.isEmpty {
            terminalStatus = "completed_with_warnings"
        } else {
            terminalStatus = "completed"
        }
        let completion = CompletionFile(
            schemaVersion: "1.0",
            sessionID: manifest.sessionID,
            manifestSchemaVersion: manifest.schemaVersion,
            terminalStatus: terminalStatus,
            stopReason: stopReason,
            audioCaptureOK: audioOK,
            transcriptOK: transcriptOK,
            diarizationOK: diarizationOK,
            warnings: warnings,
            errors: errors,
            completedAt: ISO8601.withOffset(Date())
        )
        let data = try RuntimeFiles.encoder.encode(completion)
        try data.write(to: descriptor.directory.appendingPathComponent("outputs/completion.json"), options: .atomic)
        try RuntimeFiles.writeStatus(
            sessionID: manifest.sessionID,
            sessionDir: descriptor.directory,
            status: terminalStatus,
            phase: "finished",
            startedAt: startedAt,
            scheduledEndTime: manifest.meeting.scheduledEndTime,
            lastError: errors.first
        )
        appendLog(sessionDir: descriptor.directory, "completion written: \(terminalStatus)")
    }

    private func writeStartupFailure(manifest: SessionManifest, sessionDir: URL, message: String) async throws {
        try RuntimeFiles.writeStatus(
            sessionID: manifest.sessionID,
            sessionDir: sessionDir,
            status: "failed",
            phase: "failed_startup",
            startedAt: nil,
            scheduledEndTime: manifest.meeting.scheduledEndTime,
            lastError: message
        )
        let completion = CompletionFile(
            schemaVersion: "1.0",
            sessionID: manifest.sessionID,
            manifestSchemaVersion: manifest.schemaVersion,
            terminalStatus: "failed",
            stopReason: "startup_failure",
            audioCaptureOK: false,
            transcriptOK: false,
            diarizationOK: false,
            warnings: [],
            errors: [message],
            completedAt: ISO8601.withOffset(Date())
        )
        let data = try RuntimeFiles.encoder.encode(completion)
        try data.write(to: sessionDir.appendingPathComponent("outputs/completion.json"), options: .atomic)
        RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
    }

    private func writeProcessingFailure(
        manifest: SessionManifest,
        sessionDir: URL,
        startedAt: String?,
        error: String
    ) async throws {
        let artefacts = processingArtefacts(sessionDir: sessionDir, audioStrategy: manifest.resolvedAudioStrategy)
        let terminalStatus = artefacts.audioOK ? "completed_with_warnings" : "failed"
        try RuntimeFiles.writeStatus(
            sessionID: manifest.sessionID,
            sessionDir: sessionDir,
            status: terminalStatus,
            phase: "failed_processing",
            startedAt: startedAt,
            scheduledEndTime: manifest.meeting.scheduledEndTime,
            lastError: error
        )
        let completion = CompletionFile(
            schemaVersion: "1.0",
            sessionID: manifest.sessionID,
            manifestSchemaVersion: manifest.schemaVersion,
            terminalStatus: terminalStatus,
            stopReason: "processing_failure",
            audioCaptureOK: artefacts.audioOK,
            transcriptOK: artefacts.transcriptOK,
            diarizationOK: artefacts.diarizationOK,
            warnings: [],
            errors: [error],
            completedAt: ISO8601.withOffset(Date())
        )
        let data = try RuntimeFiles.encoder.encode(completion)
        try data.write(to: sessionDir.appendingPathComponent("outputs/completion.json"), options: .atomic)
    }

    private func processingArtefacts(sessionDir: URL, audioStrategy: String) -> (audioOK: Bool, transcriptOK: Bool, diarizationOK: Bool) {
        let audioDirectory = sessionDir.appendingPathComponent("audio", isDirectory: true)
        let audioURLs: [URL] = audioStrategy == "mic_plus_system"
            ? [
                audioDirectory.appendingPathComponent("raw_mic.wav"),
                audioDirectory.appendingPathComponent("raw_system.wav"),
            ]
            : [audioDirectory.appendingPathComponent("raw_room.wav")]
        let transcriptDirectory = sessionDir.appendingPathComponent("transcript", isDirectory: true)
        let diarizationURL = sessionDir.appendingPathComponent("diarization/diarization.json")
        return (
            audioOK: audioURLs.contains { FileManager.default.fileExists(atPath: $0.path) },
            transcriptOK: FileManager.default.fileExists(atPath: transcriptDirectory.appendingPathComponent("transcript.txt").path)
                && FileManager.default.fileExists(atPath: transcriptDirectory.appendingPathComponent("transcript.json").path),
            diarizationOK: FileManager.default.fileExists(atPath: diarizationURL.path)
        )
    }

    private func prepareSessionDirectory(manifest: SessionManifest, sourceManifestURL: URL, sessionDir: URL) throws {
        try rejectExistingSessionArtifacts(at: sessionDir)
        try SessionStore.createCanonicalDirectories(at: sessionDir)
        let targetManifestURL = sessionDir.appendingPathComponent("manifest.json")
        try FileManager.default.copyItem(at: sourceManifestURL, to: targetManifestURL)
        let logURL = sessionDir.appendingPathComponent("logs/noted.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        appendLog(sessionDir: sessionDir, "session prepared for \(manifest.sessionID)")
    }

    private func rejectExistingSessionArtifacts(at sessionDir: URL) throws {
        guard FileManager.default.fileExists(atPath: sessionDir.path) else { return }
        let artifactPaths = [
            "manifest.json",
            "runtime/status.json",
            "runtime/stop-request.json",
            "runtime/capture-finalized.json",
            "runtime/capture-finalized-acknowledged.json",
            "outputs/completion.json",
        ]
        for relativePath in artifactPaths {
            if FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(relativePath).path) {
                throw CLIError("session_dir_already_contains_artifacts: \(sessionDir.path)")
            }
        }

        for directoryName in ["audio", "transcript", "diarization", "logs"] {
            let directory = sessionDir.appendingPathComponent(directoryName, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            if enumerator.nextObject() != nil {
                throw CLIError("session_dir_already_contains_artifacts: \(sessionDir.path)")
            }
        }
    }

    private func spawnSessionRunner(manifestPath: String, sessionDir: URL) throws -> Process {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["__run-session", "--manifest", manifestPath]
        let logURL = sessionDir.appendingPathComponent("logs/noted.log")
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    private enum StartupResult {
        case recording
        case permission
        case audio
        case `internal`
    }

    private func waitForStartup(sessionID: String, sessionDir: URL) async -> StartupResult {
        // Phase 1: child must write any status.json within 30 s (proves it launched).
        let launchDeadline = Date().addingTimeInterval(30)
        var childAlive = false
        while Date() < launchDeadline {
            if let status = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                if let result = checkTerminalStartup(status: status) { return result }
                childAlive = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard childAlive else { return .internal }

        // Phase 2: child is alive — wait up to 90 s for model loading and capture start.
        let modelDeadline = Date().addingTimeInterval(90)
        while Date() < modelDeadline {
            if let status = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                if let result = checkTerminalStartup(status: status) { return result }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .internal
    }

    private func checkTerminalStartup(status: RuntimeStatus) -> StartupResult? {
        if status.status == "recording", status.phase == "capturing" {
            return .recording
        }
        if status.phase == "failed_startup" {
            let error = status.lastError?.lowercased() ?? ""
            if error.contains("permission") || error.contains("access") {
                return .permission
            }
            if error.contains("audio") || error.contains("device") || error.contains("mic") {
                return .audio
            }
            return .internal
        }
        return nil
    }

    private func waitForCaptureFinalizedAcknowledgement(sessionDir: URL) async {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: RuntimeFiles.captureFinalizedAcknowledgedURL(sessionDir: sessionDir).path) {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func startupFailure(sessionID: String, sessionDir: URL, code: Int) -> Int {
        let status = RuntimeFiles.readStatus(sessionDir: sessionDir)
        writeJSON([
            "ok": false,
            "session_id": sessionID,
            "status": status?.status ?? "failed",
            "error": status?.lastError ?? "startup_failed",
        ])
        return code
    }

    private func nextMeetingAvailable(sessionDir: URL) -> Bool {
        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = ManifestValidator.validate(data: data).manifest
        else {
            return false
        }
        return manifest.nextMeeting.exists
    }

    private func transcriptionModel(for manifest: SessionManifest, settings: RuntimeSettings) -> TranscriptionModel {
        switch manifest.transcription.asrBackend {
        case "sfspeech":
            return .appleSpeech
        case "whisperkit":
            return settings.asrModelVariant.contains("large") ? .whisperLargeV3 : .whisperBase
        default:
            return .parakeet
        }
    }

    private func parseOptions(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options[key] = arguments[index + 1]
                    index += 2
                } else {
                    options[key] = "true"
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return options
    }

    private func writeJSON(_ object: [String: Any]) {
        let sanitized = object.mapValues { sanitizeJSONValue($0) }
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            print(#"{"ok":false,"error":"json_encoding_failed"}"#)
            return
        }
        print(string)
    }

    private func sanitizeJSONValue(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else {
                return NSNull()
            }
            return sanitizeJSONValue(child.value)
        }
        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { sanitizeJSONValue($0) }
        }
        return value
    }

    private func writeError(_ message: String) {
        let data = "\(message)\n".data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
    }

    private func appendLog(sessionDir: URL, _ message: String) {
        let logURL = sessionDir.appendingPathComponent("logs/noted.log")
        let line = "[\(ISO8601.withOffset(Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private func fsyncIfPossible(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            return
        }
        try? handle.synchronize()
        try? handle.close()
    }

    private func playRecordingBell() {
        if let sound = NSSound(named: "Glass") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

private struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private enum ContractSnapshot {
    static var appVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        if let infoURL = findRepositoryRoot()?.appendingPathComponent("HushScribe/Sources/HushScribe/Info.plist"),
           let plist = NSDictionary(contentsOf: infoURL),
           let version = plist["CFBundleShortVersionString"] as? String {
            return version
        }
        return "0.1.0"
    }

    static var manifestSchemaVersion: String {
        schemaVersion(schemaName: "manifest") ?? "1.0"
    }

    static var completionSchemaVersion: String {
        schemaVersion(schemaName: "completion") ?? "1.0"
    }

    private static func schemaVersion(schemaName: String) -> String? {
        guard let root = findRepositoryRoot() else { return nil }
        let schemaURL = root.appendingPathComponent("vendor/contracts/contracts/schemas/\(schemaName).v1.json")
        guard FileManager.default.fileExists(atPath: schemaURL.path) else { return nil }
        return "1.0"
    }

    private static func findRepositoryRoot() -> URL? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("vendor/contracts/CONTRACTS_TAG").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}
