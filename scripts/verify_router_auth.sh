#!/usr/bin/env bash
#
# Prove that a routed agent can authenticate to the router in every API shape.
#
# `verify_claude_cli.sh` answers "does Claude reply through JXCode?" with auth
# off. This one answers the harder question: with router auth *on* — which is
# the mode that actually protects the user's API keys — does an agent still
# get through? And does it get through whichever wire format it speaks?
#
# The bug this guards: the token reached Claude Code but nothing else. Gemini,
# opencode and oh-my-pi were handed `OPENAI_BASE_URL` with no credential at
# all, and Codex was handed a config naming `JXCODE_API_KEY` that no code ever
# exported. Turn auth on and every one of them was answered 401 — which reads
# as "the provider is not routing", because the backend is never reached.
#
# Everything is deterministic: a fake OpenAI backend on a free port, a
# throwaway JXCODE_ROOT. Exit 0 = every shape authenticated.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JXCODE="$ROOT/.build/debug/jxcode"
PY="${PYTHON:-/Users/joshua/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3}"

if [[ ! -x "$JXCODE" ]]; then
    echo "FAIL: $JXCODE not built. run: swift build --disable-sandbox -c debug"
    exit 1
fi

free_port() {
    "$PY" -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

SANDBOX="$(mktemp -d /tmp/jxcode-auth-XXXXXX)"
UPSTREAM_PORT="$(free_port)"
ROUTER_PORT="$(free_port)"
UP_LOG="$SANDBOX/upstream.log"
ROUTER_LOG="$SANDBOX/router.log"

cleanup() {
    [[ -n "${ROUTER_PID:-}" ]] && kill "$ROUTER_PID" 2>/dev/null
    [[ -n "${UP_PID:-}" ]] && kill "$UP_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

export JXCODE_ROOT="$SANDBOX/sandbox"
mkdir -p "$JXCODE_ROOT/state"
CURL=(curl -s -m 10 --noproxy '*')

# A fixed token, so the assertions are exact rather than "matches whatever
# was generated".
TOKEN="verify-token-0123456789abcdef"
cat > "$JXCODE_ROOT/state/router-auth.json" <<EOF
{
  "isEnabled" : true,
  "token" : "$TOKEN"
}
EOF

echo "JXCode → router auth verification"
echo "════════════════════════════════════════════════════════════════"
echo "  sandbox   $JXCODE_ROOT"
echo "  upstream  127.0.0.1:$UPSTREAM_PORT"
echo "  router    127.0.0.1:$ROUTER_PORT"
echo "  auth      on (token $TOKEN)"
echo

FAILURES=()

# ── 1. Upstream ──────────────────────────────────────────────────────────────
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
[[ -n "$up_ok" ]] || { echo "FAIL: upstream never became healthy"; cat "$UP_LOG"; exit 1; }
echo "   ok"

# ── 2. Router, with auth loaded ──────────────────────────────────────────────
echo "── 2. register provider + start router"
"$JXCODE" provider-add "AuthUpstream" "http://127.0.0.1:$UPSTREAM_PORT" >/dev/null 2>&1
"$JXCODE" route --provider AuthUpstream --model fake-qwen3-coder \
    --port "$ROUTER_PORT" > "$ROUTER_LOG" 2>&1 &
ROUTER_PID=$!

router_ok=""
for _ in $(seq 1 30); do
    [[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ROUTER_PORT/health")" != "000" ]] && { router_ok=1; break; }
    kill -0 "$ROUTER_PID" 2>/dev/null || break
    sleep 0.5
done
if [[ -z "$router_ok" ]]; then
    echo "FAIL: router never listened on :$ROUTER_PORT"
    cat "$ROUTER_LOG"
    exit 1
fi
echo "   ok  (listening)"
# Whether auth is actually enforced is asserted behaviourally below — by the
# 401 in step 3 — rather than by grepping this log. Swift buffers stdout when
# it is redirected to a file, so the banner is often not on disk yet.

# ── 3. Unauthenticated request must be refused ───────────────────────────────
echo "── 3. an unauthenticated request is refused"
ANTHROPIC_BODY='{"model":"claude-sonnet-4-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$ROUTER_PORT/v1/messages" \
    -H 'content-type: application/json' -d "$ANTHROPIC_BODY")"
echo "   no credential → HTTP $code"
[[ "$code" == "401" ]] || FAILURES+=("expected 401 without a credential, got $code")

# ── 4. Every shape authenticates ─────────────────────────────────────────────
echo "── 4. each agent shape authenticates"

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "   ok   $label → HTTP $actual"
    else
        echo "   FAIL $label → HTTP $actual (expected $expected)"
        FAILURES+=("$label got HTTP $actual, expected $expected")
    fi
}

# Claude Code: x-api-key.
check "anthropic /v1/messages (x-api-key)" 200 \
    "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST \
        "http://127.0.0.1:$ROUTER_PORT/v1/messages" \
        -H 'content-type: application/json' -H "x-api-key: $TOKEN" -d "$ANTHROPIC_BODY")"

# Claude Code with ANTHROPIC_AUTH_TOKEN: Authorization: Bearer.
check "anthropic /v1/messages (bearer)" 200 \
    "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST \
        "http://127.0.0.1:$ROUTER_PORT/v1/messages" \
        -H 'content-type: application/json' -H "authorization: Bearer $TOKEN" -d "$ANTHROPIC_BODY")"

# Gemini / opencode / oh-my-pi: OpenAI wire, OPENAI_API_KEY as bearer.
OPENAI_BODY='{"model":"fake-qwen3-coder","messages":[{"role":"user","content":"hi"}]}'
check "openai /v1/chat/completions (bearer)" 200 \
    "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST \
        "http://127.0.0.1:$ROUTER_PORT/v1/chat/completions" \
        -H 'content-type: application/json' -H "authorization: Bearer $TOKEN" -d "$OPENAI_BODY")"

# ── 5. The written agent config carries the real token ───────────────────────
echo "── 5. jxcode bind writes the real token"
"$JXCODE" bind --model fake-qwen3-coder --port "$ROUTER_PORT" > "$SANDBOX/bind.out" 2>&1
grep -q "auth on" "$SANDBOX/bind.out" \
    && echo "   ok  (bind reports auth on)" \
    || { echo "   FAIL: bind did not report auth on"; sed 's/^/     /' "$SANDBOX/bind.out"; FAILURES+=("bind ignored stored auth"); }

SETTINGS="$JXCODE_ROOT/env/home/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
    grep -q "$TOKEN" "$SETTINGS" \
        && echo "   ok  (claude settings.json carries the token)" \
        || { echo "   FAIL: settings.json lacks the token"; FAILURES+=("bind wrote a placeholder token"); }
else
    echo "   FAIL: no settings.json was written"
    FAILURES+=("bind wrote no settings.json")
fi

# The process environment — the path Gemini, opencode, oh-my-pi and Codex
# actually depend on, and the one that was broken — is not reachable from the
# CLI: the token is put into the sandbox by the app when it starts the router.
# It is asserted by SandboxRouterSeamTests.testEveryAgentShapeReceivesTheToken
# and testCodexEnvKeyNamesAVariableTheEnvironmentExports.

# ── Verdict ─────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "PASS — every agent shape authenticated to a router with auth on."
    exit 0
fi
echo "FAIL — ${#FAILURES[@]} problem(s):"
for f in "${FAILURES[@]}"; do echo "  • $f"; done
exit 1
