# noted Architecture

`noted` is the capture runtime for the Meeting Intelligence System. At this stage it is intentionally small: menubar control, audio capture, ASR, diarization, and local artefact writing.

## Current Shape

```
Menubar
   |
   v
SessionController
   |
   +--> MicCapture --------+
   |                       |
   +--> SystemAudioCapture +--> StreamingTranscriber --> TranscriptLogger
                           |
                           +--> OfflineDiarizerManager --> diarization.json
```

## Source Tree

```
HushScribe/Sources/HushScribe/
├── App/
│   ├── NotedApp.swift            # app entry and shared services
│   ├── SessionController.swift   # start/stop orchestration for manual sessions
│   └── StatusBarController.swift # menubar menu and small status/settings windows
├── Audio/
│   ├── MicCapture.swift
│   └── SystemAudioCapture.swift
├── Models/
│   ├── Models.swift
│   └── RecordingState.swift
├── Settings/
│   └── AppSettings.swift
├── Storage/
│   ├── SessionStore.swift
│   └── TranscriptLogger.swift
├── Transcription/
│   ├── ASRBackend.swift
│   ├── SFSpeechBackend.swift
│   ├── StreamingTranscriber.swift
│   ├── TranscriptionEngine.swift
│   └── WhisperKitBackend.swift
└── Views/
    └── SettingsView.swift
```

The source directory still carries the inherited `HushScribe` path name. The package, executable, bundle display name, and bundle identifier are now `noted`-specific.

## Removed From Runtime Scope

- MLX summary engine and all Qwen/Gemma model-download logic.
- Apple NaturalLanguage summary service.
- Transcript viewer and summary UI.
- Main transcript window.
- Meeting-app auto-detection.
- Post-session speaker naming UI.
- Homebrew cask and GitHub Pages marketing site.

Archived files live locally under ignored `archive/hushscribe-strip/` for reference.

## Current Output

Manual sessions write under `~/Documents/noted/sessions` unless changed in Settings:

```
<session-id>/
├── raw/
│   ├── microphone.wav
│   └── system.wav
├── session.json
├── transcript.txt
├── segments.json
└── diarization.json
```

This is a stripped baseline format, not the final cross-repo completion contract.

## Coming Later

Later phases add the contract-driven pieces from the master implementation plan:

- `noted` CLI.
- Manifest loader and validator.
- Canonical session directory writer.
- Runtime status file writer.
- Completion file writer.
- End-of-meeting popup.
- Next-meeting handoff execution from pre-prepared manifests.

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
