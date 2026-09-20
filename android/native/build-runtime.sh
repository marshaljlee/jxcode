#!/usr/bin/env bash
# Bundle a self-contained command line runtime into the APK.
#
# Node (plus npm and npx) and curl come from Termux's aarch64 packages. Three
# things have to be dealt with before they can live inside an app:
#
#   1. Android 10+ will not exec code out of an app's data directory (W^X), so
#      the binaries stay in nativeLibraryDir — the one place left that is
#      still executable — and are launched from there.
#   2. AGP only packages jniLibs whose name ends in `.so`, which rules out
#      versioned SONAMEs like libcrypto.so.3. bundle-runtime.py renames the
#      whole closure to libjx*.so and rewrites the ELF to match.
#   3. Library search is handled at runtime with LD_LIBRARY_PATH pointing at
#      nativeLibraryDir, not by the Termux RUNPATH baked into the binaries.
#
# Anything that is not machine code — npm's JavaScript, the CA bundle — is
# shipped as an asset and unpacked into the sandbox on first boot.
#
# Output:
#   app/src/main/jniLibs/arm64-v8a/libjx*.so
#   app/src/main/assets/runtime/npm.zip
#   app/src/main/assets/runtime/ca-bundle.crt
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PYTHON="${PYTHON:-/Users/joshua/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3}"

DEBS="$HERE/node-deb/debs"
WORK="$HERE/runtime"
OUT_LIB="$ROOT/app/src/main/jniLibs/arm64-v8a"
OUT_ASSETS="$ROOT/app/src/main/assets/runtime"

# Executables to bundle. Each becomes libjxbin_<name>.so in the APK.
ENTRIES="bin/node bin/curl"

# Packages the runtime is built from; `clean` also throws away the staged
# prefix so a removed dependency cannot survive in the next APK.
PACKAGES_FILE="$HERE/runtime-packages.txt"
CLEAN=0
if [ "${1:-}" = "clean" ]; then CLEAN=1; fi

mkdir -p "$OUT_LIB" "$OUT_ASSETS"

# ---------------------------------------------------------------- fetch ----
[ -f "$PACKAGES_FILE" ] || { echo "missing $PACKAGES_FILE" >&2; exit 1; }
# shellcheck disable=SC2046
"$PYTHON" "$HERE/fetch-termux.py" $(cat "$PACKAGES_FILE") || exit 1
MANIFEST="$WORK/deb-manifest.txt"

if [ "$CLEAN" = "1" ]; then
  # A fresh directory rather than rm -rf: the prefix is ~150 MB and a bulk
  # delete of it is not worth the risk of an interrupted run.
  STAGE="$WORK/stage-$(date +%s)"
else
  STAGE="$WORK/stage"
fi
PREFIX="$STAGE/data/data/com.termux/files/usr"

# ---------------------------------------------------------------- stage ----
# Extract exactly what the manifest lists into one Termux-shaped prefix.
while read -r deb; do
  [ -n "$deb" ] && "$PYTHON" "$HERE/extract-deb.py" "$deb" "$STAGE" >/dev/null
done < "$MANIFEST"

# -------------------------------------------------------------- package ----
"$PYTHON" "$HERE/bundle-runtime.py" "$PREFIX" "$OUT_LIB" $ENTRIES

# npm is pure JavaScript: one zip beats ~2000 asset files in every build.
if [ -d "$PREFIX/lib/node_modules/npm" ]; then
  rm -f "$OUT_ASSETS/npm.zip"
  (cd "$PREFIX/lib/node_modules" && zip -qr "$OUT_ASSETS/npm.zip" npm)
fi

# A CA bundle of its own: Node ships one, curl does not, and agents shell out
# to curl often enough that a missing trust store is a real failure.
if [ -f "$PREFIX/etc/tls/cert.pem" ]; then
  cp "$PREFIX/etc/tls/cert.pem" "$OUT_ASSETS/ca-bundle.crt"
fi

echo "assets:"
ls -la "$OUT_ASSETS"
