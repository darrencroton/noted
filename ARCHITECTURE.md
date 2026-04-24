# noted Architecture

`noted` is the capture runtime for the Meeting Intelligence System. It accepts manifests from `briefing`, captures and transcribes audio on device, and hands a completed session directory back to `briefing session-ingest`.

## Runtime Shape (Phase 2)

```
CLI invocation (noted start --manifest ...)
   |
   v
NotedCLI (start)
   |  validates manifest, prepares session dir, writes status.json
   |
   +--> spawns __run-session child process
   |       |
   |       +--> TranscriptionEngine.start()
   |       |       |--> MicCapture ---------> raw_room.wav / raw_mic.wav
   |       |       +--> SystemAudioCapture -> raw_system.wav (mic_plus_system only)
   |       |                                       |
   |       |                               StreamingTranscriber
   |       |                               (FluidAudio VAD + ASRBackend)
   |       |                                       |
   |       |                               TranscriptLogger
   |       |                               (transcript.txt, transcript.json)
   |       |
   |       +--> on noted stop --session-id:
   |               audio flush → capture-finalized handshake
   |               → OfflineDiarizerManager → diarization.json
   |               → CompletionWriter → outputs/completion.json
   |
   v
NotedCLI (stop) returns EXIT:0 after audio flush; post-processing runs async
```

## Source Tree

```
HushScribe/Sources/HushScribe/
├── App/
│   ├── NotedApp.swift              # app entry and shared services; routes CLI vs. menubar
│   ├── SessionController.swift     # menubar manual session lifecycle (legacy path)
│   └── StatusBarController.swift   # menubar menu and status/settings windows
├── Audio/
│   ├── MicCapture.swift
│   └── SystemAudioCapture.swift
├── CLI/
│   ├── Manifest.swift              # manifest model + contract-aware validator
│   ├── NotedCLI.swift              # start, stop, status, validate-manifest, version, __run-session
│   └── RuntimeFiles.swift          # registry, active-capture lock, status/stop/completion helpers
├── Models/
│   ├── Models.swift
│   └── RecordingState.swift
├── Settings/
│   ├── AppSettings.swift           # menubar UI preferences (UserDefaults-backed)
│   └── RuntimeSettings.swift       # CLI runtime settings (TOML-backed, settings.toml)
├── Storage/
│   ├── SessionStore.swift          # canonical Phase 2 session directory creation
│   └── TranscriptLogger.swift      # transcript.txt, transcript.json, diarization.json writers
├── Transcription/
│   ├── ASRBackend.swift
│   ├── SFSpeechBackend.swift
│   ├── StreamingTranscriber.swift
│   ├── TranscriptionEngine.swift
│   └── WhisperKitBackend.swift
└── Views/
    └── SettingsView.swift
```

Contract tests: `HushScribe/Tests/NotedContractTests/FixtureContractTests.swift`

The source directory still carries the inherited `HushScribe` path name. The package, executable, bundle display name, and bundle identifier are `noted`-specific (`app.noted.macos`).

## Removed From Runtime Scope (at strip)

- MLX summary engine and all Qwen/Gemma model-download logic.
- Apple NaturalLanguage summary service.
- Transcript viewer and summary UI.
- Main transcript window.
- Meeting-app auto-detection.
- Post-session speaker naming UI.
- Homebrew cask and GitHub Pages marketing site.

Archived files live locally under ignored `archive/hushscribe-strip/` for reference.

## Session Directory Output

Phase 2 canonical output under the manifest-specified `paths.session_dir`:

```
<session_dir>/
├── manifest.json
├── audio/
│   └── raw_room.wav                 # room_mic strategy
│   # OR raw_mic.wav + raw_system.wav  # mic_plus_system strategy
├── transcript/
│   ├── transcript.txt
│   ├── transcript.json
│   └── segments.json                # optional
├── diarization/
│   └── diarization.json             # when diarization enabled and succeeds
├── outputs/
│   └── completion.json              # sole terminal outcome source; written last
├── runtime/
│   └── status.json                  # atomic rewrite at every phase transition
└── logs/
    └── noted.log
```

`completion.json` is the only file `briefing session-ingest` reads to determine session outcome. It must never be inferred from file presence or log content.

## What Comes Next (Phase 3 and Beyond)

- Phase 3: end-of-meeting popup (`extend`, `switch-next`), auto-stop and auto-switch timers, `runtime/ui_state.json`.
- Phase 3: `noted start` via menubar with canonical ad hoc manifests (N-23).
- Phase 4: automatic `briefing session-ingest` invocation after completion (N-21, N-22).
- Phase 5: crash recovery, retention hooks, online/hybrid capture.

`briefing` remains the owner of calendar interpretation, manifest contents, summarisation, and Obsidian note writing.

## Build

```bash
cd HushScribe
swift build
```

Requirements are Apple Silicon, macOS 26+, and Xcode 26.3+.

## Dependencies

| Library | Purpose |
| --- | --- |
| FluidAudio | Parakeet-TDT ASR, VAD, offline diarization |
| WhisperKit | Local Whisper ASR |
| Apple Speech | Optional built-in ASR backend |
