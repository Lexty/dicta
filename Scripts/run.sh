#!/usr/bin/env bash
# Run the daemon in the foreground, logging to stderr. This is the development path; the installed
# daemon runs from the signed .app bundle under a LaunchAgent (Task 8), because the microphone TCC
# grant attaches to that bundle identity and not to a bare executable (D11).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build -c release
exec ./.build/release/Dicta "$@"
