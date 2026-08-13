#!/usr/bin/env bash
# The real test run. `swift test` is NOT a gate in a Command-Line-Tools-only environment: it
# compiles the bundle but cannot execute it, so a failing test still exits 0. The runner executable
# drives swift-testing directly and exits non-zero on the first failure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec swift run DictaTestRunner "$@"
