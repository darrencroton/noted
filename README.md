# noted

You walk out of a meeting and find a summary already waiting in your notes, with key decisions and action items pulled from what was actually said. That's the end state. `noted` is the part that makes the recording happen.

`noted` works as a standalone recorder — it captures, transcribes, and diarizes any conversation and writes the results to a session directory on disk. Pair it with [`briefing`](../briefing/README.md) and it becomes part of something larger: `briefing` prepares a pre-meeting context summary before each configured meeting and, once `noted` finishes, generates a post-meeting summary from the transcript — all written into the same meeting note.

It runs as a macOS menubar app. When a meeting is about to start, `briefing watch` invokes `noted` automatically and it begins recording. A short bell plays so everyone in the room knows. At five minutes before the scheduled end, a popup gives you options. When you stop, `noted` transcribes and diarizes on device, writes a session directory, and hands off to `briefing` — which generates the summary and writes it into your Obsidian note.

On a normal day you don't touch `noted` at all. On an unusual day — a conversation that turned important, a meeting running long — the menubar is there.

## Requirements

- Apple Silicon Mac
- macOS 26+
- Xcode 26.3+ command line tools
- Microphone permission (granted when the first recording starts)
- Screen Recording permission (online or hybrid sessions that capture system audio only)

## Installation

Build and launch the app bundle:

```bash
./scripts/release.sh test
open dist/Noted.app
```

The script handles the Swift build (`swift build -c release`) and assembles the signed app bundle in `dist/Noted.app`. Run it from the project root (the directory containing `Noted/` and `scripts/`).

**Signing and Screen Recording permission.** If you have a codesigning certificate (check with `security find-identity -v -p codesigning`), the script signs with it automatically and macOS TCC tracks the app by identity — Screen Recording permission survives rebuilds. Without any certificate the script falls back to ad-hoc signing, which ties the TCC grant to the binary hash; every rebuild produces a new hash and macOS stops recognising the app, so the permission appears to disappear. Fix: in Xcode → Settings → Accounts → Manage Certificates, add an **Apple Development** certificate, then re-run the script.

The menubar icon appears. Microphone permission is not requested at launch — macOS asks when the first recording starts.

For `briefing watch` to launch `noted` automatically, put the executable on `PATH`:

```bash
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/dist/Noted.app/Contents/MacOS/Noted" "$HOME/.local/bin/noted"
```

Ensure `$HOME/.local/bin` is on `PATH` for both your shell and any `launchd` jobs that run `briefing watch`. Run `which noted` to confirm.

For `noted` to hand completed sessions back to `briefing`, make `briefing` available as a command too. From the `briefing` repo:

```bash
./scripts/setup.sh
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/.venv/bin/briefing" "$HOME/.local/bin/briefing"
```

Run `which briefing` to confirm. `noted` searches `$HOME/.local/bin` when it invokes `briefing session-ingest`, so this covers ad hoc sessions created from the menubar. As an alternative, set `briefing_command` in `~/Library/Application Support/noted/settings.toml` to the absolute path of the briefing executable.

## Settings

`noted` keeps its settings at:

```text
~/Library/Application Support/noted/settings.toml
```

The file is created with defaults on first launch. Edit it only if you need to change something specific — most defaults work well for the common in-person use case.

```toml
host_name = "Your Name"               # used in summaries as the meeting host
language = "en-US"                    # BCP-47 language tag; change to en-AU, fr-FR, etc.
asr_backend = "fluidaudio-parakeet"   # or "whisperkit" or "sfspeech"
asr_model_variant = "parakeet-v3"
default_input_device = 0              # 0 = current system default microphone
output_root = "~/Documents/noted"     # where session directories and ad hoc notes go
briefing_command = "briefing"         # command or absolute path invoked after each completed session
ingest_after_completion = true        # set false to disable the automatic briefing handoff
diarization_enabled = true
default_extension_minutes = 5
pre_end_prompt_minutes = 5            # minutes before scheduled end when the popup appears
no_interaction_grace_minutes = 5      # grace period before auto-stop if no popup response
```

The **Settings window** in the menubar app exposes the most common controls without editing the file directly: transcription model (with model cache status), transcript locale, input microphone, the default output directory, and two toggles — one to enable or disable the automatic `briefing` summary handoff, and one for scheduled recording. The scheduled recording toggle tells `briefing watch` not to launch `noted` for scheduled meetings on this Mac.

All downloaded model assets owned by `noted` are cached under `~/Library/Application Support/noted/models/`. On app launch, `noted` starts a background prefetch for Parakeet-TDT v3, FluidAudio diarization, Whisper Base, and Whisper Large v3. Existing FluidAudio caches from `~/Library/Application Support/FluidAudio/Models/` are migrated into the noted cache when possible.

`briefing` has its own separate configuration at `user_config/settings.toml` inside the briefing repo.

## How a recording works

This is the sequence for a calendar-driven meeting:

1. About 90 seconds before the meeting's start time, `briefing watch` invokes `noted start --manifest <path>` with a pre-written manifest describing the session.
2. `noted` validates the manifest, acquires the microphone, and begins capturing audio. A short bell plays — so anyone in earshot knows recording has started.
3. During the meeting the menubar icon shows the recording state. `noted` streams a live transcript as audio arrives.
4. Five minutes before the scheduled end, a popup appears with **Stop**, **+5 min**, and (when a back-to-back meeting is scheduled) **Next Meeting**.
   - **Stop** — stops the recording immediately.
   - **+5 min** — extends the session. The same popup reappears before the new end time, including **Next Meeting** when one is scheduled.
   - **Next Meeting** — stops this session and starts the next one in one fast handoff.
   - No interaction — `noted` stops at the scheduled end time, or auto-switches to the next meeting if one exists.
5. `noted stop` returns quickly. Audio is flushed; `noted` keeps running in the background through ASR and diarization.
6. When processing completes, `noted` writes `outputs/completion.json` and invokes `briefing session-ingest`, which generates the summary and writes it into the meeting note.

## Ad hoc recording

To record an unscheduled conversation, open the menubar and choose **Start**. `noted` creates a full session from local settings and begins recording immediately.

Choose **Stop** from the menubar when done. `noted` processes the recording in the background and, when `ingest_after_completion` is true and `briefing` is on `PATH`, writes a summary note to the configured output directory.

## Pause and continue

To exclude a segment from the recording without ending the session — for a private side conversation, for example — choose **Pause** from the menubar (or `noted pause --session-id <id>` from the CLI). Audio between a pause and a continue is dropped from the raw recording. The session stays active and the session timer keeps running. Choose **Continue** to resume.

## The menubar

| Icon | Condition |
|------|-----------|
| Stopped | Idle — no active session |
| Recording | Session is capturing audio |
| Paused | Capture suspended for the active session |

The menu shows current status as a non-interactive label at the top ("Status: ready", "Status: recording", or "Status: paused"). While a session is active, the meeting title and note filename are also shown inline. The interactive items:

- **Start Ad Hoc Session** — starts an ad hoc session. Not shown when a session is active.
- **Pause Recording / Continue Recording** — pauses or resumes capture for the active session. Only shown while a session is recording.
- **Stop Recording** — stops the active session.
- **Settings...** — opens the settings panel.
- **Quit noted** — quits `noted`. Asks for confirmation if a session is active.

## Session directory

Every session writes its artefacts under the path specified in its manifest:

```text
<session_dir>/
├── manifest.json
├── audio/
│   ├── raw_room.wav              (in_person)
│   ├── raw_mic.wav               (online or hybrid)
│   └── raw_system.wav            (online or hybrid)
├── transcript/
│   ├── transcript.txt
│   ├── transcript.json
│   └── segments.json
├── diarization/
│   └── diarization.json
├── outputs/
│   └── completion.json           ← sole terminal outcome signal for briefing
├── runtime/
│   ├── status.json
│   └── ui_state.json
└── logs/
    ├── noted.log
    ├── briefing-ingest.stdout.log
    └── briefing-ingest.stderr.log
```

`completion.json` is the only authoritative outcome signal. `briefing` reads it first and never infers success from file presence or log content. Raw audio is always preserved when capture succeeds, so a failed transcript or summary can be rerun without re-hosting the meeting.

If automatic ingest failed, rerun it manually from the briefing repo:

```bash
uv run briefing session-ingest --session-dir /path/to/session
# or rerun summary generation from an existing transcript:
uv run briefing session-reprocess --session-dir /path/to/session
```

## CLI reference

All commands write one JSON line to stdout and diagnostics to stderr. Exit codes and JSON shapes are defined in `vendor/contracts/contracts/cli-contract.md`.

```bash
noted validate-manifest --manifest /path/to/manifest.json
noted start             --manifest /path/to/manifest.json
noted pause             --session-id <id>
noted continue          --session-id <id>
noted stop              --session-id <id>
noted extend            --session-id <id> --minutes 5
noted switch-next       --session-id <id>
noted status            --session-id <id>
noted wait              --session-id <id> [--timeout-seconds 300]
noted version
```

`noted stop` returns after capture is flushed and persisted. ASR, diarization, and optional `briefing` ingest continue asynchronously.

## Troubleshooting

**Recording doesn't start automatically**

- Confirm `noted` is running in the menubar (the icon should be visible).
- Confirm `briefing watch` is running: `launchctl list | grep briefing-watch`.
- Confirm `noted` is on `PATH`: `which noted`. If not found, create the symlink in the Installation section.
- Confirm the calendar event or series is configured for recording in `briefing` (series YAML has `record: true`, or the event has a `noted config` marker).
- On a multi-Mac setup, confirm the event's `location_type` matches this Mac's configured location.

**Microphone permission never appeared**

Trigger the prompt by starting an ad hoc recording from the menubar. Or grant it directly in System Settings > Privacy & Security > Microphone.

**The end-of-meeting popup didn't appear**

- Ad hoc sessions have no scheduled end time, so they have no popup.
- Confirm the session has a `scheduled_end_time` in its manifest (`noted status --session-id <id>`).
- Confirm `noted` is still running — if it crashed, no popup will appear.

**Summary not written after recording**

Check the session directory for:

- `outputs/completion.json` — if absent, `noted` may still be processing
- `transcript/transcript.txt` — if absent, ASR failed
- `logs/briefing-ingest.stderr.log` — look for errors from `briefing session-ingest`

If the stderr log says `env: briefing: No such file or directory`, install the briefing command symlink from the Installation section or set `briefing_command` to an absolute executable path.

Rerun ingest manually:

```bash
uv run briefing session-ingest --session-dir /path/to/session
```

Or rerun summary generation if the transcript exists but the summary step failed:

```bash
uv run briefing session-reprocess --session-dir /path/to/session
```

**Session shows warnings in the menubar**

Read `outputs/completion.json` and `logs/noted.log`. A diarization failure (`diarization_ok: false`) is non-fatal — the summary will use speaker-agnostic language. An ASR failure will need reprocessing.

**Screen Recording permission not sticking / app keeps asking for permission**

This happens when the app has been built with an ad-hoc signature (no stable signing identity). Each rebuild produces a new binary hash and macOS treats it as an unknown app, invalidating any previously granted permission.

First verify you have a valid codesigning identity:

```bash
security find-identity -v -p codesigning
```

If this returns `0 valid identities found`, you need to install a signing certificate before building:

1. Install the WWDR G3 intermediate certificate (required for any Apple Development cert issued after 2021):

```bash
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
open AppleWWDRCAG3.cer
```

Add it to the **login** keychain when prompted.

2. Create an Apple Development certificate in Xcode → Settings → Apple Accounts → select your Apple ID → **Manage Certificates...** → **+** → **Apple Development**.

3. Confirm the identity is now valid:

```bash
security find-identity -v -p codesigning
```

4. Rebuild and relaunch:

```bash
./scripts/release.sh test && open dist/Noted.app
```

The script will now sign with the stable identity. Once rebuilt, you need to clear the stale TCC entry that macOS holds for the old ad-hoc binary — otherwise the System Settings toggle appears ON but applies to a different binary hash and the new build is still denied:

```bash
tccutil reset ScreenCapture app.noted.macos
```

Relaunch the app, click **Open System Settings** in the permission dialog, and toggle `noted` on. The grant is now tied to your stable signing identity and will survive future rebuilds.

## Credits

Runtime models and libraries:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet-TDT ASR, VAD, and offline diarization
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — local Whisper transcription
- Apple Speech via `SFSpeechRecognizer` — optional local backend

Historical upstream source and changelog material is retained in the local ignored `archive/` directory.

## License

[MIT](LICENSE)
