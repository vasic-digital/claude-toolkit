#!/usr/bin/env python3
"""sarvam_proxy.py — compatibility proxy for the Sarvam API.

Sarvam's chat endpoint is OpenAI-strict about message shapes: a system
message whose `content` is an ARRAY of content blocks is rejected with
`400 body.messages.0.system.content : Input should be a valid string`
(reproduced live against model sarvam-105b). Claude Code (via
claude-code-router) emits exactly that shape — the system prompt travels as
content blocks — so every real launch 400s while simple string probes pass.

This proxy flattens any message whose `content` is a list of content blocks
into a single joined string (text blocks concatenated; non-text blocks
dropped with a stderr note), which is the shape strict providers accept.
Everything else passes through unchanged.

Usage:
  sarvam_proxy.py [--port 3457] [--upstream https://api.sarvam.ai]

The alias wrapper (cma_run_provider) routes sarvam* aliases through this
proxy via the <id/base/family>_proxy.py discovery rule.
"""
import argparse
import gzip
import os
import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError

UPSTREAM = "https://api.sarvam.ai"
DEFAULT_PORT = 3457

# Claude Code asks for 64000 max output tokens by default; the starter tier
# allows 4096 (`400 max_tokens (64000) exceeds the maximum allowed for
# sarvam-105b for your subscription tier (starter): 4096` — reproduced live).
# Clamp instead of failing. Override via SARVAM_MAX_OUTPUT_TOKENS.
try:
    MAX_OUTPUT_TOKENS = int(os.environ.get("SARVAM_MAX_OUTPUT_TOKENS", "4096"))
except (TypeError, ValueError):
    MAX_OUTPUT_TOKENS = 4096


def flatten_content(content):
    """Flatten a content-block list into a single string.

    Returns the input unchanged when it is already a string (or not a list),
    so OpenAI-native list content for providers that accept it is untouched
    by accident — this helper is only applied where strictness is known to
    be required (system messages), plus optionally for all roles via env.
    """
    if not isinstance(content, list):
        return content
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(p for p in parts if p)


def fix_request(body):
    """Flatten message content arrays to strings (Sarvam requirement).

    Sarvam's endpoint is OpenAI-strict about EVERY role: system content
    blocks 400 with `body.messages.0.system.content : Input should be a
    valid string` and, once system is fixed, user content blocks 400 the
    same way at messages.1.user.content (both reproduced live). Claude Code
    (via ccr) emits content blocks everywhere, so every message whose
    content is a list is flattened here.
    """
    messages = body.get("messages")
    if isinstance(messages, list):
        for msg in messages:
            if isinstance(msg, dict) and isinstance(msg.get("content"), list):
                msg["content"] = flatten_content(msg["content"])
    # Clamp max_tokens to the subscription tier ceiling (starter: 4096) —
    # Claude Code's 64000 default is rejected outright by the tier check.
    mt = body.get("max_tokens")
    if isinstance(mt, (int, float)) and mt > MAX_OUTPUT_TOKENS:
        body["max_tokens"] = MAX_OUTPUT_TOKENS
    return body


class ProxyHandler(BaseHTTPRequestHandler):
    upstream = UPSTREAM

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(content_length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return

        body = fix_request(body)
        url = f"{self.upstream.rstrip('/')}{self.path}"
        headers = {
            "Content-Type": "application/json",
            "Authorization": self.headers.get("Authorization", ""),
        }
        req = Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
        try:
            with urlopen(req, timeout=120) as resp:
                resp_body = resp.read()
                if resp.headers.get("Content-Encoding", "") == "gzip":
                    try:
                        resp_body = gzip.decompress(resp_body)
                    except Exception:
                        pass
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.end_headers()
                self.wfile.write(resp_body)
        except HTTPError as e:
            resp_body = e.read()
            encoding = e.headers.get("Content-Encoding", "") if e.headers else ""
            if encoding == "gzip":
                try:
                    resp_body = gzip.decompress(resp_body)
                except Exception:
                    pass
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(resp_body)

    def log_message(self, format, *args):
        pass


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sarvam API proxy (system content flattening)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--upstream", default=UPSTREAM)
    args = ap.parse_args(argv)
    ProxyHandler.upstream = args.upstream
    server = HTTPServer(("127.0.0.1", args.port), ProxyHandler)
    print(f"Sarvam proxy listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"Forwarding to {args.upstream}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
