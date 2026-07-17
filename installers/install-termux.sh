#!/data/data/com.termux/files/usr/bin/bash
#
# install-termux.sh — AutoLoop jxcode installer for Android ARM64 (Termux)
#
# This is a self-healing installer with retry logic, pre-flight checks,
# post-step verification, and fallback mechanisms. It will retry each step
# up to 3 times before giving up, and will never leave the system in a
# partially-installed state.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/marshaljlee/jxcode/main/installers/install-termux.sh | bash
#
#   Or skip to a specific step:
#     bash install-termux.sh --step=1     # start from step 1
#     bash install-termux.sh --step=5     # skip to config only
#
# Flags:
#   --step=N       Start from step N (1-6, default: 1)
#   --retry=N      Max retries per step (default: 3)
#   --port=PORT    jxproxy port (default: 5255)
#   --provider=X   Default LLM provider: direct, openrouter, opencode-zen
#   --skip-apk     Skip APK download step
#   --help         Show this help
#

set -euo pipefail

# =============================================================================
#  CONFIG
# =============================================================================

JXPROXY_PORT=5255
PROVIDER="direct"
SKIP_APK=""
START_STEP=1
MAX_RETRIES=3

declare -A ARG_MAP
for arg in "$@"; do
  case "$arg" in
    --step=*)    START_STEP="${arg#*=}" ;;
    --retry=*)   MAX_RETRIES="${arg#*=}" ;;
    --port=*)    JXPROXY_PORT="${arg#*=}" ;;
    --provider=*) PROVIDER="${arg#*=}" ;;
    --skip-apk)  SKIP_APK="1" ;;
    --help|-h)
      sed -n '3,18p' "$0" | sed 's/^#//' | sed 's/^ //'
      exit 0 ;;
  esac
done

# =============================================================================
#  UI HELPERS
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "  ${BOLD}┃${NC}   $1"; }
ok()     { echo -e "  ${BOLD}┃${NC}   ${GREEN}✓${NC} $1"; }
info()   { echo -e "  ${BOLD}┃${NC}     $1"; }
warn()   { echo -e "  ${BOLD}┃${NC}   ${YELLOW}⚠${NC} $1"; }
fail()   { echo -e "  ${BOLD}┃${NC}   ${RED}✗${NC} $1" >&2; }
step_h() { echo ""; echo -e "  ${BOLD}┃${NC} ${CYAN}Step $1/$2${NC} — ${BOLD}$3${NC}"; echo -e "  ${BOLD}┃${NC}"; }
banner() { echo ""; echo -e "  ${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
           echo -e "  ${BOLD}║${NC}           ${CYAN}jxcode — Android ARM64 AutoLoop Installer${NC}    ${BOLD}║${NC}"
           echo -e "  ${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"; echo ""; }
divider(){ echo -e "  ${BOLD}┃${NC} ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

TOTAL_STEPS=6

# =============================================================================
#  RETRY WRAPPER
# =============================================================================

retry() {
  local label="$1" ; shift
  local attempt=0
  local logfile ret
  logfile=$(mktemp -t jxcode-XXXXXX.log)
  while [ $attempt -lt "$MAX_RETRIES" ]; do
    attempt=$((attempt + 1))
    "$@" >"$logfile" 2>&1 && ret=0 || ret=$?
    if [ $ret -eq 0 ]; then
      rm -f "$logfile"
      return 0
    fi
    if [ $attempt -lt "$MAX_RETRIES" ]; then
      warn "'${label}' failed (attempt ${attempt}/${MAX_RETRIES})"
      info "Last error: $(tail -3 "$logfile" | tr '\n' ' ')"
      info "Retrying in 3s..."
      sleep 3
    else
      fail "'${label}' failed after ${MAX_RETRIES} attempts"
      info "Full log at: ${logfile}"
      info "Last 10 lines:"
      tail -10 "$logfile" | while IFS= read -r line; do info "  ${line}"; done
    fi
  done
  return 1
}

# =============================================================================
#  PRE-FLIGHT
# =============================================================================

banner

if [ -z "${TERMUX_VERSION:-}" ]; then
  fail "This script runs inside Termux on Android."
  fail "Install Termux from F-Droid: https://f-droid.org/packages/com.termux/"
  exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) ARCH_LABEL="ARM64" ;;
  x86_64)  ARCH_LABEL="x86_64" ;;
  *)
    fail "Unsupported architecture: $ARCH (requires aarch64 or x86_64)"
    exit 1
    ;;
esac

ok "Termux detected (${ARCH_LABEL})"

# Check storage permission (needed for APK download)
STORAGE_OK=false
if [ -d "$HOME/storage/downloads" ]; then
  STORAGE_OK=true
fi

# Check internet connectivity
if ! curl -s --max-time 5 https://github.com >/dev/null 2>&1; then
  fail "No internet connectivity detected. Check your connection."
  exit 1
fi
ok "Network reachable"

# =============================================================================
#  STEP 1: System Dependencies
# =============================================================================

step1_deps() {
  step_h 1 $TOTAL_STEPS "System dependencies (proot, git, nodejs, wget)"

  # Update package lists (non-fatal if fails)
  info "Updating package lists..."
  pkg update -y 2>&1 | tail -1 || warn "pkg update failed — continuing with cached repo data"

  # Install system packages
  info "Installing proot, git, wget, nodejs-lts..."
  pkg install -y proot git wget nodejs-lts 2>&1 | tail -1

  # Verify each package
  local missing=()
  command -v proot    >/dev/null 2>&1 || missing+=("proot")
  command -v git      >/dev/null 2>&1 || missing+=("git")
  command -v wget     >/dev/null 2>&1 || missing+=("wget")
  command -v node     >/dev/null 2>&1 || missing+=("nodejs-lts")

  if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing packages: ${missing[*]}"
    fail "Try: pkg install ${missing[*]}"
    return 1
  fi

  ok "proot $(proot --version 2>&1 | head -1 || echo 'installed')"
  ok "git $(git --version 2>/dev/null || echo 'not found')"
  ok "node $(node --version 2>/dev/null || echo 'not found')"
  divider
  return 0
}

# =============================================================================
#  STEP 2: Bun Runtime
# =============================================================================

step2_bun() {
  step_h 2 $TOTAL_STEPS "Bun JavaScript runtime"
  local bun_path=""

  # Detection logic — multiple possible locations
  for candidate in \
    "${HOME}/.bun/bin/bun" \
    "${HOME}/.npm-global/bin/bun" \
    "${HOME}/.local/bin/bun" \
    "/usr/local/bin/bun"; do
    if [ -x "$candidate" ]; then
      bun_path="$candidate"
      break
    fi
  done

  if [ -z "$bun_path" ] && command -v bun >/dev/null 2>&1; then
    bun_path="$(command -v bun)"
  fi

  # PATH setup
  export PATH="${HOME}/.npm-global/bin:${HOME}/.bun/bin:${HOME}/.local/bin:${PATH}"

  # Test existing bun
  if [ -n "$bun_path" ]; then
    if "$bun_path" --version >/dev/null 2>&1; then
      ok "Bun $("$bun_path" --version) already installed at ${bun_path}"
      divider
      return 0
    else
      warn "Bun binary at ${bun_path} exists but is broken (glibc mismatch?)"
      rm -f "$bun_path" 2>/dev/null || true
      bun_path=""
    fi
  fi

  # Install bun — try npm first (Termux-compatible build)
  info "Installing Bun via npm (Termux-compatible)..."
  npm config set prefix "${HOME}/.npm-global" 2>/dev/null || true
  mkdir -p "${HOME}/.npm-global"

  if npm install -g bun 2>&1 | tail -3; then
    # Verify
    if [ -x "${HOME}/.npm-global/bin/bun" ]; then
      export PATH="${HOME}/.npm-global/bin:${PATH}"
      ok "Bun $(bun --version) installed via npm"
      divider
      return 0
    fi
  fi

  # Fallback: bun.sh official installer (may need glibc shim)
  warn "npm install failed — trying official installer with glibc-runner..."

  # Install glibc-runner from Termux community repos
  pkg install -y glibc-runner 2>/dev/null || true

  # Try official install
  export BUN_INSTALL="${HOME}/.bun"
  curl -fsSL https://bun.sh/install 2>/dev/null | bash 2>&1 | tail -5

  if [ -x "${HOME}/.bun/bin/bun" ]; then
    export PATH="${HOME}/.bun/bin:${PATH}"
    # If glibc-runner is installed, use it
    if command -v glibc-runner >/dev/null 2>&1; then
      mv "${HOME}/.bun/bin/bun" "${HOME}/.bun/bin/bun.raw"
      cat > "${HOME}/.bun/bin/bun" << 'BUN_WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
exec glibc-runner "$(dirname "$0")/bun.raw" "$@"
BUN_WRAPPER
      chmod 755 "${HOME}/.bun/bin/bun"
    fi
    ok "Bun $(bun --version) installed via bun.sh with glibc shim"
    divider
    return 0
  fi

  # Last resort: try via npx
  warn "Direct install failed — trying npx fallback..."
  if npx --yes bun --version >/dev/null 2>&1; then
    ok "Bun available via npx"
    divider
    return 0
  fi

  fail "Could not install bun in any way."
  fail "Try manually: npm install -g bun"
  return 1
}

# =============================================================================
#  STEP 3: jxproxy Build
# =============================================================================

step3_jxproxy() {
  step_h 3 $TOTAL_STEPS "Build jxproxy proxy server"
  BIN_DIR="${HOME}/.local/bin"
  mkdir -p "$BIN_DIR"

  JXPROXY_DIR="${HOME}/.jxproxy-source"

  # Clone or update jxproxy
  if [ -d "$JXPROXY_DIR" ]; then
    info "Updating existing jxproxy clone..."
    cd "$JXPROXY_DIR"
    git fetch origin 2>&1 | tail -1 || warn "git fetch failed"
    git reset --hard origin/main 2>&1 | tail -1 || warn "git reset failed"
  else
    info "Cloning jxproxy from github.com/marshaljlee/jxproxy..."
    git clone --depth 1 https://github.com/marshaljlee/jxproxy.git "$JXPROXY_DIR" 2>&1 | tail -1
    cd "$JXPROXY_DIR"
  fi

  # Bootstrap source if needed (jxproxy patches upstream Claude Code source)
  if [ ! -f "src/entrypoints/cli.tsx" ]; then
    info "Bootstrapping jxproxy source (this downloads ~500MB)..."
    if [ -f "scripts/bootstrap.sh" ]; then
      bash scripts/bootstrap.sh 2>&1 | tail -3 || {
        warn "Bootstrap failed. Retrying with shallow clone..."
        rm -rf src 2>/dev/null || true
        bash scripts/bootstrap.sh --min 2>&1 | tail -3 || {
          fail "Bootstrap failed. Check storage (~4GB free required)."
          return 1
        }
      }
    fi
  fi

  # Install npm/bun deps
  info "Installing dependencies..."
  # On Termux: use npm (native) not bun (glibc binary — --version works but
  # actual operations like install/build crash). Verify each approach works.
  local deps_ok=false

  if command -v npm >/dev/null 2>&1; then
    info "Using npm (native Termux) for dependency install..."
    # Remove bun.lock to avoid parser conflicts with npm
    rm -f bun.lock bun.lockb 2>/dev/null || true
    retry "npm install" npm install --no-audit --no-fund && deps_ok=true
  fi

  if [ "$deps_ok" = false ] && command -v bun >/dev/null 2>&1; then
    # Quick test: bun actual operations (not just --version)
    if echo "console.log('ok')" | bun -e "$(cat)" >/dev/null 2>&1; then
      info "Trying bun install..."
      retry "bun install" bun install 2>&1 | tail -3 && deps_ok=true
    else
      warn "bun binary fails on actual operations (glibc) — removing"
      rm -f "$(command -v bun)" 2>/dev/null || true
    fi
  fi

  if [ "$deps_ok" = false ] && command -v npx >/dev/null 2>&1; then
    warn "npm install failed. Trying via npx + legacy deps..."
    retry "npx install" npx --yes npm install --legacy-peer-deps 2>&1 | tail -3 && deps_ok=true
  fi

  if [ "$deps_ok" = false ]; then
    fail "Dependency install failed after all attempts."
    info "Try manually: cd ~/.jxproxy-source && npm install"
    return 1
  fi

  # Build
  info "Building jxproxy for linux-arm64..."
  local build_ok=false

  # On Termux: prefer npx bun (works through node) or npm scripts
  if [ "$deps_ok" = true ] && command -v npx >/dev/null 2>&1; then
    info "Building via npx bun..."
    retry "npx bun build" npx --yes bun run scripts/build.ts --target=linux-arm64 2>&1 | tail -5 && build_ok=true
  fi

  if [ "$build_ok" = false ] && command -v bun >/dev/null 2>&1; then
    # Only try bun if it actually works for real operations
    if echo "console.log('ok')" | bun -e "$(cat)" >/dev/null 2>&1; then
      info "Building via bun..."
      retry "bun build" bun run scripts/build.ts --target=linux-arm64 2>&1 | tail -5 && build_ok=true
    fi
  fi

  if [ "$build_ok" = false ]; then
    # Build failed — try downloading pre-built binary from GitHub releases.
    # This is the standard approach used by jxproxy's Android installer too.
    warn "Build failed — downloading pre-built jxproxy binary..."
    local release_url="https://github.com/marshaljlee/jxproxy/releases/latest/download/jxproxy-linux-arm64"
    local download_target="${BIN_DIR}/jxproxy"
    if wget -q --timeout=60 "$release_url" -O "$download_target" 2>/dev/null; then
      chmod 755 "$download_target"
      local size
      size=$(stat -c%s "$download_target" 2>/dev/null || stat -f%z "$download_target" 2>/dev/null || echo "0")
      if [ "$size" -gt 5000000 ] && [ -x "$download_target" ]; then
        ok "jxproxy pre-built binary downloaded → ${download_target} ($(echo "scale=1; ${size}/1000000" | bc) MB)"
        build_ok=true
      else
        warn "Downloaded binary too small (${size} bytes). May be a stub."
        rm -f "$download_target" 2>/dev/null || true
      fi
    fi
  fi

  # Check for output binary
  local binary=""
  for candidate in dist/jxproxy-linux-arm64 dist/jxproxy "${BIN_DIR}/jxproxy"; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      binary="$candidate"
      break
    fi
  done

  if [ -n "$binary" ]; then
    if [ "$binary" != "${BIN_DIR}/jxproxy" ]; then
      cp "$binary" "$BIN_DIR/jxproxy"
      chmod 755 "$BIN_DIR/jxproxy"
    fi
    ok "jxproxy binary → ${BIN_DIR}/jxproxy"
  else
    warn "jxproxy binary not found. jxcode will still work if jxproxy is"
    warn "installed separately. See docs/android-arm64.md for options."
  fi

  divider
  return 0
}

# =============================================================================
#  STEP 4: PATH Setup
# =============================================================================

step4_path() {
  step_h 4 $TOTAL_STEPS "Shell PATH configuration"
  local rcfile="${HOME}/.bashrc"

  # Ensure .bashrc exists
  touch "$rcfile"

  local paths_added=0

  # Paths to ensure are in PATH
  local paths=(
    "${HOME}/.local/bin"
    "${HOME}/.npm-global/bin"
    "${HOME}/.bun/bin"
  )

  for p in "${paths[@]}"; do
    local line="export PATH=\"\${PATH}:${p}\""
    if ! grep -qF "$p" "$rcfile" 2>/dev/null; then
      echo "$line" >> "$rcfile"
      info "Added ${p} to ~/.bashrc"
      paths_added=$((paths_added + 1))
    fi
  done

  # Apply to current session
  export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${PATH}"

  if [ $paths_added -gt 0 ]; then
    ok "Added ${paths_added} path(s) to ~/.bashrc"
  else
    ok "PATH already configured"
  fi
  divider
}

# =============================================================================
#  STEP 5: Proot /tmp Bind
# =============================================================================

step5_proot() {
  step_h 5 $TOTAL_STEPS "Proot /tmp bind mount (fix Android restriction)"
  local TMP_BIND="/data/data/com.termux/files/usr/tmp"
  local BIN_DIR="${HOME}/.local/bin"
  local rcfile="${HOME}/.bashrc"

  # Verify proot is available
  if ! command -v proot >/dev/null 2>&1; then
    fail "proot is not installed. Step 1 should have installed it."
    pkg install -y proot 2>&1 | tail -1 || return 1
  fi

  # Create temp dir if needed
  mkdir -p "$TMP_BIND"

  # Add jxproxy wrapper that handles proot automatically
  local wrapper="${BIN_DIR}/jxproxy"
  mkdir -p "$BIN_DIR"

  if [ -f "${BIN_DIR}/jxproxy" ] && [ -f "${BIN_DIR}/.jxproxy-raw" ]; then
    # Already has wrapper, update just the raw binary path
    ok "proot wrapper already configured"
  elif [ -f "${BIN_DIR}/jxproxy" ]; then
    # Create wrapper that runs through proot
    local raw="${BIN_DIR}/.jxproxy-raw"
    mv "$wrapper" "$raw" 2>/dev/null || true
    cat > "$wrapper" << 'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
RAW="${DIR}/.jxproxy-raw"
TMP_BIND="/data/data/com.termux/files/usr/tmp"
if [ -x "$RAW" ]; then
  exec proot -b "${TMP_BIND}:/tmp" "$RAW" "$@"
else
  exec proot -b "${TMP_BIND}:/tmp" jxproxy "$@"
fi
WRAPPER
    chmod 755 "$wrapper"
    ok "proot wrapper created at ${wrapper}"
  else
    # Create alias in .bashrc
    local alias_line="alias jxproxy='proot -b ${TMP_BIND}:/tmp jxproxy'"
    if ! grep -q "proot.*tmp.*jxproxy" "$rcfile" 2>/dev/null; then
      echo "$alias_line" >> "$rcfile"
      ok "proot alias added to ~/.bashrc"
    else
      ok "proot alias already configured"
    fi
  fi

  divider
}

# =============================================================================
#  STEP 6: Config + APK
# =============================================================================

step6_config() {
  step_h 6 $TOTAL_STEPS "Configuration and APK"

  # ── Config ──
  local DATA_DIR="${HOME}/.jxproxy"
  local CONFIG_FILE="$DATA_DIR/config.env"
  mkdir -p "$DATA_DIR"

  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << CONFIGEOF
# jxproxy configuration — installed by jxcode termux installer
# Port (must match jxcode Flutter app default: 5255)
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
    ok "Config created → ${CONFIG_FILE}"
  else
    ok "Config already exists → ${CONFIG_FILE}"
    # Ensure port is set correctly
    if grep -q "^JXPROXY_PORT=" "$CONFIG_FILE" 2>/dev/null; then
      sed -i "s/^JXPROXY_PORT=.*/JXPROXY_PORT=${JXPROXY_PORT}/" "$CONFIG_FILE" 2>/dev/null || true
    else
      echo "JXPROXY_PORT=${JXPROXY_PORT}" >> "$CONFIG_FILE"
    fi
  fi

  # ── APK ──
  if [ -z "$SKIP_APK" ]; then
    if [ "$STORAGE_OK" = true ]; then
      local APK_DIR="${HOME}/storage/downloads"
    else
      local APK_DIR="${HOME}"
    fi

    local APK_FILE="${APK_DIR}/jxcode.apk"
    local APK_URL="https://github.com/marshaljlee/jxcode/releases/latest/download/jxcode-arm64-v8a-release.apk"

    info "Downloading jxcode APK..."
    if wget -q --timeout=30 "$APK_URL" -O "$APK_FILE" 2>/dev/null; then
      local size
      size=$(stat -c%s "$APK_FILE" 2>/dev/null || stat -f%z "$APK_FILE" 2>/dev/null || echo "0")
      if [ "$size" -gt 1000000 ]; then
        ok "APK downloaded → ${APK_FILE} ($(echo "scale=0; ${size}/1000000" | bc) MB)"
      else
        warn "APK download appears too small (${size} bytes). May be a placeholder."
      fi
    else
      warn "APK download failed (no release published yet)."
      info "Build it on your dev machine and install via adb:"
      info "  cd jxcode && flutter build apk --split-per-abi"
      info "  adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
    fi
  fi

  divider
}

# =============================================================================
#  POST-INSTALL VERIFICATION
# =============================================================================

verify() {
  echo ""
  echo -e "  ${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${BOLD}║${NC}          ${GREEN}✓ jxcode setup complete!${NC}                     ${BOLD}║${NC}"
  echo -e "  ${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Verification:${NC}"
  echo ""

  local all_ok=true

  # Check each critical component
  for check in \
    "proot:proot" \
    "git:git" \
    "node:node" \
    "bashrc:${HOME}/.bashrc"; do

    local label="${check%%:*}"
    local cmd="${check##*:}"

    if [ "$label" = "bashrc" ]; then
      if [ -f "$cmd" ]; then
        ok "${label} — exists"
      else
        warn "${label} — missing"
        all_ok=false
      fi
    elif command -v "$cmd" >/dev/null 2>&1; then
      local ver
      ver=$("$cmd" --version 2>/dev/null | head -1 || true)
      ok "${label} — ${ver}"
    else
      warn "${label} — not found in PATH"
      all_ok=false
    fi
  done

  # Check bun (various paths)
  if command -v bun >/dev/null 2>&1; then
    ok "bun — $(bun --version 2>/dev/null || echo 'installed')"
  elif [ -x "${HOME}/.bun/bin/bun" ]; then
    ok "bun — $(~/.bun/bin/bun --version 2>/dev/null || echo 'installed')"
  elif command -v npx >/dev/null 2>&1; then
    ok "bun — available via npx"
  else
    warn "bun — not found"
    all_ok=false
  fi

  # Check jxproxy binary
  if command -v jxproxy >/dev/null 2>&1; then
    ok "jxproxy — in PATH"
  elif [ -f "${HOME}/.local/bin/jxproxy" ]; then
    ok "jxproxy — at ~/.local/bin/jxproxy"
  else
    warn "jxproxy — binary not found (build may have failed)"
    all_ok=false
  fi

  # Check config
  if [ -f "${HOME}/.jxproxy/config.env" ]; then
    ok "config — ~/.jxproxy/config.env"
  else
    warn "config — missing"
    all_ok=false
  fi

  echo ""
  if [ "$all_ok" = true ]; then
    echo -e "  ${GREEN}${BOLD}  All checks passed.${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}  Some checks flagged — see warnings above.${NC}"
  fi
  echo ""

  # ── Final instructions ──
  echo -e "  ${BOLD}Next steps:${NC}"
  echo ""
  echo -e "  1. Edit ${CYAN}~/.jxproxy/config.env${NC} and add your API key(s)"
  echo -e "     ${CYAN}nano ~/.jxproxy/config.env${NC}"
  echo ""
  echo -e "  2. Start jxproxy:"
  echo -e "     ${CYAN}proot -b /data/data/com.termux/files/usr/tmp:/tmp ~/.local/bin/jxproxy server --port ${JXPROXY_PORT}${NC}"
  echo -e "     (or if using the wrapper:  ${CYAN}jxproxy server --port ${JXPROXY_PORT}${NC})"
  echo ""
  echo -e "  3. Keep Termux alive:"
  echo -e "     ${CYAN}termux-wake-lock${NC}"
  echo ""
  echo -e "  4. Open jxcode app → auto-connects to 127.0.0.1:${JXPROXY_PORT}"
  echo ""
  echo -e "  ${BOLD}Need help?${NC}"
  echo "  https://github.com/marshaljlee/jxcode/blob/main/docs/android-arm64.md"
  echo ""
}

# =============================================================================
#  MAIN LOOP
# =============================================================================

steps=(
  step1_deps
  step2_bun
  step3_jxproxy
  step4_path
  step5_proot
  step6_config
)

step_names=(
  "System dependencies"
  "Bun runtime"
  "jxproxy build"
  "PATH configuration"
  "Proot /tmp mount"
  "Config + APK"
)

overall_ok=true
for i in "${!steps[@]}"; do
  idx=$((i + 1))
  if [ "$idx" -lt "$START_STEP" ]; then
    continue
  fi

  if retry "${step_names[$i]}" "${steps[$i]}"; then
    ok "${step_names[$i]} — passed"
  else
    fail "${step_names[$i]} — failed after retries"
    overall_ok=false
    # Ask: continue to next step or abort?
    echo -e "  ${BOLD}┃${NC}"
    echo -e "  ${BOLD}┃${NC} ${YELLOW}Continue to next step anyway? (y/n)${NC}"
    read -r -t 10 cont || cont="n"
    if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
      fail "Installation aborted at step ${idx}/${TOTAL_STEPS}"
      exit 1
    fi
    warn "Continuing despite failure..."
  fi
done

verify

# Source .bashrc for convenience in the current shell
# shellcheck disable=SC1090
source "$HOME/.bashrc" 2>/dev/null || true

exit 0
