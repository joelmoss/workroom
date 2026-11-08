#!/bin/sh
#
# Test for sweep-dev-orphans.sh, against synthetic process tables (STOP_DEV_APP_PS) and a temporary
# directory standing in for /tmp (SWEEP_DEV_ORPHANS_TMP), so it never reads or signals this Mac's
# real daemons and never touches its real socket directories. The one real signal goes to a `sleep`
# this test started, listed in the table under a daemon's command line.
# Run: sh macapp/Scripts/sweep-dev-orphans_test.sh (exits non-zero on failure).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/sweep-dev-orphans.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-dev-orphans-test.XXXXXX")"
pids=""
fails=0

cleanup() {
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}

# sweep <table> [args…]: runs the sweep in dry-run against <table> and the fake /tmp.
sweep() {
  table="$1"
  shift
  STOP_DEV_APP_PS="$table" STOP_DEV_APP_DRY_RUN=1 SWEEP_DEV_ORPHANS_TMP="$TMP/tmp" \
    sh "$SCRIPT" "$@" 2>&1
}

uid="$(id -u)"
DEV="com.developwithstyle.workroom.dev"
LIVE_ID="$DEV.wr-brave-otter-2f5af8"
GONE_ID="$DEV.wr-quiet-fern-0a1b2c"
LIVE="$TMP/live/macapp/DerivedData/Build/Products/Debug/Workroom Dev.app"
GONE="$TMP/gone/macapp/DerivedData/Build/Products/Debug/Workroom Dev.app"
SUPPORT="/Users/someone/Library/Application Support"
mkdir -p "$LIVE/Contents/MacOS" "$TMP/tmp"

# --- processes ---------------------------------------------------------------------------------
cat >"$TMP/table" <<EOF
201 $GONE/Contents/MacOS/workroomd serve --socket /tmp/workroom-$uid-$GONE_ID/workroomd
202 $LIVE/Contents/MacOS/workroomd serve --socket /tmp/workroom-$uid-$LIVE_ID/workroomd
203 /Applications/Workroom Nightly.app/Contents/MacOS/workroomd serve --socket $SUPPORT/$DEV.nightly/sessions/workroomd
204 /Applications/Workroom.app/Contents/MacOS/workroomd serve --socket $SUPPORT/com.developwithstyle.workroom/sessions/workroomd
205 /usr/bin/tail -f $GONE/Contents/MacOS/workroomd serve --socket /tmp/x/workroomd
206 /bin/sh -c sleep 1 $GONE/Contents/MacOS/workroomd serve --socket /tmp/x/workroomd
207 $GONE/Contents/MacOS/wr-agent serve --socket $SUPPORT/$GONE_ID/sessions/agent.sock
208 $GONE/Contents/MacOS/workroomd attach --session 6f1c2d
209 $GONE/Contents/MacOS/Workroom Dev
210 /Applications/Workroom Nightly.app/Contents/MacOS/workroomd serve --socket /gone/Workroom Dev.app/x
211 /Applications/Workroom Dev.app/Contents/MacOS/workroomd serve --socket /tmp/x/workroomd
EOF
got="$(sweep "$TMP/table" | sed -n 's/^stop //p' | sort -n | tr '\n' ' ')"
# 201: its bundle is gone. 207: a pre-rename daemon from a gone bundle. Not 202 (bundle exists),
# 203/204/210 (Nightly and release), 205/206 (only mention the path), 208 (not a serving daemon),
# 209 (the app itself, which a deleted bundle cannot still be running for long), 211 (not a build
# product: a copy someone moved, not a deleted workroom's build).
[ "$got" = "201 207 " ] || fail "stopped '$got', want '201 207 '"

# A real signal: a `sleep` listed under an orphan's command line is stopped; one under a live
# bundle's is not.
# Detached (the `sh -c` exits at once) so a stopped one is reaped, not left a zombie `kill -0` finds.
spawn() { sh -c 'sleep 300 >/dev/null 2>&1 & echo $!'; }
orphan="$(spawn)"
kept="$(spawn)"
pids="$orphan $kept"
cat >"$TMP/real-table" <<EOF
$orphan $GONE/Contents/MacOS/workroomd serve --socket /tmp/workroom-$uid-$GONE_ID/workroomd
$kept $LIVE/Contents/MacOS/workroomd serve --socket /tmp/workroom-$uid-$LIVE_ID/workroomd
EOF
out="$(STOP_DEV_APP_PS="$TMP/real-table" SWEEP_DEV_ORPHANS_TMP="$TMP/tmp" sh "$SCRIPT" 2>&1)"
status=$?
i=0
while kill -0 "$orphan" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$orphan" 2>/dev/null && fail "the orphaned daemon is still running"
kill -0 "$kept" 2>/dev/null || fail "the live bundle's daemon was stopped"
[ $status -eq 0 ] || fail "sweep exited $status"
case "$out" in
  *"Stopped orphaned workroomd $orphan"*) ;;
  *) fail "no notice for the stopped orphan; got: $out" ;;
esac

# --- socket directories --------------------------------------------------------------------------
old() { mkdir -p "$1" && touch -t 202001010000 "$1"; }
SERVED="$TMP/tmp/workroom-$uid-$LIVE_ID"
UNSERVED="$TMP/tmp/workroom-$uid-$GONE_ID"
FRESH="$TMP/tmp/workroom-$uid-$DEV.wr-new-born-123456"
PLAIN="$TMP/tmp/workroom-$uid-$DEV"
NIGHTLY="$TMP/tmp/workroom-$uid-com.developwithstyle.workroom.nightly"
OTHER_USER="$TMP/tmp/workroom-99999-$DEV.wr-someone-else-abcdef"
# All old and none but SERVED served, so only the name rules can keep PLAIN, NIGHTLY and OTHER_USER.
for d in "$SERVED" "$UNSERVED" "$PLAIN" "$NIGHTLY" "$OTHER_USER"; do old "$d"; done
mkdir -p "$FRESH"
cat >"$TMP/dir-table" <<EOF
301 $LIVE/Contents/MacOS/workroomd serve --socket $SERVED/workroomd
303 $GONE/Contents/MacOS/workroomd serve --socket $TMP/tmp/workroom-$uid-$DEV.wr-dying-000000/workroomd
EOF
old "$TMP/tmp/workroom-$uid-$DEV.wr-dying-000000"
got="$(sweep "$TMP/dir-table" | sed -n 's/^remove //p' | sort | tr '\n' ' ')"
# The unserved dir, and the dir of the daemon this run stops (303).
want="$TMP/tmp/workroom-$uid-$DEV.wr-dying-000000 $UNSERVED "
[ "$got" = "$want" ] || fail "would remove '$got', want '$want'"

# For real: the same table minus the orphan, so nothing is signalled.
sed '/^303 /d' "$TMP/dir-table" >"$TMP/dir-table-live"
out="$(STOP_DEV_APP_PS="$TMP/dir-table-live" SWEEP_DEV_ORPHANS_TMP="$TMP/tmp" sh "$SCRIPT" --quiet 2>&1)"
[ -d "$UNSERVED" ] && fail "the unserved socket dir was not removed"
[ -d "$SERVED" ] || fail "the socket dir with a live server was removed"
[ -d "$NIGHTLY" ] || fail "Nightly's socket dir was removed"
[ -d "$PLAIN" ] || fail "the project checkout's plain-id socket dir was removed"
[ -d "$FRESH" ] || fail "a socket dir made a moment ago was removed"
[ -d "$OTHER_USER" ] || fail "another user's socket dir was removed"
case "$out" in
  *"Removed unserved socket directory $UNSERVED"*) ;;
  *) fail "no notice for the removed dir; got: $out" ;;
esac

# Nothing to do: --quiet says nothing; without it, one line.
out="$(sweep "$TMP/dir-table-live" --quiet)"
[ -z "$out" ] || fail "--quiet with nothing to do printed: $out"
out="$(sweep "$TMP/dir-table-live")"
[ "$out" = "No orphaned dev daemons or socket directories." ] || fail "with nothing to do, got: $out"

if [ $fails -ne 0 ]; then
  echo "sweep-dev-orphans_test: $fails failure(s)"
  exit 1
fi
echo "sweep-dev-orphans_test: OK"
