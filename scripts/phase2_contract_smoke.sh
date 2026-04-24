#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/HushScribe"
BIN="$PACKAGE_DIR/.build/debug/Noted"
FIXTURES="$ROOT_DIR/vendor/contracts/contracts/fixtures/manifests"
SMOKE_ROOT="${NOTED_CAPTURE_SMOKE_ROOT:-/tmp/noted-phase2-smoke}"

cd "$PACKAGE_DIR"
swift build

"$BIN" version >/dev/null

for fixture in "$FIXTURES"/valid-*.json; do
  "$BIN" validate-manifest --manifest "$fixture" >/dev/null
done

for fixture in "$FIXTURES"/invalid-*.json; do
  if "$BIN" validate-manifest --manifest "$fixture" >/dev/null; then
    echo "expected invalid manifest to fail: $fixture" >&2
    exit 1
  fi
done

DUP_ROOT="$(mktemp -d /tmp/noted-duplicate-start.XXXXXX)"
DUP_SESSION_ID="phase2-duplicate-$$"
DUP_MANIFEST="$DUP_ROOT/manifest.json"
DUP_SESSION_DIR="$DUP_ROOT/session"
mkdir -p "$DUP_SESSION_DIR/outputs"
printf '{"sentinel":true}\n' >"$DUP_SESSION_DIR/outputs/completion.json"
/usr/bin/python3 - "$FIXTURES/valid-adhoc.json" "$DUP_MANIFEST" "$DUP_SESSION_ID" "$DUP_SESSION_DIR" "$DUP_ROOT" <<'PY'
import json
import sys

source, target, session_id, session_dir, root = sys.argv[1:]
manifest = json.load(open(source, "r", encoding="utf-8"))
manifest["session_id"] = session_id
manifest["paths"]["session_dir"] = session_dir
manifest["paths"]["output_dir"] = f"{session_dir}/outputs"
manifest["paths"]["note_path"] = f"{root}/note.md"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
if "$BIN" start --manifest "$DUP_MANIFEST" >/tmp/noted-duplicate-start.json 2>/tmp/noted-duplicate-start.err; then
  echo "expected duplicate session_dir start to fail" >&2
  exit 1
fi
if ! grep -q '"sentinel":true' "$DUP_SESSION_DIR/outputs/completion.json"; then
  echo "duplicate start mutated existing completion.json" >&2
  exit 1
fi

if [[ "${NOTED_RUN_CAPTURE_SMOKE:-0}" != "1" ]]; then
  echo "Phase 2 fixture contract smoke passed. Live capture smoke skipped; set NOTED_RUN_CAPTURE_SMOKE=1 to run it."
  exit 0
fi

rm -rf "$SMOKE_ROOT"
mkdir -p "$SMOKE_ROOT/manifests" "$SMOKE_ROOT/sessions" "$SMOKE_ROOT/vault"

SESSION_ID="phase2-smoke-$(date +%Y%m%d%H%M%S)-$$"
MANIFEST="$SMOKE_ROOT/manifests/$SESSION_ID.json"
SESSION_DIR="$SMOKE_ROOT/sessions/$SESSION_ID"
CAPTURE_SECONDS="${NOTED_CAPTURE_SMOKE_SECONDS:-3}"
FAST_STOP_MAX_SECONDS="${NOTED_FAST_STOP_MAX_SECONDS:-15}"
OVERLAP_SESSION_DIR=""

/usr/bin/python3 - "$FIXTURES/valid-adhoc.json" "$MANIFEST" "$SESSION_ID" "$SESSION_DIR" "$SMOKE_ROOT" <<'PY'
import json
import sys
from datetime import datetime

source, target, session_id, session_dir, smoke_root = sys.argv[1:]
with open(source, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

now = datetime.now().astimezone().isoformat(timespec="seconds")
manifest["session_id"] = session_id
manifest["created_at"] = now
manifest["meeting"]["title"] = "Phase 2 smoke"
manifest["meeting"]["start_time"] = now
manifest["meeting"]["scheduled_end_time"] = None
manifest["meeting"]["timezone"] = datetime.now().astimezone().tzinfo.key if hasattr(datetime.now().astimezone().tzinfo, "key") else "Local"
manifest["paths"]["session_dir"] = session_dir
manifest["paths"]["output_dir"] = f"{session_dir}/outputs"
manifest["paths"]["note_path"] = f"{smoke_root}/vault/phase2-smoke.md"
manifest["transcription"]["asr_backend"] = "sfspeech"
manifest["transcription"]["diarization_enabled"] = False
manifest["hooks"]["completion_callback"] = None

with open(target, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

"$BIN" validate-manifest --manifest "$MANIFEST" >/dev/null

START_JSON="$("$BIN" start --manifest "$MANIFEST")"
/usr/bin/python3 - "$START_JSON" "$SESSION_ID" "$SESSION_DIR" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["ok"] is True, payload
assert payload["session_id"] == sys.argv[2], payload
assert payload["status"] == "recording", payload
assert payload["session_dir"] == sys.argv[3], payload
PY

sleep "$CAPTURE_SECONDS"

"$BIN" status --session-id "$SESSION_ID" >/tmp/noted-phase2-status.json
/usr/bin/python3 - /tmp/noted-phase2-status.json <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
assert payload["ok"] is True, payload
assert payload["status"] == "recording", payload
assert payload["phase"] == "capturing", payload
PY

STOP_STARTED="$(/usr/bin/python3 - <<'PY'
import time
print(time.monotonic())
PY
)"
STOP_JSON="$("$BIN" stop --session-id "$SESSION_ID")"
STOP_FINISHED="$(/usr/bin/python3 - <<'PY'
import time
print(time.monotonic())
PY
)"

/usr/bin/python3 - "$STOP_JSON" "$STOP_STARTED" "$STOP_FINISHED" "$FAST_STOP_MAX_SECONDS" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
elapsed = float(sys.argv[3]) - float(sys.argv[2])
limit = float(sys.argv[4])
assert payload["ok"] is True, payload
assert payload["status"] == "processing", payload
assert payload["audio_finalised"] is True, payload
assert elapsed <= limit, f"stop took {elapsed:.2f}s > {limit:.2f}s"
PY

if [[ -f "$SESSION_DIR/outputs/completion.json" ]]; then
  echo "completion.json existed at stop return" >&2
  exit 1
fi

if [[ ! -f "$SESSION_DIR/outputs/completion.json" ]]; then
  NEXT_SESSION_ID="$SESSION_ID-next"
  NEXT_MANIFEST="$SMOKE_ROOT/manifests/$NEXT_SESSION_ID.json"
  NEXT_SESSION_DIR="$SMOKE_ROOT/sessions/$NEXT_SESSION_ID"
  /usr/bin/python3 - "$MANIFEST" "$NEXT_MANIFEST" "$NEXT_SESSION_ID" "$NEXT_SESSION_DIR" <<'PY'
import json
import sys

source, target, session_id, session_dir = sys.argv[1:]
manifest = json.load(open(source, "r", encoding="utf-8"))
manifest["session_id"] = session_id
manifest["paths"]["session_dir"] = session_dir
manifest["paths"]["output_dir"] = f"{session_dir}/outputs"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  "$BIN" start --manifest "$NEXT_MANIFEST" >/tmp/noted-phase2-overlap.json
  /usr/bin/python3 - /tmp/noted-phase2-overlap.json "$NEXT_SESSION_ID" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
assert payload["ok"] is True, payload
assert payload["session_id"] == sys.argv[2], payload
PY
  sleep 1
  "$BIN" stop --session-id "$NEXT_SESSION_ID" >/dev/null
  OVERLAP_SESSION_DIR="$NEXT_SESSION_DIR"
else
  echo "Post-processing completed before overlap check; set NOTED_CAPTURE_SMOKE_SECONDS higher or enable a slower backend to exercise overlap."
fi

for _ in $(seq 1 180); do
  if [[ -f "$SESSION_DIR/outputs/completion.json" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "$SESSION_DIR/outputs/completion.json" ]]; then
  echo "completion.json was not written within timeout" >&2
  exit 1
fi

/usr/bin/python3 - "$SESSION_DIR" <<'PY'
import json
import pathlib
import sys

session = pathlib.Path(sys.argv[1])
required = [
    session / "manifest.json",
    session / "runtime/status.json",
    session / "logs/noted.log",
    session / "audio/raw_room.wav",
    session / "transcript/transcript.txt",
    session / "transcript/transcript.json",
    session / "outputs/completion.json",
]
missing = [str(path) for path in required if not path.exists()]
assert not missing, missing
assert (session / "audio/raw_room.wav").stat().st_size > 0

status = json.load(open(session / "runtime/status.json", "r", encoding="utf-8"))
assert status["status"] in {"completed", "completed_with_warnings", "failed"}, status
assert status["phase"] in {"finished", "failed_processing", "failed_startup", "failed_capture"}, status

completion = json.load(open(session / "outputs/completion.json", "r", encoding="utf-8"))
assert completion["schema_version"].startswith("1."), completion
assert completion["audio_capture_ok"] is True, completion
assert completion["transcript_ok"] is True, completion
assert completion["stop_reason"] == "manual_stop", completion
PY

if [[ -n "$OVERLAP_SESSION_DIR" ]]; then
  for _ in $(seq 1 180); do
    if [[ -f "$OVERLAP_SESSION_DIR/outputs/completion.json" ]]; then
      break
    fi
    sleep 1
  done
  if [[ ! -f "$OVERLAP_SESSION_DIR/outputs/completion.json" ]]; then
    echo "overlap session completion.json was not written within timeout" >&2
    exit 1
  fi
fi

echo "Phase 2 live capture smoke passed: $SESSION_DIR"
