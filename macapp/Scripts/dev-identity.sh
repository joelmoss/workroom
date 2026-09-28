#!/bin/sh
#
# Prints the bundle-id suffix that gives this checkout's Debug build its own identity, or nothing
# for the project's own checkout. The Makefile passes it to xcodebuild as WORKROOM_DEV_ID_SUFFIX,
# which macapp/project.yml appends to the Debug PRODUCT_BUNDLE_IDENTIFIER.
#
#   dev-identity.sh [checkout-root]   # default: the checkout containing this script
#
# Why per checkout. Almost everything a running "Workroom Dev" owns is keyed by its bundle id, not
# by where it was built: its preferences domain, its session helper's socket under
# Application Support/<bundle id>/ (and so which wr-agent it hands off to, #230), its saved session,
# and what LaunchServices and XCUITest treat as "that app is already running". Two workrooms of
# this repo building one id therefore share all of it: a dev app launched from one workroom hands
# the shared agent over to its own wr-agent build under the other's panes, a UI-test quit in one
# ends the other's persisted sessions, and `open` on one bundle activates the other's running copy.
# A distinct id per workroom separates all of that at once; see
# docs/designs/parallel-workroom-testing.md.
#
# A WORKROOM is a linked git worktree (its `.git` is a FILE naming the main repository's git dir)
# or a secondary jj workspace (its `.jj/repo` is a FILE naming the main workspace's store), which is
# how `workroom create` makes them. It gets `.wr-<name>-<hash>`: the sanitized directory name so a
# preferences plist or process list says which workroom it belongs to, and six hex digits of a
# checksum of the full path so two checkouts sharing a name still differ. The project's own
# checkout (`.git` and `.jj/repo` are directories, or absent) prints nothing and keeps the canonical
# `com.developwithstyle.workroom.dev`, so its preferences, TCC grants and sessions are untouched.
set -eu

root="$(cd "${1:-$(dirname "$0")/../..}" && pwd -P)"

if [ ! -f "$root/.git" ] && [ ! -f "$root/.jj/repo" ]; then
  exit 0
fi

# Bundle ids allow only [A-Za-z0-9.-], and this suffix is one component, so no dots either.
#
# The 20-character cap is a socket-path budget, not tidiness. The session helper's socket lives at
# `Application Support/<bundle id>/sessions/`, which a workroom's longer id pushes past sun_path's
# 104 bytes, so PersistentSessionPaths falls back to `/tmp/workroom-<uid>-<bundle id>/session.sock`
# — and nothing checks THAT length. At most 31 suffix characters keep it under 104 even for a
# ten-digit directory-service uid (14 + 10 + 1 + 33 + 31 + 13 = 102). The checksum carries the
# uniqueness, not the name.
name="$(basename "$root" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
  LC_ALL=C sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' | cut -c1-20 | sed -e 's/-*$//')"
# cksum is POSIX, so this is the same number on every Mac and on Linux CI.
hash="$(printf '%s' "$root" | cksum | awk '{ printf "%06x", $1 % 16777216 }')"

printf '.wr-%s%s\n' "${name:+$name-}" "$hash"
