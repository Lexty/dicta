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
# Usage:
#   bash Scripts/linkage.sh                     # build dictactl and check it
#   bash Scripts/linkage.sh --binary <path>     # check an existing binary, building nothing
#
# The second form is how the check was probed: run against `DictaTestRunner`, which legitimately
# links all three frameworks, every assertion fires. A check nobody has watched fail is a check
# nobody has verified (D18's lesson, in a different costume).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BINARY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --binary)
            [ "$#" -ge 2 ] || { echo "linkage: --binary needs a path" >&2; exit 2; }
            BINARY="$2"
            shift 2
            ;;
        *)
            echo "linkage: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$BINARY" ]; then
    swift build --product dictactl >/dev/null
    BINARY="$(swift build --show-bin-path)/dictactl"
fi

[ -f "$BINARY" ] || { echo "linkage: no such binary: $BINARY" >&2; exit 2; }

status=0
fail() {
    printf 'linkage: %s\n' "$1" >&2
    status=1
}

# The frameworks D12 keeps off the keypress path. FluidAudio is named too: it is the CoreML weight
# in person, and it reaches a binary only through DictaRuntime.
FORBIDDEN='AVFoundation|CoreML|AppKit|FluidAudio'

# 1. Load commands.
hits="$(otool -L "$BINARY" | tail -n +2 | grep -E "$FORBIDDEN" || true)"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "$BINARY links a framework the keypress client must not link (D12, §8.8)"
fi

# 2. Undefined symbols. Mangled Swift names carry the framework's module name ('6CoreML',
# '12AVFoundation'), and Objective-C classes arrive as _OBJC_CLASS_$_AVAudioEngine, so one pattern
# over the whole symbol name catches both spellings.
hits="$(nm -u "$BINARY" 2>/dev/null | grep -E "$FORBIDDEN|AVAudio|MLModel|MLMultiArray|NSApplication|NSWorkspace" || true)"
if [ -n "$hits" ]; then
    # A here-string, not `printf | head`: under `set -o pipefail` a `head` that closes the pipe
    # early kills printf with SIGPIPE, the pipeline fails, `set -e` ends the script — and the
    # remaining checks silently never run. Observed here while probing this very file.
    head -20 <<< "$hits" >&2
    fail "$BINARY references symbols from AVFoundation, CoreML or AppKit (invariant 8)"
fi

# 3. The dependency edge itself.
hits="$(nm "$BINARY" 2>/dev/null | grep -E 'DictaRuntime' || true)"
if [ -n "$hits" ]; then
    head -20 <<< "$hits" >&2
    fail "$BINARY carries DictaRuntime symbols — the D12 dependency edge has been crossed"
fi

if [ "$status" -eq 0 ]; then
    echo "linkage: clean — $(basename "$BINARY") binds no AVFoundation, CoreML or AppKit"
fi
exit "$status"
