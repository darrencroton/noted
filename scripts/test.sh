#!/bin/bash
set -euo pipefail

rm -rf dist/Noted.app
scripts/release.sh test
defaults delete app.noted.macos 2>/dev/null || true
dist/Noted.app/Contents/MacOS/Noted
