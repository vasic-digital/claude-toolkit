#!/usr/bin/env python3
"""model_verify.py — comprehensive model verification & scoring engine.

Tests every model for a provider via HTTP probes, scores them on multiple
dimensions (existence, response quality, tool calling, reasoning, streaming,
latency, context window, cost), and outputs a sorted list of verified models.

Anti-bluff detection prevents false positives:
- HTTP 200 with error body
- Empty or boilerplate responses
- Models that claim capability but don't deliver
- Rate-limited responses misidentified as working

Usage:
  CMA_PROBE_KEY=<api_key> model_verify.py --provider <id> --endpoint <url> \
    [--models model1,model2,...] [--concurrency 5] [--timeout 30] \
    [--cache-file PATH] [--output PATH] [--no-cache]

  The API key is passed via the CMA_PROBE_KEY environment variable (not argv)
  so it never appears in `ps aux` or /proc.

Output: JSON with per-provider sorted list of {model_id, score, capabilities}.

Integrates with LLMsVerifier's scoring philosophy (5 components: speed,
efficiency, cost, capability, recency) but runs as a standalone Python script
since the Go binary may not be built.
"""
import argparse
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# --- Constants ---------------------------------------------------------------

PROBE_PROMPT = "Reply with exactly: VERIFY_OK"
PROBE_MAX_TOKENS = 128  # Reasoning models need more tokens for chain-of-thought + response
EXPECTED_CONTENT = "VERIFY_OK"
TIMEOUT_DEFAULT = 30
CONCURRENCY_DEFAULT = 5
CACHE_TTL_SECONDS = 86400  # 24 hours
CACHE_VERSION = 2  # bump when verification semantics change; older caches are ignored
MIN_CONTEXT_WINDOW = 8000
MIN_OUTPUT_TOKENS = 1000

# Known error patterns that indicate a model is NOT actually working
# even when HTTP 200 is returned (anti-bluff)
ERROR_PATTERNS = [
    r"i(?: am|'m) (?:unable|not able|sorry)",
    r"cannot (?:process|fulfill|complete)",
    r"error (?:processing|generating)",
    r"model (?:not |un)available",
    r"rate.?limit",
    r"quota (?:exceeded|reached)",
    r"invalid (?:model|request)",
    r"temperature.*(?:not |un)supported",
    r"this model (?:is |does )?(?:not |no longer )?(?:available|supported)",
    r"access.?denied",
    r"unauthorized",
    r"billing",
]

# --- Scoring weights (out of 100 total) -------------------------------------

WEIGHT_EXISTENCE = 25      # Model exists and returns valid response
WEIGHT_TOOL_CALL = 20      # Supports tool/function calling
WEIGHT_REASONING = 15      # Has reasoning/chain-of-thought
WEIGHT_CONTEXT = 15        # Context window size (log scale)
WEIGHT_STREAMING = 10      # SSE streaming support
WEIGHT_LATENCY = 10        # Response speed (inverse)
WEIGHT_FREE = 5            # Free tier bonus


# --- HTTP helpers ------------------------------------------------------------

def http_post_json(url, body, headers=None, timeout=TIMEOUT_DEFAULT):
    """POST JSON to URL, return (status_code, response_body_dict, elapsed_ms)."""
    hdrs = {
        "Content-Type": "application/json",
        "User-Agent": "claude-toolkit/1.6.0 model-verify",
    }
    if headers:
        hdrs.update(headers)
    data = json.dumps(body).encode("utf-8")
    req = Request(url, data=data, headers=hdrs, method="POST")
    start = time.monotonic()
    try:
        with urlopen(req, timeout=timeout) as resp:
            elapsed = int((time.monotonic() - start) * 1000)
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw), elapsed
            except json.JSONDecodeError:
                return resp.status, {"_raw": raw}, elapsed
    except HTTPError as e:
        elapsed = int((time.monotonic() - start) * 1000)
        try:
            body_text = e.read().decode("utf-8", errors="replace")
            body_json = json.loads(body_text)
        except Exception:
            body_json = {"_error": str(e), "_raw": body_text if 'body_text' in dir() else ""}
        return e.code, body_json, elapsed
    except (URLError, OSError, TimeoutError) as e:
        elapsed = int((time.monotonic() - start) * 1000)
        return 0, {"_error": str(e)}, elapsed


def http_get_json(url, headers=None, timeout=TIMEOUT_DEFAULT):
    """GET JSON from URL, return (status_code, response_body_dict)."""
    hdrs = headers or {}
    req = Request(url, headers=hdrs, method="GET")
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw)
    except HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8", errors="replace"))
        except Exception:
            return e.code, {}
    except (URLError, OSError, TimeoutError):
        return 0, {}


# --- Anti-bluff detection ----------------------------------------------------

def is_bluff_response(content, status_code, response_body):
    """Detect false-positive responses. Returns (is_bluff, reason)."""
    if status_code != 200:
        return False, ""  # Non-200 is honest failure, not a bluff

    # Check for error-in-200-body pattern
    if isinstance(response_body, dict):
        err = response_body.get("error", {})
        if isinstance(err, dict) and err.get("message"):
            return True, f"HTTP 200 with error body: {err['message']}"
        if isinstance(err, str) and len(err) > 5:
            return True, f"HTTP 200 with error string: {err}"

    if not content or not content.strip():
        return True, "Empty response content"

    content_lower = content.lower().strip()

    # Check for known error patterns
    for pattern in ERROR_PATTERNS:
        if re.search(pattern, content_lower):
            # Only flag if the ENTIRE response is the error (not just mentioning it)
            if len(content.strip()) < 200:
                return True, f"Error pattern matched: {pattern}"

    # Check for very short non-informative responses
    if len(content.strip()) < 3 and content.strip() != EXPECTED_CONTENT:
        return True, f"Response too short: '{content.strip()}'"

    return False, ""


# --- Model probing -----------------------------------------------------------

def normalize_endpoint_for_probe(endpoint):
    """Convert Anthropic-native endpoints to OpenAI-compatible for probing.

    Verification uses OpenAI-compatible format (/v1/chat/completions) which is
    the most widely supported. Providers with /anthropic endpoints typically
    also have /v1 endpoints.
    """
    # Replace /anthropic with /v1 for probing
    if "/anthropic" in endpoint and "/v1/" not in endpoint:
        endpoint = endpoint.replace("/anthropic", "/v1")
    return endpoint


def build_probe_request(model_id, endpoint, api_key, stream=False):
    """Build the HTTP probe request for a model."""
    # Normalize endpoint for probing
    endpoint = normalize_endpoint_for_probe(endpoint)

    # Determine API format from endpoint
    if "/v1/messages" in endpoint:
        # Anthropic format
        url = endpoint
        headers = {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        }
        body = {
            "model": model_id,
            "max_tokens": PROBE_MAX_TOKENS,
            "messages": [{"role": "user", "content": PROBE_PROMPT}],
        }
    elif "/v1/chat/completions" in endpoint:
        # OpenAI-compatible format
        url = endpoint
        headers = {"Authorization": f"Bearer {api_key}"}
        body = {
            "model": model_id,
            "max_tokens": PROBE_MAX_TOKENS,
            "messages": [{"role": "user", "content": PROBE_PROMPT}],
            "stream": stream,
        }
    else:
        # Default: OpenAI-compatible with /chat/completions appended
        url = endpoint.rstrip("/") + "/chat/completions"
        headers = {"Authorization": f"Bearer {api_key}"}
        body = {
            "model": model_id,
            "max_tokens": PROBE_MAX_TOKENS,
            "messages": [{"role": "user", "content": PROBE_PROMPT}],
            "stream": stream,
        }
    return url, headers, body


def extract_response_content(response_body, endpoint):
    """Extract text content from API response, handling multiple formats."""
    if not isinstance(response_body, dict):
        return ""

    # OpenAI-compatible format
    choices = response_body.get("choices", [])
    if choices:
        msg = choices[0].get("message", {})
        content = msg.get("content", "")
        if content:
            return content
        # Some models put content in text field
        content = choices[0].get("text", "")
        if content:
            return content

    # Anthropic format
    content_list = response_body.get("content", [])
    if isinstance(content_list, list):
        for block in content_list:
            if isinstance(block, dict) and block.get("type") == "text":
                return block.get("text", "")

    # Google format
    candidates = response_body.get("candidates", [])
    if candidates:
        parts = candidates[0].get("content", {}).get("parts", [])
        for part in parts:
            if "text" in part:
                return part["text"]

    return ""


def has_tool_call_support(response_body):
    """Check if response indicates tool calling support."""
    if not isinstance(response_body, dict):
        return False

    # Check for tool_calls in response
    choices = response_body.get("choices", [])
    if choices:
        msg = choices[0].get("message", {})
        if msg.get("tool_calls"):
            return True
        # Check finish_reason
        if choices[0].get("finish_reason") == "tool_calls":
            return True

    # Check for function_call (legacy format)
    if choices:
        msg = choices[0].get("message", {})
        if msg.get("function_call"):
            return True

    return False


def has_reasoning_support(response_body):
    """Check if response indicates reasoning/chain-of-thought support."""
    if not isinstance(response_body, dict):
        return False

    # Check for reasoning_content field
    choices = response_body.get("choices", [])
    if choices:
        msg = choices[0].get("message", {})
        if msg.get("reasoning_content"):
            return True
        if msg.get("thinking"):
            return True

    # Check for thinking blocks in Anthropic format
    content_list = response_body.get("content", [])
    if isinstance(content_list, list):
        for block in content_list:
            if isinstance(block, dict) and block.get("type") == "thinking":
                return True

    return False


def test_tool_calling(model_id, endpoint, api_key, timeout):
    """Test if a model supports tool calling by sending a tool request."""
    url, headers, body = build_probe_request(model_id, endpoint, api_key)
    body["tools"] = [{
        "type": "function",
        "function": {
            "name": "test_calc",
            "description": "Calculate a math expression",
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": {"type": "string", "description": "Math expression"}
                },
                "required": ["expression"]
            }
        }
    }]
    body["messages"] = [{"role": "user", "content": "Calculate 7*6 using the tool"}]
    body["max_tokens"] = 128

    status, resp, elapsed = http_post_json(url, body, headers, timeout)
    if status != 200:
        return False

    # Check for tool calls in response
    return has_tool_call_support(resp)


def test_streaming(model_id, endpoint, api_key, timeout):
    """Test if a model supports streaming (SSE)."""
    url, headers, body = build_probe_request(model_id, endpoint, api_key, stream=True)
    body["max_tokens"] = 16

    # For streaming, we just check if the request doesn't error out
    # Full SSE parsing would be more complex
    status, resp, elapsed = http_post_json(url, body, headers, timeout)
    if status != 200:
        return False

    # If we got a non-streaming response back, the model might still support
    # streaming but the endpoint returned JSON. Check for stream-related fields.
    if isinstance(resp, dict):
        # Some endpoints return the full response even with stream=true
        # Consider it streaming-capable if we got a valid response
        choices = resp.get("choices", [])
        if choices:
            return True

    return False


# --- Main verification logic -------------------------------------------------

def verify_model(model_id, provider_id, endpoint, api_key, timeout=TIMEOUT_DEFAULT):
    """Verify a single model and return its score and capabilities.

    Returns a dict with:
      model_id, score, capabilities, latency_ms, verified, failure_reason
    """
    result = {
        "model_id": model_id,
        "provider_id": provider_id,
        "score": 0,
        "capabilities": {
            "chat": False,
            "tool_call": False,
            "reasoning": False,
            "streaming": False,
            "context_window": 0,
            "output_tokens": 0,
        },
        "latency_ms": 0,
        "verified": False,
        "failure_reason": "",
        "tested_at": datetime.now(timezone.utc).isoformat(),
    }

    # Step 1: Basic probe — does the model exist and respond?
    url, headers, body = build_probe_request(model_id, endpoint, api_key)
    status, resp, elapsed = http_post_json(url, body, headers, timeout)
    result["latency_ms"] = elapsed

    if status == 0:
        result["failure_reason"] = f"Connection failed: {resp.get('_error', 'unknown')}"
        return result

    if status == 404:
        result["failure_reason"] = "Model not found (404)"
        return result

    if status == 429:
        result["failure_reason"] = "Rate limited (429)"
        return result

    if status >= 500:
        result["failure_reason"] = f"Server error ({status})"
        return result

    # Step 2: Extract content and check for bluff
    content = extract_response_content(resp, endpoint)
    is_bluff, bluff_reason = is_bluff_response(content, status, resp)

    if is_bluff:
        result["failure_reason"] = f"Anti-bluff: {bluff_reason}"
        return result

    if status != 200:
        result["failure_reason"] = f"HTTP {status}"
        return result

    # Anti-bluff sentinel: the probe demands an exact token. A 200 whose body
    # lacks it means the endpoint produced *a* reply, not one from the
    # requested model (proxy fallback, silent model swap, canned text).
    if EXPECTED_CONTENT not in content:
        result["failure_reason"] = "sentinel VERIFY_OK missing from response"
        return result

    # Step 3: Model is alive — calculate score
    score = 0

    # Existence + valid response (25 pts)
    score += WEIGHT_EXISTENCE
    result["capabilities"]["chat"] = True

    # Step 4: Test tool calling (20 pts). Claude Code is entirely tool-driven,
    # so tool support is a hard verification gate, not just a score component.
    tool_call_ok = False
    try:
        if test_tool_calling(model_id, endpoint, api_key, timeout):
            score += WEIGHT_TOOL_CALL
            result["capabilities"]["tool_call"] = True
            tool_call_ok = True
    except Exception:
        pass

    # Step 5: Check reasoning from initial response (15 pts)
    if has_reasoning_support(resp):
        score += WEIGHT_REASONING
        result["capabilities"]["reasoning"] = True

    # Step 6: Context window — use catalog data if available (15 pts)
    # This is filled in later from catalog data
    result["capabilities"]["context_window"] = 0  # placeholder

    # Step 7: Test streaming (10 pts)
    try:
        if test_streaming(model_id, endpoint, api_key, timeout):
            score += WEIGHT_STREAMING
            result["capabilities"]["streaming"] = True
    except Exception:
        pass

    # Step 8: Latency score (10 pts) — under 2s = full, under 5s = half
    if elapsed < 2000:
        score += WEIGHT_LATENCY
    elif elapsed < 5000:
        score += WEIGHT_LATENCY // 2

    result["score"] = score
    if not tool_call_ok:
        result["failure_reason"] = "tool calling unsupported (required by Claude Code)"
    else:
        result["verified"] = True
    return result


def enrich_from_catalog(verified_models, catalog_models):
    """Enrich verification results with catalog metadata (context window, cost, etc.)."""
    for model in verified_models:
        mid = model["model_id"]
        cat = catalog_models.get(mid, {})
        limit = cat.get("limit", {})
        cost = cat.get("cost", {})

        ctx = limit.get("context", 0)
        out = limit.get("output", 0)
        model["capabilities"]["context_window"] = ctx
        model["capabilities"]["output_tokens"] = out

        # Context window score (log scale, 15 pts)
        if ctx >= MIN_CONTEXT_WINDOW:
            import math
            ctx_score = min(WEIGHT_CONTEXT, int(WEIGHT_CONTEXT * math.log10(ctx / 1000) / math.log10(1000)))
            model["score"] += ctx_score

        # Free tier bonus (5 pts)
        inp_cost = cost.get("input", 999) if cost else 999
        if inp_cost == 0:
            model["score"] += WEIGHT_FREE
            model["capabilities"]["is_free"] = True

        # Filter: skip models with too-small context or output
        if ctx < MIN_CONTEXT_WINDOW:
            model["verified"] = False
            model["failure_reason"] = f"Context window too small: {ctx} < {MIN_CONTEXT_WINDOW}"
        if out < MIN_OUTPUT_TOKENS and out > 0:
            model["verified"] = False
            model["failure_reason"] = f"Output tokens too small: {out} < {MIN_OUTPUT_TOKENS}"

    return verified_models


# --- Cache -------------------------------------------------------------------

def load_cache(cache_file):
    """Load verification cache if valid."""
    if not cache_file or not os.path.exists(cache_file):
        return {}
    try:
        with open(cache_file) as f:
            data = json.load(f)
        # Version gate: caches written by older verification logic (e.g.
        # "verified" without a tool-calling check) must never be replayed.
        if data.get("_cache_version") != CACHE_VERSION:
            return {}
        # Check TTL
        cached_at = data.get("_cached_at", 0)
        if time.time() - cached_at > CACHE_TTL_SECONDS:
            return {}
        return data
    except (json.JSONDecodeError, OSError):
        return {}


def save_cache(cache_file, data):
    """Save verification cache."""
    if not cache_file:
        return
    data["_cached_at"] = time.time()
    data["_cache_version"] = CACHE_VERSION
    os.makedirs(os.path.dirname(cache_file) or ".", exist_ok=True)
    with open(cache_file, "w") as f:
        json.dump(data, f, indent=2)


# --- Main --------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="Verify and score all models for a provider")
    ap.add_argument("--provider", required=True, help="Provider ID")
    ap.add_argument("--endpoint", required=True, help="API base URL")
    ap.add_argument("--models", default="", help="Comma-separated model IDs (empty = all from catalog)")
    ap.add_argument("--catalog", default="", help="Path to models.dev cache JSON")
    ap.add_argument("--concurrency", type=int, default=CONCURRENCY_DEFAULT)
    ap.add_argument("--timeout", type=int, default=TIMEOUT_DEFAULT)
    ap.add_argument("--cache-file", default="", help="Verification cache file path")
    ap.add_argument("--output", default="", help="Output file path (default: stdout)")
    ap.add_argument("--no-cache", action="store_true", help="Skip cache")
    ap.add_argument("--verbose", action="store_true", help="Verbose output")
    args = ap.parse_args(argv)

    # Read API key from environment variable — never from argv (secrets must not
    # appear in /proc/<pid>/cmdline or `ps aux` output).
    api_key = os.environ.get("CMA_PROBE_KEY", "")
    if not api_key:
        print(
            "Error: CMA_PROBE_KEY environment variable is not set. "
            "Pass the API key via the environment, not via --key on argv.",
            file=sys.stderr,
        )
        return 1

    # Load catalog for model metadata
    catalog_models = {}
    if args.catalog and os.path.exists(args.catalog):
        with open(args.catalog) as f:
            catalog = json.load(f)
        provider_data = catalog.get(args.provider, {})
        catalog_models = provider_data.get("models", {})

    # Determine which models to test
    if args.models:
        model_ids = [m.strip() for m in args.models.split(",") if m.strip()]
    elif catalog_models:
        model_ids = list(catalog_models.keys())
    else:
        print("Error: no models specified and no catalog available", file=sys.stderr)
        return 1

    # Check cache
    cache = {}
    if not args.no_cache and args.cache_file:
        cache = load_cache(args.cache_file)
        provider_cache = cache.get(args.provider, {})
        if provider_cache:
            cached_models = provider_cache.get("models", [])
            cached_ids = {m["model_id"] for m in cached_models}
            uncached = [m for m in model_ids if m not in cached_ids]
            if not uncached:
                # All models cached
                result = provider_cache
                result["_from_cache"] = True
                output = json.dumps(result, indent=2)
                if args.output:
                    with open(args.output, "w") as f:
                        f.write(output)
                else:
                    print(output)
                return 0
            if args.verbose:
                print(f"Cache hit: {len(cached_ids)} models, {len(uncached)} to verify", file=sys.stderr)

    # Verify models in parallel
    if args.verbose:
        print(f"Verifying {len(model_ids)} models for {args.provider}...", file=sys.stderr)

    results = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {
            pool.submit(verify_model, mid, args.provider, args.endpoint, api_key, args.timeout): mid
            for mid in model_ids
        }
        for future in as_completed(futures):
            mid = futures[future]
            try:
                result = future.result()
                results.append(result)
                if args.verbose:
                    status = "✓" if result["verified"] else "✗"
                    print(f"  {status} {mid}: score={result['score']} ({result.get('failure_reason', 'ok')})", file=sys.stderr)
            except Exception as e:
                results.append({
                    "model_id": mid,
                    "provider_id": args.provider,
                    "score": 0,
                    "verified": False,
                    "failure_reason": f"Exception: {e}",
                    "tested_at": datetime.now(timezone.utc).isoformat(),
                })

    # Enrich from catalog
    results = enrich_from_catalog(results, catalog_models)

    # Sort by score descending
    results.sort(key=lambda m: m["score"], reverse=True)

    # Build output
    verified = [m for m in results if m["verified"]]
    failed = [m for m in results if not m["verified"]]

    output_data = {
        "provider_id": args.provider,
        "endpoint": args.endpoint,
        "verified_count": len(verified),
        "failed_count": len(failed),
        "total_tested": len(results),
        "tested_at": datetime.now(timezone.utc).isoformat(),
        "models": results,
    }

    # Update cache
    if not args.no_cache and args.cache_file:
        cache[args.provider] = output_data
        save_cache(args.cache_file, cache)

    output = json.dumps(output_data, indent=2)
    if args.output:
        os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
        with open(args.output, "w") as f:
            f.write(output)
    else:
        print(output)

    return 0


if __name__ == "__main__":
    sys.exit(main())
