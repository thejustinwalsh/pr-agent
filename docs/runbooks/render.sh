#!/usr/bin/env bash
# Render each runbook .md to a single self-contained .html (inline CSS; SVGs inlined).
# Usage: bash docs/runbooks/render.sh
# Requires: pandoc (preferred) or falls back to a minimal pre-escaped HTML wrapper.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

CSS='<style>
body{max-width:46rem;margin:2rem auto;padding:0 1rem;font:16px/1.6 system-ui,sans-serif;color:#111}
pre{background:#f5f5f5;padding:.8rem;border-radius:6px;overflow:auto}
code{font-family:ui-monospace,monospace;font-size:.9em}
pre code{font-size:.85em}
h1{border-bottom:2px solid #e0e0e0;padding-bottom:.4rem}
h2{margin-top:2rem;border-bottom:1px solid #eee;padding-bottom:.2rem}
h3{margin-top:1.5rem}
h1,h2,h3{line-height:1.2}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ddd;padding:.4rem .7rem;text-align:left}
th{background:#f5f5f5}
.warn{background:#fff3f3;border-left:4px solid #c00;padding:.6rem 1rem;margin:1rem 0}
blockquote{border-left:4px solid #ccc;margin:0;padding:.5rem 1rem;background:#fafafa}
img,svg{max-width:100%}
</style>'

if command -v pandoc >/dev/null 2>&1; then
  for md in "$HERE"/*.md; do
    base="$(basename "$md" .md)"
    # Run pandoc from the runbooks directory so relative image paths (diagrams/*.svg) resolve.
    (
      cd "$HERE"
      pandoc \
        --embed-resources \
        --standalone \
        --metadata title="$base" \
        -H <(printf '%s' "$CSS") \
        "$base.md" \
        -o "$base.html"
    )
    echo "rendered $HERE/$base.html"
  done
else
  # Fallback: minimal self-contained wrapper with the raw markdown in a <pre>.
  # Produces a valid, dependency-free file even without pandoc.
  echo "WARNING: pandoc not found; using plain-text fallback (install pandoc for proper rendering)" >&2
  for md in "$HERE"/*.md; do
    base="$(basename "$md" .md)"
    {
      printf '<!doctype html><meta charset=utf-8><title>%s</title>\n' "$base"
      printf '%s\n' "$CSS"
      printf '<h1>%s</h1><pre style="white-space:pre-wrap">\n' "$base"
      sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$md"
      printf '</pre>\n'
    } > "$HERE/$base.html"
    echo "rendered $HERE/$base.html (plain fallback)"
  done
fi

echo "done — runbooks rendered"
