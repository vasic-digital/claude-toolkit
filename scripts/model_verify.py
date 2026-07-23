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

        # Free/paid tier — the same classification providers_resolve.py uses, so
        # the --multi path and the single-alias path cannot disagree about which
        # models are free. Zero on BOTH sides is free; missing pricing is
        # "unknown", never assumed free.
        inp_cost = cost.get("input") if isinstance(cost, dict) else None
        out_cost = cost.get("output") if isinstance(cost, dict) else None
        if isinstance(inp_cost, (int, float)) and isinstance(out_cost, (int, float)):
            tier = "free" if (inp_cost == 0 and out_cost == 0) else "paid"
        elif str(mid).endswith(":free"):
            tier = "free"
        else:
            tier = "unknown"
        model["credit_tier"] = tier
        if tier == "free":
            model["score"] += WEIGHT_FREE
            model["capabilities"]["is_free"] = True

        # Filter: skip models with a KNOWN too-small context or output.
        # ATM-860 (2026-07-23): ctx==0 means the catalog has NO row / NO
        # context for this model — UNKNOWN, not "a window of zero". The live
        # completion probe above is the ground truth that the model serves;
        # demoting on an absent catalog datum was a §11.4.201 false refusal
        # (it zeroed helixagent's entire live-enumerated .gguf roster). An
        # unknown context simply earns no context score.
        if 0 < ctx < MIN_CONTEXT_WINDOW:
            model["verified"] = False
            model["failure_reason"] = f"Context window too small: {ctx} < {MIN_CONTEXT_WINDOW}"
        if out < MIN_OUTPUT_TOKENS and out > 0:
            model["verified"] = False
            model["failure_reason"] = f"Output tokens too small: {out} < {MIN_OUTPUT_TOKENS}"

    return verified_models


# --- Credit probing ----------------------------------------------------------
#
# The operator's rule ("paid model if we have credit, else strongest free")
# needs a per-provider answer to "does this account have usable credit?".
# There is no universal API for that. Two signals exist, in descending order of
# trustworthiness:
#
#   1. A documented balance/credits endpoint. Very few providers publish one;
#      the ones that do are listed in providers/credit-endpoints.json (data,
#      not code, so an operator can add one without touching Python).
#   2. Inference from a probe against a PAID model. A 402 Payment Required or a
#      documented "insufficient balance" body proves there is no credit; a 200
#      proves there is. Everything else (401 bad key, 429 rate limit, 5xx,
#      timeout) proves NOTHING and must stay "unknown".
#
# Anything we cannot establish is "unknown", which providers_resolve.py treats
# as no-credit. Guessing "available" would spend real money on a hunch.

CREDIT_CACHE_VERSION = 1          # must match providers_resolve.CREDIT_CACHE_VERSION
CREDIT_CACHE_TTL_SECONDS = 86400

CREDIT_AVAILABLE = "available"
CREDIT_EXHAUSTED = "exhausted"
CREDIT_UNKNOWN = "unknown"

# Body substrings that a provider uses to say "you are out of money". Matched
# case-insensitively against the error body of a non-2xx paid-model probe.
NO_CREDIT_PATTERNS = [
    r"insufficient[ _-]?(?:balance|credit|funds|quota)",
    r"payment[ _-]?required",
    r"out of (?:credit|credits|funds)",
    r"no (?:remaining )?credits?",
    r"credit[ _-]?(?:balance )?(?:is )?(?:too low|exhausted|depleted)",
    r"balance is not enough",
    r"exceeded your current quota",
    r"billing[ _-]?(?:hard[ _-]?)?limit",
    r"add (?:more )?(?:funds|credits)",
]


def redact(text, secret=""):
    """Scrub an API key (and anything key-shaped) out of text before it is
    logged, cached, or printed. Credit detail strings end up on disk, so this
    is the only way error bodies are ever allowed out of a probe."""
    if not text:
        return ""
    out = str(text)
    if secret and len(secret) >= 6:
        out = out.replace(secret, "[REDACTED]")
    # Generic key shapes (sk-..., hf_..., long bearer blobs) in case a provider
    # echoes the credential back in its error message.
    out = re.sub(r"\b(?:sk|pk|hf|gsk|xai|nvapi|csk)[-_][A-Za-z0-9\-_]{8,}", "[REDACTED]", out)
    out = re.sub(r"Bearer\s+[A-Za-z0-9\-_.]{8,}", "Bearer [REDACTED]", out)
    return out


def _walk(obj, path):
    """Walk a path of dict keys / list indices; None if any hop is absent.

    Integer path elements index into lists, which is how DeepSeek's
    `balance_infos[0].total_balance` is reached declaratively.
    """
    cur = obj
    for key in path:
        if isinstance(key, int):
            if not isinstance(cur, list) or not (-len(cur) <= key < len(cur)):
                return None
            cur = cur[key]
        else:
            if not isinstance(cur, dict) or key not in cur:
                return None
            cur = cur[key]
    return cur


def _dig(obj, path):
    """Numeric field at `path`, or None.

    Providers are inconsistent about types: OpenRouter sends JSON numbers,
    DeepSeek sends decimal STRINGS ("110.00"). Both are accepted; anything that
    is not a number in disguise (including booleans, which Python would
    otherwise happily treat as 0/1) returns None.
    """
    cur = _walk(obj, path)
    if isinstance(cur, bool) or cur is None:
        return None
    if isinstance(cur, (int, float)):
        return cur
    if isinstance(cur, str):
        try:
            return float(cur.strip())
        except ValueError:
            return None
    return None


def _dig_bool(obj, path):
    """Boolean field at `path`, or None. DeepSeek's `is_available` is a direct
    'do you have enough money' answer — better than any arithmetic we could do."""
    cur = _walk(obj, path)
    return cur if isinstance(cur, bool) else None


def probe_balance_endpoint(spec, api_key, timeout=TIMEOUT_DEFAULT):
    """Query a documented balance endpoint. Returns a credit record or None if
    the endpoint could not give a usable answer."""
    url = spec.get("url")
    if not url:
        return None
    auth = (spec.get("auth") or "bearer").lower()
    if auth == "bearer":
        headers = {"Authorization": f"Bearer {api_key}"}
    elif auth == "x-api-key":
        headers = {"x-api-key": api_key}
    else:
        headers = {(spec.get("auth_header") or "Authorization"): api_key}

    status, body = http_get_json(url, headers, timeout)
    if status != 200 or not isinstance(body, dict):
        return {
            "credit": CREDIT_UNKNOWN,
            "signal": "balance_endpoint",
            "detail": redact(
                "%s returned HTTP %s — balance undetermined" % (url, status), api_key),
        }

    # `signals` is an ORDERED list: providers expose several fields of differing
    # precision and the order encodes which to believe first. OpenRouter is the
    # motivating case — `limit_remaining` is exact but null on keys with no
    # spending cap, so it falls through to `is_free_tier`, which answers the
    # weaker question "has this account ever bought credits".
    for sig in (spec.get("signals") or []):
        path = sig.get("path") or []
        kind = (sig.get("type") or "balance").lower()
        label = ".".join(str(p) for p in path)

        if kind in ("boolean", "boolean_negated"):
            flag = _dig_bool(body, path)
            if flag is None:
                continue
            good = flag if kind == "boolean" else (not flag)
            return {
                "credit": CREDIT_AVAILABLE if good else CREDIT_EXHAUSTED,
                "signal": "balance_endpoint",
                "detail": "%s: %s=%s (%s)" % (url, label, flag,
                                              sig.get("desc") or kind),
            }

        granted = _dig(body, path)
        if granted is None:
            continue
        spent = _dig(body, sig.get("minus")) if sig.get("minus") else None
        remaining = granted - spent if spent is not None else granted
        return {
            "credit": CREDIT_AVAILABLE if remaining > 0 else CREDIT_EXHAUSTED,
            "signal": "balance_endpoint",
            "detail": "%s: %s remaining=%s (value=%s spent=%s)"
                      % (url, label, remaining, granted,
                         spent if spent is not None else "n/a"),
        }

    return {
        "credit": CREDIT_UNKNOWN,
        "signal": "balance_endpoint",
        "detail": "%s returned 200 but none of the %d configured signals were "
                  "present — schema changed?" % (url, len(spec.get("signals") or [])),
    }


def probe_paid_model(model_id, endpoint, api_key, timeout=TIMEOUT_DEFAULT):
    """Infer credit from a minimal completion against a PAID model.

    Only two outcomes are evidence: a 200 (the account paid for a token, so it
    has credit) and an explicit payment/balance rejection. Auth errors, rate
    limits and outages are deliberately 'unknown'.
    """
    url, headers, body = build_probe_request(model_id, endpoint, api_key)
    body["max_tokens"] = 1
    body["messages"] = [{"role": "user", "content": "hi"}]
    status, resp, _elapsed = http_post_json(url, body, headers, timeout)
    blob = redact(json.dumps(resp) if isinstance(resp, dict) else str(resp), api_key)
    low = blob.lower()

    if status == 200:
        # A 200 that actually carries an error body is not proof of anything.
        err = resp.get("error") if isinstance(resp, dict) else None
        if err:
            return {"credit": CREDIT_UNKNOWN, "signal": "paid_model_probe",
                    "detail": "HTTP 200 with error body on %s: %s" % (model_id, blob[:200])}
        return {"credit": CREDIT_AVAILABLE, "signal": "paid_model_probe",
                "detail": "paid model %s served a completion (HTTP 200)" % model_id}

    if status == 402:
        return {"credit": CREDIT_EXHAUSTED, "signal": "paid_model_probe",
                "detail": "HTTP 402 Payment Required on paid model %s" % model_id}

    if status in (400, 403, 429) and any(re.search(p, low) for p in NO_CREDIT_PATTERNS):
        return {"credit": CREDIT_EXHAUSTED, "signal": "paid_model_probe",
                "detail": "HTTP %d on paid model %s with a no-credit body: %s"
                          % (status, model_id, blob[:200])}

    reason = {
        0: "network failure — no signal",
        401: "HTTP 401 (bad/expired key) — says nothing about credit",
        404: "HTTP 404 (model not served here) — says nothing about credit",
        429: "HTTP 429 (rate limit) — transient, not a credit verdict",
    }.get(status, "HTTP %s — not a recognised credit signal" % status)
    if status >= 500:
        reason = "HTTP %d (provider outage) — transient, not a credit verdict" % status
    return {"credit": CREDIT_UNKNOWN, "signal": "paid_model_probe", "detail": reason}


def run_credit_probe(provider_id, endpoint, api_key, endpoint_spec=None,
                     paid_model="", timeout=TIMEOUT_DEFAULT):
    """Best available credit signal for one provider, in priority order."""
    if endpoint_spec:
        rec = probe_balance_endpoint(endpoint_spec, api_key, timeout)
        if rec and rec["credit"] != CREDIT_UNKNOWN:
            rec["doc"] = endpoint_spec.get("doc", "")
            rec["checked_at"] = datetime.now(timezone.utc).isoformat()
            return rec
        first = rec  # keep the failed-endpoint detail if the fallback is mute
    else:
        first = None

    if paid_model:
        rec = probe_paid_model(paid_model, endpoint, api_key, timeout)
        rec["checked_at"] = datetime.now(timezone.utc).isoformat()
        return rec

    if first:
        first["checked_at"] = datetime.now(timezone.utc).isoformat()
        return first
    return {
        "credit": CREDIT_UNKNOWN, "signal": "none",
        "detail": "no balance endpoint known for %s and no --paid-model given"
                  % provider_id,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


def load_credit_cache(path):
    """Read the credit cache, honouring the same version+TTL gate the resolver
    applies. A rejected cache comes back empty, never partially trusted."""
    if not path or not os.path.exists(path):
        return {"_cache_version": CREDIT_CACHE_VERSION, "providers": {}}
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"_cache_version": CREDIT_CACHE_VERSION, "providers": {}}
    if not isinstance(data, dict) or data.get("_cache_version") != CREDIT_CACHE_VERSION:
        return {"_cache_version": CREDIT_CACHE_VERSION, "providers": {}}
    ts = data.get("_cached_at")
    if not isinstance(ts, (int, float)) or time.time() - ts > CREDIT_CACHE_TTL_SECONDS:
        return {"_cache_version": CREDIT_CACHE_VERSION, "providers": {}}
    data.setdefault("providers", {})
    return data


def save_credit_cache(path, data):
    if not path:
        return
    data["_cache_version"] = CREDIT_CACHE_VERSION
    data["_cached_at"] = time.time()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


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

def rank_by_credit(results, credit_status):
    """Order verified-model records by the credit-tier rule, strongest first.

    Decisive, not a tie-break: with credit the strongest PAID model wins; without
    it (or when we simply don't know) the strongest FREE model must win even over
    a higher-scoring paid one, because we cannot pay for it. Sorts `results` in
    place (and returns it) so `--multi` emits the alias-choosing order.

    This is a module-level function ON PURPOSE: the ordering that actually decides
    which model becomes the alias must be reachable by a test that calls the real
    code, not a re-implementation of it.
    """
    if credit_status == "available":
        tier_rank = {"paid": 0, "unknown": 1, "free": 2}
    else:
        tier_rank = {"free": 0, "unknown": 1, "paid": 2}
    results.sort(key=lambda m: (tier_rank.get(m.get("credit_tier", "unknown"), 1),
                                -m["score"]))
    return results


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
    ap.add_argument("--credit-probe", action="store_true",
                    help="Probe account credit for --provider and write --credits-file")
    ap.add_argument("--credits-file", default="", help="Credit cache path")
    ap.add_argument("--credit-endpoints", default="",
                    help="providers/credit-endpoints.json (balance endpoint table)")
    ap.add_argument("--paid-model", default="",
                    help="A PAID model id, used to infer credit when no balance endpoint exists")
    ap.add_argument("--credit-status", default="unknown",
                    choices=["available", "exhausted", "unknown"],
                    help="Known credit status; ranks free models above paid when there is no credit")
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

    # --- credit-probe mode: answer "does this account have credit?" and exit.
    if args.credit_probe:
        table = {}
        if args.credit_endpoints and os.path.exists(args.credit_endpoints):
            try:
                with open(args.credit_endpoints) as f:
                    table = json.load(f)
            except (json.JSONDecodeError, OSError):
                table = {}
        spec = table.get(args.provider) if isinstance(table, dict) else None
        record = run_credit_probe(args.provider, args.endpoint, api_key,
                                  endpoint_spec=spec, paid_model=args.paid_model,
                                  timeout=args.timeout)
        cache = load_credit_cache(args.credits_file)
        cache["providers"][args.provider] = record
        save_credit_cache(args.credits_file, cache)
        # `record` is already redacted by the probe helpers.
        print(json.dumps({"provider_id": args.provider, **record}, indent=2))
        return 0

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

    # Sort by credit tier first, then score (see rank_by_credit).
    rank_by_credit(results, args.credit_status)

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
