// poe.go — Poe API compatibility REQUEST transform (Go port of poe_proxy.py).
//
// Poe rejects Claude Code's outbound chat/completions body in two ways this
// transform repairs, then forwards everything else untouched:
//
//   - A tool whose `parameters` is missing, non-object, empty, or lacks a
//     `properties` key is rejected with a misleading
//     `400 Invalid 'tools': Field required`. fix ensures every tool carries a
//     parameters object WITH a properties key (and a type), and resolves any
//     `$ref`/`$defs` (Grok-4 and some backends reject them).
//   - Too many tool definitions (empirically >~216) trip the same misleading
//     400. cap drops only overflow `mcp__…` tools, keeping every built-in
//     Claude Code tool, down to POE_MAX_TOOLS (default 200).
//
// It also strips `cache_control` (an Anthropic-ism) from messages.
//
// This is a faithful port of poe_proxy.py's fix_request = fix_tools + cap_tools
// + strip_cache_control (plus resolve_refs / _tool_name). Every helper is poe*-
// prefixed to avoid collisions in this shared package.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// poe's outbound request is rewritten (see poeFix). Registered like every other
// provider so main.go needs no edit.
func init() { registerRequest("poe", poeFix) }

// poeMaxTools mirrors POE_MAX_TOOLS (default 200 — a safe margin under Poe's
// ~216 cutoff). Read at call time; a value that will not parse as a base-10 int
// (empty, garbage) falls back to 200, exactly like the python int()/except.
func poeMaxTools() int {
	v, ok := os.LookupEnv("POE_MAX_TOOLS")
	if !ok {
		return 200
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 200
	}
	return n
}

// poeShallowCopy copies a map's top level, mirroring python's dict(x) so a fix
// never mutates the caller's object.
func poeShallowCopy(m map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// poeResolveRefs recursively resolves `$ref` references against defs, mirroring
// resolve_refs. A dict whose `$ref` is a string pointing at `#/$defs/<name>` is
// replaced by that def (resolved); an unresolvable `$ref` (or a non-string one)
// is left as-is / recursed. A 64-deep guard stops circular refs.
func poeResolveRefs(obj interface{}, defs interface{}, depth int) interface{} {
	if depth > 64 {
		return obj
	}
	switch o := obj.(type) {
	case map[string]interface{}:
		if refRaw, ok := o["$ref"]; ok {
			// Only a *string* $ref short-circuits; a non-string one falls
			// through to whole-dict recursion (matches the python isinstance).
			if ref, ok := refRaw.(string); ok {
				if strings.HasPrefix(ref, "#/$defs/") {
					parts := strings.Split(ref, "/")
					name := parts[len(parts)-1]
					if defsMap, ok := defs.(map[string]interface{}); ok {
						if def, ok := defsMap[name]; ok {
							return poeResolveRefs(def, defs, depth+1)
						}
					}
				}
				return o // $ref present but not resolvable — return as-is
			}
		}
		out := make(map[string]interface{}, len(o))
		for k, v := range o {
			out[k] = poeResolveRefs(v, defs, depth+1)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(o))
		for i, item := range o {
			out[i] = poeResolveRefs(item, defs, depth+1)
		}
		return out
	default:
		return obj
	}
}

// poeFixParams enforces Poe's real requirement on a single tool's parameters:
// an object WITH a properties key (and a type), then resolves $ref/$defs.
// Mirrors the parameters block of fix_tools.
func poeFixParams(paramsRaw interface{}) interface{} {
	params, ok := paramsRaw.(map[string]interface{})
	// python: `if not isinstance(params, dict) or not params:` — missing,
	// non-object, or an *empty* object all collapse to the default schema.
	if !ok || len(params) == 0 {
		return map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
	}
	p := poeShallowCopy(params)
	if _, ok := p["properties"].(map[string]interface{}); !ok {
		p["properties"] = map[string]interface{}{}
	}
	if _, ok := p["type"]; !ok {
		p["type"] = "object"
	}
	if defsRaw, ok := p["$defs"]; ok {
		delete(p, "$defs")
		return poeResolveRefs(p, defsRaw, 0)
	}
	if _, ok := p["$ref"]; ok {
		// Top-level $ref — resolve with empty defs (best effort), matching python.
		return poeResolveRefs(p, map[string]interface{}{}, 0)
	}
	return p
}

// poeFixTools ensures every tool has a valid parameters field and resolves
// $ref. Non-list / empty input is returned unchanged; a non-object tool is
// dropped; a tool whose `function` is not an object is kept untouched.
// Mirrors fix_tools.
func poeFixTools(tools interface{}) interface{} {
	list, ok := tools.([]interface{})
	if !ok || len(list) == 0 {
		return tools
	}
	fixed := make([]interface{}, 0, len(list))
	for _, tool := range list {
		tm, ok := tool.(map[string]interface{})
		if !ok {
			continue // python: `if not isinstance(tool, dict): continue`
		}
		t := poeShallowCopy(tm)
		if fn, ok := t["function"].(map[string]interface{}); ok {
			f := poeShallowCopy(fn)
			f["parameters"] = poeFixParams(f["parameters"])
			t["function"] = f
		}
		fixed = append(fixed, t)
	}
	return fixed
}

// poeToolName is the best-effort tool name used for cap prioritization, "" if
// unknown. Mirrors _tool_name.
func poeToolName(tool interface{}) string {
	tm, ok := tool.(map[string]interface{})
	if !ok {
		return ""
	}
	fn, ok := tm["function"].(map[string]interface{})
	if !ok {
		return ""
	}
	name, ok := fn["name"].(string)
	if !ok {
		return ""
	}
	return name
}

// poeCapTools caps the tool list to limit, preserving EVERY built-in (non-mcp)
// tool first, then filling remaining slots with `mcp__…` tools in original
// order. Returns (capped, dropped). Mirrors cap_tools.
func poeCapTools(tools interface{}, limit int) (interface{}, int) {
	list, ok := tools.([]interface{})
	if !ok || limit <= 0 || len(list) <= limit {
		return tools, 0
	}
	builtin := make([]interface{}, 0, len(list))
	mcp := make([]interface{}, 0, len(list))
	for _, t := range list {
		if strings.HasPrefix(poeToolName(t), "mcp__") {
			mcp = append(mcp, t)
		} else {
			builtin = append(builtin, t)
		}
	}
	var kept []interface{}
	if len(builtin) >= limit {
		kept = builtin[:limit]
	} else {
		kept = append(builtin, mcp[:limit-len(builtin)]...)
	}
	return kept, len(list) - len(kept)
}

// poeStripCacheControl recursively removes every `cache_control` key from
// nested objects. Mirrors strip_cache_control.
func poeStripCacheControl(obj interface{}) interface{} {
	switch o := obj.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(o))
		for k, v := range o {
			if k == "cache_control" {
				continue
			}
			out[k] = poeStripCacheControl(v)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(o))
		for i, item := range o {
			out[i] = poeStripCacheControl(item)
		}
		return out
	default:
		return obj
	}
}

// poeFix applies every fix to the request body: fix each tool's parameters +
// resolve $ref, cap the tool count, and strip cache_control from messages.
// Equivalent to fix_request(body).
func poeFix(body map[string]interface{}) map[string]interface{} {
	if _, ok := body["tools"]; ok {
		body["tools"] = poeFixTools(body["tools"])
		limit := poeMaxTools()
		capped, dropped := poeCapTools(body["tools"], limit)
		body["tools"] = capped
		if dropped > 0 {
			fmt.Fprintf(os.Stderr,
				"poe_proxy: capped tools to %d (dropped %d overflow MCP tools to stay under Poe's limit)\n",
				limit, dropped)
		}
	}
	if _, ok := body["messages"]; ok {
		body["messages"] = poeStripCacheControl(body["messages"])
	}
	return body
}
