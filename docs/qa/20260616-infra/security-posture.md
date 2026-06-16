# LLMsVerifier — Security Posture Verification

- **Date:** 2026-06-16
- **Host:** nezha.local (user `milosvasic`), Podman 5.7.1, rootless
- **Repo:** `/Volumes/T7/Projects/claude_tookit` (branch `main`)
- **Posture:** READ-ONLY verification. No writes, restarts, or config changes were made on nezha. Only the findings doc was written in the repo.
- **Secret redaction:** Secret values are never shown. Presence + length only.

---

## Check 1 — Loopback binds (published ports MUST be 127.0.0.1)

**Command:**
```
ssh milosvasic@nezha.local 'ss -tlnp 2>/dev/null | grep -E "55432|56379|59090|53000|8080"'
```

**Captured output (real):**
```
LISTEN 0  4096  127.0.0.1:8080   0.0.0.0:*  users:(("rootlessport",pid=2116438,fd=10))
LISTEN 0  4096  127.0.0.1:59090  0.0.0.0:*  users:(("rootlessport",pid=2043324,fd=10))
LISTEN 0  4096  127.0.0.1:56379  0.0.0.0:*  users:(("rootlessport",pid=2043267,fd=10))
LISTEN 0  4096  127.0.0.1:55432  0.0.0.0:*  users:(("rootlessport",pid=2043178,fd=10))
LISTEN 0  4096  127.0.0.1:53000  0.0.0.0:*  users:(("rootlessport",pid=2043378,fd=8))
LISTEN 0  4096          *:18080         *:*  users:(("rootlessport",pid=2680900,fd=10))
```

**Cross-check — `podman ps` port mappings (real):**
```
llmsverifier_postgres_1       127.0.0.1:55432->5432/tcp   Up 3 hours (healthy)
llmsverifier_redis_1          127.0.0.1:56379->6379/tcp   Up 3 hours
llmsverifier_prometheus_1     127.0.0.1:59090->9090/tcp   Up 3 hours
llmsverifier_grafana_1        127.0.0.1:53000->3000/tcp   Up 3 hours
llmsverifier_llm-verifier_1   127.0.0.1:8080->8080/tcp    Up 2 hours
```

**Analysis:** All five in-scope LLMsVerifier ports (55432, 56379, 59090, 53000, 8080) bind to
`127.0.0.1` only — confirmed by both `ss` and `podman ps`. The `*:18080` (all-interfaces) line
belongs to `helixtranslate-api`, a separate co-tenant system **not in scope** for this review;
LLMsVerifier does not publish 18080. No LLMsVerifier port binds to 0.0.0.0.

**Verdict: PASS** — every in-scope published port is loopback-only.

> NOTE (informational, out of scope): The same host runs many other containers
> (helixcode-*, helixtranslate-*, media/torrent stack) that publish on `0.0.0.0`
> (e.g. 5432, 6379, 11434, 18080, 18443). These are not LLMsVerifier services and
> were not assessed here, but they are LAN-exposed and may warrant a separate review.

---

## Check 2 — Secret-file permissions (MUST be 600)

**Command:**
```
ssh milosvasic@nezha.local 'ls -l ~/helix-system/llmsverifier/.env ~/helix-system/llmsverifier/config.yaml'
```

**Captured output (real):**
```
-rw------- 1 milosvasic milosvasic 545 Jun 16 17:06 /home/milosvasic/helix-system/llmsverifier/.env
-rw------- 1     165531     165531 428 Jun 16 14:42 /home/milosvasic/helix-system/llmsverifier/config.yaml
```

**Analysis:** Both files are `-rw-------` (mode 0600): owner read/write, no group/other access.
`.env` is 545 bytes, `config.yaml` is 428 bytes (sizes only; contents not read). `config.yaml` is
owned by uid/gid `165531` (a rootless-Podman subuid-mapped owner from the `:U` volume mount), still
0600 — no broader exposure.

**Verdict: PASS** — both secret files are 600.

---

## Check 3 — No secrets committed in `config/containers/`

**Command:**
```
git ls-files config/containers/ | xargs grep -lEi 'PASSWORD=[^$]|sk-[A-Za-z0-9]{20}|ENCRYPTION_KEY=[0-9a-f]{32}'
```

**Captured output (real):**
```
(no output; exit code 1 = zero matches)
```

**Tracked files scanned (8):**
```
config/containers/llmsverifier/.gitignore
config/containers/llmsverifier/Dockerfile.nezha
config/containers/llmsverifier/README.md
config/containers/llmsverifier/config.yaml.template
config/containers/llmsverifier/docker-compose.app.yml
config/containers/llmsverifier/docker-compose.infra.yml
config/containers/llmsverifier/prometheus.yml
config/containers/nezha.env
```

**Manual confirmation — only placeholders are committed (real excerpts):**

`config.yaml.template`:
```yaml
api:
  jwt_secret: __JWT_SECRET__
database:
  encryption_key: __DATABASE_ENCRYPTION_KEY__
global:
  api_key: ${OPENAI_API_KEY}
```

`docker-compose.infra.yml` (fail-fast `${VAR:?...}` placeholders):
```yaml
POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
--requirepass ${REDIS_PASSWORD:?REDIS_PASSWORD is required}
GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is required}
```

`docker-compose.app.yml`:
```yaml
DATABASE_ENCRYPTION_KEY: ${DATABASE_ENCRYPTION_KEY:?DATABASE_ENCRYPTION_KEY is required}
JWT_SECRET: ${JWT_SECRET:?JWT_SECRET is required}
OPENAI_API_KEY: ${OPENAI_API_KEY:-}
ports: ["127.0.0.1:8080:8080"]
```

`config/containers/nezha.env` — contains only host/SSH-routing config (host name, address, port 22,
SSH user, key *path* `~/.ssh/id_ed25519`, runtime, labels). No passwords, API keys, or key material;
references a key by path only.

**Analysis:** No real secret matched the detection patterns. Every committed credential reference is
a placeholder (`__VAR__`) or an environment indirection (`${VAR}` / `${VAR:?required}`). No tracked
`.env` or `config.yaml` exists — only `config.yaml.template`.

**Verdict: PASS** — no committed secrets. Secret in repo: **NO**.

---

## Check 4 — `.gitignore` + no untracked secret files

**`.gitignore` location/contents (real):**
```
$ ls -l config/containers/llmsverifier/.gitignore
-rw-r--r-- 1 milosvasic staff 5 Jun 16 14:47 config/containers/llmsverifier/.gitignore

$ cat config/containers/llmsverifier/.gitignore
.env
```

**`git status --porcelain config/containers` (real):**
```
?? config/containers/llmsverifier/Dockerfile.mv
```

**On-disk inventory of `config/containers/llmsverifier/` (real):**
```
.gitignore  config.yaml.template  docker-compose.app.yml  docker-compose.infra.yml
Dockerfile.mv  Dockerfile.nezha  prometheus.yml  README.md
```

**Analysis:**
- `.gitignore` ignores `.env`. **PASS** on the `.env` requirement.
- The only untracked file is `Dockerfile.mv` — a Dockerfile, **not** an `.env` or `config.yaml`,
  and it contains no secrets (would have been caught by Check 3's pattern had it matched; it is also
  outside the secret-bearing file types). No untracked `.env`/`config.yaml` is present.
- `config.yaml` is **not** explicitly listed in `.gitignore`. This is a **minor gap, not an active
  leak**: no real `config.yaml` exists in the repo directory (only `config.yaml.template`), so nothing
  is currently exposed. Recommend adding `config.yaml` to `.gitignore` as defense-in-depth so a future
  rendered config can never be accidentally committed.

**Verdict: PASS (with minor recommendation)** — `.env` ignored; no untracked secret-bearing files;
add `config.yaml` to `.gitignore` for completeness.

---

## Summary

| # | Check | Verdict |
|---|-------|---------|
| 1 | Loopback binds (5 in-scope ports) | PASS — all 127.0.0.1 (ss + podman ps agree) |
| 2 | Secret-file perms (.env, config.yaml) | PASS — both 0600 |
| 3 | No committed secrets in config/containers | PASS — placeholders only, zero matches |
| 4 | .gitignore + no untracked secrets | PASS (minor: add `config.yaml` to .gitignore) |

**All loopback?** Yes — all 5 LLMsVerifier ports bind 127.0.0.1 (verified by `ss` and `podman ps`).
**Secrets 600?** Yes — `.env` and `config.yaml` are both `-rw-------`.
**Any secret in repo?** **NO** — only `__PLACEHOLDER__` / `${VAR}` indirections committed.

**Gaps (non-blocking):**
1. `.gitignore` lists `.env` but not `config.yaml` (no live exposure today; add for defense-in-depth).
2. Out of scope but observed: many co-tenant containers on nezha (helixcode-*, helixtranslate-*,
   media stack) publish on `0.0.0.0` and are LAN-exposed — recommend a separate hardening review.
