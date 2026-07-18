#!/usr/bin/env python3
"""kimi_proxy.py — compatibility proxy for Kimi (moonshot-flavored) endpoints.

Kimi's coding API (api.kimi.com/coding) enforces a strict JSON-schema flavor
for tool definitions: every `$ref` must start with `#/$defs/` (verified live
against model k3: `400 tools.function.parameters is not a valid moonshot
flavored json schema ... references must start with #/$defs/`). Claude Code
(via claude-code-router) emits tool schemas with `$ref`s that do NOT match
that flavor — e.g. `#/definitions/orderBy` or bare names — which makes every
tool-carrying request fail.

This proxy rewrites each tool's `parameters` so the request passes:
- collects `$defs` AND `definitions` blocks (both are hoisted into `$defs`);
- rewrites any `$ref` that does not start with `#/$defs/` to
  `#/$defs/<last-segment>` when that name is defined;
- guarantees `parameters.type == "object"` and a `properties` key (the same
  requirement Poe has — harmless to enforce uniformly);
- strips cache_control from messages (not supported upstream);
- passes through everything else unchanged.

Usage:
  kimi_proxy.py [--port 3457] [--upstream https://api.kimi.com/coding/v1]

The alias wrapper (cma_run_provider) routes kimi-* aliases through this proxy
via the <family>_proxy.py discovery rule; ccr then points at
http://127.0.0.1:<port>/v1/chat/completions.
"""
import argparse
import gzip
import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError

UPSTREAM = os.environ.get("KIMI_PROXY_UPSTREAM", "https://api.kimi.com/coding")
DEFAULT_PORT = 3457


def normalize_schema(schema):
    """Normalize one tool's parameters schema to the moonshot flavor.

    Hoists $defs + definitions into a single $defs, rewrites foreign $refs to
    `#/$defs/<name>` when resolvable, and guarantees type/properties exist.
    """
    if not isinstance(schema, dict):
        return {"type": "object", "properties": {}}
    schema = dict(schema)
    defs = {}
    for key in ("$defs", "definitions"):
        block = schema.pop(key, None)
        if isinstance(block, dict):
            defs.update(block)

    def fix(node):
        if isinstance(node, dict):
            ref = node.get("$ref")
            if isinstance(ref, str) and not ref.startswith("#/$defs/"):
                name = ref.rstrip("/").split("/")[-1]
                if name in defs:
                    node = dict(node)
                    node["$ref"] = f"#/$defs/{name}"
            return {k: fix(v) for k, v in node.items()}
        if isinstance(node, list):
            return [fix(item) for item in node]
        return node

    schema = fix(schema)
    if defs:
        schema["$defs"] = defs
    if "type" not in schema:
        schema["type"] = "object"
    if not isinstance(schema.get("properties"), dict):
        schema["properties"] = {}
    return schema


def fix_tools(tools):
    """Normalize every tool's parameters schema to the moonshot flavor."""
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
            f["parameters"] = normalize_schema(f.get("parameters"))
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
    """Apply all fixes to a request body."""
    if "tools" in body:
        body["tools"] = fix_tools(body["tools"])
    if "messages" in body:
        body["messages"] = strip_cache_control(body["messages"])
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

        # Forward upstream — path already includes /v1/chat/completions.
        url = f"{self.upstream.rstrip('/')}{self.path}"
        headers = {
            "Content-Type": "application/json",
            "Authorization": self.headers.get("Authorization", ""),
        }
        data = json.dumps(body).encode("utf-8")
        req = Request(url, data=data, headers=headers, method="POST")
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
        pass  # Suppress default logging


def main(argv=None):
    ap = argparse.ArgumentParser(description="Kimi (moonshot-flavored) API proxy")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--upstream", default=UPSTREAM,
                    help="upstream API root (path is appended, e.g. /v1/chat/completions)")
    args = ap.parse_args(argv)

    ProxyHandler.upstream = args.upstream
    server = HTTPServer(("127.0.0.1", args.port), ProxyHandler)
    print(f"Kimi proxy listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"Forwarding to {args.upstream}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
