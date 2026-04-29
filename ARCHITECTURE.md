# noted Architecture

`noted` is the Meeting Intelligence runtime agent. It accepts a manifest, captures audio, streams transcription, performs post-session diarization, writes `outputs/completion.json`, and optionally invokes `briefing session-ingest`.

It has no calendar, source-gathering, LLM, or note-writing responsibilities.

## Runtime Flow

```text
noted start --manifest <manifest.json>
  |
  | validate manifest and acquire active-capture lock
  | prepare paths.session_dir
  | write runtime/status.json
  v
spawn __run-session child
  |
  | play recording-start bell
  | capture room mic or mic + system audio
  | stream transcript.txt and transcript.json
  |
  +-- noted stop --session-id <id>
        |
        | flush and persist raw audio
        | acknowledge capture-finalized
        | return to caller
        v
      background post-processing
        |
        | offline diarization
        | write completion.json
        | optionally run briefing session-ingest
```

`stop` must remain fast. Completion is intentionally written after post-processing, not before the stop command returns.

## Source Tree

```text
Noted/
|-- Package.swift
|-- Sources/Noted/
|   |-- App/             app entry, menubar controller, popup/status windows
|   |-- Audio/           microphone and ScreenCaptureKit system-audio capture
|   |-- CLI/             command router, manifest validator, runtime files
|   |-- Models/          runtime and recording state types
|   |-- Settings/        TOML runtime settings and UI preferences
|   |-- Storage/         session directory and transcript writers
|   |-- Transcription/   ASR backends and streaming transcription
|   `-- Views/           SwiftUI settings/status views
`-- Tests/NotedContractTests/
```

The executable target is `Noted`; the installed CLI convention is the lowercase symlink `noted`.

## Settings And State

Runtime settings:

```text
~/Library/Application Support/noted/settings.toml
```

Runtime registry and active-capture files:

```text
~/Library/Application Support/noted/runtime/
~/Library/Application Support/noted/sessions/
```

WhisperKit ASR models are cached under:

```text
~/Library/Application Support/noted/models/
```

Session artefacts are written under the manifest-provided `paths.session_dir`; no consumer should infer outcome from logs or partial files.

## Session Directory

```text
<session_dir>/
|-- manifest.json
|-- audio/
|   |-- raw_room.wav
|   |-- raw_mic.wav
|   `-- raw_system.wav
|-- transcript/
|   |-- transcript.txt
|   |-- transcript.json
|   `-- segments.json
|-- diarization/
|   `-- diarization.json
|-- outputs/
|   `-- completion.json
|-- runtime/
|   |-- status.json
|   `-- ui_state.json
`-- logs/
    |-- noted.log
    |-- briefing-ingest.stdout.log
    `-- briefing-ingest.stderr.log
```

Room-mic sessions write `audio/raw_room.wav`. Mic-plus-system sessions write `audio/raw_mic.wav` and `audio/raw_system.wav`.

## Contracts

`noted` is pinned to the checked-in contracts snapshot under `vendor/contracts/`. Contract tests validate:

- manifest fixtures
- completion fixture compatibility
- CLI JSON and exit-code shapes
- end-of-meeting action state
- `wait` behavior
- automatic `briefing` handoff log files

## Boundaries

`noted` must not:

- read calendars
- decide meeting eligibility
- infer next meetings
- summarise transcripts
- call LLMs
- write Obsidian notes

`briefing` owns those concerns. The boundary is the manifest, CLI, runtime status, and completion file.

## Build

```bash
cd Noted
swift build
```

Requirements are Apple Silicon, macOS 26+, and Xcode 26.3+.
