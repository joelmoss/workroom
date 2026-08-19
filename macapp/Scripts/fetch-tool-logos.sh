#!/usr/bin/env bash
# Fetch/refresh curated tool-logo assets (issue #141). Reads Resources/tool-logos/registry.json and,
# per entry, writes an Assets.xcassets/ToolLogo-<id>.imageset from its real favicon.
#
#   macapp/Scripts/fetch-tool-logos.sh            # refresh every entry
#   macapp/Scripts/fetch-tool-logos.sh claude gh  # refresh just these ids
#
# Highest quality first: apple-touch-icon.png (typically 180x180) -> Google's public favicon proxy at
# 256px (resolves whatever a site actually declares, without this script parsing HTML) -> favicon.ico
# as a last resort.
#
# ALWAYS eyeball the fetched PNGs once before committing, against BOTH a light and a dark chip
# background — Google's proxy succeeds with a generic globe for sites it can't resolve (silently, not
# an error), and a white/dark-on-transparent icon can be effectively invisible in one theme mode. Fix
# or drop any that fail either check rather than shipping an icon nobody can see.
#
# KNOWN REGRESSION RISK — aws, mysql: their apple-touch-icon.png / proxy fetch (this script's first
# two choices) returns a technically-valid but WRONG image (a squished text banner for aws, a bad
# crop for mysql) — already hand-verified once and committed. Re-running the FULL script (no id
# filter) will silently overwrite both back to the wrong image, since a "wrong but valid" fetch looks
# identical to a correct one to this script. If you run a full refresh, re-eyeball these two
# specifically against what's already committed (`git diff` the imageset PNGs) before pushing.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$DIR/Resources/tool-logos/registry.json"
ASSETS="$DIR/WorkroomApp/Assets.xcassets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ids_filter=("$@")

wanted() {
  [[ ${#ids_filter[@]} -eq 0 ]] && return 0
  for w in "${ids_filter[@]}"; do
    [[ "$w" == "$1" ]] && return 0
  done
  return 1
}

fetch_source() {
  local id="$1" source="$2" domain
  domain="$(sed -E 's#^https?://##; s#/.*##' <<<"$source")"
  for url in "$source/apple-touch-icon.png" \
    "https://www.google.com/s2/favicons?domain=$domain&sz=256" \
    "$source/favicon.ico"; do
    # --proto '=https': a redirect can't silently downgrade to http. --max-filesize: a favicon has
    # no business being large; caps what a compromised/typosquatted faviconSource could feed sips.
    if curl -fsSL --proto '=https' --max-filesize 2M --max-time 10 "$url" -o "$TMP/$id.raw" 2>/dev/null \
      && [[ -s "$TMP/$id.raw" ]] \
      && sips -s format png "$TMP/$id.raw" --out "$TMP/$id.png" >/dev/null 2>&1; then
      echo "  $id <- $url"
      return 0
    fi
  done
  return 1
}

write_imageset() {
  local id="$1"
  local dir="$ASSETS/ToolLogo-$id.imageset"
  mkdir -p "$dir"
  sips -Z 32 "$TMP/$id.png" --out "$dir/logo_32.png" >/dev/null      # -Z: proportional, not force-square
  sips -Z 64 "$TMP/$id.png" --out "$dir/logo_32@2x.png" >/dev/null
  cat >"$dir/Contents.json" <<JSON
{
  "images" : [
    { "idiom" : "universal", "scale" : "1x", "filename" : "logo_32.png" },
    { "idiom" : "universal", "scale" : "2x", "filename" : "logo_32@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
}

# Written to a file rather than piped straight into the while loop's process substitution: under
# `set -e`, a failing process substitution does NOT propagate to the loop's exit status — a missing
# python3 or a malformed registry.json would silently produce zero rows, zero iterations, and a
# false "Done" (review finding). Checking this file explicitly turns that into a real error.
ROWS="$TMP/rows.tsv"
python3 -c '
import json, sys
for e in json.load(open(sys.argv[1])):
    i, s = e["id"], e["faviconSource"]
    print(f"{i}\t{s}")
' "$REGISTRY" >"$ROWS"
[[ -s "$ROWS" ]] || { echo "error: no rows read from $REGISTRY (missing python3, or malformed JSON?)" >&2; exit 1; }

failed=()
while IFS=$'\t' read -r id source; do
  wanted "$id" || continue
  if fetch_source "$id" "$source"; then
    write_imageset "$id"
  else
    echo "  $id: no favicon fetched" >&2
    failed+=("$id")
  fi
done <"$ROWS"

echo "Done. Eyeball the fetched PNGs under $ASSETS/ToolLogo-*.imageset before committing —"
echo "check each against BOTH a light and a dark chip background (not just \"is it the right logo\"):"
echo "Google's proxy succeeds silently with a generic globe for unresolvable domains, and some brand"
echo "art is white/dark-on-transparent and can go invisible in one theme mode."
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "warning: no logo for: ${failed[*]}" >&2
  exit 1
fi
