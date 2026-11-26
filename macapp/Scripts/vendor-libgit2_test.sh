#!/bin/sh
#
# `vendor-libgit2.sh --latest` against a local repository standing in for upstream: a `newer:` line
# for a newer release on the pinned line and for a newer release line, none when the pin is the
# newest, pre-releases ignored, and a failure (not a silent "up to date") when the tags can't be
# listed. Offline: LIBGIT2_REPO points the script at the local repository.
#
# Run: sh macapp/Scripts/vendor-libgit2_test.sh.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/macapp/Scripts/vendor-libgit2.sh"
pinned="$(grep -E '^- Version:' "$ROOT/macapp/Packages/LibGit2/VENDOR.md" | awk -F'`' '{print $2}')"
# vMAJOR.MINOR.PATCH → the next patch and the next major.
next_patch="$(echo "$pinned" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"
next_major="v$(echo "$pinned" | sed -E 's/^v([0-9]+)\..*/\1/' | awk '{print $1 + 1}').0.0"

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-libgit2-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q "$work/upstream"
git -C "$work/upstream" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m c

fails=0
latest() { LIBGIT2_REPO="$work/upstream" "$SCRIPT" --latest 2>&1; }
expect() { # description, command output, grep -E pattern, want (present|absent)
  if printf '%s\n' "$2" | grep -qE "$3"; then got=present; else got=absent; fi
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1 (wanted $3 $4)"; printf '%s\n' "$2"; fails=$((fails + 1)); fi
}

git -C "$work/upstream" tag "$pinned"
git -C "$work/upstream" tag v2.0.0-rc.1
out="$(latest)"
expect "the pin is the newest: no newer line" "$out" '^newer:' absent
expect "a pre-release is not a release" "$out" 'rc\.1' absent

git -C "$work/upstream" tag "$next_patch"
out="$(latest)"
expect "a newer patch on the pinned line is flagged" "$out" "^newer: libgit2 $next_patch is out" present
expect "it says how to vendor it" "$out" "LIBGIT2=$next_patch macapp/Scripts/vendor-libgit2.sh" present
expect "no new release line yet" "$out" 'new release line' absent

git -C "$work/upstream" tag "$next_major"
out="$(latest)"
expect "a new release line is flagged" "$out" "^newer: libgit2 $next_major is out, a new release line" present
expect "the newer patch is still flagged beside it" "$out" "^newer: libgit2 $next_patch is out" present

if LIBGIT2_REPO="$work/nowhere" "$SCRIPT" --latest >/dev/null 2>&1; then
  echo "FAIL an unreachable repository fails"; fails=$((fails + 1))
else
  echo "ok   an unreachable repository fails"
fi

# Re-vendoring replaces libgit2/ only when it is exactly what the script last wrote. Each case runs
# on a copy of the package with an unreachable upstream: a tree that passes the check gets as far
# as the clone and fails there with nothing touched; a refused one stops before it, keeping what
# is there.
fresh_copy() {
  rm -rf "$work/copy"
  mkdir -p "$work/copy/macapp/Scripts" "$work/copy/macapp/Packages/LibGit2"
  cp "$SCRIPT" "$work/copy/macapp/Scripts/"
  cp -R "$ROOT/macapp/Packages/LibGit2/libgit2" "$ROOT/macapp/Packages/LibGit2/VENDOR.md" \
    "$work/copy/macapp/Packages/LibGit2/"
}
revendor() { LIBGIT2_REPO="$work/nowhere" "$work/copy/macapp/Scripts/vendor-libgit2.sh" 2>&1; }
lib="$work/copy/macapp/Packages/LibGit2/libgit2"

fresh_copy
out="$(revendor)"
expect "an unchanged tree passes the ownership check" "$out" 'Not replacing' absent
if [ -f "$lib/COPYING" ]; then echo "ok   a failed download deletes nothing"; else
  echo "FAIL a failed download deleted the tree"; fails=$((fails + 1))
fi

fresh_copy
printf '/* local relink patch */\n' >>"$lib/deps/xdiff/xdiff.h"
out="$(revendor)"
expect "a locally edited file is refused" "$out" 'differs from the tree VENDOR.md records' present
if grep -q 'local relink patch' "$lib/deps/xdiff/xdiff.h"; then echo "ok   the edit survives"; else
  echo "FAIL the edit was lost"; fails=$((fails + 1))
fi

fresh_copy
printf 'mine\n' >"$lib/NOTES.txt"
expect "a stray file is refused" "$(revendor)" 'Not replacing' present

fresh_copy
ln -s /etc/hosts "$lib/link"
expect "a symlink is refused, not followed" "$(revendor)" 'neither a file nor a directory' present

fresh_copy
rm "$work/copy/macapp/Packages/LibGit2/VENDOR.md"
expect "a tree with no VENDOR.md is refused" "$(revendor)" 'no VENDOR.md' present

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
