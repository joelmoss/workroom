#!/bin/sh
#
# Dependency-free test for wr_classify_channel (channel-helper.sh). No bats/toolchain — just sh.
# Run: sh macapp/Scripts/channel-helper_test.sh   (exits non-zero on any mismatch).
#
# Guards the contract that MUST stay identical across the Go internal/channel package, the Swift
# ReleaseChannel enum, and this shell helper. Cases live in one shared fixture
# (internal/channel/testdata/channel_cases.tsv) that internal/channel/channel_test.go's
# TestClassify also reads, so a newly discovered case is added once instead of independently to
# two hand-maintained lists (which had already silently drifted apart).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
. "${DIR}/channel-helper.sh"

FIXTURE="${DIR}/../../internal/channel/testdata/channel_cases.tsv"
TAB="$(printf '\t')"

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

[ -f "$FIXTURE" ] || { echo "FIXTURE not found: $FIXTURE" >&2; exit 1; }

while IFS="$TAB" read -r tag want; do
  # A blank or comment line has no tab, so $want stays empty — that's the skip signal. A real
  # fixture row always has a non-empty "want" (EXCLUDED at minimum), even when its tag is empty.
  [ -n "$want" ] || continue
  expect "$tag" "$want"
done <"$FIXTURE"

if [ "$fails" -ne 0 ]; then
  echo "channel-helper_test: $fails failure(s)" >&2
  exit 1
fi
echo "channel-helper_test: all cases passed"
