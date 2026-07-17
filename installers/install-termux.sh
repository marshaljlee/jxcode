#!/data/data/com.termux/files/usr/bin/bash
#
# install-termux.sh — One-shot jxcode setup for Android ARM64 (Termux)
#
# Installs everything needed to run jxcode on an Android ARM64 device:
#   1. Termux dependencies (bun, proot, git)
#   2. jxproxy (proxy/router from github.com/marshaljlee/jxproxy)
#   3. /tmp fix via proot bind mount
#   4. jxcode APK download (from GitHub Releases)
#   5. Configuration + start instructions
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/marshaljlee/jxcode/main/installers/install-termux.sh | bash
#
# Flags:
#   --apk-url=URL    Override APK download URL (default: GitHub latest release)
#   --skip-apk       Skip APK download (already installed via adb)
#   --port=PORT      jxproxy port (default: 5255)
#   --provider=X     Default LLM provider: direct, openrouter, opencode-zen (default: direct)
#   --help           Show this help
#

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Config ---
JXPROXY_PORT=5255
PROVIDER="direct"
APK_URL=""
SKIP_APK=""

for arg in "$@"; do
  case "$arg" in
    --apk-url=*) APK_URL="${arg#*=}" ;;
    --skip-apk) SKIP_APK="1" ;;
    --port=*) JXPROXY_PORT="${arg#*=}" ;;
    --provider=*) PROVIDER="${arg#*=}" ;;
    --help|-h)
      echo "install-termux.sh — One-shot jxcode + jxproxy setup for Android ARM64"
      echo ""
      echo "  --apk-url=URL    Download APK from custom URL"
      echo "  --skip-apk       Skip APK download"
      echo "  --port=PORT      jxproxy port (default: 5255)"
      echo "  --provider=X     LLM provider: direct, openrouter, opencode-zen"
      exit 0
      ;;
  esac
done

# ─────────────────────────────────────────────────
#  PRE-FLIGHT
# ─────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║${NC}           ${CYAN}jxcode — Android ARM64 Installer${NC}           ${BOLD}║${NC}"
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# --- Termux check ---
if [ -z "${TERMUX_VERSION:-}" ]; then
  echo -e "  ${RED}✗ This script runs inside Termux on Android.${NC}"
  echo "    Install Termux from F-Droid:"
  echo "    https://f-droid.org/packages/com.termux/"
  exit 1
fi

# --- Architecture check ---
ARCH=$(uname -m)
case "$ARCH" in
  aarch64) ARCH_LABEL="ARM64" ;;
  x86_64)  ARCH_LABEL="x86_64" ;;
  *)
    echo -e "  ${RED}✗ Unsupported architecture: $ARCH${NC}"
    echo "    ARM64 (aarch64) or x86_64 required."
    exit 1
    ;;
esac

echo -e "  ${GREEN}✓${NC} Termux detected (${ARCH_LABEL})"
echo ""

# ─────────────────────────────────────────────────
#  STEP 1: Dependencies
# ─────────────────────────────────────────────────

echo -e "  ${BOLD}┃${NC} ${CYAN}Step 1/5${NC} — Installing system dependencies"

pkg update -y 2>/dev/null | tail -1
pkg install -y bun proot git wget 2>&1 | tail -1

BUN_VER=$(bun --version 2>/dev/null || echo "none")
echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} bun ${BUN_VER}, proot, git, wget"
echo ""

# ─────────────────────────────────────────────────
#  STEP 2: Clone + build jxproxy
# ─────────────────────────────────────────────────

echo -e "  ${BOLD}┃${NC} ${CYAN}Step 2/5${NC} — Cloning and building jxproxy"

JXPROXY_DIR="${HOME}/.jxproxy-source"

if [ -d "$JXPROXY_DIR" ]; then
  echo -e "  ${BOLD}┃${NC}     Updating existing clone..."
  cd "$JXPROXY_DIR"
  git pull --ff-only 2>&1 | tail -1
else
  git clone --depth 1 https://github.com/marshaljlee/jxproxy.git "$JXPROXY_DIR"
  cd "$JXPROXY_DIR"
fi

# Check if source is bootstrapped
if [ ! -d "src" ] || [ ! -f "src/entrypoints/cli.tsx" ]; then
  echo -e "  ${BOLD}┃${NC}     Bootstrapping source..."
  bash scripts/bootstrap.sh 2>&1 | tail -1
fi

bun install 2>&1 | tail -1

echo -e "  ${BOLD}┃${NC}     Building jxproxy (this takes a minute)..."
bun run scripts/build.ts --target=linux-arm64 2>&1 | tail -3

# Install to ~/.local/bin
BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${HOME}/.jxproxy"
mkdir -p "$BIN_DIR" "$DATA_DIR"

if [ -f "dist/jxproxy-linux-arm64" ]; then
  cp "dist/jxproxy-linux-arm64" "$BIN_DIR/jxproxy"
  chmod 755 "$BIN_DIR/jxproxy"
  echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} jxproxy binary → ${BIN_DIR}/jxproxy"
else
  echo -e "  ${BOLD}┃${NC}   ${YELLOW}⚠${NC} Binary not found at dist/jxproxy-linux-arm64"
fi

echo ""

# ─────────────────────────────────────────────────
#  STEP 3: Add to PATH
# ─────────────────────────────────────────────────

echo -e "  ${BOLD}┃${NC} ${CYAN}Step 3/5${NC} — Adding to PATH"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$HOME/.bashrc"
  export PATH="$PATH:$BIN_DIR"
  echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} Added ${BIN_DIR} to PATH in ~/.bashrc"
fi

echo ""

# ─────────────────────────────────────────────────
#  STEP 4: Proot /tmp fix
# ─────────────────────────────────────────────────

echo -e "  ${BOLD}┃${NC} ${CYAN}Step 4/5${NC} — Fixing /tmp access with proot"

ALIAS_LINE="alias jxproxy='proot -b /data/data/com.termux/files/usr/tmp:/tmp ${BIN_DIR}/jxproxy'"
if ! grep -q "proot.*tmp.*jxproxy" "$HOME/.bashrc" 2>/dev/null; then
  echo "$ALIAS_LINE" >> "$HOME/.bashrc"
  echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} proot alias added to ~/.bashrc"
else
  echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} proot alias already configured"
fi

# Apply to current shell
eval "$ALIAS_LINE"

echo ""

# ─────────────────────────────────────────────────
#  STEP 5a: jxproxy config
# ─────────────────────────────────────────────────

echo -e "  ${BOLD}┃${NC} ${CYAN}Step 5/5${NC} — Configuring jxproxy"

CONFIG_FILE="$DATA_DIR/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" << CONFIGEOF
# jxproxy configuration — installed by jxcode termux installer
JXPROXY_PORT=${JXPROXY_PORT}
JXPROXY_AUTH_TOKEN=jxproxy
JXPROXY_PROVIDER=${PROVIDER}
MODEL=claude-sonnet-5-20251001
ENABLE_MODEL_THINKING=true

# ⚡ Set at least one API key before starting jxproxy:
# ANTHROPIC_API_KEY=sk-ant-...
# OPENROUTER_API_KEY=sk-or-...
# OPENCODE_API_KEY=sk-oc-...

# Provider fallback chain (optional):
# FALLBACK_PROVIDERS=nvidia,local
# OPENAI_BASE_URL=https://integrate.api.nvidia.com/v1
# LOCAL_LLM_BASE_URL=http://127.0.0.1:11434/v1
CONFIGEOF
  echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} Config created → ${CONFIG_FILE}"
else
  echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} Config already exists at ${CONFIG_FILE}"
fi

# ─────────────────────────────────────────────────
#  STEP 5b: APK download
# ─────────────────────────────────────────────────

if [ -z "$SKIP_APK" ]; then
  APK_DIR="${HOME}/storage/downloads"
  mkdir -p "$APK_DIR"

  if [ -z "$APK_URL" ]; then
    APK_URL="https://github.com/marshaljlee/jxcode/releases/latest/download/jxcode-arm64-v8a-release.apk"
  fi

  echo -e "  ${BOLD}┃${NC}     Downloading jxcode APK..."
  if wget -q --timeout=15 "$APK_URL" -O "$APK_DIR/jxcode.apk" 2>/dev/null; then
    echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} APK saved to ${APK_DIR}/jxcode.apk"
    echo -e "  ${BOLD}┃${NC}     Install with:  adb install ${APK_DIR}/jxcode.apk"
    echo -e "  ${BOLD}┃${NC}     Or open the file in a file manager and tap it."
  else
    echo -e "  ${BOLD}┃${NC}   ${YELLOW}⚠${NC} APK download failed (no release yet?)"
    echo -e "  ${BOLD}┃${NC}     Build it on your dev machine:"
    echo -e "  ${BOLD}┃${NC}     cd jxcode && flutter build apk --split-per-abi"
    echo -e "  ${BOLD}┃${NC}     adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
  fi
fi

echo ""

# ─────────────────────────────────────────────────
#  DONE
# ─────────────────────────────────────────────────

echo -e "  ${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║${NC}          ${GREEN}✓ jxcode setup complete!${NC}                     ${BOLD}║${NC}"
echo -e "  ${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo ""
echo -e "  1. Edit ${CYAN}${CONFIG_FILE}${NC} and add your API key(s)"
echo -e "  2. Start jxproxy:"
echo -e "     ${CYAN}proot -b /data/data/com.termux/files/usr/tmp:/tmp ${BIN_DIR}/jxproxy server --port ${JXPROXY_PORT}${NC}"
echo -e "     (or just '${CYAN}jxproxy server --port ${JXPROXY_PORT}${NC}' after opening a new shell)"
echo -e "  3. Prevent Termux from being killed:"
echo -e "     ${CYAN}termux-wake-lock${NC}"
echo -e "  4. Install and open the jxcode app → auto-connects to 127.0.0.1:${JXPROXY_PORT}"
echo ""
echo -e "  ${BOLD}Need help?${NC}  https://github.com/marshaljlee/jxcode/blob/main/docs/android-arm64.md"
echo ""
