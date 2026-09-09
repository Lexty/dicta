#!/usr/bin/env bash
# Build Dicta.app with SwiftPM under Command Line Tools only (there is no full Xcode here, so
# `xcodebuild` is not an option -- see CLAUDE.md), then sign it with the local identity.
#
# The bundle is not an application in any user-facing sense: no dock tile, no menu bar, no windows
# (D11, §12, §13). It exists so the microphone TCC grant has a stable anchor. Everything below
# serves that one purpose:
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
# TWO bundles, not one (D27). The daemon is the TCC anchor described above; `DictaMenu.app` is the
# menu-bar UI, which opens no microphone and asks for no permission. They are built and signed by
# one script on purpose: the property that matters — an identity-based designated requirement — has
# to hold for both, and a second script is how two things that must agree stop agreeing. The menu is
# signed with the SAME identity and checked by the SAME assertions, and it is given NO entitlements
# file, so it cannot claim `com.apple.security.device.audio-input` even by a copy-paste accident.
#
# Usage: bundle.sh                          build, sign, verify -> ./Dicta.app and ./DictaMenu.app
#        bundle.sh --print-requirement [daemon|menu]   print an existing bundle's requirement
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Dicta"
BUNDLE_ID="dev.personal.dicta"
APP_DIR="$ROOT/$APP_NAME.app"
BIN="$ROOT/.build/release/Dicta"
MENU_APP_NAME="DictaMenu"
MENU_BUNDLE_ID="dev.personal.dicta.menu"
MENU_APP_DIR="$ROOT/$MENU_APP_NAME.app"
MENU_BIN="$ROOT/.build/release/DictaMenu"
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

# Unknown arguments are refused rather than ignored. Falling through to the default was not a
# harmless default: a typo -- `--print-requirment` -- turned a read-only query into a release
# rebuild and a full re-sign of the bundle every TCC grant is anchored to.
case "${1:-}" in
  --print-requirement)
    if [[ "$#" -gt 2 ]]; then
      echo "error: --print-requirement takes at most one target (daemon|menu)" >&2
      exit 2
    fi
    # Defaults to the daemon, because that is the bundle a TCC grant is recorded against and the
    # question is almost always about it. The menu is named explicitly or not at all.
    case "${2:-daemon}" in
      daemon) TARGET_DIR="$APP_DIR" ;;
      menu)   TARGET_DIR="$MENU_APP_DIR" ;;
      *)
        echo "error: unknown target '${2}' -- expected daemon or menu" >&2
        exit 2
        ;;
    esac
    if [[ ! -d "$TARGET_DIR" ]]; then
      echo "error: $TARGET_DIR does not exist -- run bundle.sh first" >&2
      exit 1
    fi
    requirement "$TARGET_DIR"
    exit 0
    ;;
  '') ;;
  *)
    echo "bundle: unknown argument: $1" >&2
    exit 2
    ;;
esac

GIT_DESC="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

echo "==> swift build -c release"
swift build -c release

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

if [[ ! -x "$MENU_BIN" ]]; then
  echo "error: binary not found at $MENU_BIN" >&2
  exit 1
fi

# Which build is running is a question the record cannot answer, and "the daemon is old" is a
# plausible cause of a symptom that otherwise looks like a bug. The signature seals Contents, so
# this has to happen before codesign.
PB=/usr/libexec/PlistBuddy

# The icon both bundles carry. It is committed rather than generated here: `Scripts/make-icon.sh`
# rebuilds it from `Resources/icon-source.png` when the artwork changes, and a build that regenerated
# it would put an image toolchain on the path between a source edit and a running daemon.
ICON="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
  echo "error: $ICON is missing -- run Scripts/make-icon.sh" >&2
  exit 1
fi

# Lay out one bundle: $1 app dir, $2 executable name, $3 built binary, $4 Info.plist source.
#
# The icon goes in unconditionally, and both plists name it. A bundle whose CFBundleIconFile points
# at a file that is not there does not fail to build and does not warn: it renders as a blank sheet
# of paper, which is indistinguishable from having no icon at all and is how this would rot.
assemble() {
  local app_dir="$1" exe="$2" binary="$3" plist="$4"
  echo "==> assembling $(basename "$app_dir")"
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
  cp "$binary" "$app_dir/Contents/MacOS/$exe"
  cp "$ICON" "$app_dir/Contents/Resources/AppIcon.icns"
  cp "$plist" "$app_dir/Contents/Info.plist"
  "$PB" -c "Add :DictaBuildRevision string $GIT_DESC" "$app_dir/Contents/Info.plist" 2>/dev/null \
    || "$PB" -c "Set :DictaBuildRevision $GIT_DESC" "$app_dir/Contents/Info.plist"
}

assemble "$APP_DIR" "$APP_NAME" "$BIN" "$ROOT/Resources/Info.plist"
assemble "$MENU_APP_DIR" "$MENU_APP_NAME" "$MENU_BIN" "$ROOT/Resources/DictaMenu-Info.plist"

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

# Sign one bundle and assert the property the whole script exists for: $1 app dir, $2 identifier,
# $3 entitlements path or the empty string.
#
# The menu passes the empty string, and that is a decision rather than an omission. Entitlements are
# claims a binary makes about itself; handing the UI the daemon's file would have it claiming
# `com.apple.security.device.audio-input`, which is precisely the second-binary-can-open-the-device
# situation D11 forbids. The linkage check says it does not; this says it may not.
sign_and_check() {
  local app_dir="$1" identifier="$2" entitlements="$3"
  echo "==> codesign (identity=$IDENTITY_CN, identifier=$identifier)"
  if [[ -n "$entitlements" ]]; then
    codesign --force --sign "$IDENTITY" \
      --identifier "$identifier" \
      --entitlements "$entitlements" \
      --keychain "$KEYCHAIN" \
      "$app_dir"
  else
    codesign --force --sign "$IDENTITY" \
      --identifier "$identifier" \
      --keychain "$KEYCHAIN" \
      "$app_dir"
  fi

  codesign --verify --verbose=2 "$app_dir"

  # --- the check that makes the grant survivable, not merely intended ---------------------------
  local req
  req="$(requirement "$app_dir")"
  if [[ -z "$req" ]]; then
    echo "error: $app_dir has no designated requirement -- it is not signed" >&2
    exit 1
  fi
  if [[ "$req" == *cdhash* ]]; then
    echo "error: the designated requirement is pinned to a cdhash:" >&2
    echo "       $req" >&2
    echo "       that is an ad-hoc signature. Every rebuild would revoke the microphone grant." >&2
    exit 1
  fi
  if [[ "$req" != *"identifier \"$identifier\""* || "$req" != *"certificate leaf"* ]]; then
    echo "error: unexpected designated requirement:" >&2
    echo "       $req" >&2
    echo "       expected: identifier \"$identifier\" and certificate leaf = H\"…\"" >&2
    exit 1
  fi

  echo "==> done: $app_dir  (revision=$GIT_DESC)"
  echo "    designated requirement, stable across rebuilds:"
  echo "    $req"
}

sign_and_check "$APP_DIR" "$BUNDLE_ID" "$ROOT/Resources/Dicta.entitlements"
sign_and_check "$MENU_APP_DIR" "$MENU_BUNDLE_ID" ""
