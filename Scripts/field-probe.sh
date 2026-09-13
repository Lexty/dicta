#!/usr/bin/env bash
# TEMPORARY: plan 20260912-dicta-focused-fields, Task 1 (F11). Deleted together with Sources/FieldProbe.
#
# Usage: field-probe.sh install     build, sign with the local identity, (re)load as a LaunchAgent
#        field-probe.sh uninstall   unload the agent and remove the bundle and the plist
#        field-probe.sh <command…>  send one command to the running probe and print the reply
#
# The probe gets its own identifier, dev.personal.dicta.fieldprobe, signed by the same "Dicta Local
# Signing" identity as the daemon: the same designated-requirement shape, and a TCC entry of its own
# rather than one that would leave traces on the daemon's.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.personal.dicta.fieldprobe"
APP_DIR="$HOME/Applications/FieldProbe.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/dicta-fieldprobe.log"
SOCKET="$HOME/Library/Application Support/$LABEL/probe.sock"
KEYCHAIN="$HOME/Library/Keychains/dicta-codesign.keychain-db"
IDENTITY_CN="Dicta Local Signing"

install_probe() {
  cd "$ROOT"
  swift build -c release --product FieldProbe
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR/Contents/MacOS"
  cp .build/release/FieldProbe "$APP_DIR/Contents/MacOS/FieldProbe"
  cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FieldProbe</string>
    <key>CFBundleExecutable</key><string>FieldProbe</string>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
  security unlock-keychain -p "" "$KEYCHAIN"
  local identity
  identity="$(security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY_CN" \
    | grep -oE '[0-9A-F]{40}' | head -1 || true)"
  [[ -n "$identity" ]] || { echo "no '$IDENTITY_CN' identity -- run Scripts/setup-signing.sh" >&2; exit 1; }
  codesign --force --sign "$identity" --identifier "$LABEL" --keychain "$KEYCHAIN" "$APP_DIR"
  echo "designated requirement: $(codesign -d -r- "$APP_DIR" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')"

  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP_DIR/Contents/MacOS/FieldProbe</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  for _ in $(seq 1 50); do
    launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
  done
  rm -f "$SOCKET"
  launchctl bootstrap "gui/$UID" "$AGENT"
  for _ in $(seq 1 50); do
    [[ -S "$SOCKET" ]] && break
    sleep 0.1
  done
  echo "loaded; log: $LOG"
}

case "${1:-}" in
  install) install_probe ;;
  uninstall)
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    rm -rf "$APP_DIR" "$AGENT"
    echo "removed"
    ;;
  '') sed -n 2,7p "${BASH_SOURCE[0]}"; exit 2 ;;
  *)
    python3 - "$SOCKET" "$*" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode())
chunks = []
while True:
    data = s.recv(65536)
    if not data:
        break
    chunks.append(data)
sys.stdout.write(b"".join(chunks).decode())
PY
    ;;
esac
