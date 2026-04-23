# HushScribe Source Triage for `noted`

**Single source of truth.** Keep/strip/rewrite calls live here, not in the Master Implementation Plan or the Initial Action Plan — both reference this file by pointer (`noted/hushscribe-triage.md`). If a call needs to change, change it here and update the dependency fallout note in the action plan if SPM dependencies shift.

This audit is based on the actual files under `HushScribe/Sources/HushScribe/`, checked against the master plan and supplemental guardrails. It also incorporates a critical comparison against the alternate draft in `/Users/dcroton/Desktop/hushscribe-triage-claude.md`.

## Scope

- Reviewed every file under `HushScribe/Sources/HushScribe/`.
- Cross-checked candidate `STRIP` files against actual references with `rg`.
- Verified there are no test targets or `Tests/` directories to account for.

## Buckets

- `KEEP`: can move to `noted` essentially intact.
- `STRIP`: delete outright; the file’s current responsibility does not belong in `noted`.
- `REWRITE`: the responsibility stays, but this file is too coupled to HushScribe’s current UI, storage, or state model to carry over as-is.

## Triage Table

| File | Bucket | Why |
| --- | --- | --- |
| `App/HushScribeApp.swift` | `REWRITE` | The app entry survives, but this file currently boots `ContentView`, `MeetingMonitor`, and `TranscriptStore` instead of a manifest-driven menubar runtime. |
| `App/StatusBarController.swift` | `REWRITE` | `noted` still needs a status item, but this controller is built around HushScribe’s popover/detached window modes, transcript viewer, and auto-detect toggle rather than the §6.4 menu and session actions. |
| `Assets/AppIcon.icns` | `REWRITE` | `noted` still needs app icon assets, but this file is HushScribe branding rather than `noted` branding. |
| `Assets/AppIcon.png` | `REWRITE` | Same reason: asset category stays, concrete asset should not. |
| `Assets/logo.svg` | `REWRITE` | The status item still needs a logo, but the current one is HushScribe-specific. |
| `Audio/MicCapture.swift` | `KEEP` | Low-level microphone capture is already isolated and matches `noted`’s in-person capture needs. |
| `Audio/SystemAudioCapture.swift` | `KEEP` | The ScreenCaptureKit capture layer is reusable for `online` mode; it has no summary or calendar logic, though its buffering destination will likely need integration tweaks later. |
| `HushScribe.entitlements` | `REWRITE` | `noted` will still need entitlements, but this file is tied to HushScribe’s identity and current permission surface. |
| `Info.plist` | `REWRITE` | `noted` still needs a plist, but bundle ID, product strings, and app identity must change. |
| `Models/Models.swift` | `REWRITE` | Shared types are still needed, but `Speaker.you/.them`, `Utterance`, and `SessionRecord` are shaped around HushScribe’s two-sided live transcript UI and JSONL session log rather than transcript segments and session-contract outputs. |
| `Models/RecordingState.swift` | `REWRITE` | The current `isRecording/isPaused` state is far smaller than the required §10 runtime model and also carries HushScribe-specific notification names. |
| `Models/SummaryModel.swift` | `STRIP` | Summary-model selection belongs to the removed MLX summary stack, not to `noted`. |
| `Models/TranscriptStore.swift` | `STRIP` | This file exists to support live transcript UI state; that UI is a non-goal, and the only hard dependency is the current `TranscriptionEngine`, which must be rewritten anyway. |
| `Services/LLMSummaryEngine.swift` | `STRIP` | Guardrail #4 explicitly removes LLM summarisation from `noted`, and this file only serves that purpose. |
| `Services/MeetingMonitor.swift` | `STRIP` | Guardrail #4 also forbids `noted` from inferring meetings; this file is pure HushScribe auto-detection logic. |
| `Services/SummaryService.swift` | `STRIP` | Apple NL summarisation is also out of scope and is only used by the stripped summary UI. |
| `Settings/AppSettings.swift` | `REWRITE` | Settings remain, but this file mixes summary config, meeting auto-detect, vault output, main-window mode, and `UserDefaults` persistence instead of the minimal TOML-backed §20.4 settings contract. |
| `Storage/SessionStore.swift` | `REWRITE` | Session storage stays, but the current actor only writes a flat JSONL utterance log and does not create the required session directory structure or runtime/completion files. |
| `Storage/TranscriptLogger.swift` | `REWRITE` | Transcript persistence stays, but this actor writes Obsidian-flavoured Markdown notes and summary side files instead of `transcript.txt`, `transcript.json`, and `segments.json` within a session directory. |
| `Transcription/ASRBackend.swift` | `KEEP` | The backend abstraction and the FluidAudio adapter already have the right shape for `noted`. |
| `Transcription/SFSpeechBackend.swift` | `KEEP` | This is a clean backend wrapper with no HushScribe-only UI or summary coupling. |
| `Transcription/StreamingTranscriber.swift` | `KEEP` | The VAD-plus-ASR streaming loop is core capture logic and is already isolated. |
| `Transcription/TranscriptionEngine.swift` | `REWRITE` | The orchestration role stays, but this file is tightly bound to `TranscriptStore`, file-import flow, HushScribe notifications, and current UI/storage assumptions rather than manifest/session-driven runtime control. |
| `Transcription/WhisperKitBackend.swift` | `KEEP` | This backend wrapper is already small and reusable. |
| `Views/ContentView.swift` | `STRIP` | The view itself does not belong in `noted`, but critical session orchestration currently lives here and must be extracted before deletion. |
| `Views/ControlBar.swift` | `STRIP` | This is HushScribe’s main-window recording control strip, replaced by menubar commands and popup actions in `noted`. |
| `Views/OnboardingView.swift` | `REWRITE` | First-run onboarding still exists, but the current steps are built around live transcript, AI summaries, and auto-record meeting detection. |
| `Views/SettingsView.swift` | `REWRITE` | A settings window survives, but most current tabs and controls are for removed concerns such as AI summaries and auto-detect. |
| `Views/SpeakerNamingView.swift` | `STRIP` | Manual post-session speaker naming is outside the planned `noted` UX and attribution policy. |
| `Views/SummarizeView.swift` | `STRIP` | Transcript viewer plus AI summary generation is explicitly outside `noted`’s scope. |
| `Views/TranscriptView.swift` | `STRIP` | Live transcript display is a stated non-goal, though this file does currently hide shared theme tokens that must be extracted first. |
| `Views/WaveformView.swift` | `REWRITE` | A level meter may still be useful, but this implementation is tied to the current theme tokens and includes mute controls that are not in the `noted` spec. |

## Comparison Notes

The alternate draft was useful in three places, and those points are incorporated here:

- `Views/ContentView.swift` is better classified as `STRIP`, not `REWRITE`, because the file itself does not survive even though important logic inside it must move first.
- `Views/TranscriptView.swift` does hide shared `Color` tokens used across the current UI, so stripping it without first extracting those tokens would break surviving/rewrite files.
- `Settings/AppSettings.swift` needs an explicit note that `SessionType` and `TranscriptionModel` must survive refactoring even though the summary and meeting-detection settings do not.

The alternate draft was too optimistic or incomplete in several places, and those calls are rejected here:

- It omits 5 required files from the task scope: `Assets/AppIcon.icns`, `Assets/AppIcon.png`, `Assets/logo.svg`, `HushScribe.entitlements`, and `Info.plist`.
- `Models/TranscriptStore.swift` is not a `KEEP`: it only exists for the live transcript UI, which the plan explicitly excludes.
- `Models/Models.swift` is not a `KEEP`: `Speaker.you/.them` is too narrow for `noted`’s transcript output contract.
- `Transcription/TranscriptionEngine.swift` is not a `KEEP`: the current file is deeply coupled to `TranscriptStore`, file import, and HushScribe notifications.
- `Views/WaveformView.swift` is not a `KEEP`: it depends on theme tokens defined in `TranscriptView.swift` and includes mute controls that do not map to the current `noted` UX.

## Strip-Safety Notes

### Summary stack

These files form a closed strip cluster:

- `Models/SummaryModel.swift`
- `Services/LLMSummaryEngine.swift`
- `Services/SummaryService.swift`
- `Views/SummarizeView.swift`

Current callers are all `STRIP` or `REWRITE` files:

- `Settings/AppSettings.swift`
- `Views/SettingsView.swift`
- `Views/ContentView.swift`
- `App/StatusBarController.swift`

No `KEEP` capture file references this stack.

### Meeting auto-detect

This file is safe to remove once app/menu wiring is rewritten:

- `Services/MeetingMonitor.swift`

Current callers:

- `App/HushScribeApp.swift`
- `Views/ContentView.swift`
- `App/StatusBarController.swift`

No `KEEP` file imports or references `MeetingMonitor`.

### Live transcript UI

These files are safe to remove only after the current orchestration and theme leakage are addressed:

- `Models/TranscriptStore.swift`
- `Views/ContentView.swift`
- `Views/ControlBar.swift`
- `Views/SpeakerNamingView.swift`
- `Views/SummarizeView.swift`
- `Views/TranscriptView.swift`

Important dependencies to replace first:

- `Transcription/TranscriptionEngine.swift` currently appends `Utterance` objects into `TranscriptStore`.
- `App/HushScribeApp.swift` and `App/StatusBarController.swift` both instantiate or pass through `TranscriptStore`.
- Multiple views currently depend on the `Color` extension defined in `Views/TranscriptView.swift`.

### Storage and engine boundary

These are not strip candidates even though their current formats are wrong:

- `Models/Models.swift`
- `Storage/SessionStore.swift`
- `Storage/TranscriptLogger.swift`
- `Transcription/TranscriptionEngine.swift`

They are the files that must absorb the manifest/session-directory/runtime/completion contract.

## Pre-Strip Extraction Checklist

These items should move before stripping starts:

1. Session orchestration from `Views/ContentView.swift`: `startSession`, `stopSession`, pause/resume, post-session diarization flow, and speaker-naming trigger points.
2. Theme tokens from `Views/TranscriptView.swift`: `Color.bg0`, `bg1`, `bg2`, `fg1`, `fg2`, `fg3`, `accent1`, `accent2`, `recordRed`.
3. Surviving enums from `Settings/AppSettings.swift`: `SessionType`, `MainWindowMode` if still wanted, and `TranscriptionModel`.

## Practical Build Order

Smallest safe path to a buildable stripped runtime:

1. Rewrite `Settings/AppSettings.swift`, `Models/RecordingState.swift`, `App/HushScribeApp.swift`, and `App/StatusBarController.swift` around the manifest-driven menubar model.
2. Extract session orchestration out of `Views/ContentView.swift` and theme tokens out of `Views/TranscriptView.swift`.
3. Rewrite `Models/Models.swift`, `Storage/SessionStore.swift`, `Storage/TranscriptLogger.swift`, and `Transcription/TranscriptionEngine.swift` around the session-directory contract.
4. Remove the summary stack, meeting auto-detect, and transcript-centric views.

## Independent Review

Independent checks run after drafting:

- Completeness: all 32 files under `HushScribe/Sources/HushScribe/` appear in the table.
- Task compliance: unlike the alternate draft, this document includes non-Swift files because the task asked for every file in the directory tree, not only `.swift` files.
- Test impact: there are no test targets in `Package.swift` and no `Tests/` directories, so triage does not change test count.
- Key build-risk check: no file classified as `KEEP` depends on the stripped summary stack or on `MeetingMonitor`.
