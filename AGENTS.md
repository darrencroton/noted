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

There are no unit tests in the project currently.

## Project Layout

The Swift package lives in `HushScribe/` for now because that path was inherited from HushScribe. The package and executable are named `Noted`.

```
HushScribe/Sources/HushScribe/
├── App/                  # App entry, session controller, status item
├── Audio/                # MicCapture, SystemAudioCapture
├── Models/               # Domain types and recording state
├── Settings/             # AppSettings
├── Storage/              # SessionStore and TranscriptLogger
├── Transcription/        # ASRBackend + FluidAudio/WhisperKit/SFSpeech backends
└── Views/                # Minimal settings view
```

Archived HushScribe source and website files live locally under ignored `archive/hushscribe-strip/`.

## Architecture Notes

- **Menubar app.** `LSUIElement = true`; launching should create only a menubar icon.
- **Manual baseline sessions.** Step 4 supports manual start/stop from the menubar. CLI, manifest loading, runtime status, completion files, and end-of-meeting popup come later.
- **Dual audio streams.** `TranscriptionEngine` owns `MicCapture` and `SystemAudioCapture`. Each stream feeds a `StreamingTranscriber`.
- **ASR pipeline.** `StreamingTranscriber` runs FluidAudio VAD and then the selected `ASRBackend`.
- **Post-session diarization.** `OfflineDiarizerManager` runs after stop against buffered system audio and writes `diarization.json` when successful.
- **Settings.** Persisted through `UserDefaults` until the TOML settings contract is implemented later.
- **Output.** Current baseline output is a session directory with raw WAV audio, `session.json`, `transcript.txt`, `segments.json`, and optionally `diarization.json`.

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
