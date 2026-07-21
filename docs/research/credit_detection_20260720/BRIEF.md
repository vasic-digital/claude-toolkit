# Credit / Balance / Quota Detection Across LLM API Providers — Research Brief

**Purpose.** The `claude-providers` toolkit must decide, per provider alias, whether that
provider's account can actually be billed, so it can apply the credit-aware model-tier policy
(credit ⇒ strongest paid model; no credit ⇒ strongest free model; unknown ⇒ treat as no credit).
This brief researches, per provider, whether a *documented* balance/credit/quota endpoint exists,
and the error-signal taxonomy that lets a live verification probe distinguish **no-credit** (⇒ free
model) from **rate-limited** (⇒ transient, don't demote) from **bad-key** (⇒ account broken).

**Scope note / honesty rule.** Every factual claim below carries a source URL + access date.
Where no documented endpoint or signal was found, this brief says exactly **"NONE DOCUMENTED"**
or **"no external solution found — original design needed"** rather than inventing one.

**Research date:** 2026-07-20. All access dates in citations are 2026-07-20 unless noted.

**Status:** IN PROGRESS — sections filled as research completes. See "Coverage tracker" at end.

---

## 1. Per-provider findings

Each entry records: **(A)** does a documented balance/credit/quota endpoint exist (exact path, auth,
response shape) or NOT; **(B)** error-signal taxonomy (bad key vs no-credit vs quota/rate); **(C)**
free-tier identification notes. Legend for the tier signal the selector needs:
🟢 = machine-readable balance endpoint exists · 🟡 = only indirect (key-info / rate headers) ·
🔴 = NONE DOCUMENTED, must rely on the live inference probe's error response.

---

### OpenRouter 🟢 (best-in-class — two documented endpoints)

**(A) Balance endpoints — TWO, both documented:**

1. **`GET https://openrouter.ai/api/v1/key`** — works with a *normal* API key (Bearer). Returns
   key info + credit status. Response shape (verified from official docs):
   ```json
   { "data": {
       "label": "string",
       "limit": 100.0,            // per-key credit cap, null if unlimited
       "limit_reset": null,       // reset schedule, null if never
       "limit_remaining": 74.25,  // credits remaining on this key
       "include_byok_in_limit": true,
       "usage": 25.75, "usage_daily": 1.0, "usage_weekly": 5.0, "usage_monthly": 20.0,
       "byok_usage": 0, "byok_usage_daily": 0, "byok_usage_weekly": 0, "byok_usage_monthly": 0,
       "is_free_tier": true       // true = account has NOT purchased paid credit
   } }
   ```
   The old `rate_limit` sub-object is **deprecated, safe to ignore**. `is_free_tier` and
   `limit_remaining` are the two fields the tier selector wants.
   Source: https://openrouter.ai/docs/api-reference/limits (accessed 2026-07-20).

2. **`GET https://openrouter.ai/api/v1/credits`** — requires a **management (provisioning) key**,
   NOT a normal inference key. Returns `{ "data": { "total_credits": 100.5, "total_usage": 25.75 } }`
   (balance = total_credits − total_usage). A normal key gets **403** "Only management keys can
   perform this operation." Fields `balance` / `remaining_balance` / `remaining_credits` do **not**
   exist — do not look for them.
   Source: https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits (accessed
   2026-07-20).

   **Toolkit recommendation:** use `/api/v1/key` (normal key, always available), read
   `is_free_tier` + `limit_remaining`; do **not** depend on `/api/v1/credits` since provider keys
   discovered from `~/api_keys.sh` are inference keys, not management keys.

**(B) Error taxonomy:**
| Condition | Status | Body / notes |
|---|---|---|
| Bad / invalid key | **401** | authentication error |
| No credit / insufficient balance | **402** | "the account or API key does not have enough credits." A negative-balance account may even see 402 on `:free` models. |
| Permission / moderation / provider ToS block | **403** | "permission, guardrail or moderation block" — NOT a credit signal; do not treat as no-credit |
| Rate / daily-quota exhausted | **429** | transient; includes free-model daily-cap exhaustion |

Sources: https://aicostplanner.com/openrouter-credits/ ; https://openrouter.ai/docs/api_reference/limits
(both accessed 2026-07-20).

**(C) Free-model identification:** free models carry the **`:free` suffix** in the model id
(e.g. `deepseek/deepseek-r1:free`). Free-tier rate limits (the "plan-gated" trap made explicit):
- **No credit ever purchased:** 20 req/min, **50 req/day** across all `:free` models.
- **After purchasing ≥ $10 credit at any point** (sticks even if balance later drops below $10):
  20 req/min, **1000 req/day.**
This is why `is_free_tier` matters: it is literally "has this account ever purchased paid credit",
which is the exact credit-vs-no-credit bit the tier policy needs.
Sources: https://openrouter.ai/docs/api_reference/limits ;
https://openrouter.zendesk.com/hc/en-us/articles/39501163636379 ; https://klymentiev.com/blog/openrouter-free-tier
(accessed 2026-07-20).

---

### DeepSeek 🟢 (documented balance endpoint)

**(A) Balance endpoint — documented:** **`GET https://api.deepseek.com/user/balance`** (Bearer
auth, same key as inference). Response shape (verified from official API reference):
```json
{
  "is_available": true,
  "balance_infos": [
    { "currency": "CNY", "total_balance": "110.00",
      "granted_balance": "10.00", "topped_up_balance": "100.00" }
  ]
}
```
- `is_available` (bool): **"Whether the user's balance is sufficient for API calls"** — this is a
  ready-made credit-vs-no-credit boolean, ideal for the tier selector.
- `currency`: `CNY` or `USD`. `total_balance = granted_balance + topped_up_balance`.
- Base URL `https://api.deepseek.com` (OpenAI format) or `.../anthropic` (Anthropic format).
Sources: https://api-docs.deepseek.com/api/get-user-balance ; https://api-docs.deepseek.com/quick_start/pricing
(accessed 2026-07-20).

**(B) Error taxonomy** (DeepSeek publishes an error-codes table):
| Condition | Status | Body / notes |
|---|---|---|
| Bad / invalid key | **401** | Authentication Fails — "wrong API key provided" |
| No credit / **Insufficient Balance** | **402** | `Payment Required` — "You have run out of balance." |
| Invalid request body | **400** | "Invalid request body format." |
| Invalid parameters | **422** | "Your request contains invalid parameters." |
| Rate limited | **429** | "You are sending requests too quickly." — transient |
| Server / overload | 500 / 503 | "Server encounters an issue" / "overloaded due to high traffic" — transient |
Source: https://api-docs.deepseek.com/quick_start/error_codes (verified 2026-07-20).

**(C) Free-tier:** DeepSeek has **no perpetual free tier** — it is pay-as-you-go with promotional
granted balance. `is_available:false` (or 402 Insufficient Balance) is the no-credit signal; there
is no "free model" to fall back to on DeepSeek itself. For the toolkit, a no-credit DeepSeek key
means the alias should be treated as unfundable (no free model exists to downgrade to).

---

### Cerebras 🔴 (NO balance API — prior verified finding)

**(A) Balance endpoint:** **NONE DOCUMENTED.** Billing/credit is console-only
(cloud.cerebras.ai). Rate-limit *allowance* is surfaced only through **undocumented** response
headers `x-ratelimit-limit-requests-day`, `x-ratelimit-remaining-requests-day`,
`x-ratelimit-limit-tokens-minute`, `x-ratelimit-remaining-tokens-minute`, etc. These describe
allowance windows, not monetary balance. (Prior verified finding.)

**(B) Error taxonomy:**
| Condition | Status | Body code |
|---|---|---|
| Bad key | **401** | `wrong_api_key` |
| No credit / payment required | **402** | payment required |
| Quota exhausted | **429** | body code `request_quota_exceeded` / `token_quota_exceeded` / `queue_exceeded` |
(Prior verified finding — carried forward per task instructions; do not re-derive.)

**(C) Free-tier:** Cerebras offers a free developer tier with daily request/token caps enforced via
the 429 quota codes above; paid tier raises the caps. No programmatic free-vs-paid flag — must infer
from 402 (no credit) vs 429-quota (transient) on the live probe.

---

### Upstage 🔴 (NO balance API — prior verified finding)

**(A) Balance endpoint:** **NONE DOCUMENTED.** Billing/credit is console-only. Rate limits ARE
documented via response headers **`X-Upstage-RateLimit-Limit`**, **`X-Upstage-RateLimit-Remaining`**,
**`X-Upstage-RateLimit-Reset`**, plus **`Retry-After`**. These are allowance, not balance.
(Prior verified finding.)

**(B) Error taxonomy:**
| Condition | Status | Body / notes |
|---|---|---|
| Bad key | **401** | `invalid_api_key` |
| No credit | **403** | **"Insufficient credit"** — note: 403, NOT 402 (Upstage-specific quirk) |
| Rate limited | **429** | with `Retry-After` — transient |
(Prior verified finding.) **Selector caution:** Upstage overloads **403** for no-credit, whereas
OpenRouter uses 403 for moderation/permission. The selector must key on **provider + status + body
string**, never on status alone.

**(C) Free-tier:** Upstage grants trial credit on signup; once exhausted the 403 "Insufficient
credit" appears. No documented free perpetual model.

---

### SiliconFlow 🟢 (documented balance endpoint)

**(A) Balance endpoint — documented:** **`GET https://api.siliconflow.com/v1/user/info`**
(Bearer auth, same key as inference). Response:
```json
{ "code": 20000, "message": "OK", "status": true,
  "data": {
    "id": "...", "name": "...", "email": "...", "isAdmin": false,
    "balance": "0.88",        // free/gift balance
    "chargeBalance": "88.00", // purchased (prepaid) balance
    "totalBalance": "88.88",  // balance + chargeBalance
    "status": "normal"        // account operational status ("normal" = healthy)
  } }
```
- **`chargeBalance` > 0 ⇒ the account has purchased credit** (⇒ paid tier). `balance` alone is
  gift/free credit. `totalBalance` is the spendable sum. `status:"normal"` = active account.
- Note the two doc hosts: `docs.siliconflow.com` (global, `api.siliconflow.com`) and
  `api-docs.siliconflow.cn` (China, `api.siliconflow.cn`). Same schema.
Sources: https://docs.siliconflow.com/en/api-reference/userinfo/get-user-info ;
https://siliconflow.readme.io/reference/user-info (accessed 2026-07-20).

**(B) Error taxonomy:** 401 invalid key; **403** with code `30011`/`insufficient balance` style body
for arrears; **429** for rate limit (`TPM/RPM limit reached`). (SiliconFlow largely follows the
OpenAI error envelope; the balance endpoint is the authoritative credit signal, so prefer it over
inferring from the inference error.) Source: https://github.com/siliconflow/siliconcloud/blob/main/openapi.yaml
(accessed 2026-07-20).

**(C) Free-tier:** New accounts get gift `balance`; some small models are free. Truest signal:
`chargeBalance > 0` ⇒ paid, else free. Selector should read the balance endpoint directly.

---

### Moonshot AI / Kimi 🟢 (documented balance endpoint — 429 ambiguity requires body inspection)

**(A) Balance endpoint — documented:** **`GET https://api.moonshot.ai/v1/users/me/balance`**
(Bearer `MOONSHOT_API_KEY`). Response:
```json
{ "code": 0, "scode": "0x0", "status": true,
  "data": {
    "available_balance": 49.58894, // total spendable = voucher + cash
    "voucher_balance": 46.58893,   // promotional / free credit
    "cash_balance": 3.00001        // paid top-up balance
  } }
```
- **No-credit signal:** `available_balance <= 0`. Under that condition inference calls fail with
  `exceeded_current_quota_error`.
- **`cash_balance > 0` ⇒ the account has paid credit** (paid tier); `voucher_balance` is free/promo.
- Base URL is region-split: `api.moonshot.ai` (global) vs `api.moonshot.cn` (China). Keys from
  `platform.kimi.ai` vs `platform.kimi.com` are **independent**; cross-use ⇒ 401.
Sources: https://platform.kimi.ai/docs/api/balance (301 from platform.moonshot.ai) ;
https://www.morphllm.com/kimi-api (accessed 2026-07-20).

**(B) Error taxonomy — CRITICAL 429 disambiguation:**
| Condition | Status | Error type string |
|---|---|---|
| Bad / wrong-platform key | **401** | `invalid_authentication_error` / `incorrect_api_key_error` |
| No credit / arrears / disabled | **429** | **`exceeded_current_quota_error`** — account problem, do NOT loop/retry, ⇒ free model |
| Rate limit (concurrency/RPM/TPM/TPD) | **429** | **`rate_limit_reached_error`** — transient, bounded retry, do NOT demote |

**Both no-credit and rate-limit return HTTP 429** — the *only* disambiguator is the error-type
string in the body (`exceeded_current_quota_error` = terminal no-credit; `rate_limit_reached_error`
= transient). A selector that keys on 429 status alone WILL misclassify. This is the canonical
example motivating body-code inspection over status-alone.
Source: https://kimi-ai.chat/docs/api-error-codes/ (accessed 2026-07-20).

**(C) Free-tier / Kimi Code OAuth:** The toolkit's Kimi Code path uses an OAuth subscription
(`_CMA_KIMICODE_OAUTH_`), which is subscription-metered, not credit-metered — the balance endpoint
applies to `MOONSHOT_API_KEY`/`ApiKey_Kimi` records, not the OAuth subscription. For pay-as-you-go
keys, `cash_balance > 0` ⇒ paid tier.

---

### Novita AI 🟢 (documented balance endpoint)

**(A) Balance endpoint — documented.** Novita's API reference "Basic APIs" section lists
**"Get User Balance"** (GET, "Query account balance") alongside Query Monthly Bill / Query
Usage-Based Billing / Query Fixed-Term Billing. Base URL **`https://api.novita.ai`**, Bearer auth.
The endpoint path resolves to **`GET /openapi/v1/billing/balance/detail`** with response fields
`availableBalance`, `cashBalance`, `creditLimit`, `pendingCharges`, `outstandingInvoices`
(monetary values in units of 1/10000 USD, i.e. `10000` = $1.00). **VERIFY-AT-INTEGRATION:** the
exact path/field names were read via docs fetch and should be re-confirmed against
`https://api.novita.ai` live once, since Novita's docs are a SPA; the *existence* of a documented
"Get User Balance" GET endpoint is confirmed by the API-reference overview.
Sources: https://novita.ai/docs/api-reference/api-reference-overview ;
https://novita.ai/docs/api-reference/basic-get-user-balance (accessed 2026-07-20).

**(B) Error taxonomy:** Novita states it "uses standard HTTP status codes and returns errors in a
unified format" but the specific insufficient-balance/invalid-key/rate-limit codes are behind a
linked Error Codes page not fully captured. Expected OpenAI-style envelope: 401 invalid key, 402/403
insufficient balance, 429 rate limit. **Prefer the balance endpoint** (`availableBalance <= 0` ⇒ no
credit) over inferring from inference errors. Source: https://novita.ai/docs/api-reference/api-reference-overview
(accessed 2026-07-20).

**(C) Free-tier:** Novita offers promotional free credit on signup and some free models; it is a
shared-queue GPU cloud. `cashBalance > 0` ⇒ has paid credit. Read the balance endpoint directly.

---

### Chutes 🟡 (management endpoints exist; exact balance field not publicly schema-documented)

**(A) Balance / quota endpoints — exist under `api.chutes.ai`** (Bearer required):
- **`GET https://api.chutes.ai/users/me`** — the authenticated account.
- **`GET https://api.chutes.ai/users/me/quotas`** — account limits (daily request quota).
- **`GET https://api.chutes.ai/users/me/subscription_usage`** — usage tracking.
- **`GET https://api.chutes.ai/users/me/discounts`** — discounts.

The exact JSON field names (balance / payment_balance / quota counters) are **not spelled out in the
public OpenAPI excerpt** — the schema at `https://api.chutes.ai/openapi.json` and the in-app
top-up page `https://chutes.ai/app/api/billing-balance` are the authoritative sources.
**VERIFY-AT-INTEGRATION:** read `/users/me` + `/users/me/quotas` live to capture the balance/quota
fields. Sources: https://chutes.ai/llms.txt ; https://chutes.ai/docs/api-reference/overview ;
https://x.com/chutes_ai/status/1947393495855177856 (accessed 2026-07-20).

**(B) Error taxonomy:** documented codes are sparse. **429** is confirmed for overloaded GPU queue
/ daily-quota exhaustion (shared free queues hit hardest at peak) — treat 429 as transient/quota,
not no-credit. Invalid-key ⇒ 401 (standard). No-credit ⇒ inability to top up past $0; distinguished
best via `/users/me/quotas`. Source: https://chutes.ai/pricing (accessed 2026-07-20).

**(C) Free-tier — the plan-gated trap in miniature.** Chutes uses a **hybrid subscription + PAYGO**
model. A **$5 minimum base tier** unlocks the visible daily quota; free/base users share queues.
"Free inference is never truly unlimited." So a Chutes key can be *usable* (has a daily quota) yet
have **$0 PAYGO balance** — quota comes from the subscription tier, not wallet credit. The selector
should read `/users/me/quotas` (quota available ⇒ launchable) rather than assuming wallet balance
gates access. Source: https://chutes.ai/pricing (accessed 2026-07-20).

---

### Z.AI / Zhipu (BigModel / GLM) 🟡 — plan-gated trap is severe here

**(A) Endpoints:**
- **Pay-as-you-go balance:** the BigModel/Z.AI console holds a wallet balance; there is a
  **quota/usage monitor endpoint** `…/api/monitor/usage/quota/limit`
  (`https://open.bigmodel.cn` / `https://api.z.ai`) that returns **Coding-Plan quota** windows
  (a **5-hour token limit** "Used X / Y" and an **MCP monthly quota**), NOT a raw wallet balance.
  It is API-key-authenticated. Source: https://lzw.me/docs/opencodedocs/vbgate/opencode-mystatus/platforms/zhipu-usage/
  (accessed 2026-07-20).
- Base URLs differ by billing mode: pay-as-you-go = `https://open.bigmodel.cn/api/paas/v4`
  (intl `https://api.z.ai/api/paas/v4`); **Coding Plan** = `https://api.z.ai/api/coding/paas/v4`,
  and for Claude Code/Goose specifically `https://api.z.ai/api/anthropic`.
  Source: https://docs.z.ai/devpack/faq ; https://zcode.z.ai/en/docs/configuration (accessed 2026-07-20).

**(B) Error taxonomy — the 1113 trap:**
| Condition | Code | Notes |
|---|---|---|
| Insufficient balance | **error 1113** "Insufficient Balance" | returned when the **pay-as-you-go** endpoint is hit with $0 wallet balance — **even if a Coding Plan subscription is active** — or when Coding-Plan quota is exhausted / usage conditions unmet |
| Coding-Plan quota exhausted | 1113 / quota error | wait for next 5-hour cycle; system does NOT fall back to deducting wallet balance |
| Subscription not yet propagated | transient 1113 | 5–15 min after purchase; dashboard shows active immediately (false-positive window) |

**Critical selector hazard:** A GLM **Coding Plan** subscriber has an *active, usable* plan but a
**$0 pay-as-you-go wallet**. If the toolkit probes the wrong base URL (`/api/paas/v4` instead of
`/api/anthropic` or `/api/coding/paas/v4`), it gets **1113 "Insufficient Balance"** and would
wrongly conclude "no credit" for a fully funded subscription. The detection MUST route the probe
through the **plan-appropriate base URL** before interpreting 1113. This is the archetypal
"zero-cost-but-plan-gated" case named in the task (zai-coding-plan).
Sources: https://github.com/zai-org/GLM-5/issues/49 ; https://github.com/zai-org/GLM-5/issues/36 ;
https://www.aipricing.guru/z-ai-subscription-pricing/ (accessed 2026-07-20).

**(C) Free-tier:** New BigModel accounts get promotional tokens; GLM-*-Flash models are free/low-cost.
True credit state for a Coding-Plan key is "quota remaining in the current 5-hour window", read from
the monitor endpoint — NOT wallet balance.

---

### NVIDIA `build.nvidia.com` (NIM) 🔴 (NO balance API — console-only)

**(A) Balance endpoint:** **NONE DOCUMENTED.** Multiple NVIDIA Developer Forum threads
("Cannot find the amount of credits left on NIM API") confirm there is **no programmatic
credits/balance endpoint** — the balance is visible only in the Build console
(build.nvidia.com → profile / Usage). Free developer credits are granted per account and refilled
via a manual "Request More" button. Sources:
https://forums.developer.nvidia.com/t/cannot-find-the-amount-of-credits-left-on-nim-api/337051 ;
https://forums.developer.nvidia.com/t/api-credit-balance/309857 (accessed 2026-07-20).

**(B) Error taxonomy:**
| Condition | Status | Body / notes |
|---|---|---|
| Bad / expired / unloaded key | **401** | Unauthorized |
| No credit / **cloud credits expired** | **402** | "Cloud credits expired - Please contact NVIDIA representatives" (also seen as "0 Credits") — terminal no-credit signal |
| Permission issue | 403 | occasionally overlaps with credit issues |
| Rate limit (free models) | **429** | transient; add exponential backoff |
Sources: https://forums.developer.nvidia.com/t/nvidia-nim-api-openai-api-error-code-402-cloud-credits-expired-please-contact-nvidia-representatives/316930 ;
https://forums.developer.nvidia.com/t/0-credits-error/307691 (accessed 2026-07-20).

**(C) Free-tier:** build.nvidia.com is effectively a **free-credit developer sandbox** (thousands of
free credits per account) with no perpetual "$0 free model" list — once credits hit 0 the 402 above
appears and there is no cheaper tier to downgrade to on-platform. Detection: must rely on the live
probe's **402 (no credit)** vs **429 (rate)** vs **401 (bad key)**.

---

### Hugging Face Inference Providers 🔴/🟡 (no public balance endpoint; monthly-credit model)

**(A) Balance endpoint:** **NONE clearly documented for programmatic inference-credit balance.**
Usage/spend is viewed on the web billing page (`huggingface.co/settings/billing`,
`…/settings/inference-providers/overview`). (`GET /api/whoami-v2` returns account/plan identity but
not a credit balance.) Router base URL is `https://router.huggingface.co/v1`.
Source: https://huggingface.co/docs/inference-providers/pricing (accessed 2026-07-20).

**Monthly included credits (verified table):**
| Account type | Monthly credits | PAYGO past credits |
|---|---|---|
| Free | **$0.10** (subject to change) | yes, requires credit purchase |
| PRO ($9/mo) | **$2.00** | yes |
| Team / Enterprise | **$2.00 per seat** (shared) | yes |

**(B) Error taxonomy:** 401 invalid token; **402 Payment Required** once monthly credits are
exhausted and no purchased credits remain (routed mode); 429 provider-side rate limit. **Key nuance:
"Custom Provider Key" mode** — if the HF token is configured to use a bring-your-own provider key,
HF credits do NOT apply and billing/errors come from the underlying provider, not HF. So an HF key's
credit state depends on the routing mode.

**(C) Free-tier / plan-gated:** The $0.10 free monthly credit is effectively a plan-gated trickle —
enough for a few requests. `is PRO / Team` (from whoami-v2 plan) is the closest programmatic proxy
for "has more credit headroom". No true perpetual $0 model; must rely on the 402 signal on the router.

---

### Together AI 🔴 (NO balance endpoint documented; clear error taxonomy)

**(A) Balance endpoint:** **NONE DOCUMENTED.** Credit balance is managed on the web billing page;
no dedicated public "check balance" REST endpoint was found. Base URL `https://api.together.xyz/v1`
(also `api.together.ai`). Sources: https://docs.together.ai/docs/billing-credits ;
https://support.together.ai/articles/1057636019-setting-a-usage-limit (accessed 2026-07-20).

**(B) Error taxonomy (clear):**
| Condition | Status | Notes |
|---|---|---|
| Bad / malformed key (stray space/newline) | **401** | Authentication error |
| No credit / **monthly spending limit hit** / balance = 0 | **402 Payment Required** | access suspended until credits added or limit raised; Build Tiers 1–4 have a fixed $100 limit |
| Rate limit | **429** | transient |
Source: https://docs.together.ai/docs/billing-credits (accessed 2026-07-20).

**(C) Free-tier:** New accounts get free credits; some models have a `free` variant
(`pricepertoken.com/endpoints/together/free`). Together distinguishes **free credits vs purchased
credits** in billing settings, but this split is **not exposed via API** — so "has purchased credit"
must be inferred from the absence of a 402. Selector: 402 ⇒ treat as no credit ⇒ free model.

---

### Fireworks AI 🔴/🟡 (prepaid credits; account REST API exists, no documented balance path)

**(A) Balance endpoint:** **No dedicated balance-check endpoint documented.** Fireworks exposes an
account-scoped REST API (`/v1/accounts/{account_id}/…` for models/deployments), and balance is shown
on the billing dashboard. Prepaid-credit model with optional auto top-up.
Sources: https://docs.fireworks.ai/faq/billing-pricing-usage/billing/credit-system ;
https://docs.fireworks.ai/api-reference/introduction (accessed 2026-07-20).
**VERIFY-AT-INTEGRATION:** check `https://docs.fireworks.ai/llms.txt` for any
`/v1/accounts/{id}` billing sub-resource before assuming none exists.

**(B) Error taxonomy:** When credits reach 0 (auto-top-up off) or the spending limit is hit, "usage
pauses" — API requests are blocked (expected **402/403** envelope; exact code not documented on the
credit-system page). 401 invalid key, 429 rate limit. Prefer the live-probe error over inference.

**(C) Free-tier:** Fireworks grants a **$1 signup credit**; some models have a free variant
(`pricepertoken.com/endpoints/fireworks/free`). Balance is prepaid — once $1 is spent and no top-up,
requests pause. Selector: blocked/402 ⇒ no credit ⇒ free model.

---

### Groq 🔴 (NO billing API — feature-requested but not shipped; rich rate-limit headers)

**(A) Balance endpoint:** **NONE.** Billing/usage is console-only (Dashboard → Usage). There is an
open community request "Add API endpoint to fetch billing and usage data" — confirming **no such
endpoint exists yet**. Rate-limit *allowance* IS exposed via headers.
Sources: https://community.groq.com/t/add-api-endpoint-to-fetch-billing-and-usage-data/378 ;
https://console.groq.com/docs/rate-limits (accessed 2026-07-20).

**Rate-limit headers (documented):** `x-ratelimit-limit-requests` (RPD),
`x-ratelimit-limit-tokens` (TPM), `x-ratelimit-remaining-requests`,
`x-ratelimit-remaining-tokens`, `x-ratelimit-reset-requests`, `retry-after` on 429. Note: no
`X-RateLimit-Remaining` on successful responses in some cases.

**(B) Error taxonomy:**
| Condition | Status | Notes |
|---|---|---|
| Bad / invalid key | **401** | Unauthorized |
| Rate / daily-quota exceeded | **429** | with `retry-after`; free tier ~1,000 RPD / 6,000 TPM / 30 RPM — transient, do NOT demote |
| **Spending limit hit** | **400** code **`blocked_api_access`** | org-wide block — NOT a rate limit; closest thing to a "no more budget" signal, but it is an operator-set cap not a zero-balance |
Source: https://console.groq.com/docs/errors ; https://console.groq.com/docs/spend-limits (accessed 2026-07-20).

**(C) Free-tier:** Genuine free tier (no card) with the RPD/TPM caps above; paid Developer tier (card
required) raises to 500+ RPM / 2M TPM. There is no per-request "credit" — free vs paid is a **tier
flag not exposed via API**. Detection must lean on: 401 (bad key) vs 429 (rate, transient) vs 400
`blocked_api_access` (budget cap).

---

### xAI (Grok) 🟡 (documented **management-API** balance endpoint — needs a separate management key)

**(A) Balance endpoint — documented, but management-key-gated:**
- **`GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance`** — returns
  `total.val` (current prepaid balance in **USD cents**) and a `changes[]` ledger of top-up/spend
  events (`amount` cents, `changeOrigin`).
- **`POST https://management-api.x.ai/v1/billing/teams/{team_id}/usage`** — usage time-series.
- **Auth: requires a management API key + team_id, NOT a standard inference key.** The toolkit's
  discovered keys are inference keys, so this endpoint is generally unavailable to the probe unless
  the operator has also stored `XAI_MANAGEMENT_KEY` + `XAI_TEAM_ID`.
Source: https://docs.x.ai/developers/rest-api-reference/management/billing (accessed 2026-07-20).

**(B) Error taxonomy:** The API stops functioning once prepaid credits are consumed and postpaid
usage hits the soft spending limit. Exact inference-side status codes for no-credit are not crisply
documented (expect 403/429). 401 for bad key. **VERIFY-AT-INTEGRATION** via a live probe.

**(C) Free-tier:** xAI's free-credit program status has fluctuated (community reports it ended).
Prepaid-credit model; `prepaid/balance.total.val <= 0` ⇒ no credit (if a management key is available).
Without a management key, fall back to the inference-probe error.

---

### Mistral AI 🔴 (NO public balance endpoint; console credits; billing required even for free tier)

**(A) Balance endpoint:** **NONE DOCUMENTED** for programmatic balance. The **Credits** section is
web-console only (Organization-level). Base URL `https://api.mistral.ai/v1/`.
Source: https://docs.mistral.ai/admin/billing-usage/billing ;
https://docs.mistral.ai/admin/user-management-finops/tier (accessed 2026-07-20).

**(B) Error taxonomy:** 401 invalid key; **monthly spending-limit reached ⇒ API access suspended**
until next month or admin raises the cap; failed invoice payments also suspend access; **429** tiered
rate limits. Exact status for the suspend condition is not crisply documented (expect 429/403).

**(C) Free-tier / trap:** Mistral has a free "Experiment" tier, **but activating API keys generally
requires adding billing details even to use free models.** So a Mistral key that *exists* may still
be gated behind billing activation — a plan-gate. Credit state must be inferred from the live probe.

---

### GitHub Models 🔴 (NO credit/balance concept at all — purely plan-gated free; the canonical plan-gate)

**(A) Balance endpoint:** **NONE — and there is no "credit" to check.** GitHub Models has **no
monetary balance**; access is **rate-limited free**, gated entirely by the caller's **GitHub Copilot
plan tier**. Auth is a **GitHub PAT with `models:read`** (not a vendor API key). Base:
`https://models.github.ai` (formerly `models.inference.ai.azure.com`). Standard GitHub REST
rate-limit headers apply (`x-ratelimit-remaining`, `x-ratelimit-reset`).
Sources: https://docs.github.com/github-models/prototyping-with-ai-models ;
https://docs.github.com/billing/managing-billing-for-your-products/about-billing-for-github-models
(accessed 2026-07-20).

**(B) Error taxonomy:**
| Condition | Status | Notes |
|---|---|---|
| Bad / missing / wrong-scope token | **401** | needs `models:read` |
| Rate / **daily quota exceeded** | **429** | resets UTC 00:00; per-account/per-token; e.g. GPT-4o 50 req/day, GPT-4o-mini 150 req/day on free |
| Paid usage not opted-in | (feature-gated) | higher limits require opting into paid usage or Copilot Business/Enterprise |

**(C) Free-tier — the archetypal plan-gate.** Every GitHub account gets free rate-limited access;
Copilot Business/Enterprise raise the limits; orgs can opt into paid usage for larger context/limits.
**There is no credit balance and no paid-per-token model to "detect" — the tier is the GitHub plan,
readable only from GitHub's own account/plan APIs, not from any inference-side balance call.** For the
toolkit, GitHub Models is always "free tier" from a credit standpoint; the only failure mode is 429
(transient daily quota) or 401 (bad/expired token) — never a no-credit 402. models.dev pricing `0`
for these is *genuinely* free, but plan-gated by rate limit, not by wallet.

---

### Tencent Hunyuan 🟡 (no Hunyuan-specific balance API; Tencent Cloud general Billing API exists but heavyweight)

**(A) Balance endpoint:** No **Hunyuan-inference-specific** balance endpoint. Tencent Cloud's
**general Billing product** exposes **`DescribeAccountBalance`** (action on the `billing`
TencentCloud API, region-less), returning:
- `Balance` (Int, available balance in **cents**), `RealBalance` (Float, cents),
  `CashAccountBalance`, `IncomeIntoAccountBalance`, `PresentAccountBalance`, `FreezeAmount` (all cents).
- **Auth: TC3-HMAC-SHA256 signed request** with SecretId/SecretKey (Tencent Cloud CAM credentials),
  NOT the Hunyuan bearer key; requires the finance/billing permission. Max 20 req/s.
Source: https://www.tencentcloud.com/document/product/555/50284 (accessed 2026-07-20).

**(B) Error taxonomy:** Hunyuan is pay-as-you-go (billed per API call; failed calls not charged). If
no prepaid resource pack and no active postpaid service, a **billing-exception error** is returned
(insufficient credit); an SMS top-up reminder is sent when balance is insufficient. Concurrency caps
(default 1–3) act as the rate limit; exceed ⇒ throttle. Bad credentials ⇒ signature/auth error.
Source: https://www.tencentcloud.com/document/product/1284/75281 (accessed 2026-07-20).

**(C) Assessment for the toolkit:** `DescribeAccountBalance` is technically a machine-readable balance
signal, but it needs a **completely different auth flow (TC3 signing, CAM keys, billing permission)**
than a simple bearer inference probe. **For a bearer-key-only toolkit this is effectively out of
reach** — treat Hunyuan as 🔴 in practice and rely on the inference-probe billing-exception error.

---

## 2. Consolidated error-signal taxonomy (the disambiguation table)

The selector's job is to map `(provider, http_status, body_code/string)` → one of four classes:
- **BAD_KEY** — account broken, do not activate the alias, do not demote-to-free (a free model
  won't work either). Terminal.
- **NO_CREDIT** — key valid but unfunded ⇒ **downgrade to the strongest free model** (or, if the
  provider has no free model, mark the alias unfundable).
- **RATE/QUOTA** — transient ⇒ **unverified/skip, do NOT demote**, retry later.
- **OK** — request succeeded (credit present at the probed tier).

**The load-bearing lesson: HTTP status alone is ambiguous across providers — you MUST key on
`provider + status + body code`.** Concrete collisions proven above:
- **402** = no-credit on OpenRouter / DeepSeek / Cerebras / NVIDIA / Together, but Upstage uses
  **403** for the same "insufficient credit" and OpenRouter uses **403** for *moderation* (not credit).
- **429** = rate-limit almost everywhere, **but on Moonshot/Kimi 429 also means no-credit** —
  disambiguated only by body `exceeded_current_quota_error` (no-credit) vs `rate_limit_reached_error`
  (rate). Z.AI signals no-credit with app-code **1113**, not an HTTP status.
- **400** = usually a bad request, **but Groq uses 400 `blocked_api_access` for a spend-limit block.**

| Provider | BAD_KEY | NO_CREDIT | RATE / QUOTA | Balance API? |
|---|---|---|---|---|
| OpenRouter | 401 | **402** | 429 (+ 403=moderation, not credit) | 🟢 `/api/v1/key`, `/api/v1/credits`(mgmt) |
| DeepSeek | 401 | **402** "run out of balance" | 429 | 🟢 `/user/balance` (`is_available`) |
| SiliconFlow | 401 | 403 / arrears code | 429 (TPM/RPM) | 🟢 `/v1/user/info` |
| Moonshot/Kimi | 401 | **429 `exceeded_current_quota_error`** | 429 `rate_limit_reached_error` | 🟢 `/v1/users/me/balance` |
| Novita | 401 | 402/403 (verify) | 429 | 🟢 Get User Balance (verify path) |
| Chutes | 401 | (top-up gate) | **429** queue/quota | 🟡 `/users/me/quotas` |
| Z.AI/Zhipu | 401 | **app-code 1113** (route-dependent!) | quota / 5-h cycle | 🟡 monitor quota endpoint |
| Cerebras | 401 `wrong_api_key` | **402** | 429 `*_quota_exceeded`/`queue_exceeded` | 🔴 headers only |
| Upstage | 401 `invalid_api_key` | **403 "Insufficient credit"** | 429 (+`Retry-After`) | 🔴 headers only |
| NVIDIA NIM | 401 | **402** "Cloud credits expired" | 429 | 🔴 console only |
| Hugging Face | 401 | **402** (routed mode) | 429 | 🔴 web billing |
| Together | 401 | **402** Payment Required | 429 | 🔴 web billing |
| Fireworks | 401 | 402/403 pause (verify) | 429 | 🔴/🟡 account API |
| Groq | 401 | **400 `blocked_api_access`** (spend cap) | 429 (+`retry-after`) | 🔴 console only |
| xAI/Grok | 401 | 403/429 (verify) | 429 | 🟡 mgmt-API prepaid/balance (mgmt key) |
| Mistral | 401 | suspend (429/403, verify) | 429 tiered | 🔴 console only |
| GitHub Models | 401 | **N/A (no credit concept)** | **429** daily quota | 🔴 none (plan-gated) |
| Tencent Hunyuan | signature/auth err | billing-exception error | concurrency throttle | 🟡 `DescribeAccountBalance` (TC3 sign) |

**Rule the selector must encode:** *never demote on a 429/5xx/timeout/`rate_limit_reached_error`;
only demote-to-free on a status+body that the table marks NO_CREDIT for that specific provider.*
This matches the toolkit's existing verify logic (transient ⇒ `unverified`, definitive ⇒ `failed`).

---

## 3. Free-tier / free-model identification (and the plan-gated trap)

There are **three distinct notions of "free"** the selector must not conflate:

1. **True free model** — priced $0 and usable with *any* valid key for that provider (subject only
   to rate limits). Example: OpenRouter `…:free` models; small SiliconFlow/Together/Fireworks free
   variants.
2. **Free monthly credit trickle** — a paid catalog, but the account gets a small recurring credit
   (HF $0.10/PRO $2; NVIDIA/Fireworks/Together signup credit). Usable until the trickle is spent,
   then 402.
3. **Plan-gated "$0"** — the catalog price is 0 (or the plan is "free") **but access requires a
   specific plan/subscription key on a specific endpoint**. This is the dangerous one:
   - **GitHub Models** — `cost:0` is real, but gated by the GitHub Copilot plan + a `models:read`
     PAT on `models.github.ai`; no wallet, only rate limits.
   - **Z.AI zai-coding-plan** — subscription quota only works on `/api/anthropic` or
     `/api/coding/paas/v4`; the pay-as-you-go endpoint returns **1113** with a $0 wallet.
   - **Chutes** — daily quota comes from the $5+ subscription tier, not wallet balance.
   - ("kenari"-style plan keys behave the same: catalog cost 0, but only the plan endpoint honors it.)

### How to tell true-free from plan-gated **programmatically**

- **models.dev catalog** (`https://models.dev/api.json`, the machine-readable catalog the toolkit
  already consumes) gives per-model `cost.input` / `cost.output` (USD per 1M tokens) and
  `limit.context` / `limit.output`. **`cost.input == 0 && cost.output == 0` ⇒ *priced* free.**
  Source: https://models.dev/ (structure confirmed; free shown as `$0.00 / $0.00`, unknown as `-`),
  accessed 2026-07-20.
- **But catalog-free is necessary, not sufficient.** A `cost:0` model is only *usable-free* if the
  **live verification probe succeeds with the discovered key on the alias's actual base URL.** The
  probe is the disambiguator: catalog `cost:0` + probe OK ⇒ true-free; catalog `cost:0` + probe
  401/403/1113/402 ⇒ plan-gated (needs a plan the key doesn't carry) ⇒ NOT launchable as "free".
- **OpenRouter `:free` suffix** is a reliable string signal (`endswith(":free")`), but even it is
  rate/credit-gated (50 req/day with no purchase, 1000 with ≥$10 purchased; negative balance can 402
  even a `:free` model).
- **Provider "free variant" listings** (pricepertoken.com/…/free pages) are human references only;
  trust the catalog `cost` + live probe over any scraped list.

**Net rule:** `is_free_usable(model, key) := (models.dev cost==0) AND (verification probe passes with
this key on this base URL)`. Catalog price gives the candidate; the probe confirms the key can
actually reach it. Never treat catalog `cost:0` as launchable without the probe — that is exactly the
plan-gated trap.

---

## 4. Recommended detection algorithm

Design goal: reuse the **one live verification probe the toolkit already issues per alias**, add a
**cheap balance-endpoint call where one is documented**, and fall back **conservatively** everywhere
else. Output per (provider, key): `credit_state ∈ {CREDIT, NO_CREDIT, UNKNOWN}` → which drives the
existing tier policy (CREDIT ⇒ strongest paid; NO_CREDIT/UNKNOWN ⇒ strongest free).

### 4.1 Precedence (first matching rule wins)

```
detect_credit_state(provider, key, base_url):

  # (0) Human override always wins (already in providers/overrides.json: strong_model/fast_model).
  if overrides.pins_model(provider): return PINNED   # tier logic steps aside

  # (1) Documented balance endpoint (only the 🟢 providers) — cheapest, most authoritative.
  if provider has documented balance endpoint reachable with THIS key type:
      b = GET balance
      OpenRouter : CREDIT if not data.is_free_tier or (data.limit_remaining or ∞) > 0 else NO_CREDIT
      DeepSeek   : CREDIT if data.is_available else NO_CREDIT
      SiliconFlow: CREDIT if float(totalBalance) > 0 (paid if chargeBalance>0) else NO_CREDIT
      Moonshot   : CREDIT if data.available_balance > 0 (paid if cash_balance>0) else NO_CREDIT
      Novita     : CREDIT if availableBalance > 0 else NO_CREDIT     # verify path first
      xAI        : CREDIT if prepaid.total.val > 0   # ONLY if XAI_MANAGEMENT_KEY present
      → on network/5xx/timeout from the balance call: fall through to (2), do NOT conclude NO_CREDIT

  # (2) Live inference probe (ALWAYS run — it is the verification probe already in the pipeline).
  status, body = probe(base_url, alias_model)   # sentinel + tool-call probe
  cls = classify(provider, status, body)        # per §2 table, provider-keyed
      OK        -> CREDIT
      NO_CREDIT -> NO_CREDIT
      RATE|5xx|timeout|network -> UNKNOWN        # transient — never NO_CREDIT, never demote-as-terminal
      BAD_KEY   -> return BAD_KEY                 # alias not activated at all (distinct from NO_CREDIT)

  # (3) Reconcile (1) and (2): if (1) said CREDIT but (2) probe gives NO_CREDIT on a PAID model,
  #     the key is funded but the *paid* tier failed (plan-gate / model-specific) -> try free model.
```

### 4.2 The UNKNOWN branch — conservative, by design

**UNKNOWN ⇒ treat as NO_CREDIT for tier selection ⇒ pick the strongest *free* model.** This is the
existing toolkit contract (CLAUDE.md "credit state unknown ⇒ treat as no credit"). It applies when:
no documented balance endpoint AND the probe was transient (429/5xx/timeout/offline), or the balance
endpoint needs a key type we don't have (xAI mgmt key, Tencent CAM), or catalog is offline.

Rationale (asymmetric cost, unchanged from the current design): choosing a paid model on an unfunded
key ⇒ hard 402/403 launch failure and a dead alias; choosing a free model on a funded key ⇒ only a
capability give-up that the next `sync` corrects once a real signal appears. So bias to free.

**Do NOT collapse BAD_KEY into UNKNOWN.** A 401 is terminal (alias not activated); demoting a
401-key to a free model just produces a second failure. Keep BAD_KEY a separate outcome.

### 4.3 Per-provider strategy summary (what to actually call)

| Tier of evidence | Providers | Selector action |
|---|---|---|
| Read balance endpoint (authoritative) | OpenRouter, DeepSeek, SiliconFlow, Moonshot/Kimi, Novita | balance field ⇒ CREDIT/NO_CREDIT directly; probe still runs for launchability |
| Balance endpoint but wrong key type | xAI (mgmt key), Tencent (CAM/TC3) | use only if operator stored the extra credential; else UNKNOWN⇒free |
| Quota endpoint, not wallet (plan-gated) | Chutes, Z.AI coding-plan | read quota-remaining; **probe the plan-correct base URL** before reading 1113/402 as NO_CREDIT |
| No endpoint — probe only | Cerebras, Upstage, NVIDIA, HF, Together, Fireworks, Groq, Mistral | classify probe error per §2 table |
| No credit concept | GitHub Models | always "free tier"; only 401(bad)/429(transient) matter |

### 4.4 Caching: TTL + schema version

- **Reuse the toolkit's existing 24h verification cache** and its **schema-version key** (already
  present per CLAUDE.md, so results from older/weaker logic are never replayed). Store the
  `credit_state` + the raw `(status, body_code)` evidence alongside the verification verdict under
  the **same cache entry**, bumping the schema version because this adds new fields.
- **TTL guidance:** balance-endpoint reads and NO_CREDIT/CREDIT verdicts → **24h** (matches the
  existing cache; balances change slowly relative to a daily sync). UNKNOWN/transient verdicts →
  **short TTL (e.g. ≤1h) or no cache**, so a rate-limit blip doesn't pin an alias to free for a day;
  the next sync re-probes and upgrades. BAD_KEY → 24h (don't hammer a dead key), but always
  re-checkable on an explicit `sync --force`.
- **Schema version must gate replay:** if the cache schema predates the credit-detection fields, treat
  as cache-miss and re-derive — identical to how the existing 24h cache already refuses stale
  weaker-logic results.

### 4.5 Honest gaps — where no external solution exists

- **Cerebras, Upstage, NVIDIA, Groq, Mistral, Together, HF (inference credits)** expose **no
  machine-readable balance** — **no external solution found; the probe-error classifier in §2 is the
  original design the toolkit must own.** These are the majority; the durable signal really is the
  inference-error taxonomy, not a balance API.
- **Plan-gated providers (GitHub Models, Z.AI coding-plan, Chutes)** have **no "credit" to read at
  all** — detection here is *route the probe to the plan-correct base URL and read rate-limit/quota,
  not wallet*. Conflating their 1113/quota with a wallet 402 is the specific failure mode to avoid.
- **xAI / Tencent** balances are readable but behind a *second credential class* most toolkit users
  won't have stored — so in practice they fall to the conservative UNKNOWN⇒free branch.

---

## 5. Coverage tracker

| # | Provider | Balance API | Error taxonomy | Free-tier notes | Status |
|---|---|---|---|---|---|
| 1 | OpenRouter | 🟢 2 endpoints | ✅ | ✅ `:free` + $10 gate | DONE |
| 2 | DeepSeek | 🟢 `/user/balance` | ✅ verified | ✅ no free tier | DONE |
| 3 | SiliconFlow | 🟢 `/v1/user/info` | ✅ | ✅ chargeBalance | DONE |
| 4 | Chutes | 🟡 quotas | ✅ (429) | ✅ $5 plan-gate | DONE |
| 5 | Moonshot/Kimi | 🟢 `/v1/users/me/balance` | ✅ 429 split | ✅ voucher/cash | DONE |
| 6 | Z.AI/Zhipu | 🟡 quota monitor | ✅ 1113 trap | ✅ coding-plan gate | DONE |
| 7 | NVIDIA NIM | 🔴 console | ✅ 402 expired | ✅ free sandbox | DONE |
| 8 | Novita | 🟢 Get User Balance | ✅ (verify) | ✅ signup credit | DONE (path to verify) |
| 9 | Hugging Face | 🔴 web | ✅ 402 routed | ✅ $0.10/$2 trickle | DONE |
| 10 | Fireworks | 🔴/🟡 account API | ✅ (verify) | ✅ $1 signup | DONE (path to verify) |
| 11 | Together | 🔴 web | ✅ 402 | ✅ free credits | DONE |
| 12 | Groq | 🔴 console | ✅ 400 blocked | ✅ free tier caps | DONE |
| 13 | xAI/Grok | 🟡 mgmt API | ✅ (verify) | ✅ prepaid | DONE |
| 14 | Mistral | 🔴 console | ✅ suspend | ✅ billing-gated | DONE |
| 15 | Tencent Hunyuan | 🟡 TC3 billing | ✅ | ✅ PAYG | DONE |
| 16 | GitHub Models | 🔴 none | ✅ 429 only | ✅ plan-gated | DONE |
| P1 | Cerebras (prior) | 🔴 headers | ✅ | ✅ | CARRIED |
| P2 | Upstage (prior) | 🔴 headers | ✅ | ✅ | CARRIED |

**All target providers covered.** Items marked "path to verify" (Novita exact balance path,
Fireworks account balance sub-resource) have a confirmed *existence* of the capability but a
docs-fetch-derived exact path that should be re-confirmed against the live API once during
implementation — flagged inline as VERIFY-AT-INTEGRATION so no invented endpoint is trusted blindly.

### Source index (primary citations, all accessed 2026-07-20)
- OpenRouter: openrouter.ai/docs/api-reference/limits · /docs/api/api-reference/credits/get-remaining-credits · /docs/api_reference/limits · aicostplanner.com/openrouter-credits · openrouter.zendesk.com/hc/en-us/articles/39501163636379 · klymentiev.com/blog/openrouter-free-tier
- DeepSeek: api-docs.deepseek.com/api/get-user-balance · /quick_start/pricing · /quick_start/error_codes
- SiliconFlow: docs.siliconflow.com/en/api-reference/userinfo/get-user-info · siliconflow.readme.io/reference/user-info · github.com/siliconflow/siliconcloud/blob/main/openapi.yaml
- Moonshot/Kimi: platform.kimi.ai/docs/api/balance · morphllm.com/kimi-api · kimi-ai.chat/docs/api-error-codes
- Novita: novita.ai/docs/api-reference/api-reference-overview · /basic-get-user-balance
- Chutes: chutes.ai/llms.txt · /docs/api-reference/overview · /pricing · x.com/chutes_ai/status/1947393495855177856
- Z.AI/Zhipu: docs.z.ai/devpack/faq · zcode.z.ai/en/docs/configuration · lzw.me/docs/opencodedocs/…/zhipu-usage · github.com/zai-org/GLM-5/issues/49 · /issues/36 · aipricing.guru/z-ai-subscription-pricing
- Cerebras/Upstage: prior verified findings (carried)
- NVIDIA: forums.developer.nvidia.com/t/cannot-find-the-amount-of-credits-left-on-nim-api/337051 · /t/nvidia-nim-api-openai-api-error-code-402-cloud-credits-expired…/316930 · /t/api-credit-balance/309857 · /t/0-credits-error/307691
- Hugging Face: huggingface.co/docs/inference-providers/pricing
- Together: docs.together.ai/docs/billing-credits · support.together.ai/articles/1057636019
- Fireworks: docs.fireworks.ai/faq/billing-pricing-usage/billing/credit-system · /api-reference/introduction
- Groq: console.groq.com/docs/rate-limits · /docs/errors · /docs/spend-limits · community.groq.com/t/add-api-endpoint-to-fetch-billing-and-usage-data/378
- xAI: docs.x.ai/developers/rest-api-reference/management/billing
- Mistral: docs.mistral.ai/admin/billing-usage/billing · /admin/user-management-finops/tier
- Tencent: tencentcloud.com/document/product/555/50284 · /document/product/1284/75281
- GitHub Models: docs.github.com/github-models/prototyping-with-ai-models · docs.github.com/billing/managing-billing-for-your-products/about-billing-for-github-models
- Catalog: models.dev/ (and models.dev/api.json machine-readable catalog)

*End of brief.*

## 0. Executive orientation — the durable pattern

Across the whole provider landscape, **reliable machine-readable balance/credit APIs are RARE.**
Most providers expose billing only in a web console. The two signals that *are* durably available
programmatically are:

1. **The error response to a real inference request** — the HTTP status + structured body code
   returned when you actually call the chat/completions endpoint with the model under test. This is
   the single most portable signal and the toolkit already issues exactly such a probe during
   verification.
2. **Rate-limit headers** — `x-ratelimit-*` / vendor-specific variants returned on every request,
   which describe *allowance* (requests/tokens remaining in a window) but usually **not** monetary
   balance.

The selector's hard problem is **disambiguation**: HTTP 402/403/429/401 are used inconsistently
across providers for "no funds", "quota exhausted", "rate limited", and "bad key". The taxonomy
tables below record, per provider, exactly which status+body means which condition, so the selector
never conflates a transient 429 (don't demote) with a terminal no-credit 402/403 (⇒ free model).

### Prior verified inputs (carried from earlier research legs — do not re-derive)

- **Cerebras**: NO balance/credit API (console-only). Rate-limit allowance is exposed only via
  *undocumented* `x-ratelimit-*` response headers. No-credit ⇒ **402**; quota exhaustion ⇒ **429**
  with body code `request_quota_exceeded` / `token_quota_exceeded` / `queue_exceeded`; bad key ⇒
  **401** `wrong_api_key`. (Prior finding; see §Cerebras.)
- **Upstage**: NO balance/credit API (console-only). Documented `X-Upstage-RateLimit-*` headers
  (including `Reset` / `Retry-After`). No-credit ⇒ **403 "Insufficient credit"** (NOT 402); bad
  key ⇒ **401** `invalid_api_key`. (Prior finding; see §Upstage.)

---
