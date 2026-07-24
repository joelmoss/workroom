#!/usr/bin/env bash
#
# Re-vendor the Markdown-preview web libraries into macapp/Resources/markdown/.
#
# The preview (MarkdownWebView + template.html) renders UNTRUSTED workroom Markdown, so DOMPurify is
# security-critical and must be kept current. These libs were originally hand-dropped with no record
# of version or source; this script is that record + the refresh path.
#
#   macapp/Scripts/vendor-markdown.sh                 # bump all three to latest, rewrite VENDOR.md
#   macapp/Scripts/vendor-markdown.sh --check         # verify on-disk files match VENDOR.md checksums
#   DOMPURIFY=3.4.11 MARKED=18.0.5 MERMAID=11.16.0 \
#     macapp/Scripts/vendor-markdown.sh               # pin explicit versions
#
# After a bump: `make app-build` and visually QA a doc with a GFM table, a task list, and a
# ```mermaid diagram in preview mode — major bumps (marked, mermaid) can change rendering.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Resources/markdown" && pwd)"
CDN="https://cdn.jsdelivr.net/npm"
DATA="https://data.jsdelivr.com/v1/packages/npm"
MANIFEST="$DIR/VENDOR.md"

# pkg | jsdelivr path within the package | local filename
LIBS=(
  "dompurify|dist/purify.min.js|dompurify.min.js"
  "marked|lib/marked.umd.min.js|marked.min.js"
  "mermaid|dist/mermaid.min.js|mermaid.min.js"
)

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

resolve() { # pkg -> exact latest version (via jsdelivr resolve API)
  curl -fsSL "$DATA/$1/resolved" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])'
}

env_pin() { # pkg -> value of matching env override, or empty
  case "$1" in
    dompurify) echo "${DOMPURIFY:-}" ;;
    marked) echo "${MARKED:-}" ;;
    mermaid) echo "${MERMAID:-}" ;;
  esac
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -f "$MANIFEST" ]] || { echo "no VENDOR.md — run without --check first"; exit 1; }
  fail=0
  for row in "${LIBS[@]}"; do
    IFS='|' read -r pkg _ file <<<"$row"
    want="$(grep -E "^\| \`$file\`" "$MANIFEST" | awk -F'`' '{print $4}')"
    have="$(sha "$DIR/$file")"
    if [[ "$want" != "$have" ]]; then
      echo "MISMATCH $file: manifest=$want disk=$have"; fail=1
    else
      echo "OK $file ($have)"
    fi
  done
  exit "$fail"
fi

{
  echo "# Vendored Markdown-preview libraries"
  echo
  echo "Bundled into this directory and loaded offline by \`template.html\` (see \`MarkdownWebView.swift\`)."
  echo "**Do not edit these files by hand.** Refresh with \`macapp/Scripts/vendor-markdown.sh\`."
  echo "DOMPurify sanitizes untrusted Markdown before it hits the DOM, so keep it current."
  echo
  echo "\`mermaid.min.js\` is the exception: it is NOT in \`template.html\`. At 3.4 MB it was ~104 ms of"
  echo "the ~117 ms script parse on every Markdown open (8-10 ms without it), so \`render.js\` injects it"
  echo "on demand, the first time a document actually contains a \\\`\\\`\\\`mermaid fence."
  echo
  echo "| File | Package | Version | SHA-256 | Source |"
  echo "|------|---------|---------|---------|--------|"
} >"$MANIFEST.tmp"

for row in "${LIBS[@]}"; do
  IFS='|' read -r pkg path file <<<"$row"
  ver="$(env_pin "$pkg")"; [[ -n "$ver" ]] || ver="$(resolve "$pkg")"
  url="$CDN/$pkg@$ver/$path"
  echo "→ $pkg@$ver  ($url)"
  curl -fsSL "$url" -o "$DIR/$file"
  echo "| \`$file\` | $pkg | $ver | \`$(sha "$DIR/$file")\` | $url |" >>"$MANIFEST.tmp"
done

mv "$MANIFEST.tmp" "$MANIFEST"
echo "wrote $MANIFEST"
