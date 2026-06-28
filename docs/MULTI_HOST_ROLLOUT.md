# Multi-host rollout — 2026-06-28 (v1.7.6)

Record of the four-host setup, key distribution, live provider/model detection,
and verification performed for the v1.7.6 release.

## Hosts

| Host             | OS                  | Login shell | node/npm | claude            | Role        |
|------------------|---------------------|-------------|----------|-------------------|-------------|
| nezha (local)    | Linux (alt 6.12)    | bash        | ✓        | ✓ (npm-global)    | source host |
| mistborn.local   | macOS (Darwin 24.5) | zsh         | ✗        | ✗ (no node/brew)  | remote      |
| thinker.local    | Linux (6.17)        | bash        | ✗        | ✓ (/usr/local)    | remote      |
| amber.local      | Linux (6.8)         | bash        | ✓        | ✓ (installed now) | remote      |

All hosts: user `milosvasic`, reachable by SSH **key** (no password used or stored).

## What was done

1. **Fixed the toolkit** (see CHANGELOG v1.7.6): alias-file migration corruption,
   `set -u` keys-sourcing abort, always-non-interactive execution
   (`CMA_NONINTERACTIVE` + `cma_can_prompt`), and macOS/bash-3.2 portability of the
   test harness.
2. **Distributed `~/api_keys.sh`** to every host via a **no-loss merge** — each host
   ends up with at least the source host's keys while keeping any host-local keys:
   - mistborn: +1 from source, **2 host-local keys preserved** (Kimi-Platform) → 86 keys
   - thinker: +7 from source → 84 keys
   - amber: created fresh → 84 keys
   - nezha (source): 84 keys
   Both `~/.bashrc` and `~/.zshrc` source it on every host.
3. **Installed/updated the toolkit** on all four hosts (`scripts/install.sh`,
   non-interactive) and configured `claude1` / `claude2` / `claude3` on each.
4. **Installed Claude Code** on amber (`npm i -g @anthropic-ai/claude-code`, 2.1.195).
   mistborn intentionally left without the runtime (no node/Homebrew) — toolkit,
   provider detection, and aliases are fully set up there regardless.
5. **Live provider/model detection** (`claude-providers sync`) on every host.

## Verification evidence

**Test suite — `scripts/tests/run-all.sh` (9 files):**

| Host     | Result            |
|----------|-------------------|
| nezha    | 9/9 ALL GREEN     |
| thinker  | 9/9 ALL GREEN     |
| amber    | 9/9 ALL GREEN     |
| mistborn | 9/9 ALL GREEN (bash 3.2) |

`test_export.sh` runs fully where pandoc + a PDF engine exist (nezha) and SKIPs
gracefully elsewhere.

**Live provider detection (active providers, 0 unbound errors on every host):**

| Host     | Active providers |
|----------|------------------|
| nezha    | 20               |
| mistborn | 18               |
| thinker  | 17               |
| amber    | 17               |

(Counts vary slightly by host due to live HTTP verification timing/rate limits.)

**Cross-host config check:** both rc files source `api_keys.sh`; `claude1/2/3` and the
`poe` / `deepseek` / `xiaomi` provider aliases are present on all four hosts.

## Notes / follow-ups

- The user's `~/api_keys.sh` contains a dangling reference
  (`export SARVAM_API_KEY=$ApiKey_Sarvam_AI_India`). The toolkit now tolerates this
  (sources keys with `nounset` disabled), but defining or removing that line in the
  keys file would be cleaner.
- mistborn has no Claude runtime (no node/Homebrew). Install node (e.g. via Homebrew
  or nvm) then `npm i -g @anthropic-ai/claude-code` to enable launching aliases there.
- Remotes were provisioned by rsync of the verified working tree; they can be switched
  to `git pull` checkouts of the released tag at any time.
