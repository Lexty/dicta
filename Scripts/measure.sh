#!/usr/bin/env bash
# Scores step 2's criterion (a) with numbers rather than impressions: keypress to "recording",
# warm, over N consecutive attempts, against a 150 ms budget (F4).
#
# WHAT IS MEASURED, exactly: the wall time of one `dictactl toggle` invocation — process start to
# process exit — for a chord that begins an attempt. The daemon performs every effect of the start
# BEFORE it answers, so that interval contains the whole cost the user waits through: dictactl's own
# cold start, the socket round trip, `agtermctl tree --json` (38 ms of it, F3/F4), opening the input
# device, and §6's "listening" indicator. It ends a hair after the daemon reached `recording`, so the
# number is an upper bound on keypress-to-recording rather than an optimistic slice of it.
#
# Note what the toggle PRINTS is `warming`: the response carries the state as of the transition that
# started the attempt, and capture confirms afterwards. That is why every attempt is confirmed with a
# separate `dictactl status`, and an attempt whose status is not `recording` is reported as a failure
# rather than quietly averaged in.
#
# Each attempt is ended with `abort`, never with a second toggle: aborting delivers nothing, so
# running this does not type ten transcripts into the user's input line.
#
# The first attempt is a discarded warm-up. Cold start was ~390 ms on the deleted skeleton against
# ~20-70 ms warm (F4), and averaging the two would report a number that describes neither.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ATTEMPTS=10
BUDGET_MS=150
SPEAK=0.4
SESSION="${AGT_SESSION_ID:-}"
AGTERM_SOCKET="${AGT_SOCKET:-}"
CONTROL=""
DICTACTL=""

usage() {
    cat <<'EOF'
usage: measure.sh [options]

options:
  -n <count>        attempts to measure, after one discarded warm-up (default 10)
  --budget <ms>     the budget each attempt is scored against (default 150, F4)
  --speak <secs>    how long each attempt records before aborting (default 0.4)
  --session <id>    the agterm session to dictate into (default "$AGT_SESSION_ID")
  --socket <path>   agterm's control socket (default "$AGT_SOCKET")
  --control <path>  dicta's own control socket
  --dictactl <path> the client to time (default: the release build, then ~/.local/bin)
  --help            print this
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n) ATTEMPTS="$2"; shift 2 ;;
        --budget) BUDGET_MS="$2"; shift 2 ;;
        --speak) SPEAK="$2"; shift 2 ;;
        --session) SESSION="$2"; shift 2 ;;
        --socket) AGTERM_SOCKET="$2"; shift 2 ;;
        --control) CONTROL="$2"; shift 2 ;;
        --dictactl) DICTACTL="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'measure: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$DICTACTL" ]; then
    for candidate in "$ROOT/.build/release/dictactl" "$HOME/.local/bin/dictactl"; do
        if [ -x "$candidate" ]; then
            DICTACTL="$candidate"
            break
        fi
    done
fi
if [ -z "$DICTACTL" ]; then
    DICTACTL="$(command -v dictactl || true)"
fi
if [ -z "$DICTACTL" ] || [ ! -x "$DICTACTL" ]; then
    printf 'measure: no dictactl to time — build one (swift build -c release) or pass --dictactl\n' >&2
    exit 3
fi

if [ -z "$SESSION" ]; then
    printf 'measure: no session — run this inside agterm, or pass --session <id>\n' >&2
    exit 3
fi

# Shared by every invocation, so an attempt cannot be measured against a different daemon or a
# different agterm than the one it was confirmed against.
ARGS=()
if [ -n "$AGTERM_SOCKET" ]; then
    ARGS+=(--socket "$AGTERM_SOCKET")
fi
if [ -n "$CONTROL" ]; then
    ARGS+=(--control "$CONTROL")
fi

now_ms() {
    # `date` on macOS has no %N. perl is always here, and Time::HiRes is core.
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time * 1000'
}

state() {
    "$DICTACTL" status "${ARGS[@]}" 2>/dev/null || echo "unreachable"
}

wait_for_idle() {
    for _ in $(seq 1 100); do
        [ "$(state)" = "idle" ] && return 0
        sleep 0.05
    done
    return 1
}

# One attempt. Prints the elapsed milliseconds on stdout, or nothing when the attempt did not reach
# `recording` — a failed attempt is reported, never silently averaged in.
attempt() {
    local start finish elapsed reached
    start="$(now_ms)"
    "$DICTACTL" toggle --mode clean --session "$SESSION" "${ARGS[@]}" >/dev/null 2>&1 || true
    finish="$(now_ms)"
    elapsed="$(perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$start" "$finish")"
    reached="$(state)"
    sleep "$SPEAK"
    # Never a second toggle: that would deliver a transcript into the input line every attempt.
    "$DICTACTL" abort "${ARGS[@]}" >/dev/null 2>&1 || true
    wait_for_idle || printf 'measure: attempt did not return to idle\n' >&2
    if [ "$reached" != "recording" ]; then
        printf 'measure: attempt reached "%s", not "recording" — %s ms not counted\n' \
            "$reached" "$elapsed" >&2
        return 1
    fi
    printf '%s\n' "$elapsed"
}

if [ "$(state)" = "unreachable" ]; then
    printf 'measure: the daemon is not answering — start it (Scripts/run.sh) first\n' >&2
    exit 3
fi
wait_for_idle || { printf 'measure: the daemon is busy; nothing was measured\n' >&2; exit 3; }

printf 'measure: %s attempts into session %s, budget %s ms\n' "$ATTEMPTS" "$SESSION" "$BUDGET_MS"
printf 'measure: warm-up (discarded, cold start is ~390 ms and describes nobody)\n'
attempt >/dev/null || true

SAMPLES=()
FAILED=0
for i in $(seq 1 "$ATTEMPTS"); do
    if ms="$(attempt)"; then
        SAMPLES+=("$ms")
        printf '  attempt %2s: %8s ms\n' "$i" "$ms"
    else
        FAILED=$((FAILED + 1))
        printf '  attempt %2s: FAILED\n' "$i"
    fi
done

if [ "${#SAMPLES[@]}" -eq 0 ]; then
    printf 'measure: no attempt reached recording — nothing to report\n' >&2
    exit 1
fi

printf '\n'
printf '%s\n' "${SAMPLES[@]}" | sort -n | awk -v budget="$BUDGET_MS" -v failed="$FAILED" '
    { v[NR] = $1; sum += $1 }
    END {
        median = (NR % 2) ? v[int(NR / 2) + 1] : (v[NR / 2] + v[NR / 2 + 1]) / 2
        p90 = v[int((NR * 0.9) + 0.999999)]
        over = 0
        for (i = 1; i <= NR; i++) if (v[i] > budget) over++
        printf "measure: n=%d  min=%.1f  median=%.1f  p90=%.1f  max=%.1f  mean=%.1f (ms)\n", \
            NR, v[1], median, p90, v[NR], sum / NR
        # The criterion is every attempt under the budget, not the average under it: one 400 ms
        # chord in ten is exactly the experience the budget exists to forbid.
        if (over == 0 && failed == 0)
            printf "measure: PASS — all %d attempts under %d ms (§10 step 2a)\n", NR, budget
        else
            printf "measure: FAIL — %d over %d ms, %d attempt(s) never reached recording\n", \
                over, budget, failed
    }
'

# Task 10 extends this script with stop → injection, for criterion (c). It is deliberately absent
# rather than stubbed: with `FakeTranscriber` behind the seam that number would measure nothing but
# a string literal being handed back.
