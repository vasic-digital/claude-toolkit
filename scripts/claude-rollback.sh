#!/usr/bin/env bash
# claude-rollback.sh — Convenience wrapper that calls claude-unify.sh with
# --rollback. Restores every .preunify.<timestamp> backup created by the
# unification run and archives the shared store out of the way.
#
# After this you can re-run install.sh to start over from scratch.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$LIB_DIR/claude-unify.sh" --rollback "$@"
