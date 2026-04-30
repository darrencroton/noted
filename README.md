# noted

`noted` is the local macOS capture agent for the Meeting Intelligence System. It runs as a menubar app, records meeting audio from manifests, transcribes on device, runs post-session diarization, and writes a contract-valid session directory for `briefing` to ingest.

`briefing` decides which meetings should be recorded, writes manifests, summarises transcripts, and updates notes. `noted` stays focused on capture, transcription, diarization, runtime status, and user controls during the meeting.

## Requirements

- Apple Silicon Mac
- macOS 26+
- Xcode 26.3+ command line tools
- Microphone permission for room recordings
- Screen Recording permission for online or hybrid recordings that capture system audio

## Build And Install

Build the Swift package:

```bash
cd Noted
swift build
```

Build the app bundle used for normal local operation:

```bash
./scripts/release.sh test
```

The bundle is written to `dist/Noted.app`. Launch it once so the menubar app and popup watcher are running:

```bash
open dist/Noted.app
```

Microphone permission is requested when a recording starts. Screen Recording permission is needed only for online or hybrid sessions that capture system audio.

For integration with `briefing`, put the app executable on `PATH` as `noted`:

```bash
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/dist/Noted.app/Contents/MacOS/Noted" "$HOME/.local/bin/noted"
```

Ensure `$HOME/.local/bin` is on `PATH` for your shell and any `launchd` jobs that invoke `briefing watch`.

## Settings

`noted` runtime settings live here:

```text
~/Library/Application Support/noted/settings.toml
```

The file is created with defaults on first app launch or first command that needs runtime settings. Important keys:

```toml
host_name = "Your Name"
language = "en-AU"
asr_backend = "fluidaudio-parakeet"
asr_model_variant = "parakeet-v3"
default_input_device = 0
output_root = "/path/to/noted/sessions"
briefing_command = "briefing"
ingest_after_completion = true
diarization_enabled = true
default_extension_minutes = 5
pre_end_prompt_minutes = 5
no_interaction_grace_minutes = 5
```

Ad hoc session notes are written directly under `output_root` next to the session directories.
WhisperKit models are cached under `~/Library/Application Support/noted/models/`.

The menubar Settings window exposes the common controls: transcription model with cache status, transcript locale, input microphone, scheduled calendar recording on/off, and the default directory. The scheduled recording toggle is honored by `briefing watch` when Briefing is installed.

`briefing_command` is the command `noted` runs after writing `outputs/completion.json`:

```bash
briefing session-ingest --session-dir <session_dir>
```

The handoff does not mutate `completion.json`. Handoff stdout and stderr are written to `logs/briefing-ingest.stdout.log` and `logs/briefing-ingest.stderr.log` inside the session directory.
`ingest_after_completion` defaults to true and is not exposed in the settings window.

`briefing` has its own separate config at `user_config/settings.toml` in the `briefing` repo.

## CLI

All CLI commands write one JSON line to stdout and diagnostics to stderr. Exit codes and JSON shapes are defined in `vendor/contracts/contracts/cli-contract.md`.

```bash
noted validate-manifest --manifest /path/to/manifest.json
noted start --manifest /path/to/manifest.json
noted pause --session-id <session-id>
noted continue --session-id <session-id>
noted stop --session-id <session-id>
noted extend --session-id <session-id> --minutes 10
noted switch-next --session-id <session-id>
noted status --session-id <session-id>
noted wait --session-id <session-id> --timeout-seconds 300
noted version
```

`noted stop` returns after capture is flushed and persisted. ASR, diarization, completion writing, and optional `briefing` ingest continue asynchronously.
`noted pause` and `noted continue` keep the session active while excluding paused audio from the raw recording. `status.json` remains `status: "recording"` and carries `is_paused` so existing status readers do not need a new runtime vocabulary value.

## Menubar App

The menubar app exposes the same runtime paths as the CLI:

- Start creates a full ad hoc manifest from local settings and records immediately.
- Pause temporarily suspends audio capture for the active session; while paused this menu item changes to Continue.
- Stop requests a fast stop for the active session.
- Status reflects `runtime/status.json`.
- The scheduled end-of-meeting popup offers Stop, Extend, and Next Meeting when the manifest allows those actions.

`noted` does not read calendars, infer next meetings, call LLMs, summarise transcripts, or write Obsidian notes.

## Session Directory

Every session writes under the manifest's `paths.session_dir`:

```text
<session_dir>/
|-- manifest.json
|-- audio/
|   `-- raw_room.wav
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

For `mic_plus_system` sessions, audio output is `raw_mic.wav` plus `raw_system.wav`. `completion.json` is the sole terminal outcome signal for consumers.

## Testing

Run the Swift contract tests:

```bash
cd Noted
swift test
```

Build the distributable local bundle:

```bash
./scripts/release.sh test
```

Run the optional capture smoke only on a permissioned Mac:

```bash
NOTED_RUN_CAPTURE_SMOKE=1 scripts/contract-smoke.sh
```

## Credits

Historical upstream source and changelog material is retained in the local ignored `archive/` directory. Runtime summarisation and transcript-reader features from earlier codebases are not part of `noted`.

Runtime models and libraries:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) for Parakeet-TDT ASR, VAD, and offline diarization
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) for local Whisper transcription
- Apple Speech via `SFSpeechRecognizer` as an optional local backend

## License

[MIT](LICENSE)
