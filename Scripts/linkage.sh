#!/usr/bin/env bash
# The linker-level budget check for the keypress client (D12, §8.8).
#
# `dictactl` runs on every chord. Its cold start is a budgeted property, and the budget is spent
# almost entirely in dyld: AVFoundation, CoreML and AppKit are hundreds of milliseconds of mapping
# and Objective-C class registration before `main` is reached. §8.8 goes further than performance —
# invariant 8 says the client never opens the microphone, because the TCC grant belongs to the
# signed daemon bundle alone (D11), and a second binary that could open the device would fracture
# it.
#
# Package.swift expresses that as a dependency edge: `dictactl` depends on DictaCore + DictaIPC and
# not on DictaRuntime. That is the intent. This script checks the RESULT, because the two can part
# company without anybody noticing — one `import AVFoundation` in DictaCore "just to get a type",
# or one added dependency line, and the edge is gone while the comment above it still claims it is
# there. A budget with no check drifts.
#
# Three assertions, deliberately overlapping:
#
#   1. `otool -L` names no AVFoundation, CoreML or AppKit in the load commands. SwiftPM links its
#      own targets statically, so pulling in DictaRuntime would surface here as its frameworks.
#   2. `nm -u` names no undefined symbol from those frameworks. This catches a weak or re-exported
#      link that the load commands would not spell out.
#   3. `nm` names no DictaRuntime symbol at all. This is the dependency edge itself, read back off
#      the binary: statically linked Swift code carries its module name in every mangled symbol.
#
# A fourth assertion, about the OTHER binary and a different invariant. §8.11 says the hold trigger
# reads modifier state and never a key stream (D5) — that is what lets push-to-talk work with no
# permission, and it is a property of WHICH API is called, so no swift-testing assertion can reach
# it either. `CGEventSource.flagsState` returns a word of flags. `CGEvent.tapCreate`,
# `NSEvent.addGlobalMonitorForEvents` and IOKit's HID manager return keystrokes, and every one of
# them would make macOS demand Input Monitoring or Accessibility. So the daemon is read back for
# their symbols: if one ever appears, D5's claim has quietly stopped being true and the user is
# about to be asked for a permission this project promised not to need.
#
# Usage:
#   bash Scripts/linkage.sh                     # build both binaries and check them
#   bash Scripts/linkage.sh --binary <path>     # check an existing client binary, building nothing
#   bash Scripts/linkage.sh --daemon <path>     # score §8.11 against a binary, and nothing else
#
# The second form is how the check was probed: run against `DictaTestRunner`, which legitimately
# links all three frameworks, every assertion fires. A check nobody has watched fail is a check
# nobody has verified (D18's lesson, in a different costume).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BINARY=""
DAEMON=""
DAEMON_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --binary)
            [ "$#" -ge 2 ] || { echo "linkage: --binary needs a path" >&2; exit 2; }
            BINARY="$2"
            shift 2
            ;;
        --daemon)
            [ "$#" -ge 2 ] || { echo "linkage: --daemon needs a path" >&2; exit 2; }
            DAEMON="$2"
            DAEMON_ONLY=1
            shift 2
            ;;
        *)
            echo "linkage: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$DAEMON_ONLY" -eq 1 ]; then
    # Probing mode: score §8.11 against the binary handed in and skip the client's three checks.
    # This is how check 4 was watched failing, which is the only way a check becomes evidence.
    [ -f "$DAEMON" ] || { echo "linkage: no such binary: $DAEMON" >&2; exit 2; }
elif [ -z "$BINARY" ]; then
    swift build --product dictactl >/dev/null
    BINARY="$(swift build --show-bin-path)/dictactl"
    # Only on the default path: `--binary` means "check exactly this one and build nothing".
    swift build --product Dicta >/dev/null
    DAEMON="$(swift build --show-bin-path)/Dicta"
fi

status=0
fail() {
    printf 'linkage: %s\n' "$1" >&2
    status=1
}

if [ -n "$BINARY" ]; then
[ -f "$BINARY" ] || { echo "linkage: no such binary: $BINARY" >&2; exit 2; }

# The tools must have UNDERSTOOD the binary before their silence means anything, and that is not a
# hypothetical: `otool -L` on a file that is not Mach-O prints "…: is not an object file" and EXITS
# 0. `tail -n +2` then eats that one line as if it were the normal header, `grep` finds nothing, and
# the script reports "linkage: clean" — about a truncated build, a shell script, or a path that is
# simply not the binary. `nm` exits non-zero in the same case, but its status was going to `|| true`
# and its stderr to /dev/null, so it reported clean too. This is the one check no swift-testing
# assertion can reach (invariant 8, D12) and the first thing `test.sh` runs; a vacuous pass here is
# worse than no check at all, because it is read as evidence.
if ! file "$BINARY" | grep -q 'Mach-O'; then
    echo "linkage: $BINARY is not a Mach-O binary — otool and nm cannot read it" >&2
    exit 2
fi

# The frameworks D12 keeps off the keypress path. FluidAudio is named too: it is the CoreML weight
# in person, and it reaches a binary only through DictaRuntime.
#
# AVFAudio is listed separately from AVFoundation and is not a synonym for it: `AVAudioEngine` lives
# in AVFAudio, and `otool -L` names both frameworks on a binary that captures audio. A regex holding
# only the umbrella therefore passes a binary that pulled in the whole capture stack — which check 2
# would still catch, but check 1 is deliberately overlapping rather than decorative, and a check
# that cannot fail is the vacuous pass this script exists to refuse.
FORBIDDEN='AVFAudio|AVFoundation|CoreML|AppKit|FluidAudio'

# 1. Load commands. The tool's own exit status is checked separately from "matched nothing", so a
# failure to read is never mistaken for a clean result.
if ! loaded="$(otool -L "$BINARY" 2>&1)"; then
    printf '%s\n' "$loaded" >&2
    fail "otool could not read $BINARY — the load-command check did not run"
    loaded=""
fi
hits="$(printf '%s\n' "$loaded" | tail -n +2 | grep -E "$FORBIDDEN" || true)"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "$BINARY links a framework the keypress client must not link (D12, §8.8)"
fi

# 2. Undefined symbols. Mangled Swift names carry the framework's module name ('6CoreML',
# '12AVFoundation'), and Objective-C classes arrive as _OBJC_CLASS_$_AVAudioEngine, so one pattern
# over the whole symbol name catches both spellings.
if ! undefined="$(nm -u "$BINARY" 2>&1)"; then
    printf '%s\n' "$undefined" >&2
    fail "nm -u could not read $BINARY — the undefined-symbol check did not run"
    undefined=""
fi
hits="$(printf '%s\n' "$undefined" \
    | grep -E "$FORBIDDEN|AVAudio|MLModel|MLMultiArray|NSApplication|NSWorkspace" || true)"
if [ -n "$hits" ]; then
    # A here-string, not `printf | head`: under `set -o pipefail` a `head` that closes the pipe
    # early kills printf with SIGPIPE, the pipeline fails, `set -e` ends the script — and the
    # remaining checks silently never run. Observed here while probing this very file.
    head -20 <<< "$hits" >&2
    fail "$BINARY references symbols from AVFoundation, CoreML or AppKit (invariant 8)"
fi

# 3. The dependency edge itself.
if ! symbols="$(nm "$BINARY" 2>&1)"; then
    printf '%s\n' "$symbols" >&2
    fail "nm could not read $BINARY — the dependency-edge check did not run"
    symbols=""
fi
hits="$(printf '%s\n' "$symbols" | grep -E 'DictaRuntime' || true)"
if [ -n "$hits" ]; then
    head -20 <<< "$hits" >&2
    fail "$BINARY carries DictaRuntime symbols — the D12 dependency edge has been crossed"
fi

if [ "$status" -eq 0 ]; then
    echo "linkage: clean — $(basename "$BINARY") binds no AVFoundation, CoreML or AppKit"
fi
fi

# 4. The daemon, against §8.11. A different question and a different binary: `Dicta` links
# AVFoundation and CoreML by design, and what it must not contain is any way of reading a keystroke.
#
# Note what is deliberately NOT checked: whether the daemon links AppKit at all. It does, twice over
# and legitimately — `AudioCapture` has observed `NSWorkspace.willSleepNotification` since long
# before push-to-talk existed (§7's sleep row), and D22 reads `NSWorkspace.frontmostApplication`.
# Widening this into "the daemon binds no AppKit" would therefore fail on the capture stack and say
# nothing about invariant 11. The invariant is about reading a KEYSTROKE, and the four symbols below
# are the four ways to do it; `_OBJC_CLASS_$_NSEvent` is among them because an `NSEvent` global
# monitor is the AppKit-shaped way to break it, and dicta has no other reason to name that class.
if [ -n "$DAEMON" ]; then
    if ! file "$DAEMON" | grep -q 'Mach-O'; then
        echo "linkage: $DAEMON is not a Mach-O binary — the §8.11 check did not run" >&2
        exit 2
    fi
    if ! daemon_symbols="$(nm "$DAEMON" 2>&1)"; then
        printf '%s\n' "$daemon_symbols" >&2
        fail "nm could not read $DAEMON — the §8.11 check did not run"
        daemon_symbols=""
    fi
    KEYSTROKES='CGEventTapCreate|CGEventTapEnable|IOHIDManager|_OBJC_CLASS_[$]_NSEvent'
    hits="$(printf '%s\n' "$daemon_symbols" | grep -E "$KEYSTROKES" || true)"
    if [ -n "$hits" ]; then
        head -20 <<< "$hits" >&2
        fail "$DAEMON can read keystrokes — the hold trigger must read modifier STATE (§8.11, D5)"
    elif [ "$status" -eq 0 ]; then
        echo "linkage: clean — $(basename "$DAEMON") reads modifier state, never a key stream"
    fi
fi

exit "$status"
