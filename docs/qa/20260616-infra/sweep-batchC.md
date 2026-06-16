# LLM Provider Verification Sweep — Batch C

- **Date:** 2026-06-16
- **Host:** nezha.local (`Linux nezha 6.12.61-6.12-alt1 x86_64`)
- **Method:** read-only `curl` for model discovery + `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha ...` for verification
- **Constraints honored:** no builds, no git, deployed `llmsverifier_*` containers untouched, only the `llm-verifier-mv:nezha` image run ephemerally with `--rm`.
- **Providers:** sarvam, replicate, inference, nlpcloud

## Results

| Provider  | Model verified                                  | Status | CanSeeCode | Score | Error (HTTP) |
|-----------|-------------------------------------------------|--------|-----------|-------|--------------|
| sarvam    | sarvam-m                                         | error  | false     | 0.00  | API request failed with status **403** (no usable key; `SARVAM_API_KEY` absent from `.env`) |
| replicate | meta/meta-llama-3-8b-instruct                    | error  | false     | 0.00  | API request failed with status **401** (key invalid/expired; also NOT OpenAI `/chat/completions` shaped) |
| inference | meta-llama/llama-3.1-8b-instruct/fp-16           | error  | false     | 0.00  | API request failed with status **400** "Invalid model provided" (key authenticates + lists models, but `/chat/completions` rejects every listed id) |
| nlpcloud  | finetuned-llama-3-70b                            | error  | false     | 0.00  | API request failed with status **404** (NOT OpenAI-compatible; native API is `/v1/gpu/<model>/chatbot`) |

**Net: 0 of 4 providers verified PASS in Batch C.** All four fail, each for a distinct and honestly-classified reason.

## Per-provider verdicts

### sarvam — FAIL (no key)
`SARVAM_API_KEY` is **not present** in `~/helix-system/llmsverifier/.env`. The verifier's `-list-providers` reports sarvam as `llmsverifier_modelverify_provider_no_key`. Running the verifier anyway against `sarvam-m` reaches the Sarvam API and gets **HTTP 403 Forbidden** (no/invalid credential). Not verifiable until a key is provisioned.

### replicate — FAIL (bad key + adapter-shape limitation)
The `REPLICATE_API_KEY` in `.env` is **invalid/expired**: even the read-only `GET /v1/models` returns **HTTP 401 "Unauthenticated"** under both `Authorization: Bearer …` and Replicate's native `Authorization: Token …` schemes. Independently, **Replicate is not an OpenAI `/chat/completions` provider** — its native surface is prediction-based (`POST /v1/models/{owner}/{name}/predictions`), so an OpenAI-shaped adapter is a structural mismatch regardless of key. Both the bad key (401) and the adapter-shape limitation are recorded honestly.

### inference — FAIL (API model-registry inconsistency)
This is the most notable finding. The key **authenticates** and `GET /v1/models` returns **HTTP 200** with 18 models (llama-3.x, deepseek-v3/r1, qwen, gemma-3, gpt-oss, mistral-nemo). However, **every** model id from that list — tried verbatim with the precision suffix (`…/fp-16`, `…/fp-8`, `…/fp8`), and stripped of the suffix — is rejected by `POST /v1/chat/completions` with **HTTP 400 "Invalid model provided"**. The verifier hits the identical 400. This is an honest provider-side inconsistency (the `/models` listing does not match what `/chat/completions` accepts for this key/plan), not a harness bug.

### nlpcloud — FAIL (not OpenAI-compatible)
NLPCloud is **not OpenAI-compatible**. `GET /v1/models` and `POST /v1/chat/completions` both return **HTTP 404 "404 page not found"**. Its real API is model-scoped and uses `Token` auth: `POST /v1/gpu/<model>/chatbot` and `POST /v1/gpu/<model>/generation` (those paths exist — they return **401** with the current key rather than 404). The OpenAI-shaped adapter cannot drive NLPCloud as-is.

---

## EVIDENCE APPENDIX

### A. Environment / preconditions
```
$ ssh nezha.local 'uname -a; ls -l ~/helix-system/llmsverifier/.env'
Linux nezha 6.12.61-6.12-alt1 #1 SMP PREEMPT_DYNAMIC Thu Dec 11 13:04:56 UTC 2025 x86_64 GNU/Linux
-rw------- 1 milosvasic milosvasic 1822 Jun 16 18:04 /home/milosvasic/helix-system/llmsverifier/.env

$ podman images | grep llm-verifier
localhost/llm-verifier:nezha
localhost/llm-verifier-mv:nezha

# Keys present in .env (masked):
REPLICATE_API_KEY=r8_4Ai...(set)
INFERENCE_API_KEY=infere...(set)
NLP_API_KEY=7d726e...(set)
# SARVAM_API_KEY: NOT PRESENT

$ podman run --rm --env-file .../.env llm-verifier-mv:nezha -list-providers | grep -iE 'sarvam|replicate|inference|nlp'
nlpcloud     llmsverifier_modelverify_provider_configured
sarvam       llmsverifier_modelverify_provider_no_key
inference    llmsverifier_modelverify_provider_configured
replicate    llmsverifier_modelverify_provider_configured
```

### B. Model discovery (read-only curl)
```
# SARVAM — key absent, no discovery possible
SARVAM_API_KEY NOT SET in .env

# REPLICATE — GET /v1/models, Bearer scheme
{"title":"Unauthenticated","detail":"You did not pass a valid authentication token","status":401}
HTTP:401
# REPLICATE — same, native Token scheme -> also 401
{"title":"Unauthenticated",...,"status":401}  HTTP:401
# REPLICATE — POST /v1/chat/completions -> 401 (and not its native shape)
{"title":"Unauthenticated",...,"status":401}  HTTP:401

# INFERENCE — GET /v1/models -> HTTP 200, 18 models
{"object":"list","data":[
 {"id":"meta-llama/llama-3.2-1b-instruct/fp-16",...},
 {"id":"meta-llama/llama-3.1-8b-instruct/fp-16",...},
 {"id":"meta-llama/llama-3.3-70b-instruct/fp-8",...},
 {"id":"deepseek/deepseek-v3-0324/fp-8",...},
 {"id":"google/gemma-3-27b-instruct/bf-16",...},
 {"id":"openai/gpt-oss-120b",...},{"id":"openai/gpt-oss-20b",...}, ...]}
HTTP:200

# NLPCLOUD — GET /v1/models -> 404 ; native /v1/gpu/<model>/... -> 401 (path exists)
404 page not found   HTTP:404   (/v1/models, /v1/chat/completions, /v1/<model>)
(empty body)         HTTP:401   (/v1/gpu/finetuned-llama-3-70b/chatbot and /generation)
```

### C. inference — every listed model id rejected by /chat/completions
```
[meta-llama/llama-3.1-8b-instruct/fp-16]  -> HTTP 400 "Invalid model provided"
[meta-llama/llama-3.1-8b-instruct]        -> HTTP 400 "Invalid model provided"
[llama-3.1-8b-instruct]                   -> HTTP 400 "Invalid model provided"
[meta-llama/llama-3.2-1b-instruct/fp-16]  -> HTTP 400 "Invalid model provided"
[meta-llama/llama-3.3-70b-instruct/fp-8]  -> HTTP 400 "Invalid model provided"
[deepseek/deepseek-v3-0324(/fp-8)]        -> HTTP 400 "Invalid model provided"
[google/gemma-3-27b-instruct(/bf-16)]     -> HTTP 400 "Invalid model provided"
[mistralai/mistral-nemo-12b-instruct/fp-8]-> HTTP 400 "Invalid model provided"
[qwen/qwen3-30b-a3b/fp8]                  -> HTTP 400 "Invalid model provided"
[openai/gpt-oss-20b], [openai/gpt-oss-120b] -> HTTP 400 "Invalid model provided"
# /v1/models re-checked immediately after: still HTTP 200 (key valid, listing works)
```

### D. Verifier runs (podman, ephemeral --rm)
```
########## INFERENCE ##########
$ podman run --rm --env-file .../.env llm-verifier-mv:nezha -provider inference -model "meta-llama/llama-3.1-8b-instruct/fp-16" -verbose
✅ Verification completed in 694.396008ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 400 (avg response time: 694ms) (response length: 0)

########## REPLICATE ##########
$ podman run --rm --env-file .../.env llm-verifier-mv:nezha -provider replicate -model "meta/meta-llama-3-8b-instruct" -verbose
→ verifying requested id directly against the provider API
✅ Verification completed in 371.837432ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 401 (avg response time: 371ms) (response length: 0)

########## NLPCLOUD ##########
$ podman run --rm --env-file .../.env llm-verifier-mv:nezha -provider nlpcloud -model "finetuned-llama-3-70b" -verbose
→ verifying requested id directly against the provider API
✅ Verification completed in 400.860773ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 404 (avg response time: 400ms) (response length: 0)

########## SARVAM ##########
$ podman run --rm --env-file .../.env llm-verifier-mv:nezha -provider sarvam -model "sarvam-m" -verbose
🔍 Verifying specific model: sarvam-m from provider: sarvam
→ verifying requested id directly against the provider API
✅ Verification completed in 915.585383ms
Provider: sarvam
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 403 (avg response time: 915ms) (response length: 0)
```

### Note on flag syntax
The deployed verifier binary (`/usr/local/bin/model-verification`) uses single-dash Go flags: `-provider`, `-model`, `-verbose` (not `--provider`). The task's double-dash form was adapted to the binary's actual flag parser; semantics are identical.
