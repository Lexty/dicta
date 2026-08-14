#!/usr/bin/env bash
# Build Dicta.app with SwiftPM under Command Line Tools only (there is no full Xcode here, so
# `xcodebuild` is not an option -- see CLAUDE.md), then sign it with the local identity.
#
# The bundle is not an application in any user-facing sense: no icon, no dock tile, no menu bar, no
# windows (D11, §12, §13). It exists so the microphone TCC grant has a stable anchor. Everything
# below serves that one purpose:
#
#   * the identifier passed to codesign is `dev.personal.dicta`, the same string as `Paths.bundleID`,
#     so the grant, the socket and the record all sit under one identity;
#   * the signature comes from a certificate rather than ad-hoc, so the DESIGNATED REQUIREMENT is
#     `identifier "…" and certificate leaf = H"…"` and does not move when the binary changes. An
#     ad-hoc signature would pin it to the cdhash, and every rebuild would revoke the grant.
#
# That second property is checked here rather than trusted: the script fails if the requirement it
# produced mentions a cdhash or does not name the certificate leaf. A budget with no check drifts,
# and this one drifts silently -- the symptom is a TCC prompt appearing again weeks later.
#
# Usage: bundle.sh            build, sign, verify -> ./Dicta.app
#        bundle.sh --print-requirement   print the designated requirement of an existing Dicta.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Dicta"
BUNDLE_ID="dev.personal.dicta"
APP_DIR="$ROOT/$APP_NAME.app"
BIN="$ROOT/.build/release/Dicta"
KEYCHAIN="$HOME/Library/Keychains/dicta-codesign.keychain-db"
IDENTITY_CN="Dicta Local Signing"

# The designated requirement, on one line, as codesign reports it. This is the string a TCC grant is
# recorded against; comparing it across two builds is how "the grant survives a rebuild" is verified
# without waiting weeks to find out that it did not.
# The leading `# ` is not decoration: codesign comments the line out when the requirement is
# IMPLICIT — which is exactly the ad-hoc case this script exists to catch. Stripping it here means
# the cdhash check below reports "ad-hoc signature" rather than the misleading "not signed at all".
# The `codesign` call is taken on its own line, and not piped, on purpose. This script runs under
# `set -euo pipefail`, so an unsigned bundle -- where `codesign -d` exits non-zero -- killed the
# whole script at the assignment below, and the "it is not signed" message that exists to explain
# exactly that case was unreachable. `--print-requirement` failed the same way, with no output and
# a bare codesign exit status.
requirement() {
  local described
  described="$(codesign -d -r- "$1" 2>/dev/null)" || return 0
  printf '%s\n' "$described" | sed -n 's/^#\{0,1\} *designated => //p'
}

if [[ "${1:-}" == "--print-requirement" ]]; then
  if [[ ! -d "$APP_DIR" ]]; then
    echo "error: $APP_DIR does not exist -- run bundle.sh first" >&2
    exit 1
  fi
  requirement "$APP_DIR"
  exit 0
fi

GIT_DESC="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

echo "==> swift build -c release"
swift build -c release

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Which build is running is a question the record cannot answer, and "the daemon is old" is a
# plausible cause of a symptom that otherwise looks like a bug. The signature seals Contents, so
# this has to happen before codesign.
PB=/usr/libexec/PlistBuddy
"$PB" -c "Add :DictaBuildRevision string $GIT_DESC" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || "$PB" -c "Set :DictaBuildRevision $GIT_DESC" "$APP_DIR/Contents/Info.plist"

# setup-signing.sh is idempotent and non-interactive, so on a fresh machine the first build creates
# the identity with no prompt and no password.
if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_CN"; then
  echo "==> no local signing identity yet -- running the one-time setup"
  bash "$ROOT/Scripts/setup-signing.sh"
fi
security unlock-keychain -p "" "$KEYCHAIN"
# `|| true` so the explicit check below is the thing that reports: under `set -o pipefail` a grep
# that matches nothing fails the whole substitution, and `set -e` would exit before the sentence
# naming what went wrong ever ran.
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" \
  | grep "$IDENTITY_CN" | grep -oE '[0-9A-F]{40}' | head -1 || true)"
if [[ -z "$IDENTITY" ]]; then
  echo "error: could not resolve the '$IDENTITY_CN' signing identity" >&2
  exit 1
fi

echo "==> codesign (identity=$IDENTITY_CN, identifier=$BUNDLE_ID)"
codesign --force --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/Dicta.entitlements" \
  --keychain "$KEYCHAIN" \
  "$APP_DIR"

codesign --verify --verbose=2 "$APP_DIR"

# --- the check that makes the grant survivable, not merely intended -----------------------------
REQ="$(requirement "$APP_DIR")"
if [[ -z "$REQ" ]]; then
  echo "error: the bundle has no designated requirement -- it is not signed" >&2
  exit 1
fi
if [[ "$REQ" == *cdhash* ]]; then
  echo "error: the designated requirement is pinned to a cdhash:" >&2
  echo "       $REQ" >&2
  echo "       that is an ad-hoc signature. Every rebuild would revoke the microphone grant." >&2
  exit 1
fi
if [[ "$REQ" != *"identifier \"$BUNDLE_ID\""* || "$REQ" != *"certificate leaf"* ]]; then
  echo "error: unexpected designated requirement:" >&2
  echo "       $REQ" >&2
  echo "       expected: identifier \"$BUNDLE_ID\" and certificate leaf = H\"…\"" >&2
  exit 1
fi

echo "==> done: $APP_DIR  (revision=$GIT_DESC)"
echo "    designated requirement, stable across rebuilds:"
echo "    $REQ"
