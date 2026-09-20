#!/usr/bin/env bash
#
# Prove that binding and unbinding are inverse operations.
#
# Every check here corresponds to a bug that actually shipped, and each one is
# written as the *observable* rule rather than the incidental detail, so it
# survives a refactor:
#
#   - "reverting on a clean sandbox creates nothing" — not "the eight files I
#     happened to think of are absent". The first version of that check passed
#     while a ninth file was being created.
#   - "the user's file comes back byte for byte" — not "it still contains their
#     text". `contains` passes on a reformatted file, which is how a lost
#     trailing newline and a collapsed blank line stayed hidden.
#
# It runs against a throwaway JXCODE_ROOT, so it never touches the real sandbox:
# no providers added, no agent config written, nothing to clean up afterwards.
#
# Exit 0 = binding and unbinding are inverse. Exit 1 = they are not, with the
# evidence printed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JXCODE="$ROOT/.build/debug/jxcode"
PY="${PYTHON:-/Users/joshua/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3}"

if [[ ! -x "$JXCODE" ]]; then
    echo "FAIL: $JXCODE not built. run: swift build --disable-sandbox -c debug"
    exit 1
fi
if [[ ! -x "$PY" ]]; then
    echo "FAIL: python not found at $PY (set PYTHON=... to override)"
    exit 1
fi

SANDBOX="$(mktemp -d /tmp/jxcode-collection-XXXXXX)"
export JXCODE_ROOT="$SANDBOX/sandbox"
mkdir -p "$JXCODE_ROOT"

FAILURES=()
fail() { FAILURES+=("$1"); }

HOME_DIR="$JXCODE_ROOT/env/home"
CLAUDE_MCP="$HOME_DIR/.claude.json"
CLAUDE_SETTINGS="$HOME_DIR/.claude/settings.json"
GEMINI_SETTINGS="$HOME_DIR/.gemini/settings.json"
OPENCODE_CONFIG="$HOME_DIR/.config/opencode/opencode.json"
CODEX_CONFIG="$HOME_DIR/.codex/config.toml"
SHARED_LEDGER="$JXCODE_ROOT/shared/mcp.json"

# Every file either binder may write. Used by the "creates nothing" check, which
# is deliberately paired with a whole-tree snapshot below — the list is the
# readable half, the snapshot is the half that cannot miss a file.
MANAGED_FILES=(
    "$CLAUDE_MCP" "$CLAUDE_SETTINGS" "$GEMINI_SETTINGS"
    "$OPENCODE_CONFIG" "$CODEX_CONFIG"
    "$HOME_DIR/.claude/CLAUDE.md" "$HOME_DIR/.codex/AGENTS.md"
    "$HOME_DIR/.gemini/GEMINI.md" "$HOME_DIR/.config/opencode/AGENTS.md"
)

tree() { find "$JXCODE_ROOT" -type f 2>/dev/null | sed "s|$JXCODE_ROOT||" | sort; }
digest() { tree | shasum | awk '{print $1}'; }

# Byte comparison, because a substring check cannot see reformatting.
# $1 is the file now, $2 is the copy taken before we touched it.
same_bytes() {
    "$PY" -c "
import pathlib, sys
now, was = pathlib.Path(sys.argv[1]).read_bytes(), pathlib.Path(sys.argv[2]).read_bytes()
if now == was:
    sys.exit(0)
print('   expected (before):', repr(was))
print('   actual   (now)   :', repr(now))
sys.exit(1)
" "$1" "$2"
}

echo "JXCode → bind/unbind inverse verification"
echo "════════════════════════════════════════════════════════════════"
echo "  sandbox   $JXCODE_ROOT"
echo

# ── 1. A clean sandbox stays clean ───────────────────────────────────────────
#
# Unbinding must not create anything in order to remove something. The original
# bug: revert materialised three config files containing `{}` in an agent's home
# and then reported that it had cleared them.
echo "── 1. both unbinds are no-ops on a clean sandbox"
"$JXCODE" shared >/dev/null 2>&1
BEFORE="$(tree)"

"$JXCODE" shared-revert >/dev/null 2>&1
"$JXCODE" unbind >/dev/null 2>&1
"$JXCODE" shared-bind >/dev/null 2>&1

if [[ "$(tree)" != "$BEFORE" ]]; then
    echo "   diff (unexpected files):"
    diff <(echo "$BEFORE") <(tree) | sed 's/^/     /'
    fail "unbinding or an empty bind created files on a clean sandbox"
else
    echo "   ok  (nothing created)"
fi

# The ledger is JXCode's own bookkeeping and follows the same rule.
[[ -f "$SHARED_LEDGER" ]] && fail "the connector ledger was created to record that it was empty"

# ── 2. Seed the collection and a user's own config ───────────────────────────
echo "── 2. seed the collection and pre-existing user content"
"$JXCODE" skill-add --name "Release checklist" --description "Steps before tagging" \
    --body $'# Release\n\nRun the suite.' >/dev/null 2>&1
"$JXCODE" connector-add --name filesystem --command npx \
    --args "-y @modelcontextprotocol/server-filesystem" >/dev/null 2>&1
"$JXCODE" automation-add --name nightly --agent claude --prompt "triage open issues" >/dev/null 2>&1

mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex"
# Their file, their formatting: compact, unsorted, and a blank-line run plus a
# trailing newline. The newline and the blank run are what a `contains` check
# would not notice losing.
printf '{"numStartups":42,"mcpServers":{"their-server":{"command":"their-binary"}}}' > "$CLAUDE_MCP"
cp "$CLAUDE_MCP" "$SANDBOX/claude.json.orig"
printf 'key1 = "a"\n\n\n[table]\nkey2 = "b"\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/config.toml.orig"
echo "   ok  (2 skills/connectors registered, 2 files of theirs written)"

# ── 3. Binding writes the four shapes, each different ────────────────────────
#
# There is no shared MCP standard: claude and gemini both use `mcpServers`,
# opencode wants `command` as a single array under `mcp`, and codex is TOML
# appended after the user's own top-level keys. A wrong shape is silent.
echo "── 3. bind writes all four config formats"
"$JXCODE" shared-bind >/dev/null 2>&1

"$PY" - "$CLAUDE_MCP" "$GEMINI_SETTINGS" "$OPENCODE_CONFIG" "$CODEX_CONFIG" <<'PY'
import json, pathlib, sys

def load(p):
    return json.loads(pathlib.Path(p).read_text())

problems = []
claude = load(sys.argv[1])
if "filesystem" not in claude.get("mcpServers", {}):
    problems.append("claude: no filesystem under mcpServers")
if claude.get("numStartups") != 42:
    problems.append("claude: the user's own numStartups was lost")
if "their-server" not in claude.get("mcpServers", {}):
    problems.append("claude: the user's own server was lost")

if "filesystem" not in load(sys.argv[2]).get("mcpServers", {}):
    problems.append("gemini: no filesystem under mcpServers")

entry = load(sys.argv[3]).get("mcp", {}).get("filesystem", {})
if not isinstance(entry.get("command"), list):
    problems.append("opencode: `command` must be a single array, not a string")
if entry.get("type") != "local" or entry.get("enabled") is not True:
    problems.append("opencode: missing `type: local` / `enabled: true`")

toml = pathlib.Path(sys.argv[4]).read_text()
if "[mcp_servers.filesystem]" not in toml:
    problems.append("codex: no [mcp_servers.filesystem] table")
if "key1" in toml and toml.index("key1") > toml.index("[mcp_servers.filesystem]"):
    problems.append("codex: our table was placed before the user's top-level keys")

for p in problems:
    print("   " + p)
sys.exit(1 if problems else 0)
PY
if [[ $? -ne 0 ]]; then
    fail "a connector config was written in the wrong shape"
else
    echo "   ok  (claude, gemini, opencode, codex)"
fi

# ── 4. Binding twice changes nothing ─────────────────────────────────────────
echo "── 4. binding is idempotent"
FIRST="$(digest)"
"$JXCODE" shared-bind >/dev/null 2>&1
if [[ "$(digest)" != "$FIRST" ]]; then
    fail "a second bind changed the tree (not idempotent)"
else
    echo "   ok  ($FIRST)"
fi

# ── 5. Unbinding returns the files ───────────────────────────────────────────
echo "── 5. revert removes what it created, restores what it did not"
"$JXCODE" shared-revert >/dev/null 2>&1

# Files we created are gone rather than left blank. `config.toml` and
# `.claude.json` are deliberately NOT in this list: they were written by hand in
# step 2, so they predate us and must survive — that is the other half of the
# rule, asserted just below.
for f in "$GEMINI_SETTINGS" "$OPENCODE_CONFIG" \
         "$HOME_DIR/.codex/AGENTS.md" "$HOME_DIR/.gemini/GEMINI.md" \
         "$HOME_DIR/.config/opencode/AGENTS.md"; do
    [[ -e "$f" ]] && fail "left behind a file it created: ${f#$JXCODE_ROOT}"
done

# Files the user owned come back byte for byte. Text only — JSON is re-rendered
# on every write, so it is compared for content below, not bytes. That gap is
# documented in the README's Known limitations.
if same_bytes "$CODEX_CONFIG" "$SANDBOX/config.toml.orig"; then
    echo "   ok  (created files removed, the user's config.toml byte-identical)"
else
    fail "config.toml did not come back byte for byte"
fi

"$PY" - "$CLAUDE_MCP" "$SANDBOX/claude.json.orig" <<'PY'
import json, pathlib, sys
now = json.loads(pathlib.Path(sys.argv[1]).read_text())
was = json.loads(pathlib.Path(sys.argv[2]).read_text())
if now != was:
    print("   expected:", was)
    print("   actual  :", now)
    sys.exit(1)
PY
if [[ $? -ne 0 ]]; then
    fail "the user's settings did not survive a bind and revert"
fi

# Nothing of ours anywhere in the agent's tree.
if grep -rl "jxcode" "$HOME_DIR" 2>/dev/null | grep -q .; then
    fail "jxcode markers remain in the agent's home"
    grep -rl "jxcode" "$HOME_DIR" 2>/dev/null | sed 's/^/     /'
else
    echo "   ok  (no jxcode markers left in the agent's home)"
fi

# ── 6. The router binding gives the same guarantees ──────────────────────────
#
# A separate writer with a separate rule set — and the one that was missed for
# longest, because the shared collection's binders had already been fixed.
#
# Both halves are checked, in two sandboxes: this one has user-owned files (so
# they must survive), the clean one below has none (so ours must be removed).
# Asserting "the file is gone" in a sandbox where the file was the user's is how
# a check can be backwards and still look like it passes.
echo "── 6. the router binding behaves the same way"
ROUTER_ROOT="$SANDBOX/router-root"
export JXCODE_ROOT="$ROUTER_ROOT"
mkdir -p "$JXCODE_ROOT"
HOME_DIR="$JXCODE_ROOT/env/home"
CODEX_CONFIG="$HOME_DIR/.codex/config.toml"
CLAUDE_SETTINGS="$HOME_DIR/.claude/settings.json"

"$JXCODE" shared >/dev/null 2>&1
"$JXCODE" provider-add local http://127.0.0.1:5299 >/dev/null 2>&1
mkdir -p "$HOME_DIR/.codex" "$HOME_DIR/.claude"
printf 'key1 = "a"\n\n\n[table]\nkey2 = "b"\n' > "$CODEX_CONFIG"
cp "$CODEX_CONFIG" "$SANDBOX/router-config.toml.orig"
printf '{"numStartups":42}' > "$CLAUDE_SETTINGS"

"$JXCODE" bind --model qwen3-coder --port 5299 >/dev/null 2>&1
[[ -f "$CODEX_CONFIG" ]] || fail "bind did not write config.toml"
[[ -f "$CLAUDE_SETTINGS" ]] || fail "bind did not write settings.json"

"$JXCODE" unbind >/dev/null 2>&1

# 6a. Files that predated us survive, byte for byte.
if same_bytes "$CODEX_CONFIG" "$SANDBOX/router-config.toml.orig"; then
    echo "   ok  (the user's config.toml byte-identical after unbind)"
else
    fail "the router's config.toml did not come back byte for byte"
fi

# 6b. Files we created are removed, and the sandbox returns to its prior state.
CLEAN_ROOT="$SANDBOX/clean-root"
export JXCODE_ROOT="$CLEAN_ROOT"
mkdir -p "$JXCODE_ROOT"
"$JXCODE" shared >/dev/null 2>&1
"$JXCODE" provider-add local http://127.0.0.1:5299 >/dev/null 2>&1
CLEAN_BEFORE="$(tree)"

"$JXCODE" bind --model qwen3-coder --port 5299 >/dev/null 2>&1
[[ -f "$CLEAN_ROOT/env/home/.codex/config.toml" ]] \
    || fail "bind did not write a config.toml on a clean sandbox"

"$JXCODE" unbind >/dev/null 2>&1
[[ -f "$CLEAN_ROOT/env/home/.codex/config.toml" ]] \
    && fail "unbind left behind the config.toml it created"
[[ -f "$CLEAN_ROOT/env/home/.claude/settings.json" ]] \
    && fail "unbind left behind the settings.json it created"
if [[ "$(tree)" == "$CLEAN_BEFORE" ]]; then
    echo "   ok  (files it created are removed; the sandbox is as it was)"
else
    fail "unbind did not restore a clean sandbox"
    diff <(echo "$CLEAN_BEFORE") <(tree) | sed 's/^/     /'
fi

echo
echo "════════════════════════════════════════════════════════════════"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "PASS — binding and unbinding are inverse operations."
    echo
    echo "  artifacts kept for inspection: $SANDBOX"
    exit 0
fi

echo "FAIL — ${#FAILURES[@]} problem(s):"
for f in "${FAILURES[@]}"; do echo "  • $f"; done
echo
echo "  artifacts: $SANDBOX"
exit 1
