#!/usr/bin/env python3
"""A minimal OpenAI-compatible backend, for verifying the JXCode router.

Serves /v1/models and /v1/chat/completions (streaming and not), and deliberately
emits CRLF line endings in the SSE stream — that is legal, and it is exactly the
case a String-based parser silently mishandles in Swift.

Usage: fake_openai_server.py [port]
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "fake-qwen3-coder"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # Quiet; the router's own log is what matters.

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        if self.path.endswith("/models"):
            payload = json.dumps(
                {"object": "list", "data": [{"id": MODEL, "object": "model"}]}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_error(404)

    def do_POST(self):
        raw = self._read_body()
        try:
            request = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self.send_error(400)
            return

        # Echo what we received so the caller can assert on the translation.
        sys.stderr.write(
            "UPSTREAM model=%r roles=%r tools=%d stream=%r\n"
            % (
                request.get("model"),
                [m.get("role") for m in request.get("messages", [])],
                len(request.get("tools") or []),
                request.get("stream"),
            )
        )
        sys.stderr.flush()

        if request.get("stream"):
            self._stream(request)
        else:
            self._complete(request)

    def _complete(self, request):
        wants_tool = bool(request.get("tools"))
        if wants_tool:
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_abc",
                        "type": "function",
                        "function": {
                            "name": "read_file",
                            "arguments": json.dumps({"path": "/etc/hosts"}),
                        },
                    }
                ],
            }
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": "Hello from the fake backend."}
            finish = "stop"

        payload = json.dumps(
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": request.get("model"),
                "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {
                    "prompt_tokens": 17,
                    "completion_tokens": 6,
                    "total_tokens": 23,
                },
            }
        ).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _stream(self, request):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        chunks = [
            {"choices": [{"index": 0, "delta": {"role": "assistant", "content": "Hel"}}]},
            {"choices": [{"index": 0, "delta": {"content": "lo "}}]},
            {"choices": [{"index": 0, "delta": {"content": "world"}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            # The usage trailer arrives after finish_reason.
            {"choices": [], "usage": {"prompt_tokens": 17, "completion_tokens": 4}},
        ]

        for chunk in chunks:
            # CRLF, deliberately.
            frame = ("data: " + json.dumps(chunk) + "\r\n\r\n").encode()
            self.wfile.write(b"%x\r\n" % len(frame) + frame + b"\r\n")
            self.wfile.flush()

        done = b"data: [DONE]\r\n\r\n"
        self.wfile.write(b"%x\r\n" % len(done) + done + b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8137
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write("fake backend on http://127.0.0.1:%d\n" % port)
    sys.stderr.flush()
    server.serve_forever()
