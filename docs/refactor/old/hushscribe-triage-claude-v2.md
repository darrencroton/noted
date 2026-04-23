# HushScribe → noted: Source File Triage

> Every file in `HushScribe/Sources/HushScribe/` assigned to **KEEP**, **STRIP**, or **REWRITE**.
> Reference: *Meeting Intelligence System — Master Implementation Plan* and *Supplemental Implementation Guardrails*.

## Legend

| Bucket    | Meaning |
|-----------|---------|
| **KEEP**    | Carries over to `noted` with no or trivial changes. |
| **STRIP**   | Removed entirely — functionality is out of scope for `noted` or moves to `briefing`. |
| **REWRITE** | The *concept* survives but the file needs substantial rework for `noted`'s architecture. |

---

## Triage Table

| # | Path | Bucket | Justification |
|---|------|--------|---------------|
| 1 | `App/HushScribeApp.swift` | **REWRITE** | Entry point stays, but must become `noted`'s menubar-only app — strip MeetingMonitor/SummarizeView/TranscriptStore creation, add manifest-driven lifecycle and CLI argument parsing. |
| 2 | `App/StatusBarController.swift` | **REWRITE** | Menubar controller survives, but menu items change entirely to §6.4 (Start, Stop, Status, Settings, Quit); popover/detached-window modes, transcript viewer item, and auto-record toggle all strip. |
| 3 | `Assets/AppIcon.icns` | **REWRITE** | `noted` needs an app icon, but this is HushScribe branding. |
| 4 | `Assets/AppIcon.png` | **REWRITE** | Same — asset category stays, concrete asset must change for `noted` identity. |
| 5 | `Assets/logo.svg` | **REWRITE** | Status-item logo survives, but current asset is HushScribe-specific. |
| 6 | `Audio/MicCapture.swift` | **KEEP** | Core mic capture via AVAudioEngine. Also defines shared helpers (`AudioLevel`, `AtomicBool`, `SyncString`) used by other files. No summary or meeting-detection dependencies. |
| 7 | `Audio/SystemAudioCapture.swift` | **KEEP** | ScreenCaptureKit system-audio capture needed for online-meeting mode. Clean of summary dependencies. |
| 8 | `HushScribe.entitlements` | **REWRITE** | `noted` still needs entitlements, but this file is tied to HushScribe's identity and current permission surface. |
| 9 | `Info.plist` | **REWRITE** | `noted` still needs a plist, but bundle ID, product strings, and app identity must change. |
| 10 | `Models/Models.swift` | **REWRITE** | `Speaker.you/.them` is a binary model shaped for the two-sided live-transcript chat UI; `noted`'s transcript segments need multi-speaker labels from diarization and manifest `participant_names`. `SessionRecord` is shaped for JSONL session logs, not the §11.1 session directory contract. |
| 11 | `Models/RecordingState.swift` | **REWRITE** | `isRecording`/`isPaused` bools must expand to §10.1 eight-state model (`idle → starting → recording → stopping → processing → completed → completed_with_warnings → failed`). Strip summary-specific notification names (`.hushscribeOpenSummarize`); keep/rename recording notifications. |
| 12 | `Models/SummaryModel.swift` | **STRIP** | Enum of on-device LLM model identifiers (Qwen, Gemma). All consumers (`LLMSummaryEngine`, `SettingsView` summary tab, `SummarizeView`) are also stripped. Removing this + `LLMSummaryEngine` eliminates the `mlx-swift-lm` package dependency. |
| 13 | `Models/TranscriptStore.swift` | **STRIP** | UI-state container for live transcript display (`volatileYouText`/`volatileThemText`, `utterances` array). Live transcript UI is a stated non-goal. `TranscriptionEngine` pushes to it at 4 sites, but that engine is being rewritten to output to session directory files instead. |
| 14 | `Services/LLMSummaryEngine.swift` | **STRIP** | On-device LLM inference via MLXLLM. Summarisation is `briefing`'s job (guardrail #4: noted stays dumb). Sole consumer of `mlx-swift-lm` dependency — stripping allows removing that package from `Package.swift`. |
| 15 | `Services/MeetingMonitor.swift` | **STRIP** | Watches for conferencing apps and polls CoreAudio to auto-detect meetings. Guardrail #4 forbids noted from interpreting meeting context — `briefing` owns calendar awareness. No KEEP file references it. |
| 16 | `Services/SummaryService.swift` | **STRIP** | Apple NaturalLanguage extractive summarisation. Its `extractTranscript(from:)` static method is only called by `SummarizeView` (also stripped), so removal is clean. |
| 17 | `Settings/AppSettings.swift` | **REWRITE** | Mixes summary config (`CustomSummaryPrompt`, `SummaryPromptSelection`, summary temperature/tokens/prompts), meeting auto-detect settings, and `UserDefaults` persistence with recording/transcription settings. Surgery required: strip summary + meeting-detection properties, keep `SessionType`/`TranscriptionModel` enums and recording settings, migrate to `settings.toml` per §20.4. |
| 18 | `Storage/SessionStore.swift` | **REWRITE** | Currently writes flat JSONL session logs. Must produce §11.1 session directory layout (`manifest.json`, `runtime/status.json`, `audio/`, `transcript/`, `completion.json`). The actor pattern is sound but the output format changes completely. |
| 19 | `Storage/TranscriptLogger.swift` | **REWRITE** | Writes `.md` files with YAML frontmatter; must write `transcript.txt`, `transcript.json`, `segments.json` per §15.5 instead. Strip `writeSummaryFile` method. Diarization rewrite and speaker-naming helpers survive conceptually but output format changes. |
| 20 | `Transcription/ASRBackend.swift` | **KEEP** | `ASRBackend` protocol + `FluidAudioASRBackend` wrapper. 17 lines, clean, no dependencies outside FluidAudio. |
| 21 | `Transcription/SFSpeechBackend.swift` | **KEEP** | Apple Speech (`SFSpeechRecognizer`) backend. 84 lines, clean. |
| 22 | `Transcription/StreamingTranscriber.swift` | **KEEP** | VAD + ASR streaming pipeline. Uses FluidAudio VadManager, `ASRBackend` protocol, `Speaker` enum. Core transcription asset with no summary dependencies. |
| 23 | `Transcription/TranscriptionEngine.swift` | **REWRITE** | The dual-stream orchestration role stays, but this file is deeply coupled to `TranscriptStore` (constructor dependency, 4+ push sites), posts HushScribe-specific notifications, and contains a file-import flow. Must be rewired to output to session directory files and integrate with the manifest-driven lifecycle. |
| 24 | `Transcription/WhisperKitBackend.swift` | **KEEP** | Simple WhisperKit ASR wrapper. 17 lines, clean. |
| 25 | `Views/ContentView.swift` | **STRIP** | 802-line main window view. **Critical extraction required first**: session orchestration logic (`startSession`, `stopSession`, pause/resume, post-session diarization flow, speaker-naming trigger) is embedded in this view and must be relocated before stripping. The view itself (transcript panel, control bar, onboarding overlay) is replaced by noted's menubar UX. |
| 26 | `Views/ControlBar.swift` | **STRIP** | Record/pause/stop button bar. Replaced by menubar menu items in noted (§6.4). `PulsingDot` helper view is self-contained and only used here. |
| 27 | `Views/OnboardingView.swift` | **REWRITE** | 7-step wizard. Remove AI Summary and Auto-Record steps; update remaining steps for noted's simpler permissions and legal flow. Core structure (multi-step wizard with progress) is reusable. |
| 28 | `Views/SettingsView.swift` | **REWRITE** | 832-line tabbed settings with 7 tabs. Strip: Meetings tab, AI Summaries model subtab, summary-related controls. Keep: Recording, Transcription model selection, Output, Privacy, About. Reduce to §20.4 minimal setting set. |
| 29 | `Views/SpeakerNamingView.swift` | **STRIP** | Post-session speaker name assignment UI. `noted` writes generic speaker labels; speaker attribution is `briefing`'s responsibility per §16.3. |
| 30 | `Views/SummarizeView.swift` | **STRIP** | 855-line transcript viewer + AI summary generation. Explicitly out of scope per master plan. References only other stripped files (`LLMSummaryEngine`, `SummaryModel`, `SummaryService`, `TranscriptLogger.writeSummaryFile`). |
| 31 | `Views/TranscriptView.swift` | **STRIP** | Live transcript chat-bubble view. **Critical extraction required first**: defines `Color` design tokens (`bg0`, `bg1`, `bg2`, `fg1`, `fg2`, `fg3`, `accent1`, `accent2`, `recordRed`) used by surviving REWRITE views — must be extracted to a shared file before stripping. |
| 32 | `Views/WaveformView.swift` | **REWRITE** | VU meter concept survives for status panel (§6.4), but this file depends on `Color` design tokens from `TranscriptView.swift` (lines 23, 28, 37, 50) and includes `isMicMuted`/`isSysMuted` mute-button controls (lines 7–10, 20–49) not in the noted spec. |

---

## Summary

| Bucket | Count | Files |
|--------|-------|-------|
| **KEEP** | 6 | MicCapture, SystemAudioCapture, ASRBackend, SFSpeechBackend, StreamingTranscriber, WhisperKitBackend |
| **STRIP** | 10 | SummaryModel, TranscriptStore, LLMSummaryEngine, MeetingMonitor, SummaryService, ContentView, ControlBar, SpeakerNamingView, SummarizeView, TranscriptView |
| **REWRITE** | 16 | HushScribeApp, StatusBarController, AppIcon.icns, AppIcon.png, logo.svg, HushScribe.entitlements, Info.plist, Models, RecordingState, AppSettings, SessionStore, TranscriptLogger, TranscriptionEngine, OnboardingView, SettingsView, WaveformView |

---

## Strip-Safety Analysis

### Summary stack (closed cluster — safe to strip together)

Files: `SummaryModel.swift`, `LLMSummaryEngine.swift`, `SummaryService.swift`, `SummarizeView.swift`

Current callers are all STRIP or REWRITE files: `AppSettings.swift`, `SettingsView.swift`, `ContentView.swift`, `StatusBarController.swift`. No KEEP file references this stack.

### Meeting auto-detect (safe once app/menu wiring is rewritten)

File: `MeetingMonitor.swift`

Current callers: `HushScribeApp.swift`, `ContentView.swift`, `StatusBarController.swift` — all REWRITE or STRIP. No KEEP file imports or references `MeetingMonitor`.

### Live transcript UI (extraction required before stripping)

Files: `TranscriptStore.swift`, `ContentView.swift`, `ControlBar.swift`, `SpeakerNamingView.swift`, `SummarizeView.swift`, `TranscriptView.swift`

Dependencies to resolve first:
- `TranscriptionEngine.swift` (REWRITE) takes `TranscriptStore` as a constructor dependency and pushes to it at 4 sites — must be rewired to file-based output.
- `HushScribeApp.swift` and `StatusBarController.swift` (both REWRITE) instantiate or pass `TranscriptStore`.
- Multiple surviving REWRITE views depend on the `Color` extension in `TranscriptView.swift`.

### Storage and engine boundary (not strip candidates)

Files: `Models.swift`, `SessionStore.swift`, `TranscriptLogger.swift`, `TranscriptionEngine.swift`

These are REWRITE, not STRIP — they absorb the manifest/session-directory/runtime/completion contract.

---

## Pre-Strip Extraction Checklist

These items **must** be extracted before their parent files are stripped:

1. **Session orchestration logic from `ContentView.swift`** — `startSession`, `stopSession`, pause/resume, post-session diarization flow, speaker-naming trigger. Relocate to a new `SessionController` or into the rewritten `TranscriptionEngine`.

2. **Color design tokens from `TranscriptView.swift`** — The `Color` extension (`bg0`, `bg1`, `bg2`, `fg1`, `fg2`, `fg3`, `accent1`, `accent2`, `recordRed`) is used by `OnboardingView`, `SettingsView`, `WaveformView`, and other surviving views. Extract to a shared `Theme.swift`.

3. **`SessionType` and `TranscriptionModel` enums from `AppSettings.swift`** — These are used by `TranscriptionEngine`, `TranscriptLogger`, and others. They survive the rewrite but must not be accidentally removed when stripping summary-related types from the same file.

4. **`TranscriptStore` dependency from `TranscriptionEngine.swift`** — The engine's transcript output must be redirected from `TranscriptStore` (UI state) to session directory file writes before `TranscriptStore` can be stripped.

---

## Dependency Removals

Stripping `LLMSummaryEngine.swift` + `SummaryModel.swift` enables removing from `Package.swift`:
- `mlx-swift-lm` (and its transitive dependency `mlx-swift`)

This significantly reduces binary size and compile time.

---

## Test Impact

HushScribe has **no test targets** — `Package.swift` defines only one `executableTarget`. No test files are affected by any triage decision. Adding a test target for `noted` is recommended as part of the rewrite phase.

---

## Practical Build Order

Smallest safe path to a buildable stripped runtime:

1. Rewrite `AppSettings.swift`, `RecordingState.swift`, `HushScribeApp.swift`, and `StatusBarController.swift` around the manifest-driven menubar model.
2. Extract session orchestration out of `ContentView.swift` and theme tokens out of `TranscriptView.swift`.
3. Rewrite `Models.swift`, `SessionStore.swift`, `TranscriptLogger.swift`, and `TranscriptionEngine.swift` around the session-directory contract (redirecting transcript output from `TranscriptStore` to files).
4. Remove the summary stack, meeting auto-detect, `TranscriptStore`, and transcript-centric views.

---

## Review Questions

| Question | Answer |
|----------|--------|
| Can every STRIP file be deleted without breaking a KEEP file's compilation? | **Yes.** No KEEP file references any STRIP file. The 6 KEEP files (MicCapture, SystemAudioCapture, ASRBackend, SFSpeechBackend, StreamingTranscriber, WhisperKitBackend) are all clean transcription infrastructure with no UI, summary, or meeting-detection imports. |
| Are there shared types that live in a STRIP file but are imported by a REWRITE file? | **Yes — two cases.** (1) `Color` design tokens in `TranscriptView.swift` are used by REWRITE views. (2) `TranscriptStore` is a constructor dependency of `TranscriptionEngine` (REWRITE). Both covered in extraction checklist. |
| Does stripping change the test target count? | **No** — there are no test targets. |
| Which REWRITE files are on the critical path for Phase 2 (Minimal noted runtime)? | `RecordingState` (state machine), `HushScribeApp` (CLI entry), `SessionStore` (session directory layout), `StatusBarController` (menu items), `TranscriptionEngine` (transcript output rewiring). |
| Is every file in the source tree accounted for? | **Yes** — 32 files confirmed via glob, 32 rows in the table. |
