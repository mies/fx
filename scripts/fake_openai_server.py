#!/usr/bin/env python3
"""Fake OpenAI-compatible /chat/completions SSE server for manual fx verification.

Streams canned chat.completion.chunk objects. If the last user/tool message
contains the word "toolcall" and no tool-role message is present yet, it streams
a split tool call instead, so fx's full tool round-trip can be exercised.
"""

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "fake-model"


def chunk(delta, finish_reason=None, usage=None):
    body = {
        "id": "chatcmpl-fake",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": MODEL,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
    }
    if usage is not None:
        body["usage"] = usage
    return body


TEXT_CHUNKS = [
    chunk({"role": "assistant", "content": "Hello"}),
    chunk({"content": " from"}),
    chunk({"content": " fake-server."}),
    chunk({}, finish_reason="stop"),
    chunk({}, usage={"prompt_tokens": 12, "completion_tokens": 5}),
]

TOOL_CHUNKS = [
    chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_fake_1", "type": "function", "function": {"name": "list_files", "arguments": ""}}]}),
    chunk({"tool_calls": [{"index": 0, "function": {"arguments": "{\"path\":"}}]}),
    chunk({"tool_calls": [{"index": 0, "function": {"arguments": " \".\"}"}}]}),
    chunk({}, finish_reason="tool_calls"),
    chunk({}, usage={"prompt_tokens": 20, "completion_tokens": 9}),
]

FOLLOWUP_CHUNKS = [
    chunk({"role": "assistant", "content": "The tool result listed"}),
    chunk({"content": " the files."}),
    chunk({}, finish_reason="stop"),
    chunk({}, usage={"prompt_tokens": 30, "completion_tokens": 6}),
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[fake-openai] " + fmt % args, file=sys.stderr)

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            payload = json.dumps({"error": {"message": "Missing API key.", "type": "invalid_request_error"}}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}

        messages = body.get("messages", [])
        roles = [m.get("role", "?") for m in messages]
        print(
            "[fake-openai] request model=%s stream=%s tool_choice=%s tools=%d roles=%s"
            % (
                body.get("model"),
                body.get("stream"),
                json.dumps(body.get("tool_choice")),
                len(body.get("tools", []) or []),
                ",".join(roles),
            ),
            file=sys.stderr,
        )

        has_tool_result = any(m.get("role") == "tool" for m in messages)
        last_text = ""
        for m in reversed(messages):
            if m.get("role") in ("user", "tool") and isinstance(m.get("content"), str):
                last_text = m["content"]
                break

        if has_tool_result:
            chunks = FOLLOWUP_CHUNKS
        elif "toolcall" in last_text:
            chunks = TOOL_CHUNKS
        else:
            chunks = TEXT_CHUNKS

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for item in chunks:
            self.wfile.write(b"data: " + json.dumps(item).encode() + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8137)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("http://127.0.0.1:%d/chat/completions" % args.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
