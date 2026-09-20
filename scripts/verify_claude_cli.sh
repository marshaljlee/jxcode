#!/usr/bin/env bash
#
# Prove that the native Claude Code CLI answers through JXCode.
#
# This is the check that matters: not "the router got a 200 from a fixture" but
# "claude, unmodified, produced a reply". Everything here is deterministic —
# a fake OpenAI backend on a free port — so a failure is always a JXCode bug,
# never a third party's billing.
#
# It runs against a throwaway JXCODE_ROOT, so it never touches the real
# sandbox: no providers added, no claude config written, nothing to clean up
# afterwards.
#
# Exit 0 = Claude answered. Exit 1 = it did not, with the evidence printed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JXCODE="$ROOT/.build/debug/jxcode"
PY="${PYTHON:-/Users/joshua/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3}"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

if [[ ! -x "$JXCODE" ]]; then
    echo "FAIL: $JXCODE not built. run: swift build --disable-sandbox -c debug"
    exit 1
fi
if [[ ! -x "$CLAUDE" ]]; then
    echo "FAIL: claude not found at $CLAUDE"
    exit 1
fi

# A free port, asked for and immediately released. Not race-proof, but it beats
# hardcoding 5255 and colliding with a running JXCode.app — which is exactly how
# an earlier "verified working" run silently tested the wrong router.
free_port() {
    "$PY" -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

SANDBOX="$(mktemp -d /tmp/jxcode-verify-XXXXXX)"
UPSTREAM_PORT="$(free_port)"
ROUTER_PORT="$(free_port)"
UP_LOG="$SANDBOX/upstream.log"
ROUTER_LOG="$SANDBOX/router.log"
CLAUDE_OUT="$SANDBOX/claude.out"
CLAUDE_ERR="$SANDBOX/claude.err"

cleanup() {
    [[ -n "${ROUTER_PID:-}" ]] && kill "$ROUTER_PID" 2>/dev/null
    [[ -n "${UP_PID:-}" ]] && kill "$UP_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

export JXCODE_ROOT="$SANDBOX/sandbox"
mkdir -p "$JXCODE_ROOT"

# The sandbox proxy in some shells intercepts 127.0.0.1 and turns every local
# probe into a 502 that looks like a broken backend.
CURL=(curl -s -m 10 --noproxy '*')

echo "JXCode → Claude Code CLI verification"
echo "════════════════════════════════════════════════════════════════"
echo "  sandbox   $JXCODE_ROOT"
echo "  upstream  127.0.0.1:$UPSTREAM_PORT"
echo "  router    127.0.0.1:$ROUTER_PORT"
echo "  claude    $CLAUDE"
echo

# ── 1. Deterministic upstream ────────────────────────────────────────────────
echo "── 1. start fake upstream"
"$PY" "$ROOT/scripts/fake_openai_server.py" "$UPSTREAM_PORT" > "$UP_LOG" 2>&1 &
UP_PID=$!

up_ok=""
for _ in $(seq 1 20); do
    if [[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$UPSTREAM_PORT/v1/models")" == "200" ]]; then
        up_ok=1; break
    fi
    sleep 0.5
done
if [[ -z "$up_ok" ]]; then
    echo "FAIL: upstream never became healthy on :$UPSTREAM_PORT"
    cat "$UP_LOG"
    exit 1
fi
echo "   ok  (200 from /v1/models)"

# ── 2. Register it inside the throwaway sandbox ──────────────────────────────
echo "── 2. register provider + start router"
"$JXCODE" provider-add "VerifyUpstream" "http://127.0.0.1:$UPSTREAM_PORT" >/dev/null 2>&1
if ! "$JXCODE" providers 2>/dev/null | grep -q VerifyUpstream; then
    echo "FAIL: provider-add did not take effect"
    exit 1
fi

"$JXCODE" route --provider VerifyUpstream --model fake-qwen3-coder \
    --port "$ROUTER_PORT" > "$ROUTER_LOG" 2>&1 &
ROUTER_PID=$!

router_ok=""
for _ in $(seq 1 30); do
    if [[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ROUTER_PORT/v1/models")" != "000" ]]; then
        router_ok=1; break
    fi
    kill -0 "$ROUTER_PID" 2>/dev/null || break
    sleep 0.5
done
if [[ -z "$router_ok" ]]; then
    echo "FAIL: router never listened on :$ROUTER_PORT"
    cat "$ROUTER_LOG"
    exit 1
fi
echo "   ok  (listening on :$ROUTER_PORT)"

# ── 3. Bind the agent ────────────────────────────────────────────────────────
echo "── 3. bind agent config"
# --port must match the router we actually started. Bind defaults to 5255, and
# on a machine with JXCode.app running that is the *app's* router — which is
# how a bind can look successful while pointing at a completely different
# provider than the one under test.
if ! "$JXCODE" bind --model fake-qwen3-coder --port "$ROUTER_PORT" 2>&1 | sed 's/^/   /'; then
    echo "FAIL: bind failed"
    exit 1
fi

CLAUDE_CONFIG_DIR="$("$JXCODE" paths 2>/dev/null | awk '/^claude config/ {print $NF}')"
if [[ -z "$CLAUDE_CONFIG_DIR" ]]; then
    echo "FAIL: could not resolve the sandbox claude config dir"
    exit 1
fi
echo "   claude config dir  $CLAUDE_CONFIG_DIR"

# ── 4. The thing that matters: does Claude answer? ───────────────────────────
echo "── 4. run the native Claude Code CLI"
export CLAUDE_CONFIG_DIR
# shellcheck disable=SC2034
timeout 120 "$CLAUDE" -p "Reply with exactly the word PONG and nothing else." \
    > "$CLAUDE_OUT" 2> "$CLAUDE_ERR"
CLAUDE_EXIT=$?

echo "   exit code: $CLAUDE_EXIT"
echo "   stdout ($(wc -c < "$CLAUDE_OUT" | tr -d ' ') bytes):"
sed 's/^/     | /' "$CLAUDE_OUT" | head -20
if [[ -s "$CLAUDE_ERR" ]]; then
    echo "   stderr:"
    sed 's/^/     | /' "$CLAUDE_ERR" | head -20
fi

# ── 5. Assert ────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════"
FAILURES=()

[[ $CLAUDE_EXIT -eq 0 ]] || FAILURES+=("claude exited $CLAUDE_EXIT")

# Non-empty output. An empty reply is the failure mode that reads as "routing
# is broken" — it is what a 403 from a credit-less provider looks like.
if [[ ! -s "$CLAUDE_OUT" ]]; then
    FAILURES+=("claude printed nothing on stdout")
fi

# It must be a reply, not an error banner.
if grep -qiE "unable to connect|connection refused|invalid api key|credit limit|unauthorized" \
        "$CLAUDE_OUT" "$CLAUDE_ERR"; then
    FAILURES+=("claude reported a connection/auth error")
fi

# Login state. Claude Code refuses to start when it believes it is not logged
# in, so this is a hard failure, not cosmetics.
if grep -qiE "not logged in|please run /login|login required" "$CLAUDE_OUT" "$CLAUDE_ERR"; then
    FAILURES+=("claude says it is not logged in")
fi

# The router must have seen a real request.
if ! grep -qE "POST /v1/messages|POST /v1/chat/completions" \
        "$JXCODE_ROOT/logs/router.log" 2>/dev/null; then
    FAILURES+=("the router never received a request from claude")
fi

# ── 5b. The same thing with no config file at all ────────────────────────────
#
# A tab launched from the app gets the router in its process environment. If
# that alone is not enough — if it also needs the settings.json that Bind
# writes — then launching Claude without first pressing Bind lands the user on
# "Not logged in", which is the whole failure this script exists to catch.
echo
echo "── 5. same thing with no bind at all (process env only)"
"$JXCODE" unbind >/dev/null 2>&1

UNBOUND_DIR="$SANDBOX/unbound-claude"
mkdir -p "$UNBOUND_DIR"
# The environment is written out by hand rather than going through
# `jxcode run`: `run` resolves the agent inside the sandbox, and a throwaway
# JXCODE_ROOT has no claude installed. What matters is that these are exactly
# the variables `Sandbox.env()` now emits — asserted by
# SandboxRouterSeamTests — so this really is the tab launch path.
if CLAUDE_CONFIG_DIR="$UNBOUND_DIR" \
   ANTHROPIC_BASE_URL="http://127.0.0.1:$ROUTER_PORT" \
   ANTHROPIC_AUTH_TOKEN=jxcode-local-router \
   ANTHROPIC_API_KEY="" \
   ANTHROPIC_MODEL=claude-sonnet-4-5 \
   timeout 120 "$CLAUDE" -p "Reply with exactly the word PONG and nothing else." \
        > "$SANDBOX/unbound.out" 2> "$SANDBOX/unbound.err"; then
    UNBOUND_EXIT=0
else
    UNBOUND_EXIT=$?
fi
echo "   exit code: $UNBOUND_EXIT"
sed 's/^/     | /' "$SANDBOX/unbound.out" | head -10

if [[ $UNBOUND_EXIT -ne 0 || ! -s "$SANDBOX/unbound.out" ]]; then
    FAILURES+=("claude did not answer from the process env alone (no bind)")
fi
if grep -qiE "not logged in|please run /login" "$SANDBOX/unbound.out" "$SANDBOX/unbound.err"; then
    FAILURES+=("claude is not logged in when launched with routing but no bind")
fi

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "PASS — Claude Code answered through JXCode, bound and unbound."
    echo
    echo "  last router lines:"
    tail -4 "$JXCODE_ROOT/logs/router.log" 2>/dev/null | sed 's/^/    /'
    exit 0
fi

echo "FAIL — ${#FAILURES[@]} problem(s):"
for f in "${FAILURES[@]}"; do echo "  • $f"; done
echo
echo "  router log:"
tail -10 "$JXCODE_ROOT/logs/router.log" 2>/dev/null | sed 's/^/    /'
exit 1
