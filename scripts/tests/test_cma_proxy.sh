#!/usr/bin/env bash
# test_cma_proxy.sh — the Go compatibility proxy (cma-proxy) build + unit tests.
#
# cma-proxy (scripts/proxy/, module cmaproxy) replaced the former per-provider
# python proxies. Its transforms are unit-tested by Go tests co-located with the
# source:
#   hermes_test.go   helixagent Hermes tool-call recovery (streaming + not),
#                    passthrough safety, </function>/</parameter>-in-value regressions
#   poe_test.go      poe tool-param injection + $ref resolve + cap + cache strip
#   kimi_test.go     kimi moonshot-flavored schema normalization
#   sarvam_test.go   sarvam content-block flatten + max_tokens tier clamp
#
# This bash test drives `go build` + `go test` so the whole proxy is covered by
# the standard suite. SKIPs (does not fail) when the Go toolchain is absent —
# same best-effort posture as the bundled ccr/proxy build.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
source "$TESTS_DIR/lib/assert.sh"
set +e

PROXY_SRC="$SCRIPTS_DIR/proxy"

if ! command -v go >/dev/null 2>&1; then
  it "go toolchain present"
  echo "  SKIP: go not on PATH — cma-proxy build/tests skipped (best-effort, like ccr)"
  summary
  exit 0
fi

it "scripts/proxy has a go.mod (module cmaproxy)"
grep -q '^module cmaproxy' "$PROXY_SRC/go.mod" 2>/dev/null
assert_eq 0 $? "go.mod declares module cmaproxy"

it "cma-proxy builds"
tmpbin="$(mktemp -d "${TMPDIR:-/tmp}/cma-proxy-test.XXXXXX")/cma-proxy"
( cd "$PROXY_SRC" && go build -o "$tmpbin" . ) 2>/dev/null
assert_eq 0 $? "go build -o <tmp> . succeeds"

it "go vet is clean"
( cd "$PROXY_SRC" && go vet ./... ) 2>/dev/null
assert_eq 0 $? "go vet ./... clean"

it "go test passes (hermes + poe + kimi + sarvam)"
tout="$( cd "$PROXY_SRC" && go test ./... 2>&1 )"; trc=$?
assert_eq 0 "$trc" "go test ./... passes"
printf '%s' "$tout" | grep -q '^ok' || printf '%s' "$tout" | grep -q 'PASS'
assert_eq 0 $? "test output reports ok/PASS"

it "gofmt is clean (no unformatted proxy sources)"
# Capture stderr into the value (2>&1, NOT suppressed) so a gofmt crash surfaces
# in the assertion instead of vacuously passing as "clean" — and so the suite's
# vacuity scanner sees a non-suppressed capture (out of scope by construction).
unformatted="$( cd "$PROXY_SRC" && gofmt -l . 2>&1 )"
assert_eq "" "$unformatted" "all .go files are gofmt-clean (and gofmt ran)"

if [ -x "$tmpbin" ]; then
  it "--has-transform gate answers for known + family + unknown providers"
  "$tmpbin" --has-transform helixagent >/dev/null 2>&1; assert_eq 0 $? "helixagent -> transform (exit 0)"
  "$tmpbin" --has-transform kimi-for-coding >/dev/null 2>&1; assert_eq 0 $? "kimi-for-coding -> kimi family (exit 0)"
  "$tmpbin" --has-transform poe2 >/dev/null 2>&1; assert_eq 0 $? "poe2 -> poe base (exit 0)"
  "$tmpbin" --has-transform no_such_provider >/dev/null 2>&1; assert_eq 1 $? "unknown provider -> no transform (exit 1)"
fi

summary
