#!/bin/bash
# JXCODE v2 — Cross-Platform Build Script
set -euo pipefail

PROJECT_NAME="jxcode"
ICLOUD_SOURCE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Git/$PROJECT_NAME"
BUILD_DIR="/tmp/${PROJECT_NAME}-build"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "═══ JXCODE v2 Build Script ═══"
echo "Source: $ICLOUD_SOURCE"
echo "Build:  $BUILD_DIR"
echo "Time:   $TIMESTAMP"
echo ""

# Step 1: Copy from iCloud (avoids codesign resource fork issue)
echo "[1/4] Copying project from iCloud..."
rm -rf "$BUILD_DIR"
cp -R "$ICLOUD_SOURCE" "$BUILD_DIR"
cd "$BUILD_DIR"
echo "  ✅ Copied"
echo "  Cleaning extended attributes (iCloud resource fork fix)..."
xattr -rc . 2>/dev/null || true
dot_clean -m . 2>/dev/null || true
echo "  ✅ Attributes cleaned"

# Step 2: Get dependencies
echo "[2/4] Installing dependencies..."
flutter pub get > /dev/null 2>&1
echo "  ✅ Dependencies resolved"

# Step 3: Run analysis + tests
echo "[3/4] Running static analysis..."
flutter analyze --no-fatal-infos > /dev/null 2>&1 && echo "  ✅ Analysis clean" || echo "  ⚠️  Issues found (check flutter analyze)"

echo "  Running tests..."
flutter test > /dev/null 2>&1 && echo "  ✅ Tests passed" || echo "  ❌ Tests failed"

# Step 4: Build both platforms
echo "[4/4] Building..."
echo "  Building macOS Intel..."
flutter build macos --debug 2>&1 | tail -1

echo "  Building Android ARM64..."
flutter build apk --debug --target-platform android-arm64 2>&1 | tail -1

echo ""
echo "═══ BUILD COMPLETE ═══"
echo "macOS:   $BUILD_DIR/build/macos/Build/Products/Debug/$PROJECT_NAME.app"
echo "Android: $BUILD_DIR/build/app/outputs/flutter-apk/app-debug.apk"
ls -lh "$BUILD_DIR/build/macos/Build/Products/Debug/$PROJECT_NAME.app"
ls -lh "$BUILD_DIR/build/app/outputs/flutter-apk/app-debug.apk"
