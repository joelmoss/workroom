#!/bin/sh
#
# Test for stop-dev-app.sh, against real processes. Runs on macOS and Linux: each fake bundle's
# executables are copies of `sleep`, so a process's argv[0] really is a path inside a bundle, which
# is all the script reads. Run: sh macapp/Scripts/stop-dev-app_test.sh (exits non-zero on failure).
#
# The case that matters is the one `pkill -x "Workroom Dev"` got wrong: two workrooms' apps have the
# same process name, and stopping one must leave the other alone, while every copy that shares the
# bundle id being launched (an Xcode build, say) must still go.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/stop-dev-app.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stop-dev-app-test.XXXXXX")"
pids=""
fails=0

cleanup() {
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# Off macOS there is no plutil; stand in one that answers the single query the script makes.
if ! command -v plutil >/dev/null 2>&1; then
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/plutil" <<'EOF'
#!/bin/sh
# plutil -extract CFBundleIdentifier raw -o - FILE
[ -f "$6" ] || exit 1
sed -n '/<key>CFBundleIdentifier<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$6"
EOF
  chmod +x "$TMP/bin/plutil"
  PATH="$TMP/bin:$PATH"
  export PATH
fi

SLEEP="$(command -v sleep)"

# A copy of `sleep` this OS will actually EXECUTE, made once and copied into every fake bundle.
#
# Neither form works everywhere, so the form is chosen by probing rather than assumed.
# `/bin/sleep` is a platform binary whose signature is validated against the Signed System Volume's
# trust cache — which covers the file at its own path, not a copy. macOS 15 runs a plain copy; macOS
# 26+ SIGKILLs it on exec. Ad-hoc re-signing is the exact inverse: it makes the copy runnable on
# macOS 26+ and, on macOS 15, replaces a signature AMFI accepted with one it does not.
#
# Getting this wrong is invisible in the worst way. If the copies cannot run, every process the test
# spawns dies at birth, so `expect_dead` passes VACUOUSLY — everything it checks for really is gone —
# while `expect_alive` and the output assertions fail, pointing at stop-dev-app.sh rather than at
# these fixtures. Both mistakes have now been made in turn, one per OS.
#
# `"$candidate" 0` is the probe: sleeping zero seconds exits 0 at once, and a killed copy exits 137.
# Probed in a subshell with a trailing `:` so a rejected copy stays quiet. The shell announces a
# foreground child killed by a signal ("Killed: 9") on its OWN stderr, so the announcement has to
# come from a shell whose stderr we control — and without the `:` the subshell would exec the binary
# and BE that child, leaving the announcement to the script's own shell. Status still carries 137.
runnable() { ( "$1" 0 >/dev/null 2>&1; status=$?; exit "$status" ) 2>/dev/null; }

SLEEP_COPY="$TMP/runnable-sleep"
cp "$SLEEP" "$SLEEP_COPY"
if ! runnable "$SLEEP_COPY"; then
  if command -v codesign >/dev/null 2>&1; then
    codesign -f -s - "$SLEEP_COPY" >/dev/null 2>&1 || true
  fi
  if ! runnable "$SLEEP_COPY"; then
    echo "FAIL: cannot make a runnable copy of $SLEEP, so this test cannot spawn anything" >&2
    exit 1
  fi
fi

# make_bundle <dir> <bundle id>: a "Workroom Dev.app" whose executables are copies of sleep.
make_bundle() {
  app="$1/Workroom Dev.app"
  mkdir -p "$app/Contents/MacOS"
  cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$2</string>
</dict>
</plist>
EOF
  # From the probed copy, not from `$SLEEP` — see `runnable` above for why a plain copy is not
  # guaranteed to execute. An embedded signature travels with the bytes, so copying it is enough.
  for exe in "Workroom Dev" wr-agent workroom-session; do
    cp "$SLEEP_COPY" "$app/Contents/MacOS/$exe"
  done
}

# spawn <executable> <args...>: start it detached; its pid lands in $spawned. Detached (the `sh -c`
# exits at once) so it is reparented and reaped as soon as it dies, as an app launched by launchd
# is. A child of this shell would linger as a zombie that `kill -0` still finds, and every stop
# would sit out the script's full 8s grace period.
spawn() {
  spawned="$(sh -c '"$@" >/dev/null 2>&1 & echo $!' sh "$@")"
  pids="$pids $spawned"
}

alive() { kill -0 "$1" 2>/dev/null; }

expect_dead() {
  i=0
  while alive "$1" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if alive "$1"; then
    echo "FAIL: $2 is still running"
    fails=$((fails + 1))
  fi
}

expect_alive() {
  if ! alive "$1"; then
    echo "FAIL: $2 was stopped"
    fails=$((fails + 1))
  fi
}

DEV_ID="com.developwithstyle.workroom.dev.wr-brave-otter-2f5af8"
make_bundle "$TMP/this" "$DEV_ID"
make_bundle "$TMP/xcode" "$DEV_ID"   # the same identity built elsewhere
make_bundle "$TMP/other" "com.developwithstyle.workroom.dev.wr-quiet-fern-0a1b2c"

THIS="$TMP/this/Workroom Dev.app/Contents/MacOS"
spawn "$THIS/Workroom Dev" 301; this_app=$spawned
spawn "$THIS/wr-agent" 302; this_agent=$spawned
spawn "$THIS/workroom-session" 303; this_daemon=$spawned
spawn "$TMP/xcode/Workroom Dev.app/Contents/MacOS/Workroom Dev" 304; xcode_app=$spawned
spawn "$TMP/other/Workroom Dev.app/Contents/MacOS/Workroom Dev" 305; other_app=$spawned
spawn "$TMP/other/Workroom Dev.app/Contents/MacOS/wr-agent" 306; other_agent=$spawned
# Mentions this bundle's agent in its arguments without being it.
spawn sh -c 'sleep 307' "$THIS/wr-agent"; bystander=$spawned

sleep 0.3
out="$(sh "$SCRIPT" "$TMP/this/Workroom Dev.app" 2>&1)"
status=$?

if [ $status -ne 0 ]; then
  echo "FAIL: stop-dev-app exited $status: $out"
  fails=$((fails + 1))
fi
expect_dead "$this_app" "this checkout's app"
expect_dead "$this_agent" "this checkout's wr-agent"
expect_dead "$this_daemon" "this checkout's workroom-session"
expect_dead "$xcode_app" "another copy with the same bundle id"
expect_alive "$other_app" "another workroom's app (different bundle id)"
expect_alive "$other_agent" "another workroom's wr-agent (different bundle id)"
expect_alive "$bystander" "a process that only mentions the bundle path in its arguments"
case "$out" in
  *"Stopping persisted Workroom Dev wr-agent (its panes will come back empty)"*) ;;
  *) echo "FAIL: no notice for the stopped wr-agent; got: $out"; fails=$((fails + 1)) ;;
esac
case "$out" in
  *"Stopping persisted Workroom Dev workroom-session"*) ;;
  *) echo "FAIL: no notice for the stopped workroom-session; got: $out"; fails=$((fails + 1)) ;;
esac

# Nothing of this identity running: quiet success.
out="$(sh "$SCRIPT" "$TMP/this/Workroom Dev.app" 2>&1)"
status=$?
if [ $status -ne 0 ] || [ -n "$out" ]; then
  echo "FAIL: with nothing to stop, want exit 0 and no output; got $status: $out"
  fails=$((fails + 1))
fi
expect_alive "$other_app" "another workroom's app, on the second run"

# Which id a session helper belongs to: the one its socket names, whichever bundle its binary lives
# in, since an agent runs the copy that spawned it or last handed it off. Checked against a synthetic
# process table: a copy of `sleep` cannot carry `serve --socket …` arguments and stay alive.
PLAIN_ID="com.developwithstyle.workroom.dev"
OTHER_ID="com.developwithstyle.workroom.dev.wr-quiet-fern-0a1b2c"
OTHER="$TMP/other/Workroom Dev.app/Contents/MacOS"
SUPPORT="/Users/someone/Library/Application Support"
cat >"$TMP/table" <<EOF
101 $THIS/Workroom Dev
102 $THIS/wr-agent serve --socket $SUPPORT/$DEV_ID/sessions/agent.sock
103 $THIS/wr-agent serve --socket /tmp/workroom-501-$PLAIN_ID/agent.sock --handoff /tmp/table
104 $OTHER/wr-agent serve --socket /tmp/workroom-501-$DEV_ID/agent.sock --idle-timeout never
105 $THIS/wr-agent attach --session 6f1c2d
106 $OTHER/Workroom Dev
107 $THIS/wr-agent serve --socket /somewhere/else/agent.sock
108 $OTHER/wr-agent serve --socket $SUPPORT/$OTHER_ID/sessions/agent.sock
EOF
got="$(STOP_DEV_APP_PS="$TMP/table" STOP_DEV_APP_DRY_RUN=1 \
  sh "$SCRIPT" "$TMP/this/Workroom Dev.app" | sed -n 's/^stop //p' | sort -n | tr '\n' ' ')"
# 101 this app; 102 serves this id; 104 serves this id from another bundle; 105 has no socket, so
# goes by its bundle; 107 names no socket shape we know, so goes by its bundle. Not 103: it lives in
# this bundle but serves the plain id — stopping it would end the project checkout's sessions.
if [ "$got" != "101 102 104 105 107 " ]; then
  echo "FAIL: stopped '$got', want '101 102 104 105 107 '"
  fails=$((fails + 1))
fi

# An unreadable bundle is an error, not "nothing to stop".
if sh "$SCRIPT" "$TMP/missing/Workroom Dev.app" >/dev/null 2>&1; then
  echo "FAIL: a bundle with no Info.plist should be an error"
  fails=$((fails + 1))
fi

if [ $fails -ne 0 ]; then
  echo "stop-dev-app_test: $fails failure(s)"
  exit 1
fi
echo "stop-dev-app_test: OK"
