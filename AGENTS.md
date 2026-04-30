# AGENTS.md

This file provides guidance when working in this repository.

## What `noted` is

`noted` is the macOS menubar capture agent for the Meeting Intelligence System. It is Apple Silicon only, targets macOS 26+, captures microphone and system audio locally, transcribes on device, diarizes after recording, and writes session artefacts for ingestion by `briefing`.

`noted` must remain a runtime agent. It does not read calendars, generate summaries, write Obsidian notes, or decide which meetings should be recorded.

## Commands

Run commands from the repo root unless noted otherwise.

```bash
cd Noted && swift build
cd Noted && swift test
./scripts/release.sh test
./scripts/contract-smoke.sh
./scripts/bump_version.sh patch
defaults delete app.noted.macos
```

The app bundle build writes `dist/Noted.app`. For local integration with `briefing`, symlink `dist/Noted.app/Contents/MacOS/Noted` to a `noted` command on `PATH`.

## Project Layout

```text
Noted/
|-- Package.swift
|-- Sources/Noted/
|   |-- App/             app entry, session controller, status item
|   |-- Audio/           microphone and system-audio capture
|   |-- CLI/             command router, manifest validator, runtime files
|   |-- Models/          domain types and recording state
|   |-- Settings/        AppSettings and RuntimeSettings
|   |-- Storage/         session store and transcript writers
|   |-- Transcription/   ASR backends and streaming transcription
|   `-- Views/           settings/status UI
`-- Tests/NotedContractTests/
```

Local runtime settings live at `~/Library/Application Support/noted/settings.toml`.

## CLI Surface

```text
noted start             --manifest <path>
noted pause             --session-id <id>
noted continue          --session-id <id>
noted stop              --session-id <id>
noted extend            --session-id <id> --minutes N
noted switch-next       --session-id <id>
noted status            --session-id <id>
noted validate-manifest --manifest <path>
noted wait              --session-id <id> [--timeout-seconds N]
noted version
```

All public command responses are single-line JSON on stdout. Diagnostics go to stderr or session logs.

## Architecture Notes

- `LSUIElement = true`; normal launch creates only a menubar icon.
- CLI invocations bypass the menubar and run headlessly.
- The menubar Start action writes a full ad hoc manifest and routes through `noted start --manifest`.
- `stop` must return after raw audio is flushed; post-processing runs asynchronously.
- `completion.json` is written last and is the only authoritative session outcome.
- `RuntimeSettings` is TOML-backed; `AppSettings` is for menubar UI preferences.
- Raw audio is preserved when capture succeeds.

## Dependencies

| Package | Purpose |
| --- | --- |
| FluidAudio | Parakeet-TDT ASR, VAD, offline diarization |
| WhisperKit | Whisper ASR |

## Conventions

- Swift 6.2 with strict concurrency.
- Use Swift Package Manager; there is no Xcode project.
- Version is stored in `Noted/Sources/Noted/Info.plist`.
- Never bypass git hooks or amend commits.
- Never delete files; move retired material to ignored `archive/`.
