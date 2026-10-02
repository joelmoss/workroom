#!/bin/sh
#
# Dependency-free test for dev-identity.sh. No toolchain — just sh.
# Run: sh macapp/Scripts/dev-identity_test.sh   (exits non-zero on any mismatch).
#
# Pins the two promises the script makes: the project's own checkout keeps the canonical
# `com.developwithstyle.workroom.dev` (no suffix), and every workroom — a linked git worktree — gets
# a suffix that is a valid bundle-id component, stable for its path and distinct from every other
# checkout's.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/dev-identity.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dev-identity-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0

identity() { sh "$SCRIPT" "$1"; }

# checkout <path> <kind>: fake the VCS metadata `workroom create` leaves behind.
checkout() {
  mkdir -p "$1"
  case "$2" in
    git-main) mkdir -p "$1/.git" ;;
    git-worktree) echo "gitdir: /repo/.git/worktrees/x" >"$1/.git" ;;
    none) ;;
  esac
}

expect_none() {
  got="$(identity "$1")"
  status=$?
  # The status matters as much as the output: "prints nothing" and "fails" both leave stdout empty,
  # and the Makefile takes this suffix from a command substitution, so a non-zero exit here is a
  # broken build rather than a canonical identity. Asserting only emptiness passed either way.
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $2 should exit 0 for the canonical identity, exited $status"
    fails=$((fails + 1))
  fi
  if [ -n "$got" ]; then
    echo "FAIL: $2 should keep the canonical identity (no suffix), got '$got'"
    fails=$((fails + 1))
  fi
}

# expect_suffix <path> <wanted name part> <description>
expect_suffix() {
  got="$(identity "$1")"
  case "$got" in
    ".wr-$2-"??????) ;;
    *)
      echo "FAIL: $3: want '.wr-$2-<6 hex>', got '$got'"
      fails=$((fails + 1))
      return
      ;;
  esac
  # One bundle-id component: [a-z0-9-] after the leading dot, never empty, never a second dot.
  if ! printf '%s' "$got" | grep -Eq '^\.[a-z0-9-]+$'; then
    echo "FAIL: $3: '$got' is not a single valid bundle-id component"
    fails=$((fails + 1))
  fi
}

checkout "$TMP/project" git-main
expect_none "$TMP/project" "a git repository's main checkout"
checkout "$TMP/unversioned" none
expect_none "$TMP/unversioned" "a directory with no VCS metadata"

checkout "$TMP/workrooms/brave-otter" git-worktree
expect_suffix "$TMP/workrooms/brave-otter" "brave-otter" "a git worktree"

# Sanitised into one lower-case component.
checkout "$TMP/workrooms/Fix Login_Flow.v2" git-worktree
expect_suffix "$TMP/workrooms/Fix Login_Flow.v2" "fix-login-flow-v2" "a name needing sanitising"
checkout "$TMP/workrooms/--edge--" git-worktree
expect_suffix "$TMP/workrooms/--edge--" "edge" "leading and trailing separators"

# Capped at 20 characters of name, without a dangling hyphen at the cut.
checkout "$TMP/workrooms/abcdefghijklmnopqrs-uvwxyz" git-worktree
expect_suffix "$TMP/workrooms/abcdefghijklmnopqrs-uvwxyz" "abcdefghijklmnopqrs" \
  "a long name cut at a separator"

# The whole suffix must fit the session socket's /tmp fallback,
# `/tmp/workroom-<uid>-com.developwithstyle.workroom.dev<suffix>/session.sock`, inside sun_path's
# 104 bytes (NUL included) even for a ten-digit uid — nothing checks that path's length at runtime.
checkout "$TMP/workrooms/$(printf 'n%.0s' $(seq 1 60))" git-worktree
longest="$(identity "$TMP/workrooms/$(printf 'n%.0s' $(seq 1 60))")"
fallback="/tmp/workroom-4294967295-com.developwithstyle.workroom.dev$longest/session.sock"
if [ "${#fallback}" -gt 103 ]; then
  echo "FAIL: suffix '$longest' makes the socket fallback ${#fallback} bytes, over sun_path's 103"
  fails=$((fails + 1))
fi

# A name with nothing usable still gets a unique suffix.
checkout "$TMP/workrooms/___" git-worktree
got="$(identity "$TMP/workrooms/___")"
case "$got" in
  .wr-??????) ;;
  *) echo "FAIL: a name with nothing usable: want '.wr-<6 hex>', got '$got'"; fails=$((fails + 1)) ;;
esac

# Same name, different path: different identities. Same path: the same identity, every time.
checkout "$TMP/elsewhere/brave-otter" git-worktree
a="$(identity "$TMP/workrooms/brave-otter")"
b="$(identity "$TMP/elsewhere/brave-otter")"
if [ "$a" = "$b" ]; then
  echo "FAIL: two checkouts named brave-otter share the identity '$a'"
  fails=$((fails + 1))
fi
if [ "$a" != "$(identity "$TMP/workrooms/brave-otter")" ]; then
  echo "FAIL: the identity for one path changed between runs"
  fails=$((fails + 1))
fi

# Reached through a symlink, a checkout is still the same checkout.
ln -s "$TMP/workrooms/brave-otter" "$TMP/link-to-otter"
if [ "$(identity "$TMP/link-to-otter")" != "$a" ]; then
  echo "FAIL: a symlinked path gave a different identity from the checkout it points at"
  fails=$((fails + 1))
fi

# With no argument it describes the checkout it LIVES IN, and never fails. Compared against that
# checkout named explicitly, not just checked for exit 0: the default root is computed by walking up
# from the script (`$(dirname "$0")/../..`), and an off-by-one there still exits 0 and still prints
# nothing whenever the wrong directory also happens to be a main checkout — which `macapp/` is. Only
# the comparison can tell a resolved default root from a wrong one.
default_out="$(sh "$SCRIPT")"
default_status=$?
if [ "$default_status" -ne 0 ]; then
  echo "FAIL: dev-identity.sh with no argument exited $default_status"
  fails=$((fails + 1))
fi
# Comparing the no-argument run against this repo root would prove nothing: both the right root and
# a wrong one are main checkouts here, so both print nothing and the assertion holds either way.
# Run a COPY from inside a fake worktree instead, where only the correct root has the `.git` file —
# an off-by-one lands on `macapp/`, which has none, and the suffix disappears.
checkout "$TMP/rooted" git-worktree
mkdir -p "$TMP/rooted/macapp/Scripts"
cp "$SCRIPT" "$TMP/rooted/macapp/Scripts/dev-identity.sh"
rooted_out="$(sh "$TMP/rooted/macapp/Scripts/dev-identity.sh")"
if [ "$rooted_out" != "$(identity "$TMP/rooted")" ]; then
  echo "FAIL: run with no argument from inside a workroom gave '$rooted_out', want" \
    "'$(identity "$TMP/rooted")' — its default root walks up the wrong number of levels"
  fails=$((fails + 1))
fi

if [ $fails -ne 0 ]; then
  echo "dev-identity_test: $fails failure(s)"
  exit 1
fi
echo "dev-identity_test: OK"
