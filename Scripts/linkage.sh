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
# A fifth assertion, about a THIRD binary. D27 gives dicta a menu-bar UI, and puts it in its own
# bundle precisely so the daemon's shape does not move. `DictaMenu` inherits invariant 8 one step
# further out — it must not be able to open the microphone, because the grant belongs to the
# daemon's bundle alone — and invariant 11, because a UI is the natural place to reach for a hotkey
# and an `NSEvent` monitor is how that would be spelled. What it may do that `dictactl` may not is
# link SwiftUI: that is the single difference between their rules, and it is stated here rather than
# left to be inferred from a passing run.
#
# Measured while this check was written (2026-08-23), because the strength of the rule depended on
# it: a trivial SwiftUI `MenuBarExtra` binary references NEITHER `_OBJC_CLASS_$_NSEvent` NOR AppKit
# in its load commands — SwiftUI reaches AppKit internally — while a binary calling
# `NSEvent.addGlobalMonitorForEvents` shows `U _OBJC_CLASS_$_NSEvent` in `nm -u` AND the selector
# `addGlobalMonitorForEventsMatchingMask:handler:` in `strings`. So the menu is held to the daemon's
# full four-symbol rule rather than a weakened one, and the selector is checked as well: the class
# check is the strong general net, the selector check is the one that names the actual capability
# and would survive a future legitimate reason to mention `NSEvent`.
#
# Usage:
#   bash Scripts/linkage.sh                     # build all three binaries and check them
#   bash Scripts/linkage.sh --binary <path>     # check an existing client binary, building nothing
#   bash Scripts/linkage.sh --daemon <path>     # score §8.11 against a binary, and nothing else
#   bash Scripts/linkage.sh --menu <path>       # score the menu's rules against a binary, only
#
# The second form is how the check was probed: run against `DictaTestRunner`, which legitimately
# links all three frameworks, every assertion fires. A check nobody has watched fail is a check
# nobody has verified (D18's lesson, in a different costume).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BINARY=""
DAEMON=""
MENU=""
ONLY=0
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
            ONLY=1
            shift 2
            ;;
        --menu)
            [ "$#" -ge 2 ] || { echo "linkage: --menu needs a path" >&2; exit 2; }
            MENU="$2"
            ONLY=1
            shift 2
            ;;
        *)
            echo "linkage: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$ONLY" -eq 1 ]; then
    # Probing mode: score one binary's own rules and skip everything else. This is how checks 4 and
    # 5 were watched failing, which is the only way a check becomes evidence.
    [ -z "$DAEMON" ] || [ -f "$DAEMON" ] || { echo "linkage: no such binary: $DAEMON" >&2; exit 2; }
    [ -z "$MENU" ] || [ -f "$MENU" ] || { echo "linkage: no such binary: $MENU" >&2; exit 2; }
elif [ -z "$BINARY" ]; then
    swift build --product dictactl >/dev/null
    BINARY="$(swift build --show-bin-path)/dictactl"
    # Only on the default path: `--binary` means "check exactly this one and build nothing".
    swift build --product Dicta >/dev/null
    DAEMON="$(swift build --show-bin-path)/Dicta"
    swift build --product DictaMenu >/dev/null
    MENU="$(swift build --show-bin-path)/DictaMenu"
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
KEYSTROKES='CGEventTapCreate|CGEventTapEnable|IOHIDManager|_OBJC_CLASS_[$]_NSEvent'
# The selector, checked separately from the class. An Objective-C selector is a STRING in
# `__TEXT,__objc_methname` and never appears in `nm` output, so the class check above is what
# actually catches a monitor today — but the class is the general net and this is the specific one.
# If a binary ever acquires a legitimate reason to name `NSEvent`, this is the check that still
# means something, and the class rule is the one that would have to be relaxed.
MONITORS='addGlobalMonitorForEvents|addLocalMonitorForEvents'

# Shared by the daemon (§8.11, D5) and the menu (D27): the same invariant, asked of two binaries for
# two reasons. The daemon must not read keystrokes because push-to-talk's whole claim is that it
# needs no permission; the menu must not because a UI is the natural place to reach for a hotkey,
# and the first `NSEvent` monitor is the moment macOS starts demanding Input Monitoring.
check_keystrokes() {
    local path="$1"
    local what="$2"
    local symbols text
    if ! file "$path" | grep -q 'Mach-O'; then
        echo "linkage: $path is not a Mach-O binary — the §8.11 check did not run" >&2
        exit 2
    fi
    if ! symbols="$(nm "$path" 2>&1)"; then
        printf '%s\n' "$symbols" >&2
        fail "nm could not read $path — the §8.11 check did not run"
        return
    fi
    local hits
    hits="$(printf '%s\n' "$symbols" | grep -E "$KEYSTROKES" || true)"
    if [ -n "$hits" ]; then
        head -20 <<< "$hits" >&2
        fail "$path can read keystrokes — $what must read modifier STATE, never events (§8.11, D5)"
        # Deliberately NOT returning here. The selector check below would otherwise be shadowed on
        # every binary that trips the class check — that is, on every binary that could ever
        # exercise it — and a branch nothing has been observed to run is not evidence of anything.
        # Both run, both report.
    fi
    # `strings` rather than a section dump: `otool -s __TEXT __objc_methname` prints hex that has to
    # be reassembled, and the one thing this check must not do is fail to run and report clean.
    if ! text="$(strings -a "$path" 2>&1)"; then
        printf '%s\n' "$text" >&2
        fail "strings could not read $path — the event-monitor check did not run"
        return
    fi
    hits="$(printf '%s\n' "$text" | grep -E "$MONITORS" || true)"
    if [ -n "$hits" ]; then
        head -20 <<< "$hits" >&2
        fail "$path installs an event monitor — that is Input Monitoring, which dicta does not ask for"
    fi
}

# The other direction, invariant 14. With `--focused-fields` the daemon POSTS keystrokes into another
# application and reads accessibility to find the field; that is the capability the user grants
# Accessibility for, and it belongs to the daemon's bundle alone, exactly as the microphone does
# (invariant 8). `dictactl` and `DictaMenu` must name none of the five C functions that capability is
# spelled with. `Dicta` legitimately names four of them, which is the positive control: when this was
# written (2026-09-13) `nm Dicta` showed `U _AXUIElementCopyAttributeValue`,
# `U _AXUIElementCreateSystemWide`, `U _CGEventKeyboardSetUnicodeString` and `U _CGEventPostToPid`,
# and the current `dictactl` and `DictaMenu` matched nothing.
#
# The names are matched EXACTLY — a leading underscore, the C name, end of line — rather than as
# substrings. A substring `CGEventPost` would also match `CGEventPostToPid`, which is harmless, but a
# substring `AXUIElement` is the kind of pattern SwiftUI's own accessibility machinery could one day
# satisfy inside a mangled Swift name, and a gate that fails on a framework's internals gets relaxed
# until it means nothing. A C function arrives in `nm` under its own name and nothing else.
#
# Probed on 2026-09-13 by adding `CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)?
# .postToPid(0)` to `dictactl`'s `main.swift` (in a function nothing called — the debug link keeps
# it). The gate exited 1, printing the symbol and then the failure line (checkout path elided):
#                  U _CGEventPostToPid
#   linkage: …/.build/arm64-apple-macosx/debug/dictactl can post keystrokes or read accessibility — only the daemon may, and only with --focused-fields (invariant 14)
# and exited 0 again once the call was removed.
# Every accessibility, Secure Input and posting entry point the daemon's focused-field path calls,
# so a client or menu that reached any of them -- the trust check or a settable attribute included,
# not only the element read -- fails by name.
POSTING='CGEventPost|CGEventPostToPid|CGEventKeyboardSetUnicodeString|AXUIElementCreateSystemWide|AXUIElementCreateApplication|AXUIElementCopyAttributeValue|AXUIElementSetAttributeValue|AXIsProcessTrusted|AXIsProcessTrustedWithOptions|IsSecureEventInputEnabled'

check_posting() {
    local path="$1"
    local symbols hits
    if ! file "$path" | grep -q 'Mach-O'; then
        echo "linkage: $path is not a Mach-O binary — the invariant 14 check did not run" >&2
        exit 2
    fi
    if ! symbols="$(nm "$path" 2>&1)"; then
        printf '%s\n' "$symbols" >&2
        fail "nm could not read $path — the invariant 14 check did not run"
        return
    fi
    hits="$(printf '%s\n' "$symbols" | grep -E "[[:space:]]_($POSTING)\$" || true)"
    if [ -n "$hits" ]; then
        head -20 <<< "$hits" >&2
        fail "$path can post keystrokes or read accessibility — only the daemon may, and only with --focused-fields (invariant 14)"
    fi
}

# 3b. The keypress client, against invariant 14. Run here rather than beside checks 1-3 only because
# a shell function has to be defined before it is called.
if [ -n "$BINARY" ]; then
    before="$status"
    check_posting "$BINARY"
    if [ "$status" -eq "$before" ]; then
        echo "linkage: clean — $(basename "$BINARY") posts no keystroke and reads no accessibility"
    fi
fi

# 4. The daemon, against §8.11. A different question and a different binary: `Dicta` links
# AVFoundation and CoreML by design, and what it must not contain is any way of reading a keystroke.
if [ -n "$DAEMON" ]; then
    before="$status"
    check_keystrokes "$DAEMON" "the hold trigger"
    if [ "$status" -eq "$before" ]; then
        echo "linkage: clean — $(basename "$DAEMON") reads modifier state, never a key stream"
    fi
fi

# 5. The menu-bar UI, against invariants 8 and 11 (D27). It may link SwiftUI — that is the ONE
# difference from `dictactl`'s rules — and it may not link the capture stack or read a key.
if [ -n "$MENU" ]; then
    before="$status"
    if ! file "$MENU" | grep -q 'Mach-O'; then
        echo "linkage: $MENU is not a Mach-O binary — the menu's checks did not run" >&2
        exit 2
    fi
    if ! menu_loaded="$(otool -L "$MENU" 2>&1)"; then
        printf '%s\n' "$menu_loaded" >&2
        fail "otool could not read $MENU — the menu's load-command check did not run"
        menu_loaded=""
    fi
    # AppKit is absent from the list on purpose: SwiftUI reaches it internally and a menu-bar app
    # legitimately needs it (NSPasteboard is how D28's clipboard recovery is spelled). What the menu
    # must not touch is the microphone and the models.
    MENU_FORBIDDEN='AVFAudio|AVFoundation|CoreML|FluidAudio'
    hits="$(printf '%s\n' "$menu_loaded" | tail -n +2 | grep -E "$MENU_FORBIDDEN" || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >&2
        fail "$MENU links the capture stack — the UI must never open the microphone (D11, §8.8)"
    fi
    if ! menu_undefined="$(nm -u "$MENU" 2>&1)"; then
        printf '%s\n' "$menu_undefined" >&2
        fail "nm -u could not read $MENU — the menu's undefined-symbol check did not run"
        menu_undefined=""
    fi
    hits="$(printf '%s\n' "$menu_undefined" \
        | grep -E "$MENU_FORBIDDEN|AVAudio|MLModel|MLMultiArray" || true)"
    if [ -n "$hits" ]; then
        head -20 <<< "$hits" >&2
        fail "$MENU references capture or CoreML symbols (invariant 8, one binary further out)"
    fi
    if ! menu_symbols="$(nm "$MENU" 2>&1)"; then
        printf '%s\n' "$menu_symbols" >&2
        fail "nm could not read $MENU — the menu's dependency-edge check did not run"
        menu_symbols=""
    fi
    hits="$(printf '%s\n' "$menu_symbols" | grep -E 'DictaRuntime' || true)"
    if [ -n "$hits" ]; then
        head -20 <<< "$hits" >&2
        fail "$MENU carries DictaRuntime symbols — the UI is a socket client, not a second daemon"
    fi
    check_keystrokes "$MENU" "the UI"
    check_posting "$MENU"
    if [ "$status" -eq "$before" ]; then
        echo "linkage: clean — $(basename "$MENU") binds SwiftUI, no capture stack, no key stream, no posting"
    fi
fi

exit "$status"
