# Changelog

## [0.3.0] - 2026-05-07

- Pinned contracts v2.0.0.
- Removed manifest `mode.audio_strategy`; capture layout now follows `mode.type` directly.
- `in_person` captures `raw_room.wav`; `online` and `hybrid` capture `raw_mic.wav` plus `raw_system.wav`.

## [0.2.0] - 2026-04-30

- Added `noted pause --session-id <id>` and `noted continue --session-id <id>` CLI commands and matching menubar controls.
- Paused sessions remain `status: "recording"` and report `is_paused: true` in `runtime/status.json`; no new locked runtime status value is added.
- Pinned contracts v1.0.2, which adds the optional `is_paused` property to `runtime-status.v1.json` and optional `meeting.location_type` to `manifest.v1.json`.

## [0.1.0] - 2026-04-25

Initial `noted` release candidate for the Meeting Intelligence System.

- Added manifest-driven CLI runtime: `start`, `stop`, `extend`, `switch-next`, `status`, `wait`, `validate-manifest`, and `version`.
- Added canonical session directory output with raw audio, transcripts, diarization, runtime status, logs, and terminal `outputs/completion.json`.
- Added fast stop behavior so capture flush returns before asynchronous ASR/diarization completion.
- Added menubar app support for ad hoc sessions, status, scheduled end prompts, Stop, Extend, and Next Meeting actions.
- Added TOML runtime settings at `~/Library/Application Support/noted/settings.toml`.
- Added automatic `briefing session-ingest --session-dir <session_dir>` handoff after completion.
- Pinned shared contracts under `vendor/contracts/`.

Historical pre-`noted` changelog material is retained locally under ignored `archive/`.
