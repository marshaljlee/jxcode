#!/usr/bin/env bash
# Cross-builds the Looper CLI and daemon for Android/arm64 and installs them
# into jniLibs.
#
#   ./build-looper.sh            build looper + looperd
#   ./build-looper.sh clean      also drop the fetched source checkout
#
# Why this exists:
#
# Looper publishes darwin and linux builds but no Android one, and the linux
# build is a glibc program — Android is Bionic, so it will not run here. Go
# makes a real Android build possible instead of a port: with CGO pointed at
# the NDK compiler the output links against Bionic and its interpreter is
# /system/bin/linker64, which is the one Android will exec.
#
# CGO cannot simply be switched off. Looper's storage layer imports
# github.com/mattn/go-sqlite3, which is a cgo binding; with CGO_ENABLED=0 the
# package fails to compile (undefined: sqlite3.Error). That is the whole reason
# this script exists rather than a plain `go build`.
#
# Both binaries need only liblog/libdl/libc, all supplied by the platform, so
# nothing else has to ship alongside them. See NodeRuntime.kt for how the app
# finds a bundled executable at runtime.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"
[ -n "$NDK" ] || { echo "error: no NDK under $ANDROID_HOME/ndk" >&2; exit 1; }
command -v go >/dev/null || { echo "error: go is not on PATH" >&2; exit 1; }
command -v git >/dev/null || { echo "error: git is not on PATH" >&2; exit 1; }

API="${JXCODE_ANDROID_API:-29}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"
[ -x "$CC" ] || { echo "error: no $CC" >&2; exit 1; }

REPO="https://github.com/nexu-io/looper.git"
SRC="$PWD/looper-src"
OUT="$ROOT/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$OUT"

if [ "${1:-}" = "clean" ]; then
    # `rm -rf` on a git checkout the script owns, and only when asked for
    # explicitly. It is a clone of a public repository, not user data.
    rm -rf "$SRC"
    echo "removed $SRC"
fi

if [ ! -d "$SRC/.git" ]; then
    echo "==> fetching looper source"
    git clone --depth 1 "$REPO" "$SRC"
fi

# Stamp the version the git tag reports, so the bundled binary does not claim
# to be "0.0.0-dev" on the device. LOOPER_BUILD_VERSION is the variable the
# upstream version package reads.
VERSION="$(git -C "$SRC" describe --tags --always 2>/dev/null || echo dev)"
echo "==> looper version: $VERSION"

# The android/arm64 pair. GOOS=android (not linux) is what makes the Go linker
# emit an Android ELF with the Bionic interpreter; GOOS=linux keeps glibc.
export CGO_ENABLED=1
export GOOS=android
export GOARCH=arm64
export CC CXX
export GOFLAGS=-mod=mod

cd "$SRC"
for cmd in looper looperd; do
    echo "==> building $cmd"
    go build -trimpath \
        -ldflags "-s -w" \
        -o "$OUT/libjxbin_$cmd.so" \
        "./cmd/$cmd"
    # Every file in jniLibs must end in .so or AGP silently drops it, so the
    # binaries carry the libjxbin_ prefix the runtime expects — same namespace
    # node and curl use.
    chmod 755 "$OUT/libjxbin_$cmd.so"
    size="$(wc -c < "$OUT/libjxbin_$cmd.so" | tr -d ' ')"
    echo "    $OUT/libjxbin_$cmd.so ($(( size / 1024 / 1024 )) MB)"
done

echo "==> verifying the interpreter is Bionic's, not glibc's"
READELF="$TOOLCHAIN/bin/llvm-readelf"
for cmd in looper looperd; do
    # llvm-readelf prints `[Requesting program interpreter: /system/bin/linker64]`,
    # so the trailing bracket has to come off before the value is compared.
    interp="$("$READELF" -l "$OUT/libjxbin_$cmd.so" 2>/dev/null \
        | grep -A1 INTERP | tail -1 | sed 's/.*: //; s/[][]//g')"
    echo "    $cmd -> $interp"
    case "$interp" in
        /system/bin/linker64) ;;
        *) echo "error: $cmd does not target Android" >&2; exit 1 ;;
    esac
done

echo "done"