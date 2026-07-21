// registry.go — provider transform registry.
//
// Each provider contributes at most one REQUEST transform (rewrite the outbound
// chat/completions body — e.g. poe/kimi tool-schema fixes) and/or is flagged as
// a RESPONSE-transform provider (helixagent's Hermes tool-call recovery, applied
// in ServeHTTP). Provider files register themselves in an init(), so a new
// provider is a self-contained file with no edit to main.go.
package main

import "strings"

// reqTransforms maps a canonical provider key to a request-body transform.
var reqTransforms = map[string]func(map[string]interface{}) map[string]interface{}{}

// respProviders is the set of provider keys whose RESPONSE is transformed.
var respProviders = map[string]bool{}

func registerRequest(key string, fn func(map[string]interface{}) map[string]interface{}) {
	reqTransforms[key] = fn
}

func registerResponse(key string) { respProviders[key] = true }

// providerKey resolves an alias id to a registered transform key, matching the
// launch wrapper's historic discovery order: exact id, then id up to its first
// digit (poe2 -> poe), then id up to its first '-' (kimi-for-coding -> kimi).
func providerKey(id string) string {
	if id == "" {
		return ""
	}
	cands := []string{id}
	if i := strings.IndexFunc(id, func(r rune) bool { return r >= '0' && r <= '9' }); i > 0 {
		cands = append(cands, id[:i])
	}
	if i := strings.IndexByte(id, '-'); i > 0 {
		cands = append(cands, id[:i])
	}
	for _, c := range cands {
		if respProviders[c] || reqTransforms[c] != nil {
			return c
		}
	}
	return ""
}

// hasTransform reports whether cma-proxy transforms requests or responses for id.
func hasTransform(id string) bool { return providerKey(id) != "" }
