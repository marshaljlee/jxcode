#!/usr/bin/env bash
# Builds the JXCode Android APK (arm64-v8a).
#
#   ./build.sh            -> dist/jxcode-arm64-v8a-debug.apk
#   ./build.sh release    -> dist/jxcode-arm64-v8a-release.apk
#   ./build.sh install    -> builds debug and installs it on the attached device
#   ./build.sh native     -> rebuilds the bundled .so files (node, curl, llama…)
#   ./build.sh <anything> -> passed straight through to Gradle
#
# Three environment settings this script resolves that a bare `gradle` will not:
#
#   * Java does not read HTTP_PROXY/HTTPS_PROXY from the environment, so behind
#     a proxy dependency resolution hangs until it times out. The proxy is
#     translated into -D system properties here and into GRADLE_OPTS, which the
#     wrapper needs too — its distribution download runs in a separate JVM.
#   * JAVA_HOME: prefers Android Studio's bundled JDK, then Homebrew's
#     openjdk@21, then whatever java_home reports.
#   * The Gradle version. AGP 8.13 is not compatible with Gradle 9.6+: 9.6
#     removed the internal `org.gradle.api.problems` API the Android plugin
#     still calls, and the failure arrives as a stack trace from plugin
#     application rather than as a version complaint. `gradle` on the PATH is
#     whatever Homebrew last installed — currently 9.7 — so the build is pinned
#     to the wrapper's Gradle 8.14.3 instead. A bare `gradle` is only used when
#     the wrapper is missing, and then only after its version is checked.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

# `native` is the one task that must run where the sources are: it writes the
# .so files into app/src/main/jniLibs, which the Gradle build only reads.
if [ "${1:-}" = "native" ]; then
    exec "$SOURCE_DIR/native/build-native.sh"
fi

# Build outside iCloud.
#
# This project lives in iCloud Drive, and the File Provider re-uploads every
# file Gradle writes. A build emits tens of thousands of small files — R8, dex,
# resources, incremental Kotlin state — and each one becomes a round trip to
# the cloud, which is what turned a two-minute build into half an hour. So the
# tree is mirrored into a local cache directory and Gradle runs there; only the
# finished APK comes back.
BUILD_DIR="${JXCODE_BUILD_DIR:-$HOME/Library/Caches/jxcode-android-build}"
mkdir -p "$BUILD_DIR"
rsync -a --delete \
    --exclude '.gradle' \
    --exclude 'build' \
    --exclude 'app/build' \
    --exclude 'dist' \
    --exclude 'native' \
    "$SOURCE_DIR/" "$BUILD_DIR/"
cd "$BUILD_DIR"

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    :
elif [ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]; then
    JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
elif [ -x /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java ]; then
    JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
else
    JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
fi
export JAVA_HOME
[ -n "$JAVA_HOME" ] || { echo "error: no JDK 21+ found" >&2; exit 1; }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
[ -d "$ANDROID_HOME" ] || { echo "error: Android SDK not found at $ANDROID_HOME" >&2; exit 1; }

PROXY_ARGS=()
proxy_host_port() {
    local url="${1:-}"
    [ -n "$url" ] || return 0
    local without_scheme="${url#*://}"
    without_scheme="${without_scheme%%/*}"
    echo "${without_scheme%:*}" "${without_scheme##*:}"
}
read -r PHOST PPORT <<<"$(proxy_host_port "${HTTPS_PROXY:-${https_proxy:-}}")" || true
if [ -n "${PHOST:-}" ] && [ -n "${PPORT:-}" ]; then
    PROXY_ARGS+=("-Dhttps.proxyHost=$PHOST" "-Dhttps.proxyPort=$PPORT"
                 "-Dhttp.proxyHost=$PHOST"  "-Dhttp.proxyPort=$PPORT")
    # The wrapper downloads its distribution in its own JVM and only reads
    # GRADLE_OPTS, so without this the first run hangs on services.gradle.org.
    export GRADLE_OPTS="${GRADLE_OPTS:-} ${PROXY_ARGS[*]}"
fi

# The last Gradle AGP 8.x works with. Anything newer fails inside the Android
# plugin, so refuse it here rather than emit a 200-line stack trace.
MAX_GRADLE_MAJOR=9
MAX_GRADLE_MINOR=5

gradle_is_compatible() {
    local binary="$1" version major minor
    [ -x "$binary" ] || return 1
    version="$("$binary" --version 2>/dev/null | awk '/^Gradle /{print $2; exit}')"
    [ -n "$version" ] || return 1
    major="${version%%.*}"
    minor="$(echo "$version" | cut -d. -f2)"
    [ "$major" -lt "$MAX_GRADLE_MAJOR" ] && return 0
    [ "$major" -eq "$MAX_GRADLE_MAJOR" ] && [ "$minor" -le "$MAX_GRADLE_MINOR" ]
}

if [ -x ./gradlew ]; then
    GRADLE="./gradlew"
else
    GRADLE=""
    for candidate in "${GRADLE_HOME:-}/bin/gradle" /opt/homebrew/bin/gradle "$(command -v gradle 2>/dev/null || true)"; do
        [ -x "$candidate" ] || continue
        if gradle_is_compatible "$candidate"; then
            GRADLE="$candidate"
            break
        fi
        echo "warning: skipping $candidate — too new for AGP 8.13" >&2
    done
    [ -n "$GRADLE" ] || {
        echo "error: no compatible Gradle found; run 'gradle wrapper --gradle-version 8.14.3' or set GRADLE_HOME" >&2
        exit 1
    }
fi

# Copies the built APK somewhere with a name that says what it is. The size is
# the sanity check: with node, curl and llama.cpp bundled, a real APK is tens of
# MB — anything under 5 MB means the assets or the jniLibs did not land.
copy_to_dist() {
    local variant="$1" source="$2" size target
    [ -f "$source" ] || { echo "error: expected $source" >&2; return 1; }
    mkdir -p "$SOURCE_DIR/dist"
    target="$SOURCE_DIR/dist/jxcode-arm64-v8a-$variant.apk"
    cp "$source" "$target"
    size="$(wc -c <"$target" | tr -d ' ')"
    echo "dist/jxcode-arm64-v8a-$variant.apk ($(( size / 1024 / 1024 )) MB)"
}

TASK="${1:-debug}"
case "$TASK" in
    debug)
        "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" --console=plain :app:assembleDebug
        copy_to_dist debug app/build/outputs/apk/debug/app-debug.apk
        ;;
    release)
        "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" --console=plain :app:assembleRelease
        copy_to_dist release app/build/outputs/apk/release/app-release.apk
        ;;
    install)
        "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" --console=plain :app:installDebug
        ;;
    *)
        "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" --console=plain "$@"
        ;;
esac
