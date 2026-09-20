#!/usr/bin/env python3
"""Prove Claude Code answers *in a real interactive terminal*.

`verify_claude_cli.sh` drives `claude -p`, which is one-shot: it prints and
exits. This drives the thing the user actually looks at — the interactive TUI
inside a pty, exactly as `jxcode pty claude` (and therefore JXCode's terminal
tab) runs it. Nothing here touches /v1/messages directly.

It allocates a pty, sets a real window size, spawns the agent through
`jxcode pty`, waits for the prompt, types a question, and reads what comes
back on the screen.

Exit 0 = Claude answered in the terminal. Exit 1 = it did not.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

REPO = os.path.dirname(os.path.abspath(__file__))
JXCODE = os.path.join(REPO, "..", ".build", "debug", "jxcode")
CLAUDE_BIN = os.path.expanduser("~/.local/bin/claude")
ANSI = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][B0]|\r")

PROMPT = "Reply with exactly the word PONG and nothing else."


def free_port():
    import socket

    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def strip(data: bytes) -> str:
    # Replace escapes with a space, not with nothing. Terminal UIs position the
    # cursor instead of emitting runs of spaces, so deleting the sequences
    # glues every word to the next ("trustthisfolder") — which both looks
    # unreadable and breaks every substring match.
    text = ANSI.sub(b" ", data).decode("utf8", "replace")
    return re.sub(r"[ \t]{2,}", " ", text)


def wait_for(pred, timeout, poll=0.25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(poll)
    return False


class Pty:
    """A child process attached to a real terminal."""

    def __init__(self, argv, env, cols=120, rows=40):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc = subprocess.Popen(
            argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            preexec_fn=os.setsid,
            close_fds=True,
        )
        os.close(slave)
        self.buffer = bytearray()

    def pump(self, seconds=0.5):
        deadline = time.time() + seconds
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.2)
            if not r:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.buffer += chunk

    def text(self):
        return strip(bytes(self.buffer))

    def type(self, text):
        os.write(self.master, text.encode())

    def alive(self):
        return self.proc.poll() is None

    def kill(self):
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
        except Exception:
            self.proc.kill()


def main():
    # Optional: verify against a real provider instead of the local fixture.
    #   verify_claude_terminal.py --provider xKiro --model deepseek/deepseek-v3.2
    provider = None
    model = None
    argv = sys.argv[1:]
    if "--provider" in argv:
        provider = argv[argv.index("--provider") + 1]
    if "--model" in argv:
        model = argv[argv.index("--model") + 1]
    real = provider is not None

    upstream_port = free_port()
    router_port = free_port()
    root = f"/tmp/jxcode-pty-{os.getpid()}"
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    sandbox = os.path.join(root, "sandbox")
    os.makedirs(sandbox)
    claude_home = os.path.join(root, "claude-home")
    os.makedirs(claude_home)

    print("Native-terminal verification (interactive TUI in a pty)")
    print("=" * 64)
    print(f"  upstream  127.0.0.1:{upstream_port}")
    print(f"  router    127.0.0.1:{router_port}")
    print(f"  claude    {CLAUDE_BIN}")
    print()

    # A real provider is registered in the *real* sandbox, not the throwaway
    # one — pointing JXCODE_ROOT at an empty sandbox is why this initially
    # reported "router never came up" for xKiro.
    if real:
        router_env = {k: v for k, v in os.environ.items() if k != "JXCODE_ROOT"}
    else:
        router_env = dict(os.environ, JXCODE_ROOT=sandbox)
    upstream = None
    if not real:
        upstream = subprocess.Popen(
            [
                sys.executable,
                os.path.join(REPO, "fake_openai_server.py"),
                str(upstream_port),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=router_env,
        )
        time.sleep(1.5)

        if (
            subprocess.run(
                [
                    JXCODE,
                    "provider-add",
                    "VerifyUpstream",
                    f"http://127.0.0.1:{upstream_port}",
                ],
                env=router_env,
                capture_output=True,
            ).returncode
            != 0
        ):
            print("FAIL: could not register the test provider")
            return 1
        provider, model = "VerifyUpstream", "fake-qwen3-coder"

    router = subprocess.Popen(
        [
            JXCODE,
            "route",
            "--provider",
            provider,
            "--model",
            model,
            "--port",
            str(router_port),
        ],
        stdout=open(os.path.join(root, "router.log"), "wb"),
        stderr=subprocess.STDOUT,
        env=router_env,
    )

    import urllib.request

    up = False
    for _ in range(40):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{router_port}/v1/models", timeout=2)
            up = True
            break
        except Exception:
            time.sleep(0.25)
    if not up:
        print("FAIL: router never came up")
        router.kill()
        if upstream: upstream.kill()
        return 1
    print("  router up")

    # The real sandbox (claude is installed there), a throwaway CLAUDE_CONFIG_DIR
    # so nothing of the user's is read or written, and the router handed over
    # exactly the way the app hands it over.
    env = {k: v for k, v in os.environ.items() if k != "JXCODE_ROOT"}
    env["CLAUDE_CONFIG_DIR"] = claude_home
    env["TERM"] = "xterm-256color"

    term = Pty(
        [JXCODE, "pty", "--router", f"http://127.0.0.1:{router_port}", "claude"],
        env=env,
    )

    # The interactive TUI does not start at a chat prompt. First run it asks
    # whether you trust the workspace, and the cursor sits on "No, exit" — so
    # pressing Enter there would quit. Answer it, then wait for the real prompt.
    # One loop, because the TUI opens on a trust prompt only when the
    # workspace has not been trusted before — and that state persists in the
    # workspace's .claude/settings.local.json, so a second run goes straight to
    # the chat. Waiting for one and then the other wasted 90s on the wrong one.
    print("  waiting for the interactive UI …")
    term.pump(1.0)
    ready = False
    trusted = False
    deadline = time.time() + 60
    while time.time() < deadline:
        term.pump(0.8)
        screen = term.text()
        if "trust this folder" in screen:
            # Cursor starts on "No, exit"; Down selects "Yes, I trust this folder".
            term.type("\x1b[B")
            time.sleep(0.4)
            term.type("\r")
            trusted = True
            print("  confirmed: yes, I trust this folder")
            # Fresh buffer: the trust prompt's own "❯" must not be mistaken
            # for the chat input line.
            term.buffer.clear()
            continue
        if "❯" in screen:
            ready = True
            break
    if not ready:
        print("  router said:")
        print(
            "    "
            + (open(os.path.join(root, "router.log")).read() or "(nothing)")
            .strip()[:1500]
            .replace("\n", "\n    ")
        )
        print(f"FAIL: Claude never presented a chat prompt ({len(term.buffer)} bytes read)")
        print(term.text()[-2000:])
        term.kill()
        router.kill()
        if upstream: upstream.kill()
        return 1
    print(f"  chat prompt ready{' (trust was already granted)' if not trusted else ''}")

    # Clear first: everything after this point is the turn, so the echoed
    # prompt cannot satisfy the check. That was a real false positive — searching
    # the whole buffer for "PONG" matched the question, not the answer, and
    # reported PASS on a screen that held nothing but a spinner.
    term.buffer.clear()
    term.type(PROMPT + "\r")
    print(f"  typed: {PROMPT}")

    # "⏺" is Claude Code's marker for an assistant turn. Waiting for it,
    # rather than for expected words, keeps this honest for any backend.
    answered = wait_for(lambda: (term.pump(1.0), "⏺" in term.text())[1], timeout=180)

    # Let the stream finish: keep reading until nothing arrives for 4s.
    quiet_until = time.time() + 4
    while time.time() < quiet_until:
        before = len(term.buffer)
        term.pump(1.0)
        if len(term.buffer) != before:
            quiet_until = time.time() + 4

    screen = term.text()
    # The reply is everything after the last assistant-turn marker.
    reply = screen.rsplit("⏺", 1)[-1] if answered else ""
    router_alive = router.poll() is None
    term.kill()
    router.kill()
    if upstream: upstream.kill()
    print(f"  router alive at end of session: {router_alive}")

    print()
    print("=" * 64)
    # Show the tail of the session as evidence, not a paraphrase of it.
    tail = "\n".join(line.rstrip() for line in screen.splitlines() if line.strip())
    print("  terminal transcript (tail):")
    for line in tail.splitlines()[-25:]:
        print(f"    | {line}")

    # Show what was actually answered, so a pass is never inferred from
    # something the harness typed itself.
    print()
    print(f"  reply text: {reply.strip()[:300]!r}")

    problems = []
    letters = sum(c.isalpha() for c in reply)
    if not answered:
        problems.append("Claude never rendered an assistant turn (no ⏺ in the terminal)")
    elif letters < 2:
        problems.append(f"the assistant turn held no words ({letters} letters)")
    if "not logged in" in screen.lower():
        problems.append("Claude says it is not logged in")
    if re.search(r"connection refused|unable to connect", screen, re.I):
        problems.append("Claude could not reach the router")

    print()
    if problems:
        print("FAIL:")
        for p in problems:
            print(f"  • {p}")
        return 1

    print("PASS — Claude answered in the native interactive terminal.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
