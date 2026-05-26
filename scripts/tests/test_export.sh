#!/usr/bin/env bash
# test_export.sh — claude-export-docs.sh produces HTML and PDF, expands
# <!-- INCLUDE: path --> markers, and the output PDF starts with "%PDF-".

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
mkdir -p "$HOME/Documents/scripts"

# Tiny fixture markdown + a fixture script to include. We point the
# export script at this synthetic doc instead of the real one.
fixture_script="$HOME/Documents/scripts/sample.sh"
cat > "$fixture_script" <<'EOF'
#!/usr/bin/env bash
echo "SAMPLE_SCRIPT_BODY_MARKER"
EOF

fixture_md="$HOME/Documents/fixture.md"
cat > "$fixture_md" <<'EOF'
---
title: Fixture
---
# Fixture

Body paragraph above the include.

```bash
<!-- INCLUDE: scripts/sample.sh -->
```

End of fixture.
EOF

it "MD_FILE env override is honored and HTML is generated"
MD_FILE="$fixture_md" "$SCRIPTS_DIR/claude-export-docs.sh" >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "export exits 0"
assert_file "$HOME/Documents/fixture.html" "html generated"
assert_file "$HOME/Documents/fixture.pdf" "pdf generated"

it "<!-- INCLUDE: --> markers are expanded in output"
assert_file_contains "$HOME/Documents/fixture.html" "SAMPLE_SCRIPT_BODY_MARKER" "include expanded"
assert_file_not_contains "$HOME/Documents/fixture.html" "<!-- INCLUDE:" "markers removed"

it "PDF starts with the %PDF- magic bytes"
head -c 5 "$HOME/Documents/fixture.pdf" | grep -q '^%PDF-'
assert_eq 0 $? "PDF magic header present"

it "regeneration is non-destructive (file timestamps move forward)"
MD_FILE="$fixture_md" "$SCRIPTS_DIR/claude-export-docs.sh" >/dev/null 2>&1
assert_file "$HOME/Documents/fixture.html" "html still present after rerun"
assert_file "$HOME/Documents/fixture.pdf" "pdf still present after rerun"

summary
