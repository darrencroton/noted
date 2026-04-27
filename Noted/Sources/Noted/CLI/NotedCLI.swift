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
        case "extend":
            return extend(options: options)
        case "switch-next":
            return await switchNext(options: options)
        case "wait":
            return await wait(options: options)
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

            let startupResult = await waitForStartup(sessionID: manifest.sessionID, sessionDir: sessionDir, child: child)
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
            case .internalFailure(let message):
                if child.isRunning {
                    child.terminate()
                }
                if RuntimeFiles.readStatus(sessionDir: sessionDir)?.phase != "failed_startup" {
                    try? await writeStartupFailure(
                        manifest: manifest,
                        sessionDir: sessionDir,
                        message: message
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

    private func extend(options: [String: String]) -> Int {
        guard let sessionID = options["session-id"] else {
            writeError("missing --session-id <id>")
            writeJSON(["ok": false, "error": "missing_session_id"])
            return 2
        }
        guard let minutesStr = options["minutes"], let minutes = Int(minutesStr), minutes > 0 else {
            writeError("--minutes must be a positive integer")
            writeJSON(["ok": false, "error": "invalid_minutes"])
            return 6
        }

        guard let record = RuntimeFiles.readRegistry(sessionID: sessionID) else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "unknown_session_id"])
            return 2
        }

        let sessionDir = URL(fileURLWithPath: record.sessionDir, isDirectory: true)
        guard let currentStatus = RuntimeFiles.readStatus(sessionDir: sessionDir),
              currentStatus.status == "recording"
        else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "session_not_recording"])
            return 3
        }

        guard let currentEndTimeStr = currentStatus.scheduledEndTime,
              let currentEndTime = ISO8601.parseDate(currentEndTimeStr)
        else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "no_scheduled_end_time"])
            return 6
        }

        let newEndTime = currentEndTime.addingTimeInterval(Double(minutes) * 60)
        let newEndTimeStr = ISO8601.withOffset(newEndTime)
        let totalExtension = currentStatus.currentExtensionMinutes + minutes

        do {
            // Update status.json; the session runner picks up the new scheduled_end_time on its
            // next loop iteration and resets the prompt timer accordingly.
            try RuntimeFiles.writeStatus(
                sessionID: sessionID,
                sessionDir: sessionDir,
                status: currentStatus.status,
                phase: currentStatus.phase,
                startedAt: currentStatus.startedAt,
                scheduledEndTime: newEndTimeStr,
                currentExtensionMinutes: totalExtension,
                preEndPromptShown: currentStatus.preEndPromptShown
            )

            // Clearing the prompt file causes the session runner to re-fire it at the new time.
            RuntimeFiles.clearPreEndPrompt(sessionDir: sessionDir)

            var uiState = RuntimeFiles.readUIState(sessionDir: sessionDir) ?? UIState()
            uiState.extensionCount += 1
            uiState.lastAction = "extend"
            uiState.lastActionAt = ISO8601.withOffset(Date())
            try RuntimeFiles.writeUIState(uiState, to: sessionDir)

            appendLog(sessionDir: sessionDir, "session extended by \(minutes)m, new end: \(newEndTimeStr)")

            writeJSON([
                "ok": true,
                "session_id": sessionID,
                "status": "recording",
                "current_extension_minutes": totalExtension,
                "scheduled_end_time": newEndTimeStr,
            ])
            return 0
        } catch {
            writeError(error.localizedDescription)
            writeJSON(["ok": false, "session_id": sessionID, "error": "extend_failed"])
            return 6
        }
    }

    private func switchNext(options: [String: String]) async -> Int {
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
        guard let currentStatus = RuntimeFiles.readStatus(sessionDir: sessionDir),
              (currentStatus.status == "recording" || currentStatus.status == "stopping")
        else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "session_not_recording"])
            return 3
        }

        // Read the session's manifest for next_meeting info.
        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = ManifestValidator.validate(data: manifestData).manifest
        else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "cannot_read_manifest"])
            return 4
        }

        guard manifest.nextMeeting.exists, let nextManifestPath = manifest.nextMeeting.manifestPath else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "no_next_meeting"])
            return 3
        }

        // Only write the stop request if still recording; if already stopping, the existing
        // stop reason is authoritative and must not be overwritten.
        if currentStatus.status == "recording" {
            do {
                try RuntimeFiles.writeStopRequest(sessionDir: sessionDir, reason: "auto_switch_to_next_meeting")
            } catch {
                writeError(error.localizedDescription)
                writeJSON(["ok": false, "session_id": sessionID, "error": "stop_request_failed"])
                return 4
            }
        }

        // Wait for the session runner to flush and signal capture-finalized (fast-stop).
        let stopDeadline = Date().addingTimeInterval(20)
        var captureFinalized = false
        while Date() < stopDeadline {
            if FileManager.default.fileExists(atPath: RuntimeFiles.captureFinalizedURL(sessionDir: sessionDir).path) {
                captureFinalized = true
                break
            }
            if let s = RuntimeFiles.readStatus(sessionDir: sessionDir),
               s.status == "completed" || s.status == "completed_with_warnings" || s.status == "failed" {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard captureFinalized else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "stop_capture_timeout"])
            return 4
        }

        // Validate before ACK so next-manifest-missing.json is written before the runner
        // reaches postProcess, regardless of scheduling order between the two processes.
        let nextManifestURL = URL(fileURLWithPath: nextManifestPath)
        let nextManifest = ManifestValidator.validate(fileURL: nextManifestURL).manifest
        if nextManifest == nil {
            try? RuntimeFiles.writeNextManifestMissing(sessionDir: sessionDir)
        }
        try? RuntimeFiles.acknowledgeCaptureFinalized(sessionID: sessionID, sessionDir: sessionDir)

        guard let nextManifest else {
            appendLog(sessionDir: sessionDir, "switch-next: next manifest missing or invalid: \(nextManifestPath)")
            writeJSON([
                "ok": false,
                "previous_session_id": sessionID,
                "error": "next_manifest_missing_or_invalid",
            ])
            return 8
        }

        var uiState = RuntimeFiles.readUIState(sessionDir: sessionDir) ?? UIState()
        uiState.lastAction = "switch_next"
        uiState.lastActionAt = ISO8601.withOffset(Date())
        try? RuntimeFiles.writeUIState(uiState, to: sessionDir)

        // Spawn `noted start --manifest <path>` as a subprocess so its stdout is captured
        // separately from our own output, and both processes run concurrently (the old session's
        // postProcess and the new session's startup overlap).
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
        let nextProcess = Process()
        nextProcess.executableURL = executableURL
        nextProcess.arguments = ["start", "--manifest", nextManifestPath]
        nextProcess.standardOutput = Pipe()
        nextProcess.standardError = FileHandle.standardError

        let startExitCode: Int32 = await withCheckedContinuation { continuation in
            nextProcess.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do {
                try nextProcess.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }

        if startExitCode == 0 {
            writeJSON([
                "ok": true,
                "previous_session_id": sessionID,
                "next_session_id": nextManifest.sessionID,
                "status": "recording",
            ])
            return 0
        } else {
            writeJSON([
                "ok": false,
                "previous_session_id": sessionID,
                "error": "next_session_start_failed",
            ])
            return 8  // current session stopped normally; next session start failed
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

    private func wait(options: [String: String]) async -> Int {
        guard let sessionID = options["session-id"] else {
            writeError("missing --session-id <id>")
            writeJSON(["ok": false, "error": "missing_session_id"])
            return 2
        }
        let timeoutSeconds = Int(options["timeout-seconds"] ?? "3600") ?? 3600

        guard let record = RuntimeFiles.readRegistry(sessionID: sessionID) else {
            writeJSON(["ok": false, "session_id": sessionID, "error": "unknown_session_id"])
            return 2
        }

        let sessionDir = URL(fileURLWithPath: record.sessionDir, isDirectory: true)
        let completionURL = sessionDir.appendingPathComponent("outputs/completion.json")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))

        // Poll every 500 ms. Check immediately on entry - session may already be done.
        repeat {
            if FileManager.default.fileExists(atPath: completionURL.path),
               let data = try? Data(contentsOf: completionURL),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let terminalStatus = payload["terminal_status"] as? String
            {
                writeJSON([
                    "ok": true,
                    "session_id": sessionID,
                    "terminal_status": terminalStatus,
                    "session_dir": record.sessionDir,
                ])
                return 0
            }
            if Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } while Date() < deadline

        // One final check: completion may have appeared during the last sleep window.
        if FileManager.default.fileExists(atPath: completionURL.path),
           let data = try? Data(contentsOf: completionURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let terminalStatus = payload["terminal_status"] as? String
        {
            writeJSON([
                "ok": true,
                "session_id": sessionID,
                "terminal_status": terminalStatus,
                "session_dir": record.sessionDir,
            ])
            return 0
        }

        writeJSON(["ok": false, "session_id": sessionID, "error": "timeout"])
        return 7
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

            // In-memory tracking for values that the `extend` command may update via status.json.
            var inMemoryScheduledEndTime = manifest.meeting.scheduledEndTime
            var inMemoryExtensionMinutes = 0
            var inMemoryPreEndPromptShown = false

            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "recording",
                phase: "capturing",
                startedAt: startedAtString,
                scheduledEndTime: inMemoryScheduledEndTime
            )
            appendLog(sessionDir: sessionDir, "capture started")

            // Prompt scheduler state. promptFired tracks whether the pre-end-prompt.json is
            // currently live. graceDeadline is the time at which auto-stop/auto-switch fires.
            // autoSwitchToNext is set when this process writes its own stop-request so that the
            // session runner (not the parent CLI) is responsible for launching the next session.
            var promptFired = false
            var graceDeadline: Date? = nil
            var autoSwitchToNext = false

            while !FileManager.default.fileExists(atPath: RuntimeFiles.stopRequestURL(sessionDir: sessionDir).path) {
                // Pick up scheduledEndTime and extensionMinutes changes written by `noted extend`.
                if let freshStatus = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                    inMemoryScheduledEndTime = freshStatus.scheduledEndTime
                    inMemoryExtensionMinutes = freshStatus.currentExtensionMinutes
                }

                // `noted extend` clears pre-end-prompt.json so the prompt re-fires at the new time.
                if promptFired,
                   !FileManager.default.fileExists(atPath: RuntimeFiles.preEndPromptURL(sessionDir: sessionDir).path)
                {
                    promptFired = false
                    graceDeadline = nil
                }

                let now = Date()

                // Fire prompt if scheduled end time is known and the prompt window has opened.
                if !promptFired, let scheduledEnd = inMemoryScheduledEndTime.flatMap(ISO8601.parseDate(_:)) {
                    let promptSeconds = Double(manifest.recordingPolicy.preEndPromptMinutes) * 60
                    if now >= scheduledEnd.addingTimeInterval(-promptSeconds) {
                        promptFired = true
                        inMemoryPreEndPromptShown = true
                        playEndOfMeetingBeep()

                        let isFollowUp = inMemoryExtensionMinutes > 0
                        try? RuntimeFiles.writePreEndPrompt(sessionDir: sessionDir, promptAt: now, isFollowUp: isFollowUp)
                        try? RuntimeFiles.writeStatus(
                            sessionID: manifest.sessionID,
                            sessionDir: sessionDir,
                            status: "recording",
                            phase: "capturing",
                            startedAt: startedAtString,
                            scheduledEndTime: inMemoryScheduledEndTime,
                            currentExtensionMinutes: inMemoryExtensionMinutes,
                            preEndPromptShown: true
                        )
                        var uiState = RuntimeFiles.readUIState(sessionDir: sessionDir) ?? UIState()
                        if uiState.promptShownAt == nil { uiState.promptShownAt = ISO8601.withOffset(now) }
                        try? RuntimeFiles.writeUIState(uiState, to: sessionDir)
                        appendLog(sessionDir: sessionDir, isFollowUp ? "follow-up prompt fired" : "pre-end prompt fired")

                        // §12.3: grace applies only when next meeting exists; otherwise auto-stop
                        // fires at scheduledEnd exactly.
                        if manifest.nextMeeting.exists {
                            let graceSeconds = Double(manifest.recordingPolicy.noInteractionGraceMinutes) * 60
                            graceDeadline = scheduledEnd.addingTimeInterval(graceSeconds)
                        } else {
                            graceDeadline = scheduledEnd
                        }
                    }
                }

                // Auto-stop or auto-switch once grace period expires with no user interaction.
                if let deadline = graceDeadline, now >= deadline {
                    if manifest.nextMeeting.exists, manifest.nextMeeting.manifestPath != nil {
                        autoSwitchToNext = true
                        try? RuntimeFiles.writeStopRequest(sessionDir: sessionDir, reason: "auto_switch_to_next_meeting")
                    } else {
                        try? RuntimeFiles.writeStopRequest(sessionDir: sessionDir, reason: "scheduled_stop")
                    }
                    appendLog(sessionDir: sessionDir, "auto-\(autoSwitchToNext ? "switch" : "stop") triggered")
                    break
                }

                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let stopReason = RuntimeFiles.readStopReason(sessionDir: sessionDir)
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: sessionDir,
                status: "stopping",
                phase: "flushing_audio",
                startedAt: startedAtString,
                scheduledEndTime: inMemoryScheduledEndTime,
                currentExtensionMinutes: inMemoryExtensionMinutes,
                preEndPromptShown: inMemoryPreEndPromptShown
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
                scheduledEndTime: inMemoryScheduledEndTime,
                currentExtensionMinutes: inMemoryExtensionMinutes,
                preEndPromptShown: inMemoryPreEndPromptShown
            )
            RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
            playRecordingBell()
            try RuntimeFiles.writeCaptureFinalized(sessionID: manifest.sessionID, sessionDir: sessionDir)

            // For auto-switch: spawn the next session immediately after releasing the capture lock
            // so both the old session's postProcess and the new session's startup run concurrently.
            // Validate the next manifest first; it may have been archived by `briefing watch`.
            if autoSwitchToNext, let nextPath = manifest.nextMeeting.manifestPath {
                let nextValidation = ManifestValidator.validate(fileURL: URL(fileURLWithPath: nextPath))
                if nextValidation.isValid {
                    let executableURL = Bundle.main.executableURL
                        ?? URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
                    let nextProcess = Process()
                    nextProcess.executableURL = executableURL
                    nextProcess.arguments = ["start", "--manifest", nextPath]
                    nextProcess.standardOutput = Pipe()
                    nextProcess.standardError = FileHandle.standardError
                    try? nextProcess.run()
                    appendLog(sessionDir: sessionDir, "auto-switched: spawned next session")
                } else {
                    try? RuntimeFiles.writeNextManifestMissing(sessionDir: sessionDir)
                    appendLog(sessionDir: sessionDir, "auto-switch: next manifest missing or invalid: \(nextPath)")
                }
            }

            // For user-driven stop/switch-next, wait for the parent CLI to acknowledge
            // capture-finalized before starting postProcess. For auto-switch initiated by this
            // process, skip the wait - no parent is listening.
            if !autoSwitchToNext {
                await waitForCaptureFinalizedAcknowledgement(sessionDir: sessionDir)
            }

            try await postProcess(
                manifest: manifest,
                descriptor: descriptor,
                transcriptionEngine: transcriptionEngine,
                startedAt: startedAtString,
                stopReason: stopReason,
                scheduledEndTime: inMemoryScheduledEndTime,
                currentExtensionMinutes: inMemoryExtensionMinutes,
                preEndPromptShown: inMemoryPreEndPromptShown
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
            return 6
        }
    }

    @MainActor
    private func postProcess(
        manifest: SessionManifest,
        descriptor: SessionDescriptor,
        transcriptionEngine: TranscriptionEngine,
        startedAt: String?,
        stopReason: String,
        scheduledEndTime: String?,
        currentExtensionMinutes: Int,
        preEndPromptShown: Bool = false
    ) async throws {
        var warnings: [String] = []
        var errors: [String] = []
        let audioOK = FileManager.default.fileExists(atPath: descriptor.microphoneAudioURL.path)
            || FileManager.default.fileExists(atPath: descriptor.systemAudioURL.path)
        let transcriptOK = FileManager.default.fileExists(atPath: descriptor.transcriptDirectory.appendingPathComponent("transcript.txt").path)
            && FileManager.default.fileExists(atPath: descriptor.transcriptDirectory.appendingPathComponent("transcript.json").path)

        // Include a warning when switch-next found the next manifest had been invalidated.
        if FileManager.default.fileExists(atPath: RuntimeFiles.nextManifestMissingURL(sessionDir: descriptor.directory).path) {
            warnings.append("next_manifest_missing")
        }

        var diarizationOK = false
        if manifest.transcription.diarizationEnabled {
            try RuntimeFiles.writeStatus(
                sessionID: manifest.sessionID,
                sessionDir: descriptor.directory,
                status: "processing",
                phase: "running_diarization",
                startedAt: startedAt,
                scheduledEndTime: scheduledEndTime,
                currentExtensionMinutes: currentExtensionMinutes,
                preEndPromptShown: preEndPromptShown
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
            scheduledEndTime: scheduledEndTime,
            currentExtensionMinutes: currentExtensionMinutes,
            preEndPromptShown: preEndPromptShown
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
            scheduledEndTime: scheduledEndTime,
            currentExtensionMinutes: currentExtensionMinutes,
            preEndPromptShown: preEndPromptShown,
            lastError: errors.first
        )
        appendLog(sessionDir: descriptor.directory, "completion written: \(terminalStatus)")
        invokeCompletionHandoff(
            settings: RuntimeSettings.load(),
            sessionID: manifest.sessionID,
            sessionDir: descriptor.directory,
            terminalStatus: terminalStatus
        )
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
        appendLog(sessionDir: sessionDir, "completion written: failed")
        RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
        invokeCompletionHandoff(
            settings: RuntimeSettings.load(),
            sessionID: manifest.sessionID,
            sessionDir: sessionDir,
            terminalStatus: "failed"
        )
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
        appendLog(sessionDir: sessionDir, "completion written: \(terminalStatus)")
        RuntimeFiles.releaseActiveCapture(sessionID: manifest.sessionID)
        invokeCompletionHandoff(
            settings: RuntimeSettings.load(),
            sessionID: manifest.sessionID,
            sessionDir: sessionDir,
            terminalStatus: terminalStatus
        )
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
        let targetManifestURL = sessionDir.appendingPathComponent("manifest.json")
        try rejectExistingSessionArtifacts(
            at: sessionDir,
            allowingExistingManifestAt: sourceManifestURL.standardizedFileURL == targetManifestURL.standardizedFileURL
                ? targetManifestURL
                : nil
        )
        try SessionStore.createCanonicalDirectories(at: sessionDir)
        if sourceManifestURL.standardizedFileURL != targetManifestURL.standardizedFileURL {
            try FileManager.default.copyItem(at: sourceManifestURL, to: targetManifestURL)
        }
        let logURL = sessionDir.appendingPathComponent("logs/noted.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        appendLog(sessionDir: sessionDir, "session prepared for \(manifest.sessionID)")
    }

    private func rejectExistingSessionArtifacts(at sessionDir: URL, allowingExistingManifestAt allowedManifestURL: URL? = nil) throws {
        guard FileManager.default.fileExists(atPath: sessionDir.path) else { return }
        let artifactPaths = [
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

        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path),
           allowedManifestURL?.standardizedFileURL != manifestURL.standardizedFileURL {
            throw CLIError("session_dir_already_contains_artifacts: \(sessionDir.path)")
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

    private func invokeCompletionHandoff(
        settings: RuntimeSettings,
        sessionID: String,
        sessionDir: URL,
        terminalStatus: String
    ) {
        guard settings.ingestAfterCompletion else {
            appendLog(sessionDir: sessionDir, "briefing ingest skipped: ingest_after_completion=false")
            return
        }

        let command = settings.briefingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            appendLog(sessionDir: sessionDir, "briefing ingest skipped: briefing_command is empty")
            return
        }

        let logsDir = sessionDir.appendingPathComponent("logs", isDirectory: true)
        let stdoutURL = logsDir.appendingPathComponent("briefing-ingest.stdout.log")
        let stderrURL = logsDir.appendingPathComponent("briefing-ingest.stderr.log")
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)

            let process = Process()
            if command.contains("/") {
                process.executableURL = URL(fileURLWithPath: NSString(string: command).expandingTildeInPath)
                process.arguments = ["session-ingest", "--session-dir", sessionDir.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command, "session-ingest", "--session-dir", sessionDir.path]
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            appendLog(
                sessionDir: sessionDir,
                "briefing ingest starting: command=\(command) session_id=\(sessionID) terminal_status=\(terminalStatus) stdout=\(stdoutURL.path) stderr=\(stderrURL.path)"
            )
            try process.run()
            process.waitUntilExit()
            appendLog(
                sessionDir: sessionDir,
                "briefing ingest completed: command=\(command) exit_code=\(process.terminationStatus) session_id=\(sessionID) terminal_status=\(terminalStatus) stdout=\(stdoutURL.path) stderr=\(stderrURL.path)"
            )
        } catch {
            appendLog(
                sessionDir: sessionDir,
                "briefing ingest failed to start: command=\(command) session_id=\(sessionID) error=\(error.localizedDescription) stdout=\(stdoutURL.path) stderr=\(stderrURL.path)"
            )
        }
    }

    private enum StartupResult {
        case recording
        case permission
        case audio
        case internalFailure(String)
    }

    private func waitForStartup(sessionID: String, sessionDir: URL, child: Process) async -> StartupResult {
        // Phase 1: child must write any status.json within 30 s (proves it launched).
        let launchDeadline = Date().addingTimeInterval(30)
        var childAlive = false
        while Date() < launchDeadline {
            if let status = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                if let result = checkTerminalStartup(status: status) { return result }
                childAlive = true
                break
            }
            if !child.isRunning {
                return .internalFailure("session_runner_exited_before_startup")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard childAlive else { return .internalFailure("session_runner_did_not_start") }

        // The child is alive; allow model loading and audio startup to finish.
        let modelDeadline = Date().addingTimeInterval(90)
        while Date() < modelDeadline {
            if let status = RuntimeFiles.readStatus(sessionDir: sessionDir) {
                if let result = checkTerminalStartup(status: status) { return result }
            }
            if !child.isRunning {
                return .internalFailure("session_runner_exited_before_startup")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .internalFailure("startup_timeout")
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
            return .internalFailure(status.lastError ?? "startup_failed")
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

    // Distinct from the recording-start bell (§12.1) - uses "Ping" so the two cues differ.
    private func playEndOfMeetingBeep() {
        if let sound = NSSound(named: "Ping") {
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

enum ContractSnapshot {
    static var appVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        if let infoURL = findRepositoryRoot()?.appendingPathComponent("Noted/Sources/Noted/Info.plist"),
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
