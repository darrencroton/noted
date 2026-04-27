# Changelog

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
