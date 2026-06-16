# Heavy-test proof — real LLM verification on nezha

Captured runtime evidence (no bluff) that the deployed LLMsVerifier System on
nezha.local performs **real verification against live production LLM APIs**.

## Issue I (root cause) — verification request sent no Authorization header

`verification/code_verification.go:makeVerificationRequest` issued a bare
`GetHTTPClient().Post(...)` to `{baseURL}/chat/completions` **without attaching
the provider API key**, so every verification was unauthenticated → HTTP 401
for every provider, even with a valid configured key.

- Discriminator: `--list-providers` showed `deepseek` + `groq` as **configured**
  (key present in the client), yet verification returned 401 → bug is in the
  request builder, not the keys.
- Independent confirmation the keys are valid: direct `GET /models` returned
  **200** for both DeepSeek and Groq.

Fix: `patches/0001-verification-add-auth-header.patch` — build the request with
`http.NewRequestWithContext`, set `Authorization: Bearer <GetAPIKey()>` +
`Content-Type`, then `Do(req)`. The interface already exposed `GetAPIKey()`; it
simply wasn't used.

## RED → GREEN (real captured output)

### Before fix (RED)
```
Status: error
Can See Code: false
Error: Meaningful response verification failed: API request failed with status 401 (response length: 0)
```
(Both DeepSeek and Groq; direct /models = 200, so keys valid.)

### After fix (GREEN) — live API calls
```
=== DeepSeek (deepseek-chat) ===
Verification completed in 11.526s
Status: verified
Can See Code: true
Affirmative Response: true
Verification Score: 0.78
-> model_passed

=== Groq (llama-3.3-70b-versatile) ===
Verification completed in 4.026s
Status: verified
Can See Code: true
Affirmative Response: true
Verification Score: 0.98
-> model_passed
```

These are real end-to-end calls (11.5s / 4.0s real latency) to live DeepSeek and
Groq APIs through the deployed, cgo-built `llm-verifier-mv:nezha` image, reading
the keys from the mode-600 on-host `.env`.

## Upstreaming note

The fix is kept as a reviewable patch in this repo (and applied to the nezha
build) rather than drive-by-pushed to the LLMsVerifier `main`, which carries its
own test/Challenge/anti-bluff governance. Upstreaming it there (with that repo's
full suite) is the proper follow-up.
