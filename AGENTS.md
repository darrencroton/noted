# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What is HushScribe

HushScribe is a macOS menu bar app (Apple Silicon only, macOS 26+) that transcribes meetings and voice memos entirely on-device. No audio or data leaves the machine. Output is Obsidian-compatible `.md` files with YAML frontmatter. The bundle identifier is `com.drcursor.hushscribe`.

## Build Commands

All commands run from the repo root.

```bash
# Dev build (debug)
cd HushScribe && swift build

# Release build → signed .app + .dmg in dist/
./scripts/release.sh test        # local only, skips notarization

# Full release (build + notarize + GH release + cask update)
./scripts/release.sh

# Bump version in Info.plist
./scripts/bump_version.sh patch   # or minor | major | 2.5.0

# Reset user defaults (useful when testing)
defaults delete com.drcursor.hushscribe
```

There are no unit tests in the project currently.

## Project Layout

The Swift package lives in `HushScribe/` (the inner directory). `Package.swift` is at `HushScribe/Package.swift`; sources are under `HushScribe/Sources/HushScribe/`.

```
HushScribe/Sources/HushScribe/
├── App/                  # App entry point, menu bar (StatusBarController)
├── Audio/                # MicCapture (AVAudioEngine), SystemAudioCapture (ScreenCaptureKit)
├── Models/               # Domain types, RecordingState, SummaryModel, TranscriptStore
├── Services/             # LLMSummaryEngine (MLX), MeetingMonitor, SummaryService (Apple NL)
├── Settings/             # AppSettings — all config via UserDefaults
├── Storage/              # SessionStore, TranscriptLogger (.md writer)
├── Transcription/        # ASRBackend protocol + FluidAudio/WhisperKit/SFSpeech backends
└── Views/                # SwiftUI views (ContentView, Settings, Onboarding, etc.)
```

Other top-level directories:
- `scripts/` — build, release, and version-bump scripts
- `Casks/` — Homebrew cask formula (`hushscribe.rb`)
- `docs/` — GitHub Pages site and planning documents
- `assets/` — screenshots and icons

## Architecture Notes

- **Menu bar app.** `LSUIElement = true` — no dock icon. `StatusBarController` owns the menu bar item. The main window opens from the menu bar and hides itself after onboarding.
- **Dual audio streams.** `TranscriptionEngine` orchestrates `MicCapture` (your mic) and `SystemAudioCapture` (remote participants via ScreenCaptureKit, filtered to the active conferencing app). Each stream feeds its own `StreamingTranscriber`.
- **ASR pipeline.** `StreamingTranscriber` runs VAD (Silero via FluidAudio) then the selected `ASRBackend`. The `ASRBackend` protocol has three implementations: `FluidAudioASRBackend` (Parakeet-TDT v3, default), `WhisperKitBackend`, and `SFSpeechBackend`.
- **Post-session diarization.** After recording stops, `OfflineDiarizerManager` (FluidAudio) splits system audio into labelled speakers. `SpeakerNamingView` lets the user assign real names.
- **LLM summaries.** `LLMSummaryEngine` uses mlx-swift-lm to run Qwen3 or Gemma 3 on-device. Models are downloaded on demand and cached in `~/Library/Caches/models/`. `SummaryService` handles the Apple NaturalLanguage fallback.
- **Settings.** All persisted via `UserDefaults` through `AppSettings` (`@Observable`). No Core Data, no SQLite.
- **Output.** `TranscriptLogger` writes `.md` files with YAML frontmatter (`type`, `created`, `duration`, `source_app`, `attendees`, `tags`) to user-configured vault paths (default `~/Documents/HushScribe/{Meetings,Voice}`).

## Dependencies (Swift Package Manager)

| Package | Purpose |
|---|---|
| FluidAudio | Parakeet-TDT v3 ASR, Silero VAD, offline speaker diarization |
| WhisperKit | Whisper Base / Large v3 ASR |
| mlx-swift-lm | On-device LLM inference (Qwen3, Gemma 3) via Apple MLX |

FluidAudio and mlx-swift-lm are pinned to specific revisions; WhisperKit uses semver (`from: "0.9.0"`).

## Release Workflow

1. `./scripts/bump_version.sh <patch|minor|major>` — updates `Info.plist`
2. Update `CHANGELOG.md` with the new version entry
3. Commit and push
4. `./scripts/release.sh` — builds release binary, compiles MLX Metal shaders, creates signed `.app` + `.dmg`, notarizes, creates GH release with changelog notes, updates the Homebrew cask SHA and version

## Key Conventions

- Swift 6.2 with strict concurrency. `@MainActor` is used throughout — `AppSettings`, `TranscriptStore`, `RecordingState`, and all views are main-actor-isolated.
- The `@Observable` macro (Observation framework) is used instead of `ObservableObject`/`@Published`.
- No Xcode project — pure Swift Package Manager. Build via `swift build` from `HushScribe/`.
- Version is stored only in `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`). Use `bump_version.sh` to change it.
- The app is code-signed with a Developer ID certificate and notarized via `notarytool` with a stored keychain profile named "HushScribe".
