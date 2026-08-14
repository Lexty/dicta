#!/usr/bin/env bash
# Scores step 2's criteria (a) and (c) with numbers rather than impressions.
#
#   (a) keypress to "recording", warm, over N consecutive attempts, against a 150 ms budget (F4).
#       This is what a bare `measure.sh` does, and it types nothing into a pane.
#   (c) stop to injection for a 60-second utterance, against a 2 s budget. Behind `--stop`, because
#       measuring it means DELIVERING the text: the interval being measured ends at the last
#       keystroke, so an abort would measure the wrong thing (see the section at the bottom).
#
# WHAT IS MEASURED, exactly: the wall time of one `dictactl toggle` invocation — process start to
# process exit — for a chord that begins an attempt. The daemon performs every effect of the start
# BEFORE it answers, so that interval contains the whole cost the user waits through: dictactl's own
# cold start, the socket round trip, `agtermctl tree --json` (38 ms of it, F3/F4), opening the input
# device, and §6's "listening" indicator. It ends a hair after the daemon reached `recording`, so
# the number is an upper bound on keypress-to-recording rather than an optimistic slice of it.
#
# Note what the toggle PRINTS is `warming`: the response carries the state as of the transition that
# started the attempt, and capture confirms afterwards. That is why every attempt is confirmed with
# a separate `dictactl status`, and an attempt whose status is not `recording` is reported as a
# failure rather than quietly averaged in.
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
# Criterion (c), off by default: it delivers text into the session's input line, and a measurement
# that types into whatever the user was doing is not something to run by accident.
STOP_LATENCY=0
STOP_ATTEMPTS=3
STOP_BUDGET_MS=2000
UTTERANCE=60
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
  --stop            ALSO measure stop -> injection for criterion (c). This DELIVERS text
                    into the session's input line, once per attempt
  --stop-n <count>  attempts for criterion (c) (default 3)
  --utterance <s>   how long each criterion (c) attempt records (default 60, per §10)
  --stop-budget <ms>
                    the budget stop -> injection is scored against (default 2000)
  --session <id>    the agterm session to dictate into (default "$AGT_SESSION_ID")
  --socket <path>   agterm's control socket (default "$AGT_SOCKET")
  --control <path>  dicta's own control socket
  --dictactl <path> the client to time (default: the release build, then ~/.local/bin)
  --help            print this
EOF
}

# Every value-taking flag checks that its value is there. Without it, `measure.sh -n` dies under
# `set -u` with bash's own "$2: unbound variable" instead of this script's usage message -- and
# under `set -e` that exit is indistinguishable from a measurement that failed.
need() { [ "$1" -ge 2 ] || { printf 'measure: %s needs a value\n' "$2" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
    case "$1" in
        -n) need $# "-n"; ATTEMPTS="$2"; shift 2 ;;
        --budget) need $# "--budget"; BUDGET_MS="$2"; shift 2 ;;
        --speak) need $# "--speak"; SPEAK="$2"; shift 2 ;;
        --stop) STOP_LATENCY=1; shift ;;
        --stop-n) need $# "--stop-n"; STOP_ATTEMPTS="$2"; shift 2 ;;
        --utterance) need $# "--utterance"; UTTERANCE="$2"; shift 2 ;;
        --stop-budget) need $# "--stop-budget"; STOP_BUDGET_MS="$2"; shift 2 ;;
        --session) need $# "--session"; SESSION="$2"; shift 2 ;;
        --socket) need $# "--socket"; AGTERM_SOCKET="$2"; shift 2 ;;
        --control) need $# "--control"; CONTROL="$2"; shift 2 ;;
        --dictactl) need $# "--dictactl"; DICTACTL="$2"; shift 2 ;;
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
#
# Expanded as `${ARGS[@]+"${ARGS[@]}"}` everywhere below: macOS ships bash 3.2, where a bare
# `"${ARGS[@]}"` on an EMPTY array is an unbound variable under `set -u` and aborts the script. The
# empty case is the ordinary one -- no `--socket`, no `--control` -- so this would fail exactly when
# the defaults are being measured.
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
    "$DICTACTL" status ${ARGS[@]+"${ARGS[@]}"} 2>/dev/null || echo "unreachable"
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
    "$DICTACTL" toggle --mode clean --session "$SESSION" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 || true
    finish="$(now_ms)"
    elapsed="$(perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$start" "$finish")"
    reached="$(state)"
    sleep "$SPEAK"
    # Never a second toggle: that would deliver a transcript into the input line every attempt.
    "$DICTACTL" abort ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 || true
    wait_for_idle || printf 'measure: attempt did not return to idle\n' >&2
    if [ "$reached" != "recording" ]; then
        printf 'measure: attempt reached "%s", not "recording" — %s ms not counted\n' \
            "$reached" "$elapsed" >&2
        return 1
    fi
    printf '%s\n' "$elapsed"
}

# One criterion-(c) attempt: record for $UTTERANCE seconds, then time the `stop`.
#
# WHAT IS MEASURED: the wall time of one `dictactl stop` invocation. The daemon performs the whole
# remainder of the attempt before it answers — drain, recognition, the replacement stage, the filter
# seam, the sanitiser, and `agtermctl session type` — so that interval is stop-to-injection with the
# keystrokes inside it, which is exactly what §10's criterion (c) names.
#
# This DELIVERS. There is no version of it that does not: the interval ends at the last keystroke,
# so an attempt aborted to keep the pane clean would measure recognition alone and score the
# criterion against a number that leaves out the delivery.
stop_attempt() {
    local start finish elapsed reached
    "$DICTACTL" toggle --mode clean --session "$SESSION" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 || true
    reached="$(state)"
    if [ "$reached" != "recording" ]; then
        printf 'measure: attempt reached "%s", not "recording" — not counted\n' "$reached" >&2
        "$DICTACTL" abort ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 || true
        wait_for_idle || true
        return 1
    fi
    sleep "$UTTERANCE"
    start="$(now_ms)"
    "$DICTACTL" stop ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 || true
    finish="$(now_ms)"
    elapsed="$(perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$start" "$finish")"
    wait_for_idle || printf 'measure: attempt did not return to idle\n' >&2
    printf '%s\n' "$elapsed"
}

# The distribution, and the verdict. Shared by both criteria: every attempt must be under the
# budget, not the mean — one slow chord in ten is the experience a budget exists to forbid.
#
# RETURNS NON-ZERO ON FAIL, and the callers turn that into the script's own exit status. This is
# what a scorer is for: the FAIL line is one row in a report that scrolls, and a run where three
# attempts in ten blew the budget used to be indistinguishable from a clean one to anything that
# checks `$?`. That is D18 wearing a different hat — `swift test` exiting 0 on a failing suite is
# the reason this project has its own test runner, and a measurement script that exits 0 on a
# missed budget is the same mistake in the one place the budget is actually scored.
report() {
    local budget="$1" failed="$2" label="$3"
    shift 3
    printf '%s\n' "$@" | sort -n | awk -v budget="$budget" -v failed="$failed" -v label="$label" '
        { v[NR] = $1; sum += $1 }
        END {
            median = (NR % 2) ? v[int(NR / 2) + 1] : (v[NR / 2] + v[NR / 2 + 1]) / 2
            p90 = v[int((NR * 0.9) + 0.999999)]
            over = 0
            for (i = 1; i <= NR; i++) if (v[i] > budget) over++
            printf "measure: n=%d  min=%.1f  median=%.1f  p90=%.1f  max=%.1f  mean=%.1f (ms)\n", \
                NR, v[1], median, p90, v[NR], sum / NR
            if (over == 0 && failed == 0)
                printf "measure: PASS — all %d attempts under %d ms (%s)\n", NR, budget, label
            else {
                printf "measure: FAIL — %d over %d ms, %d attempt(s) never counted (%s)\n", \
                    over, budget, failed, label
                exit 1
            }
        }
    '
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
# `|| VERDICT=1` rather than a bare call: `set -e` would otherwise abort here on a missed budget,
# skipping criterion (c) entirely and reporting the wrong reason for the non-zero exit.
VERDICT=0
report "$BUDGET_MS" "$FAILED" "§10 step 2a" "${SAMPLES[@]}" || VERDICT=1

if [ "$STOP_LATENCY" -eq 0 ]; then
    printf '\nmeasure: criterion (c) not measured — pass --stop, which DELIVERS text into %s\n' \
        "$SESSION"
    exit "$VERDICT"
fi

# Criterion (c). Announced before it runs, because the next thing that happens is text appearing in
# the user's input line — unsubmitted, but there.
printf '\n'
printf 'measure: criterion (c): %s attempts of %s s each, budget %s ms\n' \
    "$STOP_ATTEMPTS" "$UTTERANCE" "$STOP_BUDGET_MS"
printf 'measure: each attempt TYPES its transcript into session %s (unsubmitted). Speak, or the\n' \
    "$SESSION"
printf 'measure: numbers will describe recognising silence, which is not what (c) asks about.\n'

STOP_SAMPLES=()
STOP_FAILED=0
for i in $(seq 1 "$STOP_ATTEMPTS"); do
    printf '  attempt %2s: speak for %s s...\n' "$i" "$UTTERANCE"
    if ms="$(stop_attempt)"; then
        STOP_SAMPLES+=("$ms")
        printf '  attempt %2s: %8s ms\n' "$i" "$ms"
    else
        STOP_FAILED=$((STOP_FAILED + 1))
        printf '  attempt %2s: FAILED\n' "$i"
    fi
done

if [ "${#STOP_SAMPLES[@]}" -eq 0 ]; then
    printf 'measure: no attempt delivered — nothing to report for criterion (c)\n' >&2
    exit 1
fi

printf '\n'
report "$STOP_BUDGET_MS" "$STOP_FAILED" "§10 step 2c" "${STOP_SAMPLES[@]}" || VERDICT=1
# The transcripts are in the record too, so `dictactl last --recognised` scores criterion (b) off
# the same run rather than needing its own dictation.
printf 'measure: the text of each attempt is in the record — `dictactl last --recognised`\n'
# Either criterion failing fails the run. Falling off the end here exits 0 whatever was measured.
exit "$VERDICT"
