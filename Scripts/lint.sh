#!/usr/bin/env bash
# Style gate.
#
# Two layers, and the second is the one that always runs:
#
#   1. SwiftLint, if it happens to be on PATH. It is NOT a dependency of this project and nothing
#      installs it — a linter is not worth a global install on this machine.
#   2. Mechanical checks implemented here, in tools that ship with macOS. These run unconditionally,
#      so `bash Scripts/lint.sh` means the same thing on a machine without SwiftLint.
#
# The Cyrillic check is the one with teeth. SPEC.md is English-only across the whole project with no
# exceptions, precisely so this check has nothing legitimate to find; carving out "user-facing
# strings" would turn every new string into a judgement call and disarm the check.
#
# Every check here was verified able to FAIL when Task 1 wrote it — the same principle as D18. Two
# of them were silently passing until that probe: perl needs -CSD to see a Cyrillic codepoint rather
# than its UTF-8 bytes, and `$.` keeps counting across files unless ARGV is closed at each eof.
#
# Scope: files git tracks, plus new files that are not ignored, minus anything binary. Never .build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export MAX_LINE=100
status=0

fail() {
    printf 'lint: %s\n' "$1" >&2
    status=1
}

# --- files under inspection -------------------------------------------------------------------

# `while read` rather than `mapfile`, and `${ARR[@]+"${ARR[@]}"}` rather than a bare `"${ARR[@]}"`:
# macOS ships bash 3.2 as /bin/bash, which has no `mapfile` and treats an empty array's expansion as
# an unbound variable under `set -u`. This script ran only because Homebrew's bash 5 happened to come
# first on PATH -- a lint gate that silently needs a package the project refuses to install is the
# same trap as the SwiftLint one it already avoids.
ALL_FILES=()
while IFS= read -r line; do
    ALL_FILES+=("$line")
done < <(git ls-files --cached --others --exclude-standard)

FILES=()
if [ "${#ALL_FILES[@]}" -gt 0 ]; then
    # -T is perl's "looks like text" heuristic; it keeps a future icon or model file from being
    # scanned as if it were source.
    while IFS= read -r line; do
        FILES+=("$line")
    done < <(perl -e 'for (@ARGV) { print "$_\n" if -f $_ && -T $_ }' "${ALL_FILES[@]}")
fi

SWIFT_FILES=()
for f in ${FILES[@]+"${FILES[@]}"}; do
    [[ "$f" == *.swift ]] && SWIFT_FILES+=("$f")
done

# --- 1. SwiftLint, when available -------------------------------------------------------------

if command -v swiftlint >/dev/null 2>&1; then
    echo "lint: swiftlint $(swiftlint version)"
    swiftlint lint --quiet --strict || fail "swiftlint reported violations"
else
    echo "lint: swiftlint not installed — skipping it, running the built-in checks only"
fi

# --- 2. Checks that always run ----------------------------------------------------------------

# The one file whose Cyrillic is DATA rather than language: the example replacement dictionary.
# Tier 0 exists to undo Parakeet transliterating English technical terms into Cyrillic (D9a), so
# every pattern in it is a Cyrillic string by construction and an example without them would teach
# nothing. This stays a single named path rather than a category — "user-facing strings" was the
# carve-out that turned every new string into a judgement call and disarmed this check, and one file
# named here is not a judgement call. A missing file is a failure, so the exemption cannot outlive
# what it exempts.
CYRILLIC_EXEMPT=(docs/replacements.example.conf)
for exempt in "${CYRILLIC_EXEMPT[@]}"; do
    [ -f "$exempt" ] || fail "$exempt is exempt from the Cyrillic check but does not exist"
done

CYRILLIC_FILES=()
for f in ${FILES[@]+"${FILES[@]}"}; do
    skip=
    for exempt in "${CYRILLIC_EXEMPT[@]}"; do
        [ "$f" = "$exempt" ] && skip=1
    done
    [ -n "$skip" ] || CYRILLIC_FILES+=("$f")
done

if [ "${#CYRILLIC_FILES[@]}" -gt 0 ]; then
    # English only, no exceptions (SPEC.md, preamble) beyond the one named above.
    hits="$(perl -CSD -ne '
        print "$ARGV:$.: $_" if /[\x{0400}-\x{04FF}]/;
        close ARGV if eof;
    ' "${CYRILLIC_FILES[@]}" || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >&2
        fail "Cyrillic found — this repository is English-only, with no exceptions"
    fi
fi

if [ "${#FILES[@]}" -gt 0 ]; then

    hits="$(perl -CSD -ne '
        printf "%s:%d: trailing whitespace\n", $ARGV, $. if /[ \t]+$/;
        close ARGV if eof;
    ' "${FILES[@]}" || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >&2
        fail "trailing whitespace"
    fi
fi

if [ "${#SWIFT_FILES[@]}" -gt 0 ]; then
    # Tabs: SwiftPM's own formatting is spaces, and a mixed file diffs badly.
    # perl rather than `grep -P`: BSD grep, which is what /usr/bin/grep is here, has no -P.
    hits="$(perl -CSD -ne '
        printf "%s:%d: tab\n", $ARGV, $. if /\t/;
        close ARGV if eof;
    ' "${SWIFT_FILES[@]}" || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >&2
        fail "tab characters in Swift sources — use four spaces"
    fi

    # Columns, not bytes: `awk` in the C locale would report a comment containing an em dash three
    # columns longer than it looks in an editor.
    hits="$(perl -CSD -ne '
        chomp;
        printf "%s:%d: %d columns\n", $ARGV, $., length($_) if length($_) > $ENV{MAX_LINE};
        close ARGV if eof;
    ' "${SWIFT_FILES[@]}" || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >&2
        fail "lines over $MAX_LINE columns"
    fi
fi

# Every script is invoked as `bash Scripts/x.sh`, but a non-executable script called from a
# LaunchAgent or a keymap line fails at the worst possible moment.
for script in Scripts/*.sh; do
    [ -x "$script" ] || fail "$script is not executable (chmod +x)"
done

if [ "$status" -eq 0 ]; then
    echo "lint: clean (${#FILES[@]} files, ${#SWIFT_FILES[@]} Swift)"
fi
exit "$status"
