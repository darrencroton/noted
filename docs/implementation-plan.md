# noted Implementation Plan

This plan turns the system-level Meeting Intelligence System plan into `noted` engineering tickets. It covers master-plan phases 2 through 5 for the Swift capture agent.

Authoritative inputs:

- `../hushscribe-triage.md`
- `../ARCHITECTURE.md`
- `../vendor/contracts/CONTRACTS_TAG` pinned to `v1.0.1`
- `../vendor/contracts/contracts/cli-contract.md`
- `../vendor/contracts/contracts/session-directory.md`
- `../vendor/contracts/contracts/schemas/manifest.v1.json`
- `../vendor/contracts/contracts/schemas/completion.v1.json`
- `../vendor/contracts/contracts/schemas/runtime-status.v1.json`

## Contracts Consumption

This plan assumes the current copied-snapshot mechanism: `vendor/contracts/CONTRACTS_TAG` records the pinned release tag and `vendor/contracts/contracts/` contains the checked-in contract snapshot. Confirm this with the dev team before cutting tickets. If the team switches to a submodule or fetch-at-test-time mechanism, update the paths in this plan first so issues do not cite stale locations.

## Scope Boundaries

`noted` owns manifest execution, local capture, ASR, diarization, runtime state, completion output, menubar UI, and popup actions.

`noted` must not read calendars, infer meeting eligibility, compute next meetings, summarize transcripts, write Obsidian notes, or interpret meeting context. Calendar-driven manifests are written by `briefing`; only ad hoc sessions may be normalized into a full canonical manifest locally.

## Cross-Repo Dependency Map

| System phase | noted work | briefing work | Blocks / blocked by |
| --- | --- | --- | --- |
| Phase 2: Minimal `noted` Runtime | CLI, manifest validation, session directory writer, in-person capture, fast stop, async post-processing, completion file | None required beyond locked contracts | Blocks real Phase 4 end-to-end ingestion; `briefing` can build against fixtures before this is complete |
| Phase 3: End-of-Meeting UX | Popup, `extend`, `switch-next`, auto-stop, auto-switch, UI state persistence | `session-plan` must pre-write next manifests for realistic switch testing | Depends on Phase 2; blocks polished back-to-back flow |
| Phase 4: `briefing` Integration | Completion handoff invokes `briefing session-ingest`; switch-next consumes pre-prepared manifests | `session-plan`, `session-ingest`, `watch`, transcript adapter, summary block writer | Depends on Phase 2; Phase 3 needed for full back-to-back UX, but not for first ingest slice |
| Phase 5: Hardening | Crash recovery, diagnostics, online/hybrid capture, retention hooks | `session-reprocess`, retention policy, operator diagnostics | Depends on real Phase 4 usage data; plan only at broad stroke now |

## Estimates

Estimates are days of focused work, not elapsed calendar time. They include implementation and local tests, but not review wait time or exploratory product review.

## Phase 2 - Minimal Runtime

Goal: A real in-person meeting can be recorded from the CLI with a valid manifest. `stop` returns promptly after audio is flushed. Post-processing finishes asynchronously and writes transcript artefacts plus `outputs/completion.json`.

### Acceptance Criteria

- `noted validate-manifest --manifest <path>` validates all shared manifest fixtures and exits `0` for valid fixtures, `2` for invalid fixtures.
- `hooks.completion_callback` is accepted only when absent or `null`; non-null callbacks remain invalid/reserved in v1.
- `noted start --manifest <path>` validates, creates the canonical session tree, copies the manifest to `<session_dir>/manifest.json`, writes `runtime/status.json`, writes `logs/noted.log`, plays the recording-start bell, starts in-person room-mic capture, and returns one JSON line matching `cli-contract.md`.
- `noted stop --session-id <id>` stops capture, flushes raw audio to `audio/raw_room.wav`, transitions to `processing`, returns before ASR or diarization completes, and does not write `completion.json` synchronously.
- Async post-processing writes `transcript/transcript.txt`, `transcript/transcript.json`, optional `transcript/segments.json`, `diarization/diarization.json` when available, and finally `outputs/completion.json`.
- `completion.json` validates against `completion.v1.json` and is the only terminal outcome source.
- `runtime/status.json` validates against `runtime-status.v1.json` at each stable phase.
- Only one active capture is permitted; starting a second capture exits `5`.
- All emitted timestamps are ISO-8601 with explicit offsets.
- A CLI-only smoke test can record a short local session using the fixture manifest shape without any `briefing` process running.
- The inherited menubar Start action must not create legacy/noncanonical session output in Phase 2. It is hidden, disabled, or routed to a clear "not available until ad hoc manifests ship" path until N-23 implements canonical ad hoc manifests.

### Tickets

| Ticket | Title | Estimate | Dependencies | Acceptance notes |
| --- | --- | ---: | --- | --- |
| N-01 | Add CLI entrypoint and command router | 2 days | Current Swift package | Provides Phase 2 commands: `start`, `stop`, `status`, `validate-manifest`, `version`; `extend` and `switch-next` arrive in Phase 3 and must not silently no-op before then; stdout is one JSON line; diagnostics go to stderr |
| N-02 | Implement contract snapshot lookup | 1 day | `vendor/contracts` | Version command reports app version plus manifest/completion schema versions from pinned contracts |
| N-02a | Implement TOML settings layer | 3 days | Current Swift package | Replaces remaining UserDefaults-backed runtime settings with `~/Library/Application Support/noted/settings.toml`; includes `host_name`, `language`, `asr_backend`, `asr_model_variant`, default input device, and `output_root` |
| N-03 | Implement manifest models and validator | 3 days | N-01, N-02 | Parses major-1 manifests, rejects missing required fields, rejects naive timestamps, accepts absent/null `hooks.completion_callback`, covers shared valid/invalid fixtures |
| N-04 | Rewrite session storage for canonical directory layout | 3 days | N-03 | Creates `runtime/`, `audio/`, `transcript/`, `diarization/`, `outputs/`, `logs/`; never writes outside `session_dir` except reserved note path |
| N-05 | Implement runtime status writer | 2 days | N-04 | Atomic rewrites of `runtime/status.json` on every state/phase transition; schema-valid output |
| N-06 | Adapt in-person capture to `room_mic` contract | 3 days | N-02a, N-04 | Writes `audio/raw_room.wav`; handles configured default input device from settings; startup failures produce contract-shaped errors |
| N-07 | Add recording-start bell | 1 day | N-06 | Bell plays at actual capture start, between `acquiring_audio_resources` and `capturing`; no user-toggleable setting |
| N-08 | Implement fast stop and background processor handoff | 4 days | N-05, N-06 | `stop` returns after raw audio flush; ASR/diarization continue while the app can accept the next capture |
| N-09 | Adapt ASR and diarization outputs | 6 days | N-02a, N-08 | Swift stack uses configured `asr_backend` and `asr_model_variant`; produces `transcript.txt`, `transcript.json`, optional `segments.json`, and diarization output; diarization failure degrades with warning. Re-estimate after the storage/engine rewrite is started because this is likely the densest adaptation work |
| N-10 | Implement completion writer | 2 days | N-08, N-09 | Writes schema-valid completion after processing; maps stop reasons to terminal status per `session-directory.md` |
| N-11 | Enforce active-capture concurrency | 2 days | N-01, N-08 | Second `start` during active capture exits `5`; post-processing may overlap a later capture |
| N-12 | Minimal menubar state bridge | 2 days | N-05 | Menubar shows idle, recording, processing, done/failed without exposing transcript or summary UI |
| N-13 | Phase 2 contract and smoke tests | 4 days | N-02a, N-03 through N-12 | Shared fixtures pass; short capture smoke verifies raw audio, transcript, status, completion, and fast-stop behavior |

Phase 2 focused estimate: 36 days.

### Phase 2 Open Questions

- What is the exact Swift JSON Schema validation approach: library, generated validator, or hand-written validator constrained to v1? Pick the cheapest option that can run fixture tests deterministically.
- What is the acceptable fast-stop upper bound for local tests? The contract says prompt return; the team should choose a concrete threshold before writing performance tests.

## Phase 3 - End-of-Meeting UX

Goal: Scheduled sessions prompt before the planned end, and every popup action uses the same path as the CLI. Back-to-back handoff works from pre-prepared manifests without involving calendar logic.

### Acceptance Criteria

- For a manifest with `meeting.scheduled_end_time`, `noted` beeps and shows the popup at `scheduled_end_time - recording_policy.pre_end_prompt_minutes`.
- Popup buttons map to `stop`, `extend`, and `switch-next` behavior with no GUI-only logic.
- `extend` updates `runtime/status.json.scheduled_end_time` and `current_extension_minutes`, then re-prompts with the simpler continued-meeting flow described in the master plan.
- `switch-next` stops the current capture with `stop_reason: auto_switch_to_next_meeting`, invokes `noted start --manifest <next_manifest_path>`, and returns exit `8` if the manifest is missing or invalid after stopping the current session normally.
- If the user takes no action, auto-stop or auto-switch follows the manifest policy and `no_interaction_grace_minutes`.
- `runtime/ui_state.json` persists prompt display history and button events. `briefing` does not need to read it.

### Tickets

| Ticket | Title | Estimate | Dependencies | Acceptance notes |
| --- | --- | ---: | --- | --- |
| N-14 | Implement prompt scheduler | 2 days | Phase 2 | Handles null `scheduled_end_time` by suppressing prompt for ad hoc sessions |
| N-15 | Build end-of-meeting popup UI | 3 days | N-14 | Stop, +5, and Next Meeting buttons are shown only when policy and manifest allow |
| N-16 | Implement `extend` command and shared action path | 3 days | N-15 | Idempotent within a popup cycle; updates status JSON with explicit-offset timestamp |
| N-17 | Implement `switch-next` command and shared action path | 4 days | N-15 | Starts pre-prepared manifest directly; handles missing/invalid next manifest with exit `8` and warning |
| N-18 | Implement auto-stop and auto-switch timers | 3 days | N-14, N-17 | Honors `no_interaction_grace_minutes` and next-meeting availability |
| N-19 | Persist `runtime/ui_state.json` | 2 days | N-15 through N-18 | Menubar restart does not lose popup/action history |
| N-20 | Back-to-back integration tests | 4 days | N-17, N-18 | Next capture starts within 2 seconds of current capture stopping in the happy path |

Phase 3 focused estimate: 21 days.

### Phase 3 Open Questions

- How should the UI surface the "next manifest missing" case after `switch-next` exit `8`?
- What test harness controls clock time for scheduled prompts without waiting in real time?

## Phase 4 - briefing Integration Support

Goal: `noted` completes its side of the integration by handing finished sessions to `briefing session-ingest` and consuming manifests written by `briefing session-plan` and maintained by `briefing watch`.

### Acceptance Criteria

- On post-processing completion, after `outputs/completion.json` is fully written, `noted` invokes `briefing session-ingest --session-dir <session_dir>` per the master-plan decision.
- Handoff failures are logged in `logs/noted.log` and do not mutate `completion.json`.
- `noted` continues to launch only from manifests; it never calls calendar APIs or computes next meetings.
- Back-to-back handoff works when `briefing` pre-writes `next_meeting.manifest_path`.
- Ad hoc sessions use the same manifest schema, with permitted nulls, and can be ingested by `briefing` through the no-series path.

### Tickets

| Ticket | Title | Estimate | Dependencies | Acceptance notes |
| --- | --- | ---: | --- | --- |
| N-21 | Add configurable `briefing` command invocation | 2 days | Phase 2 | Supports path/command override in settings; logs command, exit code, stdout/stderr location |
| N-22 | Invoke `briefing session-ingest` after completion | 2 days | N-10, N-21 | Completion is present before invocation; failures are recoverable by manual command |
| N-23 | Implement ad hoc full-manifest writer | 4 days | N-03, N-04 | Menubar Start creates a canonical manifest with allowed nulls and defaults from `noted` settings |
| N-24 | Integration fixture with `briefing` | 3 days | N-22 plus `briefing session-ingest` | End-to-end local test uses a completed session directory and verifies ingest is called once |
| N-25 | Switch-next race handling with `briefing watch` invalidation | 2 days | N-17 | Missing/deleted next manifest degrades as the contract describes |

Phase 4 support focused estimate: 13 days.

### Phase 4 Open Questions

- Should `noted` retry `briefing session-ingest` on non-zero exit, or should retry be operator/manual only for v1?
- Where should `noted` store stdout/stderr from the ingest command: `logs/noted.log` only or separate files under `logs/`?

## Phase 5 - Hardening

Do not break this into detailed tickets yet. Use real Phase 2-4 failures to shape it.

Broad work areas:

- Crash recovery for sessions that have raw audio but no terminal completion.
- Operator diagnostics for permissions, model availability, device selection, and post-processing failures.
- Retention support aligned with the 30-day raw-audio plus FLAC policy.
- Diarization quality review against real meetings and the decision trigger in the master plan.
- Online and hybrid mode using CoreAudio Tap with ScreenCaptureKit fallback.
- Optional `wait`, `list-sessions`, `tail-log`, and `resume` CLI commands if they prove useful during integration.

Phase 5 should not begin until the first real Phase 4 vertical slice has produced enough operational data to rank risks.

## Tickets in the First Vertical Slice

The full Phase 2-4 estimate is not the Step 7 estimate. Step 7 should prove the narrowest useful path before polishing the whole surface.

Minimum `noted` slice:

- N-01 through N-08.
- N-09 as a thin path: produce `transcript.txt` and `transcript.json`; diarization may be disabled or fail with a warning as long as `completion.json` reflects that truthfully.
- N-10 and N-11.
- N-13 focused on CLI contract tests and one short real capture.

Nice-to-have for the same slice, but not required to prove the runtime boundary:

- N-12 if menubar state is needed for the demo.
- N-21 and N-22 if the Step 7 goal is automatic completion handoff rather than manually running `briefing session-ingest`.

Explicitly out of the first slice:

- Phase 3 popup work.
- N-23 canonical ad hoc menubar Start. Until this lands, menubar Start must not create legacy output.
- Online/hybrid capture.

## Tickets That Can Start Tomorrow

- N-01 CLI entrypoint and router.
- N-02 contract snapshot lookup.
- N-02a TOML settings layer.
- N-03 manifest models and validator, if the validation approach is chosen.

## Highest-Risk Assumptions

- Fast stop plus overlapping post-processing will be reliable with Swift ASR/diarization on the target Mac.
- Contract validation in Swift can be kept strict enough without turning into a large schema-engine project.
- Current HushScribe capture code can be adapted to the canonical directory layout without destabilizing audio capture.
- Back-to-back handoff timing is achievable while previous-session post-processing is active.

Cheapest ways to test these:

- Build a CLI-only Phase 2 spike before any popup work.
- Record and stop a 30-second real capture repeatedly, measuring return time and artefact completeness.
- Run ASR/diarization post-processing while starting a second capture.

## Review Questions

- Which Phase 2 tickets are too large to become GitHub issues as written?
- Which ticket could the dev team start tomorrow without waiting on `briefing`?
- Which failure mode would hurt most if the contract shape is wrong: invalid manifests, missing completion files, or slow stop?
- What assumptions about Swift validation, audio devices, or async processing could turn out false, and what is the cheapest test?
