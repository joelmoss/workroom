#!/usr/bin/env bash
#
# Re-vendor the tree-sitter C runtime into macapp/Packages/TreeSitter/lib/.
#
# Upstream dropped its Package.swift in 0.27.0 (tree-sitter 277f53f8), so SwiftPM can no longer
# take the runtime from github.com directly. We build it ourselves from a vendored copy of the
# upstream `lib/include` and `lib/src`; this script is the record of which release that copy is,
# and the refresh path.
#
#   macapp/Scripts/vendor-tree-sitter.sh                    # bump to the latest release tag
#   TREE_SITTER=v0.27.2 macapp/Scripts/vendor-tree-sitter.sh  # pin an explicit tag
#   macapp/Scripts/vendor-tree-sitter.sh --check            # verify lib/ matches VENDOR.md
#
# After a bump: compare the defines and C standard in upstream's Makefile with the TreeSitter
# target in Package.swift, check TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION in
# lib/include/tree_sitter/api.h still covers the grammar ABIs (TreeSitterRuntimeTests asserts it),
# then `make app-package-test` and `make app-test`.
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/TreeSitter" && pwd)"
LIB="$PKG/lib"
MANIFEST="$PKG/VENDOR.md"
REPO="https://github.com/tree-sitter/tree-sitter"

# One SHA-256 over every vendored file's path and content, so --check sees a changed, added or
# removed file alike.
tree_sha() {
  (cd "$PKG" && find lib -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) \
    | shasum -a 256 | awk '{print $1}'
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -f "$MANIFEST" ]] || { echo "no VENDOR.md; run without --check first"; exit 1; }
  want="$(grep -E '^- Tree SHA-256:' "$MANIFEST" | awk -F'`' '{print $2}')"
  have="$(tree_sha)"
  if [[ "$want" != "$have" ]]; then
    echo "MISMATCH lib/: manifest=$want disk=$have"; exit 1
  fi
  echo "OK lib/ ($have)"
  exit 0
fi

tag="${TREE_SITTER:-}"
if [[ -z "$tag" ]]; then
  tag="$(git ls-remote --tags --refs "$REPO" | sed 's#.*refs/tags/##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-tree-sitter.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "→ tree-sitter $tag"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$REPO" "$work/ts"
commit="$(git -C "$work/ts" rev-parse HEAD)"

rm -rf "$LIB"
mkdir -p "$LIB"
cp -R "$work/ts/lib/include" "$work/ts/lib/src" "$LIB/"
cp "$work/ts/LICENSE" "$LIB/LICENSE"

{
  echo "# Vendored tree-sitter runtime"
  echo
  echo "\`lib/\` is upstream's \`lib/include\` and \`lib/src\` plus its \`LICENSE\`, unmodified."
  echo "**Do not edit these files by hand.** Refresh with \`macapp/Scripts/vendor-tree-sitter.sh\`."
  echo
  echo "- Version: \`$tag\`"
  echo "- Commit: \`$commit\`"
  echo "- Source: $REPO/tree/$tag/lib"
  echo "- Tree SHA-256: \`$(tree_sha)\`"
} >"$MANIFEST"
echo "wrote $MANIFEST"
