# AGENTS.md

This file provides guidance to Codex when working in this repository.

## What is noted

`noted` is the macOS menubar capture agent for the Meeting Intelligence System. It is Apple Silicon only, targets macOS 26+, captures microphone and system audio locally, transcribes on device, diarizes after recording, and writes session artefacts for later ingestion by `briefing`.

`noted` must remain a runtime agent. It does not read calendars, generate summaries, write Obsidian notes, or decide which meetings should be recorded.

## Build Commands

All commands run from the repo root.

```bash
# Dev build
cd HushScribe && swift build

# Local app bundle build, skips notarization
./scripts/release.sh test

# Bump version in Info.plist
./scripts/bump_version.sh patch   # or minor | major | 0.2.0

# Reset user defaults
defaults delete app.noted.macos
```

Contract tests live in `HushScribe/Tests/NotedContractTests/` and validate schema fixtures and the pinned contracts version. There are no other unit tests currently.

## Project Layout

The Swift package lives in `HushScribe/` for now because that path was inherited from HushScribe. The package and executable are named `Noted`.

```
HushScribe/Sources/HushScribe/
├── App/                  # App entry, session controller, status item
├── Audio/                # MicCapture, SystemAudioCapture
├── CLI/                  # NotedCLI, Manifest validator, RuntimeFiles
├── Models/               # Domain types and recording state
├── Settings/             # AppSettings, RuntimeSettings (TOML-backed)
├── Storage/              # SessionStore and TranscriptLogger
├── Transcription/        # ASRBackend + FluidAudio/WhisperKit/SFSpeech backends
└── Views/                # Minimal settings view
```

Archived HushScribe source and website files live locally under ignored `archive/hushscribe-strip/`.

## Architecture Notes

- **Menubar app.** `LSUIElement = true`; launching creates only a menubar icon. CLI invocations bypass the menubar and run headlessly.
- **Phase 2 CLI runtime.** `noted start --manifest`, `stop`, `status`, `validate-manifest`, and `version` are all implemented. The menubar Start action is disabled until Phase 3 (canonical ad hoc manifests).
- **Dual audio streams.** `TranscriptionEngine` owns `MicCapture` and `SystemAudioCapture`. Each stream feeds a `StreamingTranscriber`.
- **ASR pipeline.** `StreamingTranscriber` runs FluidAudio VAD and then the selected `ASRBackend`.
- **Post-session diarization.** `OfflineDiarizerManager` runs after stop against the captured audio and writes `diarization/diarization.json` when successful.
- **Settings.** TOML-backed at `~/Library/Application Support/noted/settings.toml` via `RuntimeSettings.swift`. Legacy `AppSettings` remains for menubar-specific UI preferences.
- **Output.** Phase 2 canonical session directory under the manifest-specified `paths.session_dir`:
  ```
  audio/raw_room.wav          # room-mic capture (mic_plus_system: raw_mic.wav + raw_system.wav)
  transcript/transcript.txt
  transcript/transcript.json
  transcript/segments.json    # optional
  diarization/diarization.json  # when diarization succeeds
  outputs/completion.json     # sole terminal outcome source; written last
  runtime/status.json         # updated at every phase transition
  logs/noted.log
  ```

## Dependencies

| Package | Purpose |
| --- | --- |
| FluidAudio | Parakeet-TDT ASR, Silero VAD, offline diarization |
| WhisperKit | Whisper Base / Large v3 ASR |

## Key Conventions

- Swift 6.2 with strict concurrency.
- The `@Observable` macro is used instead of `ObservableObject`/`@Published`.
- No Xcode project; build with Swift Package Manager from `HushScribe/`.
- Version is stored in `Info.plist`.
