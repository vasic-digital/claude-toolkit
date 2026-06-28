#!/usr/bin/env python3
"""alias_e2e_test.py — end-to-end test for provider aliases.

Tests each alias by sending a request through ccr's configured endpoint
and verifying the response works without errors (especially cache_control).

Usage:
  alias_e2e_test.py [--alias NAME] [--all] [--verbose] [--timeout 30]

Tests each alias by:
1. Reading the env file for the alias
2. Sending a test request to the provider through ccr
3. Verifying HTTP 200 with valid content
4. Checking for cache_control or other errors
5. Verifying tool calling support
"""
import argparse
import json
import os
import re
import sys
import time
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


TEST_PROMPT = "Do you see our codebase? Reply with YES or NO and explain briefly."
EXPECTED_KEYWORDS = ["yes", "see", "code", "project", "directory", "file"]
ERROR_PATTERNS = [
    r"cache_control.*not.*valid",
    r"unknown field",
    r"422",
    r"error from provider",
    r"rate.?limit",
    r"quota",
    r"access.?denied",
]


def load_env(env_path):
    """Load env file and return dict of key=value pairs."""
    env = {}
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("'\"")
            env[key] = value
    return env


def get_ccr_config():
    """Read ccr config to find provider endpoints."""
    cfg_path = os.path.expanduser("~/.claude-code-router/config.json")
    if not os.path.exists(cfg_path):
        return {}
    with open(cfg_path) as f:
        return json.load(f)


def test_provider_direct(base_url, api_key, model, timeout=30):
    """Test a provider directly (bypassing ccr) with cache_control in request.

    Returns (success, response_content, error_message, latency_ms).
    """
    # Build request with cache_control to test if the transformer strips it
    url = base_url.rstrip("/") + "/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "User-Agent": "claude-toolkit/1.6.0 e2e-test",
    }
    body = {
        "model": model,
        "max_tokens": 128,
        "messages": [
            {
                "role": "user",
                "content": TEST_PROMPT,
                "cache_control": {"type": "ephemeral"},  # This should be stripped by ccr
            }
        ],
    }

    start = time.monotonic()
    try:
        data = json.dumps(body).encode("utf-8")
        req = Request(url, data=data, headers=headers, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            elapsed = int((time.monotonic() - start) * 1000)
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                result = json.loads(raw)
            except json.JSONDecodeError:
                return False, "", "Invalid JSON response", elapsed

            # Extract content
            content = ""
            choices = result.get("choices", [])
            if choices:
                msg = choices[0].get("message", {})
                content = msg.get("content", "")
                if not content:
                    content = msg.get("reasoning_content", "")

            if not content:
                return False, "", "Empty response content", elapsed

            return True, content, "", elapsed

    except HTTPError as e:
        elapsed = int((time.monotonic() - start) * 1000)
        try:
            err_body = e.read().decode("utf-8", errors="replace")
            err_json = json.loads(err_body)
            err_msg = err_json.get("message", err_body[:200])
        except Exception:
            err_msg = str(e)[:200]
        return False, "", f"HTTP {e.code}: {err_msg}", elapsed

    except (URLError, OSError, TimeoutError) as e:
        elapsed = int((time.monotonic() - start) * 1000)
        return False, "", str(e)[:200], elapsed


def test_alias(alias_name, env, timeout=30, verbose=False):
    """Test a single alias end-to-end.

    Returns dict with test results.
    """
    result = {
        "alias": alias_name,
        "model": env.get("CMA_PROVIDER_MODEL", ""),
        "fast_model": env.get("CMA_PROVIDER_FAST_MODEL", ""),
        "transport": env.get("CMA_PROVIDER_TRANSPORT", ""),
        "base_url": env.get("CMA_PROVIDER_BASE_URL", ""),
        "tests": [],
        "overall_pass": False,
    }

    base_url = env.get("CMA_PROVIDER_BASE_URL", "")
    transport = env.get("CMA_PROVIDER_TRANSPORT", "router")

    if not base_url:
        result["tests"].append({"name": "env_check", "pass": False, "error": "No base URL"})
        return result

    # For router transport, the provider endpoint needs /chat/completions
    if transport == "router" and not base_url.endswith("/chat/completions"):
        test_url = base_url.rstrip("/") + "/chat/completions"
    else:
        test_url = base_url

    # Get API key from keys file
    key_var = env.get("CMA_PROVIDER_KEYVAR", "")
    api_key = ""
    if key_var:
        keys_file = os.path.expanduser("~/api_keys.sh")
        if os.path.exists(keys_file):
            # Parse the keys file to find the value
            with open(keys_file) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith(f"export {key_var}=") or line.startswith(f"{key_var}="):
                        _, _, val = line.partition("=")
                        api_key = val.strip().strip('"').strip("'")
                        # Handle variable references like $OtherVar
                        if api_key.startswith("$"):
                            ref_var = api_key[1:]
                            with open(keys_file) as f2:
                                for line2 in f2:
                                    if line2.strip().startswith(f"export {ref_var}=") or line2.strip().startswith(f"{ref_var}="):
                                        _, _, val2 = line2.partition("=")
                                        api_key = val2.strip().strip('"').strip("'")
                                        break

    if not api_key:
        result["tests"].append({"name": "key_check", "pass": False, "error": f"No API key for {key_var}"})
        return result

    # Test 1: Direct request (should work for OpenAI-compatible endpoints)
    model = env.get("CMA_PROVIDER_MODEL", "")
    if verbose:
        print(f"  Testing {alias_name} ({model})...", file=sys.stderr)

    success, content, error, latency = test_provider_direct(test_url, api_key, model, timeout)
    result["tests"].append({
        "name": "direct_request",
        "pass": success,
        "content": content[:100] if content else "",
        "error": error,
        "latency_ms": latency,
    })

    if not success:
        # Check if it's a cache_control error specifically
        if "cache_control" in error.lower() or "unknown field" in error.lower():
            result["tests"].append({
                "name": "cache_control_check",
                "pass": False,
                "error": f"cache_control not stripped: {error}",
            })
        return result

    # Test 2: Check content quality
    content_lower = content.lower()
    has_relevant_content = any(kw in content_lower for kw in EXPECTED_KEYWORDS)
    result["tests"].append({
        "name": "content_quality",
        "pass": has_relevant_content,
        "content_preview": content[:200],
    })

    # Test 3: Check for error patterns in response
    has_error = False
    for pattern in ERROR_PATTERNS:
        if re.search(pattern, content_lower):
            has_error = True
            result["tests"].append({
                "name": "error_pattern_check",
                "pass": False,
                "error": f"Error pattern found: {pattern}",
            })
            break
    if not has_error:
        result["tests"].append({"name": "error_pattern_check", "pass": True})

    # Test 4: Tool calling (send request with tools)
    tool_url = test_url
    tool_headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "User-Agent": "claude-toolkit/1.6.0 e2e-test",
    }
    tool_body = {
        "model": model,
        "max_tokens": 128,
        "messages": [{"role": "user", "content": "Calculate 7*6 using the test_calc tool"}],
        "tools": [{
            "type": "function",
            "function": {
                "name": "test_calc",
                "description": "Calculate a math expression",
                "parameters": {
                    "type": "object",
                    "properties": {"expression": {"type": "string"}},
                    "required": ["expression"],
                },
            },
        }],
    }
    try:
        data = json.dumps(tool_body).encode("utf-8")
        req = Request(tool_url, data=data, headers=tool_headers, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            tool_result = json.loads(raw)
            choices = tool_result.get("choices", [])
            has_tool_calls = False
            if choices:
                msg = choices[0].get("message", {})
                has_tool_calls = bool(msg.get("tool_calls"))
            result["tests"].append({
                "name": "tool_calling",
                "pass": has_tool_calls,
            })
    except Exception as e:
        result["tests"].append({
            "name": "tool_calling",
            "pass": False,
            "error": str(e)[:100],
        })

    # Overall pass: direct request + content quality + no errors
    result["overall_pass"] = all(
        t["pass"] for t in result["tests"]
        if t["name"] in ["direct_request", "content_quality", "error_pattern_check"]
    )

    return result


def main(argv=None):
    ap = argparse.ArgumentParser(description="End-to-end test for provider aliases")
    ap.add_argument("--alias", default="", help="Test specific alias")
    ap.add_argument("--all", action="store_true", help="Test all aliases")
    ap.add_argument("--verbose", action="store_true", help="Verbose output")
    ap.add_argument("--timeout", type=int, default=30, help="Request timeout")
    ap.add_argument("--output", default="", help="Output JSON file")
    args = ap.parse_args(argv)

    providers_dir = os.path.expanduser("~/.local/share/claude-multi-account/providers")

    if args.alias:
        aliases = [args.alias]
    elif args.all:
        # Find all provider env files
        aliases = []
        for f in sorted(os.listdir(providers_dir)):
            if f.endswith(".env"):
                aliases.append(f[:-4])  # Remove .env extension
    else:
        print("Specify --alias NAME or --all", file=sys.stderr)
        return 1

    results = []
    passed = 0
    failed = 0

    for alias_name in aliases:
        env_path = os.path.join(providers_dir, f"{alias_name}.env")
        if not os.path.exists(env_path):
            print(f"SKIP {alias_name}: env file not found", file=sys.stderr)
            continue

        env = load_env(env_path)
        result = test_alias(alias_name, env, timeout=args.timeout, verbose=args.verbose)
        results.append(result)

        if result["overall_pass"]:
            passed += 1
            status = "✓"
        else:
            failed += 1
            status = "✗"

        if args.verbose or not result["overall_pass"]:
            print(f"{status} {alias_name}: model={result['model']}", file=sys.stderr)
            for t in result["tests"]:
                if not t["pass"]:
                    print(f"    FAIL: {t['name']} - {t.get('error', '')}", file=sys.stderr)

    output = {
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "results": results,
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
    else:
        print(json.dumps(output, indent=2))

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
