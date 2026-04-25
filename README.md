# noted

`noted` is the local macOS capture agent for the Meeting Intelligence System. It runs as a menubar app, records meeting audio on command, transcribes on device with Parakeet-TDT or Whisper, runs post-session speaker diarization, and writes a contract-valid session directory for later ingestion by `briefing`.

## What noted does

- Accepts a session manifest written by `briefing` and starts recording.
- Captures room-mic audio (or mic + system audio for online meetings).
- Transcribes on device using the configured ASR backend.
- Runs post-session speaker diarization asynchronously after `stop` returns.
- Writes a canonical session directory including `outputs/completion.json` as the sole terminal outcome signal.
- Shows the scheduled end-of-meeting popup and routes Stop, Extend, and Next Meeting actions through the same CLI paths used by automation.

## What noted does not do

- Does not read calendars or decide which meetings to record.
- Does not summarise transcripts or call LLMs.
- Does not write Obsidian notes.
- Does not include a transcript viewer UI.

Those responsibilities belong to `briefing`.

## Current status

Completed work:

- Phase 2 minimal runtime: manifest validation, canonical session directories, room-mic capture, fast stop, async post-processing, completion files, and contract smoke coverage.
- Phase 3 end-of-meeting UX: popup, `extend`, `switch-next`, auto-stop/auto-switch, `runtime/ui_state.json`, back-to-back contract tests, and N-25 missing/invalid next-manifest handling.
- Phase 4 integration polish: configurable `briefing` command handoff, automatic `briefing session-ingest` invocation after completion, canonical ad hoc menubar Start manifests, and local smoke/runbook coverage with `briefing`.

Remaining before Phase 5:

- Operational soak with real meetings before Phase 5 hardening.

## Build

Requirements:

- Apple Silicon Mac
- macOS 26+
- Xcode 26.3+ command line tools

```bash
cd HushScribe
swift build
```

For a distributable app bundle (skips notarization):

```bash
./scripts/release.sh test
```

## CLI

The primary interface is the CLI, launched through the app bundle:

```bash
# Validate a manifest before starting
dist/Noted.app/Contents/MacOS/Noted validate-manifest --manifest /path/to/manifest.json

# Start a session from a manifest
dist/Noted.app/Contents/MacOS/Noted start --manifest /path/to/manifest.json

# Stop an active session (returns after audio flush; ASR/diarization continue async)
dist/Noted.app/Contents/MacOS/Noted stop --session-id <session-id>

# Extend the scheduled end time for an active session
dist/Noted.app/Contents/MacOS/Noted extend --session-id <session-id> --minutes 10

# Stop the current session and start the pre-planned next meeting
dist/Noted.app/Contents/MacOS/Noted switch-next --session-id <session-id>

# Poll status of an active or completed session
dist/Noted.app/Contents/MacOS/Noted status --session-id <session-id>

# Print app and schema versions
dist/Noted.app/Contents/MacOS/Noted version
```

All commands write one JSON line to stdout and diagnostics to stderr. Exit codes and JSON shapes are defined in `vendor/contracts/contracts/cli-contract.md`.

## Settings

Runtime settings live at `~/Library/Application Support/noted/settings.toml`. Relevant Meeting Intelligence keys:

```toml
briefing_command = "briefing"
ingest_after_completion = true
ad_hoc_note_directory = "/path/to/ad-hoc/notes"
```

After any terminal `outputs/completion.json` is written, `noted` invokes:

```bash
briefing session-ingest --session-dir <session_dir>
```

The handoff does not mutate `completion.json`. `noted` records the command, exit code, and stdout/stderr log paths in `logs/noted.log`; the captured streams are written to `logs/briefing-ingest.stdout.log` and `logs/briefing-ingest.stderr.log`.

## Session directory layout

Every session writes under the `paths.session_dir` specified in the manifest:

```
<session_dir>/
├── manifest.json
├── audio/
│   └── raw_room.wav            # room-mic (or raw_mic.wav + raw_system.wav for mic_plus_system)
├── transcript/
│   ├── transcript.txt
│   ├── transcript.json
│   └── segments.json           # optional
├── diarization/
│   └── diarization.json        # when diarization succeeds
├── outputs/
│   └── completion.json         # sole terminal outcome source; written last
├── runtime/
│   └── status.json             # updated at every phase transition
└── logs/
    ├── noted.log
    ├── briefing-ingest.stdout.log  # when automatic ingest runs
    └── briefing-ingest.stderr.log  # when automatic ingest runs
```

## Permissions

| Permission | Why |
| --- | --- |
| Microphone | Captures local speaker audio. |
| Screen Recording | Enables ScreenCaptureKit system-audio capture for online meetings. |

TCC approvals are per code-signature. Re-signing the app bundle (including debug builds substituted into the dist bundle) revokes prior approvals and requires user confirmation on first post-sign launch.

## Testing

Contract tests in `HushScribe/Tests/NotedContractTests/` validate manifest and completion fixtures against the pinned contracts schema. Run with:

```bash
cd HushScribe && swift test
```

## Settings

`~/Library/Application Support/noted/settings.toml` controls ASR backend, model variant, input device, output root, and other runtime preferences. The file is created on first launch with defaults. Reset with:

```bash
defaults delete app.noted.macos
```

## Credits

`noted` starts from a squashed import of [HushScribe](https://github.com/drcursor/HushScribe), which is a fork of [Tome](https://github.com/Gremble-io/Tome) by Gremble-io and traces lineage to [OpenGranola](https://github.com/yazinsai/OpenGranola). Attribution and license notices are preserved in this repository.

Models and libraries:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference for Parakeet-TDT ASR, VAD, and offline diarization.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for local Whisper transcription.
- Apple Speech via `SFSpeechRecognizer` as an optional local backend.

## License

[MIT](LICENSE)
