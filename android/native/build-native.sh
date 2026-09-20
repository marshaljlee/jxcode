#!/usr/bin/env bash
# Builds the arm64-v8a native libraries and installs them into jniLibs.
#
#   ./build-native.sh            pty + llama (llama.cpp must be fetched)
#   ./build-native.sh pty-only   pty only, no llama.cpp needed
#
# Uses the NDK clang directly rather than AGP's externalNativeBuild: the SDK
# has no bundled cmake, and keeping the llama.cpp build out of Gradle means a
# full rebuild of a 10-minute C++ tree never happens by accident on a Kotlin
# change.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-all}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"
[ -n "$NDK" ] || { echo "error: no NDK under $ANDROID_HOME/ndk" >&2; exit 1; }

API=29
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
CLANG="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
CLANGXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"
OUT="$(pwd)/../app/src/main/jniLibs/arm64-v8a"
mkdir -p "$OUT"
echo "NDK: $NDK"

# --- pty ---------------------------------------------------------------------
echo "==> libjxpty.so"
"$CLANG" -shared -fPIC -O2 -Wall \
    ../app/src/main/cpp/jxpty.c -o "$OUT/libjxpty.so"
echo "    $OUT/libjxpty.so"

if [ "$MODE" = "pty-only" ]; then
    exit 0
fi

# --- llama.cpp ---------------------------------------------------------------
[ -d llama.cpp ] || { echo "error: run ./fetch-llama.sh first" >&2; exit 1; }

BUILD="$(pwd)/build/arm64-novomp"
echo "==> llama.cpp (arm64-v8a, CPU)"
cmake -S llama.cpp -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-$API \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_STANDALONE=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_CPU_ALL_VARIANTS=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_ALL_WARNINGS=OFF \
    -DLLAMA_ALL_WARNINGS_3RD_PARTY=OFF \
    -DBUILD_SHARED_LIBS=ON

cmake --build "$BUILD" --config Release -j"$(sysctl -n hw.ncpu)"

mapfile -t LIBS < <(find "$BUILD" -name '*.so' -not -path '*/CMakeFiles/*')
[ ${#LIBS[@]} -gt 0 ] || { echo "error: llama.cpp produced no shared libraries" >&2; exit 1; }
for lib in "${LIBS[@]}"; do
    cp "$lib" "$OUT/$(basename "$lib")"
    echo "    $OUT/$(basename "$lib")"
done

# llama.cpp and the bridge are C++. Without the shared runtime shipped too,
# libjxllama.so dlopen-fails on device with "library libc++_shared.so not
# found" — a runtime-only failure that a successful link hides completely.
STLLIB="$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
if [ -f "$STLLIB" ]; then
    cp "$STLLIB" "$OUT/"
    echo "    $OUT/libc++_shared.so"
fi

echo "==> libjxllama.so"
"$CLANGXX" -shared -fPIC -O3 -std=c++17 \
    -I llama.cpp/include \
    -I llama.cpp/ggml/include \
    -I llama.cpp/src \
    jxllama.cpp \
    "${LIBS[@]}" \
    -llog -landroid \
    -o "$OUT/libjxllama.so"
echo "    $OUT/libjxllama.so"

echo "done"
