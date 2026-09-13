#!/usr/bin/env bash
# Render the daemon's LaunchAgent from Scripts/launchagent.plist and print it to stdout.
#
#   bash Scripts/render-agent.sh <app-bundle> <log-file> [--focused-fields]
#
# A script of its own rather than a function inside install.sh, so that `BundleTests` can run the
# EXACT rendering the installer ships -- both settings, through `plutil -lint` -- without a test
# ever being one broken argument away from a real install (a build, a bootout and a bootstrap).
#
# `--focused-fields` (D31) is one whole line of ProgramArguments in the template, a `<string>`
# holding the placeholder. With the flag that line becomes `<string>--focused-fields</string>`;
# without it the line is DELETED, never substituted with an empty value. `<string></string>` in
# ProgramArguments is an empty argument, which the daemon refuses as an unknown option -- a
# LaunchAgent that throttle-loops at login with the reason only in a log.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: render-agent.sh <app-bundle> <log-file> [--focused-fields]" >&2
    exit 2
fi
APP="$1"
LOG="$2"
FOCUSED_FIELDS=0
if [ "$#" -eq 3 ]; then
    if [ "$3" != "--focused-fields" ]; then
        echo "render-agent.sh: unknown option $3" >&2
        exit 2
    fi
    FOCUSED_FIELDS=1
fi

# Escaped, because these land on sed's REPLACEMENT side, where `&` means "the whole match" and `\`
# and the `|` delimiter mean what they always do. A home directory containing one of them would
# produce a mangled path in a plist that `plutil -lint` then passes, since it is valid XML naming a
# binary that does not exist -- and the symptom would be a LaunchAgent that silently never starts.
escape_replacement() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

if [ "$FOCUSED_FIELDS" -eq 1 ]; then
    FIELDS_EDIT='s|<string>__DICTA_FOCUSED_FIELDS__</string>|<string>--focused-fields</string>|'
else
    FIELDS_EDIT='/<string>__DICTA_FOCUSED_FIELDS__<\/string>/d'
fi

sed -e "s|__DICTA_APP__|$(escape_replacement "$APP")|g" \
    -e "s|__DICTA_LOG__|$(escape_replacement "$LOG")|g" \
    -e "$FIELDS_EDIT" \
  "$ROOT/Scripts/launchagent.plist"
