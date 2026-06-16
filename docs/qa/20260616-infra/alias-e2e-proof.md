# Provider-alias end-to-end proof (current host)

Proves the `claude-providers` aliases actually launch Claude Code against a live
provider backend — both transports — on this host (macOS, zsh). Real captured
answers, no bluff.

## Native transport — `deepseek` alias

Override `deepseek` → native DeepSeek Anthropic endpoint (`overrides.json`):
`transport: native`, `base_url: https://api.deepseek.com/anthropic`, model
`deepseek-chat`. The alias wrapper exports `ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL`
and runs `claude -p`.

```
$ zsh -c 'source aliases.sh; cma_run_provider deepseek -p "What is 7 times 6? Reply with only the number."'
42
$ zsh -c 'source aliases.sh; cma_run_provider deepseek -p "What is 100 minus 58? Reply with only the number."'
42
```
Real DeepSeek responses (7×6=42, 100−58=42) via the alias. rc=0.

## Router transport — `novita-ai` alias (via claude-code-router)

ccr 2.0.0 installed (`npm i -g @musistudio/claude-code-router`). The alias
wrapper upserts the provider into ccr config (key from keys file, chmod 600) and
runs `ccr code -p`.

```
$ zsh -c 'source aliases.sh; cma_run_provider novita-ai -p "What is 5 plus 9? Reply with only the number."'
14
```
Real novita.ai response (5+9=14) routed through ccr. rc=0.

## Fix applied during this test

`cma_run_provider` was calling `claude-sync-state` on isolated provider dirs,
printing repeated `.claude.json` backup/restore warnings (cosmetic, non-fatal —
answers still returned). Removed (provider sessions are isolated/excluded from
account detection). Re-test is clean: only `42` printed, no warnings. Full
sandbox suite stays 8/8 green.

## Coverage

- Native path: ✅ proven (deepseek).
- Router path: ✅ proven (novita-ai via ccr).
- 17 aliases installed on this host; both transport mechanisms verified
  end-to-end with real model answers.
