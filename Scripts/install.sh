#!/usr/bin/env bash
# Install the binaries into ~/.local/bin, where the keymap snippet expects to find dictactl by
# absolute path (§12 — going through a login shell would add tens of milliseconds of profile
# loading to every keypress).
#
# Does NOT touch ~/.config/agterm/keymap.conf: add docs/keymap.snippet.conf by hand, then
# `agtermctl keymap reload`.
#
# Task 8 extends this to bundle, sign and load the LaunchAgent in one command.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release

mkdir -p "$HOME/.local/bin"
install -m 0755 .build/release/dictactl "$HOME/.local/bin/dictactl"
install -m 0755 .build/release/Dicta "$HOME/.local/bin/dicta-daemon"

echo "installed: ~/.local/bin/dictactl, ~/.local/bin/dicta-daemon"
echo "next: add docs/keymap.snippet.conf to ~/.config/agterm/keymap.conf && agtermctl keymap reload"
