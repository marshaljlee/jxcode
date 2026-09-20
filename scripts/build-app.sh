#!/usr/bin/env bash
#
# Build JXCode.app — a double-clickable macOS bundle around the SwiftPM executable.
#
# `swift run` works for development, but a bare executable has no Info.plist, so
# it gets no dock icon and no proper activation behaviour. This wraps it.

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/JXCode.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
# --disable-sandbox: SwiftPM shells out to sandbox-exec to compile its manifest,
# which fails when the build itself already runs inside a sandbox.
swift build --disable-sandbox -c "$CONFIG"

BINPATH="$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path)"
BIN="$BINPATH/JXCodeApp"
CLI="$BINPATH/jxcode"

if [[ ! -x "$BIN" ]]; then
  echo "error: executable not found at $BIN" >&2
  exit 1
fi

# The two products differ only by case, and the default filesystem does not.
# If they ever resolve to the same inode again, the .app would contain the
# CLI (or vice versa) and the failure would be baffling rather than obvious.
if [[ -e "$CLI" && "$BIN" -ef "$CLI" ]]; then
  echo "error: JXCodeApp and jxcode are the same file — the product names" >&2
  echo "       collide case-insensitively. Rename one in Package.swift." >&2
  exit 1
fi

# Another collision symptom: the app must link AppKit, the CLI must not.
if ! otool -L "$BIN" 2>/dev/null | grep -q AppKit; then
  echo "error: $BIN does not link AppKit — it is not the app binary." >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JXCode"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>JXCode</string>
    <key>CFBundleDisplayName</key>     <string>JXCode</string>
    <key>CFBundleIdentifier</key>      <string>app.jxcode.JXCode</string>
    <key>CFBundleExecutable</key>      <string>JXCode</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <!-- Needed to embed agent web dashboards (e.g. Jules). -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature. Best effort: an unsigned bundle is still runnable locally,
# but Gatekeeper is friendlier with a signature, and a stable identity keeps
# Keychain and WebKit data-store access consistent across rebuilds.
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP" 2>/dev/null \
    && echo "    signed" \
    || echo "    skipped (codesign unavailable or refused)"
fi

echo
echo "Built: $APP"
echo "Launch: open '$APP'"
echo
echo "Note: the sandbox lives at ~/Library/Application Support/JXCode"
echo "      override with JXCODE_ROOT for a throwaway environment."
