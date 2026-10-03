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

# The bundle is assembled and signed in a scratch directory *outside* iCloud,
# then copied to `.build`.
#
# This repo lives in iCloud Drive, and a File Provider volume hands the bundle
# two attributes the signer refuses outright — `com.apple.FinderInfo` on the
# bundle root and directories, and `com.apple.fileprovider.fpfs#P` — which
# `xattr -cr` cannot remove there and `xattr -d` reports as "No such xattr"
# while `xattr -l` still lists them. Signing in place therefore failed every
# time with "resource fork, Finder information, or similar detritus not
# allowed", and because the failure was swallowed the build still reported
# success and shipped a bundle with no signature at all.
#
# Assembling off the synced volume sidesteps the File Provider entirely. The
# copy back is plain, so no AppleDouble `._*` files ride along and the
# signature survives it.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/jxcode-bundle.XXXXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# Assembled and signed here, then copied to `$APP` at the end.
BUNDLE="$STAGE/JXCode.app"

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
# A previous bundle can still be held by the File Provider while iCloud is
# syncing a freshly signed .app, and `rm -rf` then fails with "Operation not
# permitted". Under `set -e` that aborts a build which has already compiled
# successfully, so it is retried — and if it genuinely cannot be removed, the
# script stops rather than leaving a stale bundle in place and reporting
# success against it.
for attempt in 1 2 3 4 5; do
  rm -rf "$BUNDLE" 2>/dev/null || true
  if [[ ! -e "$BUNDLE" ]]; then break; fi
  echo "    waiting for the filesystem to release the old bundle (try $attempt)" >&2
  sleep 2
done
if [[ -e "$BUNDLE" ]]; then
  echo "error: could not remove $APP — something still holds it." >&2
  echo "       Quit JXCode if it is running, then retry." >&2
  exit 1
fi
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/JXCode"

# The icon/logo: assets/icon.png is the source of truth (JX2.png, 1023×1023).
# Iconset renders every size macOS asks for; logo.png is the same art for the
# in-app mark (AppLogoView reads it from Bundle.main at runtime).
ICON_SRC="$ROOT/assets/icon.png"
if [[ -f "$ICON_SRC" ]]; then
  echo "==> Rendering icon from assets/icon.png"
  # The source PNG may carry Finder/quarantine xattrs (iCloud Drive does
  # this), and codesign refuses a bundle whose resources have them.
  xattr -c "$ICON_SRC" 2>/dev/null || true
  ICONSET="$BUNDLE.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for spec in 16 32 128 256 512; do
    sips -z "$spec" "$spec" "$ICON_SRC" --out "$ICONSET/icon_${spec}x${spec}.png" >/dev/null
    dbl=$((spec * 2))
    sips -z "$dbl" "$dbl" "$ICON_SRC" --out "$ICONSET/icon_${spec}x${spec}@2x.png" >/dev/null
  done
  if iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    AppIcon.icns written"
  else
    echo "    warning: iconutil failed; bundle ships without an .icns" >&2
  fi
  rm -rf "$ICONSET"
  cp "$ICON_SRC" "$BUNDLE/Contents/Resources/logo.png"
  # Deliberately NOT bundling logo-mark.png.
  #
  # This used to generate the X2 mark into the bundle, and `AppLogoView` prefers
  # that file over its bolt glyph — so every built app drew a white "JX" in the
  # sidebar. The app should show the accent-coloured bolt there instead,
  # which is what `AppLogoView` falls back to when no mark is bundled.
  #
  # Removing the file rather than editing `Theme.swift` is the smaller change:
  # the fallback path is already there, is already tested by `swift run` (which
  # has no bundle resource at all), and now describes the shipped build instead
  # of a development accident.
  #
  # Set JXCODE_BUNDLE_LOGO_MARK=1 to get the old behaviour back.
  if [ "${JXCODE_BUNDLE_LOGO_MARK:-0}" = "1" ]; then
    if ! swift "$ROOT/scripts/make-logo-mark.swift" "$ICON_SRC" \
          "$BUNDLE/Contents/Resources/logo-mark.png" 2>/dev/null; then
      echo "    warning: mark generation failed; using the committed copy" >&2
      cp "$ROOT/assets/logo-mark.png" "$BUNDLE/Contents/Resources/logo-mark.png"
    fi
  fi
else
  echo "    note: assets/icon.png missing — bundle ships with the default icon" >&2
fi

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
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
#
# This step used to be allowed to fail. It ran `codesign … 2>/dev/null` and
# printed "skipped" on failure, so a build that could not be signed reported
# success and shipped a bundle with no _CodeSignature directory at all. An
# unsigned bundle loses its Dock icon in some states, re-prompts for Keychain
# access on every rebuild, and fails WebKit's local data store — none of which
# points at signing. So it fails the build instead.
if command -v codesign >/dev/null 2>&1; then
echo "==> Ad-hoc signing"

# `xattr -cr` is not enough on its own, and this repo lives in iCloud Drive.
# Three attributes survive it and each one is refused by the signer:
#
#   com.apple.FinderInfo  on directories. iCloud re-attaches it on sync, and
#                         inside a File Provider volume `xattr -d` reports
#                         "No such xattr" while `xattr -l` still lists it —
#                         so the only way to clear it is to move the bundle
#                         out of the synced tree and strip it there.
#   com.apple.macl        on the copied binary and resources. Not removable by
#                         `xattr -c` in every case; named deletion works.
#   com.apple.fileprovider.fpfs#P  on the bundle root, same File Provider
#                         behaviour as FinderInfo.
#
# Clearing them by name is harmless when they are absent, so this runs
# unconditionally rather than trying to detect the iCloud case first.
xattr -cr "$BUNDLE" 2>/dev/null || true
find "$BUNDLE" -type d -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "$BUNDLE" -type f -exec xattr -d com.apple.macl {} \; 2>/dev/null || true

# `$BUNDLE` is in the scratch directory, so none of the File Provider
# attributes above are present in the first place. The named deletions stay
# because they are free when the attributes are absent and are what makes this
# script work if `$STAGE` is ever pointed back at a synced path.
if ! codesign --force --deep --sign - "$BUNDLE"; then
  echo >&2
  echo "error: the bundle could not be signed, and an unsigned bundle is not" >&2
  echo "       a usable build — it loses its Dock icon, re-prompts for" >&2
  echo "       Keychain access each rebuild and fails WebKit's local store." >&2
  echo "       The message above is the signer's own; it names the attribute" >&2
  echo "       it refused if it is the detritus one." >&2
  exit 1
fi
echo "    signed"

# Signing without checking means a signature that exists but is not valid is
# reported the same as one that works.
if ! codesign --verify --verbose=2 "$BUNDLE"; then
  echo >&2
  echo "error: the signature was written but does not verify." >&2
  exit 1
fi
fi

# Publish the signed bundle. `cp -R` rather than `ditto`, and from the scratch
# copy rather than from anywhere iCloud can add `._*` files: an AppleDouble
# file inside a signed bundle is rejected by the signature, which is the same
# trap this script already documents for /Applications.
echo "==> Installing to $APP"
for attempt in 1 2 3 4 5; do
  rm -rf "$APP" 2>/dev/null || true
  if [[ ! -e "$APP" ]]; then break; fi
  echo "    waiting for the filesystem to release the old bundle (try $attempt)" >&2
  sleep 2
done
if [[ -e "$APP" ]]; then
  echo "error: could not remove $APP — something still holds it." >&2
  echo "       Quit JXCode if it is running, then retry." >&2
  exit 1
fi
cp -R "$BUNDLE" "$APP"

# The copy is the shipped artifact, so the signature is checked again where it
# will actually be launched from rather than trusted from the staging copy.
if ! codesign --verify "$APP" 2>/dev/null; then
  echo >&2
  echo "error: the bundle did not survive the copy to $APP signed." >&2
  echo "       iCloud re-attached attributes on the way in. Build with" >&2
  echo "       JXCODE_BUILD_STAGE pointed outside iCloud, then retry." >&2
  exit 1
fi
echo "    signature verified in place"

echo
echo "Built: $APP"
echo "Launch: open '$APP'"
echo
echo "Note: the sandbox lives at ~/Library/Application Support/JXCode"
echo "      override with JXCODE_ROOT for a throwaway environment."
