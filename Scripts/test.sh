#!/usr/bin/env bash
# The test gate.
#
# `swift test` is NOT a gate in a Command-Line-Tools-only environment (D18): it compiles the bundle
# but cannot execute it, so a failing test still exits 0. This runner drives swift-testing through
# its own entry point and exits non-zero on failure. Verified by experiment — see CLAUDE.md.
#
# Arguments are passed straight through to swift-testing, so a single suite can be run with
#   bash Scripts/test.sh --filter "sanitiser"
#
# The linker budget runs first, because no swift-testing assertion can reach it: D12 and §8.8 are
# properties of the LINKED `dictactl` binary, and the test runner deliberately links everything
# they forbid. It is here rather than in `lint.sh` so that "test.sh is the gate" stays true — the
# incremental build it costs is a second or two.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
bash Scripts/linkage.sh
exec swift run DictaTestRunner "$@"
