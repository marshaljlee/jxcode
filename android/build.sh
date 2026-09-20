#!/usr/bin/env bash
# Builds the JXCode Android APK (arm64-v8a).
#
#   ./build.sh            -> app/build/outputs/apk/debug/app-arm64-v8a-debug.apk
#   ./build.sh release    -> app/build/outputs/apk/release/app-arm64-v8a-release.apk
#   ./build.sh install    -> builds debug and installs it on the attached device
#
# Two environment settings this script resolves that a bare `gradle` will not:
#
#   * Java does not read HTTP_PROXY/HTTPS_PROXY from the environment, so behind
#     a proxy dependency resolution hangs until it times out. The proxy is
#     translated into -D system properties here.
#   * JAVA_HOME: prefers Android Studio's bundled JDK, then Homebrew's
#     openjdk@21, then whatever java_home reports.
set -euo pipefail

cd "$(dirname "$0")"

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
fi
read -r NHOST NPORT <<<"$(proxy_host_port "${no_proxy:-${NO_PROXY:-}}")" || true

GRADLE="gradle"
if [ -x ./gradlew ]; then GRADLE="./gradlew"; fi

TASK="${1:-debug}"
case "$TASK" in
    debug)   "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" :app:assembleDebug ;;
    release) "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" :app:assembleRelease ;;
    install) "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" :app:installDebug ;;
    native)  exec ./native/build-native.sh ;;
    *)       "$GRADLE" "${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"}" "$@" ;;
esac
