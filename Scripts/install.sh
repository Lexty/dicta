#!/usr/bin/env bash
# Install dicta: bundle, sign, install, load. One command, because the four steps are only correct
# together -- a freshly signed bundle that nothing reloaded leaves the OLD daemon serving the socket,
# and every measurement afterwards describes a build that is no longer the one on disk.
#
# What lands where, and why:
#
#   ~/.local/bin/dictactl        the keypress client. The keymap invokes it by ABSOLUTE PATH and not
#                                through a login shell (§12), so it must be at a path that does not
#                                move with the checkout.
#   ~/Applications/Dicta.app     the signed daemon bundle -- the anchor the microphone TCC grant
#                                attaches to (D11). Copied with `ditto`, which preserves the
#                                signature; `cp -R` can drop the extended attributes it lives in.
#   ~/Library/LaunchAgents/dev.personal.dicta.plist
#                                the user agent that keeps it running across login.
#
# Deliberately NOT installed: a bare `dicta-daemon` executable. It would run, it would serve the
# socket, and its microphone grant would be attributed to whatever terminal launched it -- exactly
# the failure the bundle exists to prevent. The development path is `bash Scripts/run.sh`, which is
# honest about being one.
#
# Does NOT touch ~/.config/agterm/keymap.conf: add docs/keymap.snippet.conf by hand, then
# `agtermctl keymap reload`. Rewriting a user's keymap is not something an installer should do.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LABEL="dev.personal.dicta"
APP_DEST="$HOME/Applications/Dicta.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/dicta.log"

# --- the keypress client ------------------------------------------------------------------------
echo "==> building and installing dictactl"
swift build -c release
mkdir -p "$HOME/.local/bin"
# Invariant 8 against the artifact that actually ships. `Scripts/test.sh` runs this check on the
# DEBUG build -- the only one the gate can afford to compile -- so the release binary, which is the
# one that opens no microphone in the user's ~/.local/bin, is checked here or nowhere.
bash "$ROOT/Scripts/linkage.sh" --binary .build/release/dictactl
install -m 0755 .build/release/dictactl "$HOME/.local/bin/dictactl"

# --- the signed daemon bundle -------------------------------------------------------------------
bash "$ROOT/Scripts/bundle.sh"

echo "==> installing $APP_DEST"
mkdir -p "$HOME/Applications"
# Copied BESIDE the installed bundle and swapped in, rather than copied over it. Under `set -e` a
# `ditto` that fails partway -- no space, interrupted, a permission on one file -- used to abort the
# script with `$APP_DEST` already deleted or half written and the LaunchAgent from the previous
# install still pointing at it: launchd then throttle-loops on a binary that is not there, every
# chord is dead, and the only trace is in a log nobody is reading. The window where neither bundle
# is in place is now a rename. The signature is verified on the copy BEFORE the swap, for the same
# reason -- a bundle that no longer satisfies the requirement must never become the installed one.
STAGED="$APP_DEST.incoming"
rm -rf "$STAGED"
ditto "$ROOT/Dicta.app" "$STAGED"

# The requirement is what the TCC grant is recorded against; if the copy did not preserve the
# signature, the grant would be attached to a bundle that no longer satisfies it -- and the symptom
# would be a TCC prompt at the worst possible moment rather than an error here.
codesign --verify --verbose=2 "$STAGED"

rm -rf "$APP_DEST"
mv "$STAGED" "$APP_DEST"

# --- the LaunchAgent ----------------------------------------------------------------------------
echo "==> writing $AGENT"
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
# Escaped, because these land on sed's REPLACEMENT side, where `&` means "the whole match" and `\`
# and the `|` delimiter mean what they always do. A home directory containing one of them would
# produce a mangled path in a plist that `plutil -lint` then passes, since it is valid XML naming a
# binary that does not exist -- and the symptom would be a LaunchAgent that silently never starts.
escape_replacement() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
sed -e "s|__DICTA_APP__|$(escape_replacement "$APP_DEST")|g" \
    -e "s|__DICTA_LOG__|$(escape_replacement "$LOG")|g" \
  "$ROOT/Scripts/launchagent.plist" > "$AGENT"
plutil -lint "$AGENT" >/dev/null

echo "==> reloading the agent"
# bootout first: bootstrap onto a live label fails, and an agent left loaded would keep the previous
# build resident. `|| true` because "not loaded" is the normal case on a first install.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

# `bootout` RETURNS BEFORE THE SERVICE IS GONE. It asks launchd to unload and comes back; the label
# can still be registered for a moment afterwards, and `bootstrap` landing in that window fails with
# `Bootstrap failed: 5: Input/output error`. Under `set -e` that killed the script three lines from
# the end -- after the agent had been booted out and before anything replaced it. The result is the
# worst outcome this script can produce: no daemon, no LaunchAgent, no summary printed, and the user
# finds out by pressing a chord and getting silence. Observed on 2026-08-16.
#
# So: wait for the label to actually disappear, then bootstrap, and retry the one error that means
# "you were too early". The waits are bounded -- a launchd that never lets go is a real failure and
# must be reported as one, not spun on for ever.
for _ in $(seq 1 50); do
    launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done

bootstrapped=0
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID" "$AGENT" 2>/tmp/dicta-bootstrap.$$; then
        bootstrapped=1
        break
    fi
    # Anything that is not the race is fatal on the spot: a malformed plist or a path that does not
    # exist will not fix itself by being retried, and retrying it five times only buries the reason.
    if ! grep -q "Input/output error" /tmp/dicta-bootstrap.$$; then
        cat /tmp/dicta-bootstrap.$$ >&2
        rm -f /tmp/dicta-bootstrap.$$
        echo "install: launchctl bootstrap failed for a reason that is not the unload race" >&2
        exit 1
    fi
    echo "    bootstrap raced the unload (attempt $attempt), retrying"
    sleep 0.3
done
rm -f /tmp/dicta-bootstrap.$$
if [ "$bootstrapped" -ne 1 ]; then
    echo "install: launchctl bootstrap kept losing the race with bootout -- the agent is NOT loaded" >&2
    echo "install: rerun this script, or load it by hand:" >&2
    echo "         launchctl bootstrap gui/$UID $AGENT" >&2
    exit 1
fi

launchctl kickstart -k "gui/$UID/$LABEL"

echo
echo "installed:"
echo "  ~/.local/bin/dictactl"
# Read off what was INSTALLED, not off the build tree's copy: this line is presented as confirming
# what landed in ~/Applications, and the requirement is what the TCC grant is recorded against.
# Captured before it is printed: a `codesign` that fails inside an `echo` argument is not caught by
# `set -e`, so the line would print an empty parenthesis and the script would exit 0 -- a confirmed
# install with no confirmation in it. `bundle.sh` already uses this shape.
REQUIREMENT="$(codesign -d -r- "$APP_DEST" 2>/dev/null \
  | sed -n 's/^#\{0,1\} *designated => //p')" || REQUIREMENT=""
[ -n "$REQUIREMENT" ] || REQUIREMENT="no designated requirement could be read"
echo "  $APP_DEST   ($REQUIREMENT)"
echo "  $AGENT      (log: $LOG)"
echo
# The order is load-bearing on a fresh install, and the daemon is already running by the time this
# prints. The models load ONCE, at daemon start, and never on the attempt path (D10) -- so a daemon
# started before they were fetched has already given up on them and refuses every dictation until it
# is restarted. Fetching without the kickstart therefore looks installed and dictates nothing, and
# the user finds out by pressing a chord and losing an utterance. `--fetch-models` prints the same
# restart line when it finishes; it is repeated here because this is the page the order is read off.
echo "next, in this order:"
echo "  1. $APP_DEST/Contents/MacOS/Dicta --fetch-models   (once, ~600 MB; skip if already staged)"
echo "  2. launchctl kickstart -k gui/$UID/$LABEL          (the running daemon loads models only"
echo "                                                      at start, so it must be restarted)"
echo "  3. add docs/keymap.snippet.conf to ~/.config/agterm/keymap.conf && agtermctl keymap reload"
