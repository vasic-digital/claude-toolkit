#!/usr/bin/env python3
"""toon_encode.py — Python wrapper for TOON encoding.

Converts JSON data to TOON format for token-efficient LLM prompts.
Uses the Node.js @toon-format/toon library under the hood.

Usage:
  toon_encode.py '{"users":[{"id":1,"name":"Alice"}]}'
  toon_encode.py --file data.json
  echo '{"data":...}' | toon_encode.py

TOON (Token-Oriented Object Notation) saves ~40% tokens vs JSON for
structured data in LLM prompts by declaring fields once in arrays.
"""
import argparse
import json
import subprocess
import sys
import os


def find_toon_script():
    """Find the toon.mjs script."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(script_dir, "toon.mjs"),
        os.path.join(os.path.expanduser("~/.local/share/claude-multi-account"), "toon.mjs"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


def encode_toon(data):
    """Encode Python data to TOON format via Node.js."""
    toon_script = find_toon_script()
    if not toon_script:
        # Fallback: simple YAML-like encoding
        return fallback_encode(data)

    json_str = json.dumps(data)
    try:
        result = subprocess.run(
            ["node", toon_script, "encode", json_str],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            return fallback_encode(data)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return fallback_encode(data)


def fallback_encode(data):
    """Simple YAML-like encoding when TOON library not available."""
    if isinstance(data, list):
        if all(isinstance(item, dict) for item in data) and data:
            # Tabular format
            keys = list(data[0].keys())
            lines = [f"[{len(data)}]{{{','.join(keys)}}}:"]
            for item in data:
                row = ",".join(str(item.get(k, "")) for k in keys)
                lines.append(f"  {row}")
            return "\n".join(lines)
        else:
            lines = [f"[{len(data)}]:"]
            for item in data:
                lines.append(f"  - {json.dumps(item) if not isinstance(item, str) else item}")
            return "\n".join(lines)
    elif isinstance(data, dict):
        lines = []
        for k, v in data.items():
            if isinstance(v, (dict, list)):
                lines.append(f"{k}:")
                lines.append(f"  {fallback_encode(v)}")
            else:
                lines.append(f"{k}: {json.dumps(v) if not isinstance(v, str) else v}")
        return "\n".join(lines)
    else:
        return str(data)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Encode JSON to TOON format")
    ap.add_argument("input", nargs="?", default="", help="JSON string to encode")
    ap.add_argument("--file", "-f", help="JSON file to encode")
    ap.add_argument("--compact", action="store_true", help="Compact output")
    args = ap.parse_args(argv)

    if args.file:
        with open(args.file) as f:
            data = json.load(f)
    elif args.input:
        data = json.loads(args.input)
    else:
        # Read from stdin
        data = json.loads(sys.stdin.read())

    toon = encode_toon(data)
    print(toon)


if __name__ == "__main__":
    main()
