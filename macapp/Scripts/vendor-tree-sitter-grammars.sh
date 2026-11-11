#!/usr/bin/env bash
#
# Re-vendor the tree-sitter grammars that SwiftPM can no longer take from github.com directly, into
# macapp/Packages/SyntaxHighlighting/Grammars/<repo>/.
#
# From their 0.25 releases (yaml 0.7.2), these grammars' Package.swift decide whether to compile
# `src/scanner.c` with `FileManager.default.fileExists(atPath: "src/scanner.c")`. SwiftPM evaluates
# a manifest in a directory other than the package's, under both Xcode and `swift test`, so the
# check is false, the external scanner is dropped and the link fails on
# `tree_sitter_<lang>_external_scanner_*`. Each Grammars/<repo>/Package.swift is ours and lists its
# sources outright; this script copies the upstream files it builds and records which release they
# are.
#
#   macapp/Scripts/vendor-tree-sitter-grammars.sh              # vendor every grammar at its pin
#   macapp/Scripts/vendor-tree-sitter-grammars.sh css yaml     # just these
#   macapp/Scripts/vendor-tree-sitter-grammars.sh --check      # verify each copy matches VENDOR.md
#   macapp/Scripts/vendor-tree-sitter-grammars.sh --latest     # print each repo's newest tag
#
# To bump one: change its tag in GRAMMARS below, run the script for it, and check upstream's
# Package.swift at the new tag for a changed source list, header path or C standard (copy any change
# into ours). The generated parser's ABI must stay inside the runtime's range
# (TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION in macapp/Packages/TreeSitter/lib/include). Then
# `make app-package-test` and `make app-test`.
set -euo pipefail

# <directory, = upstream repo name> <owner/repo> <tag>
GRAMMARS=(
  "tree-sitter-css tree-sitter/tree-sitter-css v0.25.0"
  "tree-sitter-javascript tree-sitter/tree-sitter-javascript v0.25.0"
  "tree-sitter-python tree-sitter/tree-sitter-python v0.25.0"
  "tree-sitter-yaml tree-sitter-grammars/tree-sitter-yaml v0.7.2"
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/SyntaxHighlighting/Grammars" && pwd)"

# The upstream paths a grammar package builds from. Everything else in the repo (grammar.js,
# grammar.json, node-types.json, the other languages' bindings, tests) stays upstream.
VENDORED=(src bindings queries LICENSE)

# One SHA-256 over every vendored file's path and content, so --check sees a changed, added or
# removed file alike.
tree_sha() { # tree_sha <grammar dir>
  (cd "$1" && find "${VENDORED[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) \
    | shasum -a 256 | awk '{print $1}'
}

mode=vendor
wanted=()
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --latest) mode=latest ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) wanted+=("$arg") ;;
  esac
done

selected() { # selected <dir>
  [[ ${#wanted[@]} -eq 0 ]] && return 0
  local w
  for w in "${wanted[@]}"; do [[ "$w" == "$1" || "tree-sitter-$w" == "$1" ]] && return 0; done
  return 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-grammars.XXXXXX")"
trap 'rm -rf "$work"' EXIT
rc=0
for entry in "${GRAMMARS[@]}"; do
  read -r dir repo tag <<<"$entry"
  selected "$dir" || continue
  dest="$ROOT/$dir"
  url="https://github.com/$repo"

  case "$mode" in
    latest)
      newest="$(git ls-remote --tags --refs "$url" | sed 's#.*refs/tags/##' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
      echo "$dir: pinned $tag, newest $newest"
      ;;
    check)
      want="$(grep -E '^- Tree SHA-256:' "$dest/VENDOR.md" 2>/dev/null | awk -F'`' '{print $2}')"
      have="$(tree_sha "$dest")"
      pinned="$(grep -E '^- Version:' "$dest/VENDOR.md" 2>/dev/null | awk -F'`' '{print $2}')"
      if [[ "$want" != "$have" ]]; then
        echo "MISMATCH $dir: manifest=$want disk=$have"; rc=1
      elif [[ "$pinned" != "$tag" ]]; then
        echo "STALE $dir: VENDOR.md says $pinned, the script pins $tag"; rc=1
      else
        echo "OK $dir $tag ($have)"
      fi
      ;;
    vendor)
      echo "→ $dir $tag"
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$url" "$work/$dir"
      commit="$(git -C "$work/$dir" rev-parse HEAD)"
      src="$work/$dir"
      [[ -f "$src/src/scanner.c" ]] || { echo "$dir $tag has no src/scanner.c" >&2; exit 1; }

      rm -rf "${VENDORED[@]/#/$dest/}"
      mkdir -p "$dest/src" "$dest/bindings/swift"
      # The parser, its scanner and anything they #include (yaml's scanner pulls in schema.*.c).
      cp "$src"/src/*.c "$dest/src/"
      cp -R "$src/src/tree_sitter" "$dest/src/"
      # The Swift module's public header, without upstream's SwiftTreeSitter test target.
      find "$src/bindings/swift" -mindepth 1 -maxdepth 1 -type d ! -name '*Tests' \
        -exec cp -R {} "$dest/bindings/swift/" \;
      cp -R "$src/queries" "$dest/"
      cp "$src/LICENSE" "$dest/LICENSE"

      {
        echo "# Vendored $dir"
        echo
        echo "\`src/\`, \`bindings/swift/\`, \`queries/\` and \`LICENSE\` are copied from upstream, unmodified."
        echo "**Do not edit them by hand.** Refresh with \`macapp/Scripts/vendor-tree-sitter-grammars.sh\`."
        echo "\`Package.swift\` is ours: upstream's probes for \`src/scanner.c\`, which SwiftPM gets wrong."
        echo
        echo "- Version: \`$tag\`"
        echo "- Commit: \`$commit\`"
        echo "- Source: $url/tree/$tag"
        echo "- Tree SHA-256: \`$(tree_sha "$dest")\`"
      } >"$dest/VENDOR.md"
      ;;
  esac
done
exit $rc
