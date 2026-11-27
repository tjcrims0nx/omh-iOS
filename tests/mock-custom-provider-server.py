#!/usr/bin/env python3
"""Mock OpenAI-compatible and Anthropic-compatible provider endpoints for the
custom-provider persistence UI test.

Listens on 127.0.0.1:18080. The iOS Simulator shares the Mac's network, so
the app under test reaches this server at http://127.0.0.1:18080.

Endpoints (all deterministic, no real credentials, no network access):
  GET  /v1/models            -> {"object": "list", "data": [...]} (verification)
  POST /v1/chat/completions -> OpenAI-format reply "mock openai reply"
  POST /v1/messages         -> Anthropic-format reply "mock anthropic reply"
  GET  /redirect/models     -> 302 to /v1/models (redirect-protection probe;
                               a client that follows redirects would see 200,
                               a client that blocks them sees 302)

Security: the server logs only the request method and path. It never logs
headers (which carry API keys) or request bodies. Nothing credential-like
appears in its output.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 18080

MODELS = {
    "object": "list",
    "data": [
        {"id": "mock-openai-model", "object": "model"},
        {"id": "mock-anthropic-model", "object": "model"},
    ],
}
OPENAI_REPLY = {
    "id": "chatcmpl-mock",
    "object": "chat.completion",
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": "mock openai reply"},
            "finish_reason": "stop",
        }
    ],
    "model": "mock-openai-model",
}
ANTHROPIC_REPLY = {
    "id": "msg-mock",
    "type": "message",
    "role": "assistant",
    "content": [{"type": "text", "text": "mock anthropic reply"}],
    "model": "mock-anthropic-model",
    "stop_reason": "end_turn",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Log method + path only. Never log headers or bodies: they can
        # carry API keys.
        print(f"{self.command} {self.path}", flush=True)

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 0:
            self.rfile.read(length)

    def do_GET(self):
        if self.path == "/v1/models":
            self._send_json(200, MODELS)
        elif self.path == "/redirect/models":
            self.send_response(302)
            self.send_header("Location", "/v1/models")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        self._read_body()
        if self.path == "/v1/chat/completions":
            self._send_json(200, OPENAI_REPLY)
        elif self.path == "/v1/messages":
            self._send_json(200, ANTHROPIC_REPLY)
        else:
            self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"mock custom-provider server on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()
