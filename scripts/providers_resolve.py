#!/usr/bin/env python3
r"""providers_resolve.py — the dynamic brain of claude-providers.

Given the set of API-key variable NAMES the user has (never values), the
cached models.dev catalog, and two small editable config files, resolve each
LLM key into a concrete provider record: alias name, base URL, transport,
strong + fast model. Nothing about providers/models is hardcoded — every value
is derived from models.dev data, with `key-aliases.json` (name normalization)
and `overrides.json` (manual pins) as the only human inputs.

This module is pure and offline: it reads the models.dev cache from disk, it
does not fetch. The bash wrapper (claude-providers.sh) handles fetching/caching
and consumes this resolver's JSON output.

Usage:
  providers_resolve.py \
    --models-dev PATH \            # cached models.dev api.json
    --keys "A_API_KEY,B_API_KEY" \ # present key var NAMES (comma-sep)
    [--key-aliases PATH] [--overrides PATH] \
    [--only PROVIDER_ID]           # restrict output to one provider

Output: JSON array of records on stdout. Each record:
  {key_var, classification, provider_id, alias, base_url, transport,
   strong_model, fast_model, status, reason}
status ∈ {resolved, unmapped, skipped}.
"""
import argparse
import json
import re
import sys

# --- classification of key variable NAMES (not values) --------------------
# VCS/infra keys are never turned into provider aliases. These patterns are
# intentionally conservative and live here (not models.dev) because "is this
# key a model backend or a git token" is a host-policy decision, not catalog
# data.
VCS_PATTERNS = (
    re.compile(r"^GITHUB(_|$)"), re.compile(r"^GITLAB_"),
    re.compile(r"^GITFLIC_"), re.compile(r"^GITVERSE_"),
)
INFRA_PATTERNS = (
    # FIRE?BASE matches both the correct "FIREBASE" and the keys-file typo
    # "FIRBASE". (The earlier ^FIR?BASE made the E optional in the wrong place
    # and failed to match a correctly-spelled FIREBASE_API_KEY.)
    re.compile(r"^FIRE?BASE"), re.compile(r"^CLOUDFLARE"),
    re.compile(r"^MODAL"),
)
# GITHUB_MODELS_* is an LLM backend despite the GITHUB prefix — exempt it.
VCS_EXEMPT = (re.compile(r"^GITHUB_MODELS"),)


def classify(key_var):
    for p in VCS_EXEMPT:
        if p.search(key_var):
            return "llm"
    for p in VCS_PATTERNS:
        if p.search(key_var):
            return "vcs"
    for p in INFRA_PATTERNS:
        if p.search(key_var):
            return "infra"
    return "llm"


def find_provider_by_env(catalog, key_var):
    """Match a key var name against each provider's models.dev `env` array."""
    for pid, p in catalog.items():
        env = p.get("env") or []
        if key_var in env:
            return pid
    return None


def transport_for(provider):
    """native iff the provider speaks the Anthropic API natively."""
    npm = (provider.get("npm") or "").lower()
    api = (provider.get("api") or "").lower()
    if npm.endswith("anthropic") or api.rstrip("/").endswith("/anthropic"):
        return "native"
    return "router"


def _num(x):
    return x if isinstance(x, (int, float)) else None


def select_models(provider):
    """Pick (strong, fast) model IDs from models.dev metadata.

    strong: reasoning first, then newest release_date, then largest context,
            tie-break highest output cost (proxy for flagship).
    fast:   lowest input cost among tool-call-capable models (else any).
    Returns (strong_id, fast_id) — either may be None if no models listed.
    """
    models = provider.get("models") or {}
    items = list(models.values())
    if not items:
        return None, None

    def strong_key(m):
        cost = m.get("cost") or {}
        limit = m.get("limit") or {}
        return (
            1 if m.get("reasoning") else 0,
            m.get("release_date") or "",
            _num(limit.get("context")) or 0,
            _num(cost.get("output")) or 0,
        )

    strong = max(items, key=strong_key)

    tool_models = [m for m in items if m.get("tool_call")] or items

    def fast_key(m):
        cost = m.get("cost") or {}
        limit = m.get("limit") or {}
        # lowest input cost, then smallest context; unknown cost sorts last.
        c = _num(cost.get("input"))
        return (
            c if c is not None else float("inf"),
            _num(limit.get("context")) or float("inf"),
        )

    fast = min(tool_models, key=fast_key)
    return strong.get("id"), fast.get("id")


def sanitize_alias(name):
    """Make a provider id into a valid shell alias (letter-led, [A-Za-z0-9_-])."""
    a = re.sub(r"[^A-Za-z0-9_-]", "-", name)
    a = re.sub(r"-+", "-", a).strip("-")
    if not a or not a[0].isalpha():
        a = "p-" + a
    return a


def resolve(catalog, present_keys, key_aliases, overrides, only=None):
    records = []
    for key_var in present_keys:
        cls = classify(key_var)
        rec = {
            "key_var": key_var, "classification": cls,
            "provider_id": None, "alias": None, "base_url": None,
            "transport": None, "strong_model": None, "fast_model": None,
            "status": "skipped", "reason": "",
        }
        if cls != "llm":
            rec["reason"] = f"classified {cls}; not a model backend"
            records.append(rec)
            continue

        pid = key_aliases.get(key_var) or find_provider_by_env(catalog, key_var)
        if not pid or pid not in catalog:
            rec["status"] = "unmapped"
            rec["reason"] = "no models.dev provider for this key var"
            rec["provider_id"] = pid
            records.append(rec)
            continue

        provider = catalog[pid]
        strong, fast = select_models(provider)
        rec.update({
            "provider_id": pid,
            "alias": sanitize_alias(pid),
            "base_url": provider.get("api"),
            "transport": transport_for(provider),
            "strong_model": strong,
            "fast_model": fast,
            "status": "resolved",
        })

        # overrides.json: per-provider manual pins (alias/base_url/transport/
        # strong_model/fast_model). This is how a user promotes e.g. deepseek
        # to a native /anthropic endpoint without any hardcoding in code.
        ov = overrides.get(pid) or {}
        for field in ("alias", "base_url", "transport", "strong_model", "fast_model"):
            if ov.get(field):
                rec[field] = ov[field]

        if not rec["strong_model"]:
            rec["status"] = "unmapped"
            rec["reason"] = "provider has no usable models in catalog"
        if rec["transport"] == "router" and not rec["base_url"]:
            # A router provider with no base URL can't be configured for ccr —
            # don't activate a broken alias; surface it for an override instead.
            rec["status"] = "unmapped"
            rec["reason"] = "router provider missing base_url (catalog api null)"

        records.append(rec)

    if only:
        records = [r for r in records if r.get("provider_id") == only]
    return records


def load_json(path, default):
    if not path:
        return default
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dev", required=True)
    ap.add_argument("--keys", default="")
    ap.add_argument("--key-aliases")
    ap.add_argument("--overrides")
    ap.add_argument("--only")
    args = ap.parse_args(argv)

    with open(args.models_dev) as f:
        catalog = json.load(f)
    present = [k.strip() for k in args.keys.split(",") if k.strip()]
    key_aliases = load_json(args.key_aliases, {})
    overrides = load_json(args.overrides, {})

    records = resolve(catalog, present, key_aliases, overrides, only=args.only)
    json.dump(records, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
