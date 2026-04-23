# noted

`noted` is the local macOS capture agent for the Meeting Intelligence System. It runs as a menubar app, records meeting audio, transcribes on device, runs post-session diarization, and writes session artefacts to disk for later ingestion by `briefing`.

This repository is currently in the stripped HushScribe baseline phase. The goal of this phase is a clean, buildable runtime that keeps capture, ASR, and diarization while removing everything that belongs to later system phases.

## What noted is

- A macOS 26+ Apple Silicon menubar app.
- A local audio capture and transcription agent.
- The owner of runtime recording state and post-session diarization.
- A producer of session artefacts under `~/Documents/noted/sessions` by default.

## What noted is not

- It does not read calendars.
- It does not decide which meetings should be recorded.
- It does not summarise transcripts or run LLMs.
- It does not write Obsidian notes.
- It does not include a transcript reader or editor UI.
- It does not ship a Homebrew cask yet.

Those responsibilities belong to `briefing` or later contract-driven phases.

## Build

Requirements:

- Apple Silicon Mac
- macOS 26+
- Xcode 26.3+ command line tools

```bash
cd HushScribe
swift build
```

There are no unit tests in this stripped baseline yet.

## Run

The app is an `LSUIElement` menubar app. Launching it should show only the menubar icon. The current menubar menu exposes:

- `Start`
- `Stop`
- `Status`
- `Settings`
- `Quit noted`

Manual sessions currently write:

- `session.json`
- `transcript.txt`
- `segments.json`
- `raw/microphone.wav`
- `raw/system.wav` when system-audio capture succeeds
- `diarization.json` when system-audio diarization succeeds

## Permissions

Changing the bundle identifier to `app.noted.macos` means macOS will prompt again for privacy permissions on first launch.

| Permission | Why |
| --- | --- |
| Microphone | Captures local speaker audio. |
| Screen Recording | Enables ScreenCaptureKit system-audio capture for online meetings. |
| Speech Recognition | Required only when using the Apple Speech backend. |

## Credits

`noted` starts from a squashed import of [HushScribe](https://github.com/drcursor/HushScribe), which is a fork of [Tome](https://github.com/Gremble-io/Tome) by Gremble-io and traces lineage to [OpenGranola](https://github.com/yazinsai/OpenGranola). Attribution and license notices are preserved in this repository.

Models and libraries retained in this stripped baseline:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference for Parakeet-TDT ASR, VAD, and offline diarization.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for local Whisper transcription.
- Apple Speech via `SFSpeechRecognizer` as an optional local backend.

## License

[MIT](LICENSE)
