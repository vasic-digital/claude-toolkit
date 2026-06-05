#!/usr/bin/env python3
"""opencode_sync.py — engine behind claude-opencode-sync.sh.

Scans a Claude Code plugin cache and produces an OpenCode config that exposes
every plugin's Skills, MCP servers, and the user CLAUDE.md instructions.

Driven entirely by environment variables (see claude-opencode-sync.sh):
  OC_CONFIG, OC_PLUGINS_DIR, OC_SHARED_CLAUDE_MD, OC_ALLOWLIST,
  OC_EXTRA_SKILL_DIRS, OC_AVAILABLE_RUNTIMES, OC_ENABLE_ALL,
  OC_ENABLE_ALL_LOCAL, OC_OUT, OC_STATS

Writes the merged config to OC_OUT and a stats JSON blob to OC_STATS.
Pure stdlib; no third-party deps. Deterministic (stable sort order) so the
output diffs cleanly and the test suite can assert on it.
"""
import os
import re
import json


def env(name, default=""):
    return os.environ.get(name, default)


def latest_version_dir(plugin_dir):
    """Return the newest version subdir of a plugin, or None.

    Plugins live at <cache>/<plugin>/<version>/. Sorting lexicographically
    biases toward the highest semver and keeps a stable, reproducible choice
    when several versions coexist ('unknown' sorts after digits)."""
    try:
        subs = [s for s in os.listdir(plugin_dir)
                if os.path.isdir(os.path.join(plugin_dir, s))]
    except OSError:
        return None
    return sorted(subs)[-1] if subs else None


def sanitize(name):
    """OpenCode MCP keys must be filename-safe identifiers."""
    n = re.sub(r"[^A-Za-z0-9_-]", "-", name)
    return re.sub(r"-+", "-", n).strip("-")


def expand_plugin_root(value, base):
    return value.replace("${CLAUDE_PLUGIN_ROOT}", base)


def has_unresolved_placeholder(env_map):
    """True if any env value still references an unresolved ${VAR} secret."""
    return any(isinstance(v, str) and "${" in v for v in env_map.values())


def parse_allowlist(raw):
    items = set()
    for tok in raw.replace("\n", " ").split():
        tok = tok.strip()
        if tok:
            items.add(tok)
    return items


def extract_servers(doc):
    """Pull the {name: cfg} server map out of a .mcp.json document.

    Claude plugins use two shapes: the wrapped form
    {"mcpServers": {name: cfg}} (also seen as "mcp") and the bare form
    {name: cfg} with no wrapper. Detect the bare form by checking that every
    value looks like a server config (has command/url/type)."""
    if isinstance(doc.get("mcpServers"), dict):
        return doc["mcpServers"]
    if isinstance(doc.get("mcp"), dict):
        return doc["mcp"]
    if doc and all(
        isinstance(v, dict) and ("command" in v or "url" in v or "type" in v)
        for v in doc.values()
    ):
        return doc
    return {}


def scan(plugins_dir):
    """Walk the plugin cache once, returning (skill_dirs, mcp_servers).

    skill_dirs: list of absolute '<plugin>/<ver>/skills' paths that hold at
                least one '<skill>/SKILL.md'.
    mcp_servers: list of dicts {plugin, name, cfg, base}.
    """
    skill_dirs, mcp_servers = [], []
    try:
        plugins = sorted(d for d in os.listdir(plugins_dir)
                         if not d.startswith(".")
                         and os.path.isdir(os.path.join(plugins_dir, d)))
    except OSError:
        return skill_dirs, mcp_servers

    for plugin in plugins:
        pdir = os.path.join(plugins_dir, plugin)
        ver = latest_version_dir(pdir)
        if not ver:
            continue
        base = os.path.join(pdir, ver)

        skills = os.path.join(base, "skills")
        if os.path.isdir(skills):
            has_skill = any(
                os.path.isfile(os.path.join(skills, d, "SKILL.md"))
                for d in os.listdir(skills)
                if os.path.isdir(os.path.join(skills, d))
            )
            if has_skill:
                skill_dirs.append(skills)

        mcp_file = os.path.join(base, ".mcp.json")
        if os.path.isfile(mcp_file):
            try:
                doc = json.load(open(mcp_file))
            except (ValueError, OSError):
                doc = {}
            servers = extract_servers(doc)
            for name, cfg in servers.items():
                mcp_servers.append(
                    {"plugin": plugin, "name": name, "cfg": cfg, "base": base})
    return skill_dirs, mcp_servers


def build_mcp(mcp_servers, allowlist, runtimes, enable_all, enable_all_local):
    """Translate Claude .mcp.json entries into OpenCode mcp config.

    Returns (mcp_dict, stats). Deduplicates servers with identical transport
    identity; resolves name collisions by qualifying with the plugin name.
    """
    out, identity = {}, {}
    stats = {"local": 0, "remote": 0, "skipped": 0,
             "dedup": 0, "renamed": 0, "enabled": 0}

    for entry in mcp_servers:
        plugin, name, cfg, base = (
            entry["plugin"], entry["name"], entry["cfg"], entry["base"])
        key = f"{plugin}/{name}"
        in_allow = key in allowlist

        if "command" in cfg:
            cmd = [expand_plugin_root(str(x), base)
                   for x in [cfg["command"]] + list(cfg.get("args", []))]
            env_map = {k: expand_plugin_root(str(v), base)
                       for k, v in (cfg.get("env") or {}).items()}
            runtime = cfg["command"]
            runtime_ok = runtime in runtimes
            needs_secret = has_unresolved_placeholder(env_map)
            enabled = bool(
                enable_all
                or (in_allow and runtime_ok and not needs_secret)
                or (enable_all_local and runtime_ok and not needs_secret))
            ocfg = {"type": "local", "command": cmd, "enabled": enabled}
            if env_map:
                ocfg["environment"] = env_map
            ident = ("local", tuple(cmd), tuple(sorted(env_map.items())))
            stats["local"] += 1
        elif "url" in cfg:
            url = expand_plugin_root(cfg["url"], base)
            enabled = bool(enable_all or in_allow)
            ocfg = {"type": "remote", "url": url, "enabled": enabled}
            hdr = cfg.get("headers")
            if hdr:
                ocfg["headers"] = {k: expand_plugin_root(str(v), base)
                                   for k, v in hdr.items()}
            ident = ("remote", url)
            stats["remote"] += 1
        else:
            stats["skipped"] += 1
            continue

        if ident in identity:                      # identical server already kept
            stats["dedup"] += 1
            if enabled and not out[identity[ident]].get("enabled"):
                out[identity[ident]]["enabled"] = True
            continue

        chosen = sanitize(name)
        if chosen in out:                          # name clash, different config
            chosen = sanitize(f"{plugin}-{name}")
            stats["renamed"] += 1
        out[chosen] = ocfg
        identity[ident] = chosen

    stats["enabled"] = sum(1 for v in out.values() if v.get("enabled"))
    return out, stats


def main():
    cfg_path = env("OC_CONFIG")
    plugins_dir = env("OC_PLUGINS_DIR")
    shared_md = env("OC_SHARED_CLAUDE_MD")
    allowlist = parse_allowlist(env("OC_ALLOWLIST"))
    runtimes = set(env("OC_AVAILABLE_RUNTIMES").split())
    extra_skills = [p for p in env("OC_EXTRA_SKILL_DIRS").split() if p]
    enable_all = env("OC_ENABLE_ALL") == "1"
    enable_all_local = env("OC_ENABLE_ALL_LOCAL") == "1"

    skill_dirs, mcp_servers = scan(plugins_dir)
    mcp_new, mcp_stats = build_mcp(
        mcp_servers, allowlist, runtimes, enable_all, enable_all_local)

    # Load existing config (preserve provider, existing mcp keys, etc.).
    cfg = {"$schema": "https://opencode.ai/config.json"}
    if os.path.isfile(cfg_path):
        try:
            cfg = json.load(open(cfg_path))
        except (ValueError, OSError):
            pass  # corrupt/empty: start fresh but keep going

    # MCP: add new keys without clobbering anything already configured.
    cfg.setdefault("mcp", {})
    for k, v in mcp_new.items():
        cfg["mcp"].setdefault(k, v)

    # Skills: union of existing + scanned + extras.
    skills = cfg.setdefault("skills", {})
    paths = set(skills.get("paths", []))
    paths.update(skill_dirs)
    paths.update(extra_skills)
    skills["paths"] = sorted(paths)

    # Instructions: include the shared CLAUDE.md if present.
    instr = set(cfg.get("instructions", []))
    if shared_md and os.path.exists(shared_md):
        instr.add(shared_md)
    if instr:
        cfg["instructions"] = sorted(instr)

    with open(env("OC_OUT"), "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")

    stats = {
        "skill_paths": len(cfg["skills"]["paths"]),
        "mcp_total": len(cfg["mcp"]),
        "mcp_enabled": sum(1 for v in cfg["mcp"].values() if v.get("enabled")),
        "mcp_local": mcp_stats["local"],
        "mcp_remote": mcp_stats["remote"],
        "mcp_dedup": mcp_stats["dedup"],
        "mcp_renamed": mcp_stats["renamed"],
        "instructions": len(cfg.get("instructions", [])),
    }
    with open(env("OC_STATS"), "w") as f:
        json.dump(stats, f)
        f.write("\n")


if __name__ == "__main__":
    main()
