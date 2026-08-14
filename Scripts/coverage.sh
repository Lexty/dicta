#!/usr/bin/env bash
# Line coverage for DictaCore, with a floor.
#
# DictaCore is where every decision lives as a pure value — the state machine, the sanitiser, the
# replacement engine, the record schema, the wire types (D19). Its tests ARE the executable form of
# §6, §8 and §9, so a hole in its coverage is a rule nobody is checking. The floor is 80% lines.
#
# `swift test --enable-code-coverage` is not available here for the same reason `swift test` is not
# a gate (D18): under Command Line Tools only there is no `xctest` host, so the instrumented bundle
# is built and never run, and the profile it would have written never exists. This drives the
# profile the same way the gate drives the tests — through DictaTestRunner's own entry point — and
# then uses llvm-profdata/llvm-cov straight from the CLT toolchain.
#
# Coverage of the OTHER targets is deliberately not floored. DictaRuntime is seams over AVFoundation,
# CoreML and subprocesses; a percentage there would count how much of the world's surface is
# name-checked in a fake, which is not a property worth defending.
#
# Usage:
#   bash Scripts/coverage.sh              # report DictaCore, fail under the floor
#   bash Scripts/coverage.sh --all        # also print every other target, for information only
#   bash Scripts/coverage.sh --floor 90   # a different floor
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FLOOR=80
SHOW_ALL=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --all) SHOW_ALL=1; shift ;;
        --floor)
            [ "$#" -ge 2 ] || { echo "coverage: --floor needs a percentage" >&2; exit 2; }
            FLOOR="$2"
            shift 2
            ;;
        *) echo "coverage: unknown argument: $1" >&2; exit 2 ;;
    esac
done

PROFDATA_TOOL="$(xcrun -f llvm-profdata)"
COV_TOOL="$(xcrun -f llvm-cov)"

echo "coverage: building DictaTestRunner with instrumentation"
swift build --enable-code-coverage --product DictaTestRunner >/dev/null
BIN="$(swift build --enable-code-coverage --show-bin-path)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "coverage: running the suite"
LLVM_PROFILE_FILE="$WORK/dicta.profraw" "$BIN/DictaTestRunner" >"$WORK/test.log" 2>&1 || {
    tail -20 "$WORK/test.log" >&2
    echo "coverage: the suite failed — coverage of a red suite means nothing" >&2
    exit 1
}
tail -1 "$WORK/test.log"

"$PROFDATA_TOOL" merge -sparse -o "$WORK/dicta.profdata" "$WORK/dicta.profraw"

echo
"$COV_TOOL" report "$BIN/DictaTestRunner" -instr-profile="$WORK/dicta.profdata" Sources/DictaCore

if [ -n "$SHOW_ALL" ]; then
    echo
    echo "coverage: every other target, for information only — no floor applies"
    "$COV_TOOL" report "$BIN/DictaTestRunner" -instr-profile="$WORK/dicta.profdata" \
        Sources/DictaIPC Sources/DictaRuntime
fi

# The TOTAL row's line-coverage percentage. `llvm-cov export` would be sturdier than parsing a
# table, but it emits every region of every file in the binary and the summary needs jq to reach;
# the report's own TOTAL row is one line and is what a human reads anyway.
# `|| true` so a missing TOTAL row is reported by the check below rather than by `set -e` exiting
# mid-pipeline with nothing said: under `set -o pipefail` the failing grep fails the substitution.
TOTAL_LINE="$("$COV_TOOL" report "$BIN/DictaTestRunner" \
    -instr-profile="$WORK/dicta.profdata" Sources/DictaCore | grep '^TOTAL' || true)"
# The percentages on the row are, in order: regions, functions, LINES, branches. Take the third by
# counting rather than the last one on the row — branches reports as "-" today, and a toolchain that
# starts emitting branch counters would silently move "the last percentage" onto a different metric.
PERCENT="$(awk '{
    n = 0
    for (i = 1; i <= NF; i++) {
        if ($i ~ /%$/) {
            n++
            if (n == 3) { gsub(/%/, "", $i); print $i; exit }
        }
    }
}' <<< "$TOTAL_LINE")"
if [ -z "$PERCENT" ]; then
    echo "coverage: could not read a percentage out of llvm-cov's TOTAL row" >&2
    exit 1
fi

echo
if awk -v p="$PERCENT" -v f="$FLOOR" 'BEGIN { exit !(p + 0 >= f + 0) }'; then
    echo "coverage: DictaCore at ${PERCENT}% lines — floor is ${FLOOR}%"
else
    echo "coverage: DictaCore at ${PERCENT}% lines — BELOW the ${FLOOR}% floor" >&2
    exit 1
fi
