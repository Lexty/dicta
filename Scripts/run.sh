#!/usr/bin/env bash
# Run the daemon in the foreground (step 1: fake capture, fake transcription, no microphone).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build -c release
exec ./.build/release/Dicta
