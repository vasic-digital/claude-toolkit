#!/usr/bin/env python3
"""poe_proxy.py — lightweight proxy for Poe API compatibility.

Fixes Claude Code → Poe tool format issues:
- Ensures all tools have `parameters` field (Poe requires it)
- Strips cache_control from messages
- Passes through everything else unchanged

Usage:
  poe_proxy.py [--port 3457] [--poe-url https://api.poe.com/v1]

ccr config should point to this proxy instead of directly to Poe:
  api_base_url: http://localhost:3457/v1/chat/completions
"""
import argparse
import gzip
import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError

POE_URL = "https://api.poe.com/v1"
DEFAULT_PORT = 3457


def resolve_refs(obj, defs):
    """Recursively resolve $ref references in a JSON schema object."""
    if isinstance(obj, dict):
        if "$ref" in obj and isinstance(obj["$ref"], str):
            ref = obj["$ref"]
            if ref.startswith("#/$defs/"):
                name = ref.split("/")[-1]
                if name in defs:
                    return resolve_refs(defs[name], defs)
            return obj
        return {k: resolve_refs(v, defs) for k, v in obj.items()}
    if isinstance(obj, list):
        return [resolve_refs(item, defs) for item in obj]
    return obj


def fix_tools(tools):
    """Ensure every tool has a valid parameters field and resolve $ref."""
    if not tools or not isinstance(tools, list):
        return tools
    fixed = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        t = dict(tool)
        func = t.get("function")
        if isinstance(func, dict):
            f = dict(func)
            if "parameters" not in f or not f["parameters"]:
                f["parameters"] = {"type": "object", "properties": {}}
            # Resolve $ref references (Grok-4 and some providers don't support them)
            params = f["parameters"]
            if isinstance(params, dict) and "$defs" in params:
                defs = params.pop("$defs")
                f["parameters"] = resolve_refs(params, defs)
            elif isinstance(params, dict) and "$ref" in params:
                # Top-level $ref — resolve with empty defs (best effort)
                f["parameters"] = resolve_refs(params, {})
            t["function"] = f
        fixed.append(t)
    return fixed


def strip_cache_control(obj):
    """Recursively remove cache_control from nested objects."""
    if isinstance(obj, dict):
        return {k: strip_cache_control(v) for k, v in obj.items() if k != "cache_control"}
    if isinstance(obj, list):
        return [strip_cache_control(item) for item in obj]
    return obj


def fix_request(body):
    """Apply all fixes to request body."""
    # Fix tools
    if "tools" in body:
        body["tools"] = fix_tools(body["tools"])
    # Strip cache_control from messages
    if "messages" in body:
        body["messages"] = strip_cache_control(body["messages"])
    return body


class ProxyHandler(BaseHTTPRequestHandler):
    poe_url = POE_URL

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(content_length)
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            self.send_error(400, "Invalid JSON")
            return

        # Apply fixes
        body = fix_request(body)

        # Forward to Poe — path already includes /v1/chat/completions
        url = f"{self.poe_url.rstrip('/')}{self.path}" if not self.path.startswith("/v1") else f"https://api.poe.com{self.path}"
        headers = {
            "Content-Type": "application/json",
            "Authorization": self.headers.get("Authorization", ""),
            # Do NOT send Accept-Encoding — let urllib handle decompression
        }
        data = json.dumps(body).encode("utf-8")
        req = Request(url, data=data, headers=headers, method="POST")

        # Check if streaming is requested
        is_stream = body.get("stream", False)

        try:
            with urlopen(req, timeout=120) as resp:
                resp_body = resp.read()
                # Decompress gzip if needed
                encoding = resp.headers.get("Content-Encoding", "")
                if encoding == "gzip":
                    resp_body = gzip.decompress(resp_body)
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.end_headers()
                self.wfile.write(resp_body)
        except HTTPError as e:
            resp_body = e.read()
            # Decompress gzip if needed
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
        pass  # Suppress default logging


def main(argv=None):
    ap = argparse.ArgumentParser(description="Poe API proxy")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--poe-url", default=POE_URL)
    args = ap.parse_args(argv)

    ProxyHandler.poe_url = args.poe_url
    server = HTTPServer(("127.0.0.1", args.port), ProxyHandler)
    print(f"Poe proxy listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"Forwarding to {args.poe_url}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
