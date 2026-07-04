# DRAFT — CONST-052 rule-number collision: investigation + renumber proposal

**Status: DRAFT-ONLY / research artifact.** This document proposes a fix but
applies nothing. No `CONSTITUTION.md`, `CLAUDE.md`, `AGENTS.md`, `QWEN.md`, or
`GEMINI.md` is modified by producing it. Landing any of this requires the careful
separate governance-edit workflow (§11.4.49) described in §5 below, which is a
Phase-3 task — not this research pass.

- **Date:** 2026-07-04
- **Author:** research/draft pass (Phase-5/6 provider-verification overhaul track)
- **Trigger:** `docs/superpowers/specs/2026-07-04-provider-verification-design.md`
  §3.4 proposes a NEW constitution rule it labels **"CONST-052"** — a boundary
  contract for the generic `semantic-code-visibility` capability. That id is
  already taken.

---

## 1. The collision (confirmed)

The design spec §3.4 (`docs/superpowers/specs/2026-07-04-provider-verification-design.md`,
lines 215–223) proposes:

> "The `semantic-code-visibility` capability MUST accept fixture, prompt, sentinel,
> judge-config, and rubric as CLI args. It MUST NOT bundle consumer-project-specific
> fixtures, prompts, sentinels, or rubrics as defaults. A consumer project supplies its
> own."
>
> — labelled **"CONST-052 (proposed new constitution entry)"**

But **CONST-052 already exists** in the LLMsVerifier submodule constitution. From
`submodules/LLMsVerifier/CONSTITUTION.md` (line 656):

> `## CONST-052: Lowercase-Snake_Case-Naming Mandate (cascaded from constitution submodule §11.4.29)`

The spec itself even leans on the real CONST-052 elsewhere: §2.3 (line 149) says a
default fixture referencing a consumer project would be "codified as CONST-052", and
line 726 references "legacy `Upstreams/` per CONST-052 transition" — both of which are
the *lowercase-snake_case* rule, NOT a boundary contract. So the spec has **two
distinct rules fighting over the single id CONST-052**. Collision confirmed.

---

## 2. Numbering scheme actually in use (grep evidence)

Two coupled schemes are in play. Every named `CONST-0NN` anchor in the LLMsVerifier
constitution is explicitly "cascaded from constitution submodule §11.4.NN" — e.g.
CONST-050←§11.4.27, CONST-051←§11.4.28, CONST-052←§11.4.29, CONST-053←§11.4.30,
CONST-054←§11.4.31. So a new cascaded rule needs a **fresh id in BOTH** schemes:
a local `CONST-0NN` anchor AND a master `§11.4.NNN` section in the constitution
submodule.

### 2a. Highest existing `CONST-0NN` anchor

Command:

```
grep -rhoE 'CONST-0[0-9]{2}' submodules/LLMsVerifier/CLAUDE.md submodules/LLMsVerifier/CONSTITUTION.md | sort -u -t- -k2 -n | tail -1
```

Real output:

```
CONST-068
```

Full numeric-sorted set (note gaps at 017, 045, 046, 062–067):

```
CONST-001 … CONST-016, CONST-018 … CONST-044, CONST-047 … CONST-061, CONST-068
```

(`CONST-052` sits squarely inside the occupied range — it is taken.)
**Highest existing CONST id = `CONST-068`.**

### 2b. Highest existing `§11.4.NNN` reference

The naive `sort -u | tail` used first is a *lexical* sort, which buries the 3-digit
ids (`§11.4.100`+) before the 2-digit ones and reports a false max of `§11.4.99`.
Re-run with a version/numeric sort:

```
grep -rhoE '§11\.4\.[0-9]{1,3}' submodules/LLMsVerifier/CLAUDE.md | sort -u -V | tail -1
```

Real output:

```
§11.4.165
```

Tail of the true numeric-sorted set:

```
… §11.4.160 §11.4.161 §11.4.162 §11.4.163 §11.4.164 §11.4.165
```

**Highest existing §11.4 id = `§11.4.165`** (Universal Independent Verification
Agent Mandate). The master §11.4 scheme is where all recent additions land
(§11.4.150+ are 2026-06 mandates); `CONST-0NN` is the older/parallel *local anchor*
scheme that only cascades a subset and has not advanced past 068.

---

## 3. Recommended scheme + next-free id

Because the two schemes are coupled, resolving the collision cleanly means claiming
the next-free id in **each** (do not reuse the +23 historical offset — the schemes
have diverged: CONST maxes at 068 while §11.4 maxes at 165, so an offset-derived id
is a guess and would collide). Both ids below are backed by the grep output in §2:

| Scheme | Highest existing (grep) | **Next-free** |
|---|---|---|
| Local anchor `CONST-0NN` (what the spec was actually writing) | `CONST-068` | **`CONST-069`** |
| Master `§11.4.NNN` (constitution submodule section it cascades from) | `§11.4.165` | **`§11.4.166`** |

**Primary recommendation:** give the boundary rule the local anchor **`CONST-069`**,
cascaded from a new master section **`§11.4.166`** — i.e. header
`## CONST-069: … (cascaded from constitution submodule §11.4.166)`. The spec was
plainly reaching for a `CONST-0NN` anchor (it wrote "CONST-052"), so keeping it in the
anchor scheme is the least-surprising fix; the new master §11.4.166 is what makes it a
real cascaded constitution rule rather than a floating local note.

**If Phase-3 governance prefers to track the rule purely by master number** (recent
practice favors §11.4.NNN), then use **`§11.4.166`** as the canonical id and skip a new
CONST anchor. Either way the *first-free* value in the chosen scheme is what the grep
supports; both candidates are presented because the choice of scheme is a governance
call, not a fact derivable from grep. What is NOT acceptable is re-using `CONST-052`.

---

## 4. Drafted anchor text (project-not-aware / CONST-051 clean)

Below is the proposed anchor, written in the house style of the surrounding anchors
(cf. CONST-050/051/052/053/054 in `submodules/LLMsVerifier/CONSTITUTION.md`): a title
line, an optional verbatim-mandate block, a normative body, an anti-bluff/test line, a
cascade-requirement line, and a canonical-authority pointer. It is deliberately
**project-not-aware** (honors CONST-051): it names NO consumer project — no
`claude_toolkit`, no `cma_`, no `claude-providers`, no release-tag prefix. The
`fixture`/`prompt`/`sentinel` inputs are described generically as consumer-supplied
runtime args.

> **DRAFT anchor — do not apply; for Phase-3 review only.**

```markdown
## CONST-069: Semantic-Visibility-Capability-Boundary Mandate (cascaded from constitution submodule §11.4.166)

A generic semantic-visibility capability MUST accept its fixture, prompt, sentinel,
and judge-config (judge endpoint/model/threshold + rubric) as runtime arguments
supplied by the consuming project, and MUST NOT bundle consumer-specific fixtures,
prompts, sentinels, or rubrics as defaults. The capability MUST NOT read any
consumer's private directories or verification caches, MUST NOT reference any
consumer project name, command prefix, or release-tag prefix in its source, and MUST
NOT assume the identity of any single consumer (it serves N ≥ 2 unrelated consumers).
Every consumer-specific input is passed in per-invocation; a default that embeds
consumer context re-couples the submodule and is a CONST-069 violation of equal
severity to a CONST-051 decoupling breach.

**Anti-bluff / test coverage (per CONST-050(B)):** a Challenge bootstraps a throwaway
consuming project, invokes the capability with consumer-supplied
fixture/prompt/sentinel/judge-config args only, and asserts (a) it runs with no
bundled defaults present and (b) grep of the submodule source finds no consumer
project name, prefix, or private-path reference. Wire evidence captured per §11.4.2.
A capability shipping any consumer-specific default, or a source grep hit for a
consumer identifier, is a CONST-069 violation.

**Cascade requirement:** This anchor (verbatim or by `CONST-069` ID reference) MUST
remain in this submodule's CONSTITUTION.md, CLAUDE.md, and AGENTS.md, and propagate
recursively to any nested owned-by-us submodule. See parent project's
`CONSTITUTION.md` §CONST-069 and constitution submodule `Constitution.md` §11.4.166
for the full mandate.
```

Notes for the reviewer:
- The header's cascade source (`§11.4.166`) is the next-free master id from §2b; if
  Phase-3 instead lands the master section at a different number, update this header
  to match — the anchor and its master section must agree.
- The verbatim-user-mandate block is omitted (framing is "optional" per the anchor
  style, and there is no captured verbatim user quote for this rule yet — inventing
  one would be a bluff). If Phase-3 elicits a verbatim user mandate, insert it as a
  `> Verbatim user mandate (DATE): *"…"*` block, matching CONST-050/051/052.

---

## 5. Landing it is a Phase-3 §11.4.49 governance task — NOT done here

Actually adopting this rule is a governance edit and MUST go through the careful
separate workflow (§11.4.49). This research pass performs **none** of these steps —
they are listed only so Phase-3 knows the shape of the work:

1. **Fetch + pull the constitution submodule first** so edits land on the current
   canonical HEAD (never edit a stale pointer). Per §11.4.32, a constitution content
   change triggers `scripts/verify-all-constitution-rules.sh` before the new HEAD is
   treated as canonical.
2. **Author the master section** `§11.4.166` in the constitution submodule, then
   **apply the cascaded `CONST-069` anchor** into every governed file
   (`CONSTITUTION.md`, `CLAUDE.md`, `AGENTS.md`, and `QWEN.md`/`GEMINI.md` where the
   cascade set requires it) across the constitution submodule, LLMsVerifier, and any
   nested owned-by-us submodule.
3. **Validate** — run the governance-cascade verifier + the full rule-gate sweep;
   confirm the anchor is present and consistent in all cascade targets and that the
   header's master-id reference matches the section actually created.
4. **Commit + push to all upstreams** (the four mirrors — GitHub, GitLab, GitFlic,
   GitVerse) per the multi-upstream push norm.
5. **Bump the submodule pointer** in each consuming project and commit the bump.
6. **Fix the design spec** `docs/superpowers/specs/2026-07-04-provider-verification-design.md`
   in the same governance pass: replace every "CONST-052 (proposed new constitution
   entry)" occurrence (§3.4, and the "codified as CONST-052" phrasing at line 149,
   plus the summary references at lines 665/685) with the chosen new id (`CONST-069` /
   `§11.4.166`), and leave the genuine CONST-052 (lowercase-snake_case) references at
   lines 151-context and 726 untouched.

Until every step above is performed by Phase-3 under §11.4.49, this remains a
**DRAFT only**. Nothing here is canonical and no rule number is reserved.
