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
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError

POE_URL = "https://api.poe.com/v1"
DEFAULT_PORT = 3457

# Poe rejects requests carrying too many tool definitions with a misleading
# `400 Invalid 'tools': Field required`. Empirically the cutoff is ~216 tools
# (215 accepted, 220 rejected; verified count-based, not payload-size-based).
# On hosts with a large MCP-plugin load Claude Code can emit 400+ tools, which
# always trips this. We cap the tool list below Poe's limit, dropping only
# overflow MCP tools (`mcp__…`) so every built-in Claude Code tool is preserved.
# Parametrized via POE_MAX_TOOLS (default 200 — safe margin under ~216).
try:
    POE_MAX_TOOLS = int(os.environ.get("POE_MAX_TOOLS", "200"))
except (TypeError, ValueError):
    POE_MAX_TOOLS = 200


def resolve_refs(obj, defs, _depth=0):
    """Recursively resolve $ref references in a JSON schema object."""
    # Depth guard: a circular $ref (e.g. {"$defs":{"A":{"$ref":"#/$defs/A"}}})
    # would otherwise recurse until Python's RecursionError. 64 is far deeper
    # than any real tool schema; beyond it we stop resolving and return as-is.
    if _depth > 64:
        return obj
    if isinstance(obj, dict):
        if "$ref" in obj and isinstance(obj["$ref"], str):
            ref = obj["$ref"]
            if ref.startswith("#/$defs/"):
                name = ref.split("/")[-1]
                if name in defs:
                    return resolve_refs(defs[name], defs, _depth + 1)
            return obj
        return {k: resolve_refs(v, defs, _depth + 1) for k, v in obj.items()}
    if isinstance(obj, list):
        return [resolve_refs(item, defs, _depth + 1) for item in obj]
    return obj


def fix_tools(tools):
    """Ensure every tool has a valid parameters field and resolve $ref.

    Poe's real requirement (verified live, v1.14.0): `parameters` must exist,
    be an object, AND carry a `properties` key (an empty one is fine). A bare
    `{"type": "object"}` with no `properties` — the natural encoding of a
    zero-argument tool — is rejected with the misleading
    `400 Invalid 'tools': Field required`.
    """
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
            params = f.get("parameters")
            if not isinstance(params, dict) or not params:
                params = {"type": "object", "properties": {}}
            else:
                params = dict(params)
                if not isinstance(params.get("properties"), dict):
                    params["properties"] = {}
                if "type" not in params:
                    params["type"] = "object"
            # Resolve $ref references (Grok-4 and some providers don't support them)
            if "$defs" in params:
                defs = params.pop("$defs")
                params = resolve_refs(params, defs)
            elif "$ref" in params:
                # Top-level $ref — resolve with empty defs (best effort)
                params = resolve_refs(params, {})
            f["parameters"] = params
            t["function"] = f
        fixed.append(t)
    return fixed


def _tool_name(tool):
    """Best-effort tool name for prioritization (empty string if unknown)."""
    if isinstance(tool, dict):
        f = tool.get("function")
        if isinstance(f, dict):
            return f.get("name") or ""
    return ""


def cap_tools(tools, limit=None):
    """Cap the tool list to Poe's limit, preserving built-in tools first.

    Poe rejects >~216 tools. When over the limit we keep every non-MCP
    (built-in Claude Code) tool, then fill the remaining slots with MCP tools
    (`mcp__…`) in their original order. Order among kept tools is preserved.
    Returns (capped_tools, dropped_count).
    """
    if limit is None:
        limit = POE_MAX_TOOLS
    if not isinstance(tools, list) or limit <= 0 or len(tools) <= limit:
        return tools, 0
    builtin = [t for t in tools if not _tool_name(t).startswith("mcp__")]
    mcp = [t for t in tools if _tool_name(t).startswith("mcp__")]
    if len(builtin) >= limit:
        kept = builtin[:limit]
    else:
        kept = builtin + mcp[: limit - len(builtin)]
    return kept, len(tools) - len(kept)


def strip_cache_control(obj):
    """Recursively remove cache_control from nested objects."""
    if isinstance(obj, dict):
        return {k: strip_cache_control(v) for k, v in obj.items() if k != "cache_control"}
    if isinstance(obj, list):
        return [strip_cache_control(item) for item in obj]
    return obj


def fix_request(body):
    """Apply all fixes to request body."""
    # Fix tools (inject missing `parameters`, resolve $ref) then cap the count.
    if "tools" in body:
        body["tools"] = fix_tools(body["tools"])
        body["tools"], dropped = cap_tools(body["tools"])
        if dropped:
            print(f"poe_proxy: capped tools to {POE_MAX_TOOLS} "
                  f"(dropped {dropped} overflow MCP tools to stay under Poe's limit)",
                  file=sys.stderr)
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
                    try:
                        resp_body = gzip.decompress(resp_body)
                    except Exception:
                        pass  # corrupt/incomplete gzip — forward the raw body as-is
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
