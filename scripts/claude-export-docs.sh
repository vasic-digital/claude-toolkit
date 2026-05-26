#!/usr/bin/env bash
# claude-export-docs.sh — Convert the multi-account markdown doc to
# matching .html and .pdf siblings. Re-runnable; overwrites outputs.
#
# Order of preference for PDF: pandoc + weasyprint > pandoc + wkhtmltopdf
# > chromium --headless print-to-pdf > weasyprint on the generated HTML.
# HTML always uses pandoc with a self-contained option so the file is
# portable without external CSS/JS.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

DOC_DIR="${DOC_DIR:-$HOME/Documents}"
MD_FILE="${MD_FILE:-$DOC_DIR/Claude_Multi_Account_Fine_Tuning.md}"
HTML_FILE="${MD_FILE%.md}.html"
PDF_FILE="${MD_FILE%.md}.pdf"

[[ -f "$MD_FILE" ]] || cma_die "markdown not found: $MD_FILE"
cma_require pandoc

# --- Preprocess: expand `<!-- INCLUDE: relative/path -->` markers ---
# These markers, placed inside a fenced code block in the source markdown,
# get replaced with the contents of the referenced file (relative to the
# directory containing the markdown). That keeps the .md small while the
# generated HTML/PDF stays self-contained.
PROCESSED_MD="$(mktemp --suffix=.md)"
trap 'rm -f "$PROCESSED_MD"' EXIT

awk -v base="$(dirname "$MD_FILE")" '
  /<!-- INCLUDE: / {
    match($0, /INCLUDE: ([^ ]+) -->/, m)
    if (m[1] != "") {
      path = m[1]
      if (path !~ /^\//) path = base "/" path
      while ((getline line < path) > 0) print line
      close(path)
      next
    }
  }
  { print }
' "$MD_FILE" > "$PROCESSED_MD"

# --- HTML ---
# --standalone makes a complete HTML doc (head/body), --embed-resources
# inlines CSS/JS/images so the file is self-contained.
cma_log "rendering HTML -> $HTML_FILE"
pandoc \
  --from=gfm+yaml_metadata_block \
  --to=html5 \
  --standalone \
  --embed-resources \
  --toc --toc-depth=3 \
  --highlight-style=tango \
  --metadata title="Claude Multi-Account Fine Tuning" \
  -o "$HTML_FILE" \
  "$PROCESSED_MD"

# --- PDF ---
cma_log "rendering PDF -> $PDF_FILE"

render_pdf_via_pandoc_engine() {
  local engine="$1"
  command -v "$engine" >/dev/null 2>&1 || return 1
  pandoc \
    --from=gfm+yaml_metadata_block \
    --pdf-engine="$engine" \
    --toc --toc-depth=3 \
    --highlight-style=tango \
    -V geometry:margin=0.9in \
    -V mainfont="DejaVu Serif" \
    -V monofont="DejaVu Sans Mono" \
    --metadata title="Claude Multi-Account Fine Tuning" \
    -o "$PDF_FILE" \
    "$PROCESSED_MD"
}

render_pdf_via_chromium() {
  local engine
  for engine in chromium chromium-browser google-chrome chrome; do
    if command -v "$engine" >/dev/null 2>&1; then
      # Use the freshly generated HTML so styling matches.
      "$engine" --headless --no-sandbox --disable-gpu \
        --print-to-pdf="$PDF_FILE" \
        --print-to-pdf-no-header \
        "file://$HTML_FILE" >/dev/null 2>&1
      return $?
    fi
  done
  return 1
}

render_pdf_via_weasyprint_on_html() {
  command -v weasyprint >/dev/null 2>&1 || return 1
  weasyprint "$HTML_FILE" "$PDF_FILE"
}

# Try engines in order; the first that succeeds wins.
if render_pdf_via_pandoc_engine weasyprint 2>/dev/null; then
  cma_log "pdf engine: weasyprint (via pandoc)"
elif render_pdf_via_pandoc_engine wkhtmltopdf 2>/dev/null; then
  cma_log "pdf engine: wkhtmltopdf (via pandoc)"
elif render_pdf_via_weasyprint_on_html 2>/dev/null; then
  cma_log "pdf engine: weasyprint on html"
elif render_pdf_via_chromium 2>/dev/null; then
  cma_log "pdf engine: chromium headless"
else
  cma_die "no usable PDF engine. Install one of: weasyprint, wkhtmltopdf, chromium."
fi

ls -lh "$HTML_FILE" "$PDF_FILE"
