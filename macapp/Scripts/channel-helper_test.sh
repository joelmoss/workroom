#!/bin/sh
#
# Dependency-free test for wr_classify_channel (channel-helper.sh). No bats/toolchain — just sh.
# Run: sh macapp/Scripts/channel-helper_test.sh   (exits non-zero on any mismatch).
#
# Guards the contract that MUST stay identical across the Go internal/channel package, the Swift
# ReleaseChannel enum, and this shell helper.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
. "${DIR}/channel-helper.sh"

fails=0

# expect <tag> <want-channel-or-"EXCLUDED">
expect() {
  tag="$1"
  want="$2"
  if got="$(wr_classify_channel "$tag")"; then
    rc=0
  else
    rc=1
  fi
  if [ "$want" = "EXCLUDED" ]; then
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: classify('$tag') = '$got' (rc 0), want EXCLUDED (rc 1)"
      fails=$((fails + 1))
    fi
  else
    if [ "$rc" -ne 0 ] || [ "$got" != "$want" ]; then
      echo "FAIL: classify('$tag') = '$got' (rc $rc), want '$want'"
      fails=$((fails + 1))
    fi
  fi
}

expect "v1.3.0" "stable"
expect "1.3.0" "stable"
expect "v2.0.0" "stable"
expect "v1.2.3+build.5" "stable"
expect "v2.0.0-beta.21" "pre"
expect "v1.4.0-rc1" "pre"
expect "v1.4.0-rc.1" "pre"
expect "v1.4.0-alpha" "pre"
expect "v2.0.0-beta.1+exp" "pre"
expect "nightly" "nightly"
expect "appcast" "EXCLUDED"
expect "" "EXCLUDED"
expect "garbage" "EXCLUDED"
expect "v1.2" "EXCLUDED"
expect "v1.2.x" "EXCLUDED"
expect "v1.2." "EXCLUDED"
expect "v1..3" "EXCLUDED"

if [ "$fails" -ne 0 ]; then
  echo "channel-helper_test: $fails failure(s)" >&2
  exit 1
fi
echo "channel-helper_test: all cases passed"
