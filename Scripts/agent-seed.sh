#!/usr/bin/env bash
# Decide whether the daemon's new LaunchAgent carries `--focused-fields` as a seed, and print it.
#
#   bash Scripts/agent-seed.sh <old-agent-plist> <setup-json>
#
# Prints `--focused-fields` only when the agent being replaced had the flag AND `setup.json` does
# not exist; otherwise prints nothing. Exits 0 either way.
#
# The installer no longer chooses where dictation goes: the person does, in the menu's setup window,
# and the daemon keeps that choice in `setup.json`. The flag survives only as a seed, read by the
# daemon when `setup.json` does not exist yet. An install from an agent that had the flag, onto a
# daemon that has not written `setup.json` yet, must therefore keep the flag for one more start, or
# that person's choice is lost and they are asked again. Once `setup.json` exists the file decides,
# so the flag is dropped.
#
# "Exists" is any directory entry at all, a dangling symlink and a file that cannot be read or parsed
# included. The daemon treats an unreadable `setup.json` as a problem to show, never as an absent one
# to migrate over, and reseeding would contradict it.
#
# A script of its own, as `render-agent.sh` is, so that `BundleTests` can RUN the decision rather
# than grep for it, without a test ever being one broken argument away from a real install.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: agent-seed.sh <old-agent-plist> <setup-json>" >&2
    exit 2
fi
OLD_AGENT="$1"
SETUP="$2"

if [ -e "$SETUP" ] || [ -L "$SETUP" ]; then
    exit 0
fi
if [ -f "$OLD_AGENT" ] && grep -q '<string>--focused-fields</string>' "$OLD_AGENT"; then
    echo "--focused-fields"
fi
