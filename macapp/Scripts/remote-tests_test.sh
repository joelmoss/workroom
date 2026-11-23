#!/bin/sh
#
# Dependency-free test for remote-tests.sh (`make app-test-remote`): its counts from canned xcodebuild,
# `swift test` and cargo output, the verdict that fails a suite which ran no test or skipped every
# one, its suite names, and the missing-runtime error, with stub `docker` and `container` CLIs. No
# fixture, runtime or build.
# Run: sh macapp/Scripts/remote-tests_test.sh   (exits non-zero on any failure).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# A named template, because template-less BSD `mktemp -d` ignores $TMPDIR (see build-daemon_test.sh).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/remote-tests_test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
# same <description> <got> <want>
same() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: got '$2', want '$3'"
    fails=$((fails + 1))
  fi
}

# verdict_of <kind> <exit status> <log> [class]: the row's verdict, as remote-tests.sh reaches it.
verdict_of() {
  # shellcheck disable=SC2046 # counts prints three numbers, or nothing.
  bash "$DIR/remote-tests.sh" verdict "$2" $(bash "$DIR/remote-tests.sh" counts "$1" "$3" ${4:+"$4"})
}

# --- make app-test, with test-summary.sh's per-class lines ---

cat >"$TMP/xcode.log" <<'EOF'
Tests: Passed - 14 passed, 0 failed, 3 skipped (of 17)
  CLASS WorkroomAppTests/RemoteHostIntegrationTests: 12 passed, 0 failed, 0 skipped
  CLASS WorkroomAppTests/RemoteProvisioningIntegrationTests: 0 passed, 0 failed, 3 skipped
  CLASS WorkroomAppTests/SSHHostIntegrationTests: 2 passed, 1 failed, 9 skipped
Result bundle: /tmp/Test-WorkroomApp.xcresult
EOF
same "xcode counts" "$(bash "$DIR/remote-tests.sh" counts xcode "$TMP/xcode.log" RemoteHostIntegrationTests)" "12 0 0"
same "xcode ran" "$(verdict_of xcode 0 "$TMP/xcode.log" RemoteHostIntegrationTests)" "PASS"
# The run's total passed; one class in it skipped every test, which only its own line shows.
same "xcode class skipped whole" "$(verdict_of xcode 0 "$TMP/xcode.log" RemoteProvisioningIntegrationTests)" "ALL SKIPPED"
same "xcode class failed" "$(verdict_of xcode 1 "$TMP/xcode.log" SSHHostIntegrationTests)" "FAILED"
# A class -only-testing selected and the bundle never ran has no line at all.
same "xcode class absent" "$(verdict_of xcode 0 "$TMP/xcode.log" ContainerCreateLiveTests)" "NO TESTS RAN"
# A class whose name ends another's is not that one.
same "xcode class suffix" "$(bash "$DIR/remote-tests.sh" counts xcode "$TMP/xcode.log" HostIntegrationTests)" ""

cat >"$TMP/xcode-nobundle.log" <<'EOF'
** BUILD FAILED **
test-summary: no WorkroomApp result bundle from this run in DerivedData/Logs/Test (the run stopped before tests started, or -resultBundlePath put it elsewhere)
EOF
same "xcode build failed" "$(verdict_of xcode 65 "$TMP/xcode-nobundle.log" RemoteHostIntegrationTests)" "FAILED (exit 65)"

# --- swift test (HostDrivers), XCTest's own lines ---

# What `swift test --filter ContainerHostDriverLiveTests` prints without the opt-in: exit 0.
cat >"$TMP/swift-skipped.log" <<'EOF'
Test Suite 'Selected tests' started at 2026-11-23 21:48:23.979.
Test Suite 'ContainerHostDriverLiveTests' started at 2026-11-23 21:48:23.979.
Test Case '-[HostDriversTests.ContainerHostDriverLiveTests testAStockImageBecomesAWorkroomOnApplesRuntime]' skipped (0.001 seconds).
Test Suite 'ContainerHostDriverLiveTests' passed at 2026-11-23 21:48:23.980.
	 Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'Selected tests' passed at 2026-11-23 21:48:23.980.
	 Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.001 (0.002) seconds
EOF
same "swift counts skipped" "$(bash "$DIR/remote-tests.sh" counts swift "$TMP/swift-skipped.log")" "0 0 1"
same "swift skipped" "$(verdict_of swift 0 "$TMP/swift-skipped.log")" "ALL SKIPPED"

cat >"$TMP/swift-passed.log" <<'EOF'
Test Suite 'ContainerHostDriverLiveTests' passed at 2026-11-23 21:48:23.980.
	 Executed 1 test, with 0 failures (0 unexpected) in 41.2 (41.2) seconds
Test Suite 'Selected tests' passed at 2026-11-23 21:48:23.980.
	 Executed 3 tests, with 0 failures (0 unexpected) in 41.2 (41.2) seconds
EOF
same "swift counts the last line" "$(bash "$DIR/remote-tests.sh" counts swift "$TMP/swift-passed.log")" "3 0 0"
same "swift passed" "$(verdict_of swift 0 "$TMP/swift-passed.log")" "PASS"

cat >"$TMP/swift-failed.log" <<'EOF'
	 Executed 4 tests, with 1 test skipped and 1 failure (0 unexpected) in 9.0 (9.0) seconds
EOF
same "swift counts failed" "$(bash "$DIR/remote-tests.sh" counts swift "$TMP/swift-failed.log")" "2 1 1"
same "swift failed" "$(verdict_of swift 1 "$TMP/swift-failed.log")" "FAILED"

# A filter that matches nothing: a warning, exit 0, and no `Executed` line.
printf 'warning: No matching test cases were run\n' >"$TMP/swift-none.log"
same "swift no tests" "$(verdict_of swift 0 "$TMP/swift-none.log")" "NO TESTS RAN"

# --- cargo test (run.sh's over_ssh runs) ---

cat >"$TMP/cargo-passed.log" <<'EOF'
running 9 tests
test over_ssh_a ... ok
test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 140 filtered out; finished in 52.10s
EOF
same "cargo counts" "$(bash "$DIR/remote-tests.sh" counts cargo "$TMP/cargo-passed.log")" "9 0 0"
same "cargo passed" "$(verdict_of cargo 0 "$TMP/cargo-passed.log")" "PASS"

# A filter that matches no test still prints a result line, with nothing run.
cat >"$TMP/cargo-none.log" <<'EOF'
running 0 tests
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 149 filtered out; finished in 0.00s
EOF
same "cargo no tests" "$(verdict_of cargo 0 "$TMP/cargo-none.log")" "NO TESTS RAN"

cat >"$TMP/cargo-ignored.log" <<'EOF'
running 3 tests
test result: ok. 0 passed; 0 failed; 3 ignored; 0 measured; 0 filtered out; finished in 0.00s
EOF
same "cargo all ignored" "$(verdict_of cargo 0 "$TMP/cargo-ignored.log")" "ALL SKIPPED"

cat >"$TMP/cargo-failed.log" <<'EOF'
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.10s
test result: FAILED. 7 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out; finished in 3.00s
EOF
same "cargo sums binaries" "$(bash "$DIR/remote-tests.sh" counts cargo "$TMP/cargo-failed.log")" "11 2 0"
same "cargo failed" "$(verdict_of cargo 101 "$TMP/cargo-failed.log")" "FAILED"

# The fixture never came up: no result line, and run.sh's exit status.
printf 'error: the fixture never served; its log:\n' >"$TMP/cargo-nofixture.log"
same "cargo no fixture" "$(verdict_of cargo 1 "$TMP/cargo-nofixture.log")" "FAILED (exit 1)"

# A command that failed after its tests passed fails the row.
same "exit status wins" "$(bash "$DIR/remote-tests.sh" verdict 2 5 0 0)" "FAILED"

# --- An app suite's rows when its run failed ---

# The run exited 65 for one class's failure: that class's row fails, the others keep their counts
# and pass, and a class the summary never counted takes the run's status.
out="$(bash "$DIR/remote-tests.sh" rows ssh-host 65 "$TMP/xcode.log" RemoteHostIntegrationTests \
  SSHHostIntegrationTests ContainerCreateLiveTests)"
got=$?
same "rows exit" "$got" 1
case "$out" in
*"ssh-host: RemoteHostIntegrationTests"*"12"*"0"*"0"*"PASS"*) ;;
*) echo "FAIL: a class that passed keeps its counts and passes. Got:"; echo "$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
*"ssh-host: SSHHostIntegrationTests"*"FAILED"*) ;;
*) echo "FAIL: the class that failed says so. Got:"; echo "$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
*"ContainerCreateLiveTests"*"FAILED (exit 65)"*) ;;
*) echo "FAIL: an uncounted class takes the run's status. Got:"; echo "$out"; fails=$((fails + 1)) ;;
esac
case "$out" in
*"its command"*) echo "FAIL: a failure a class explains needs no row of its own. Got:"; echo "$out"
  fails=$((fails + 1)) ;;
esac

# A run that failed after every class passed (the fixture's teardown, say) still fails, on a row
# of its own.
out="$(bash "$DIR/remote-tests.sh" rows remote-host 1 "$TMP/xcode.log" RemoteHostIntegrationTests)"
got=$?
same "rows exit, every class passed" "$got" 1
case "$out" in
*"remote-host: its command"*"FAILED (exit 1)"*) ;;
*) echo "FAIL: a failed run no class explains gets a row. Got:"; echo "$out"; fails=$((fails + 1)) ;;
esac
bash "$DIR/remote-tests.sh" rows remote-host 0 "$TMP/xcode.log" RemoteHostIntegrationTests >/dev/null
same "rows exit, all passed" "$?" 0

# --- What a run's cleanup removes: only what carries its own label ---

run=remote-tests-123-456
printf 'aaa111\t%s\nbbb222\t\nccc333\tremote-tests-999-456\nddd444\t%s\n' "$run" "$run" \
  >"$TMP/docker.txt"
same "docker: this run's only" "$(bash "$DIR/remote-tests.sh" ours docker "$run" <"$TMP/docker.txt" | tr '\n' ' ')" \
  "aaa111 ddd444 "
same "docker: no run, nothing" "$(bash "$DIR/remote-tests.sh" ours docker "" <"$TMP/docker.txt")" ""

cat >"$TMP/apple-containers.json" <<EOF
[{"id":"wr-1","configuration":{"id":"wr-1","labels":{"workroom.test-run":"$run","workroom.provisioner":"live-test"}}},
 {"id":"wr-2","configuration":{"id":"wr-2","labels":{"workroom.provisioner":"live-test"}}},
 {"id":"mine","configuration":{"id":"mine"}},
 {"id":"wr-3","configuration":{"id":"wr-3","labels":{"workroom.test-run":"remote-tests-999-456"}}}]
EOF
same "apple containers: this run's only" \
  "$(bash "$DIR/remote-tests.sh" ours apple-containers "$run" <"$TMP/apple-containers.json")" "wr-1"

cat >"$TMP/apple-images.json" <<EOF
[{"configuration":{"name":"workroom-test-git"},"variants":[{"config":{"config":{"Labels":{"workroom.test-run":"$run"}}}}]},
 {"configuration":{"name":"debian:bookworm-slim"},"variants":[{"config":{"config":{}}}]},
 {"configuration":{"name":"node:22"}}]
EOF
same "apple images: this run's only" \
  "$(bash "$DIR/remote-tests.sh" ours apple-images "$run" <"$TMP/apple-images.json")" "workroom-test-git"
same "apple: unreadable listing, nothing" \
  "$(printf 'not json' | bash "$DIR/remote-tests.sh" ours apple-containers "$run")" ""

# --- Suite names and runtimes, before anything is built ---

mkdir -p "$TMP/bin"
# Both runtimes installed and stopped: `docker info` and `container system status` fail.
printf '#!/bin/sh\necho "Cannot connect to the Docker daemon" >&2\nexit 1\n' >"$TMP/bin/docker"
printf '#!/bin/sh\necho "apiserver is not running" >&2\nexit 1\n' >"$TMP/bin/container"
chmod +x "$TMP/bin/docker" "$TMP/bin/container"

# expect_exit <description> <expected exit> <expected substring> -- <env assignments...>
expect_exit() {
  desc="$1"
  want="$2"
  text="$3"
  shift 4
  env PATH="$TMP/bin:$PATH" WR_LINUX_DAEMON="$TMP/no-daemon" "$@" bash "$DIR/remote-tests.sh" \
    >"$TMP/out" 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: $desc: exit $got, want $want. Output:"
    cat "$TMP/out"
    fails=$((fails + 1))
  elif ! grep -qF -- "$text" "$TMP/out"; then
    echo "FAIL: $desc: output lacks '$text'. Got:"
    cat "$TMP/out"
    fails=$((fails + 1))
  fi
}

expect_exit "unknown suite" 2 "no suite or group 'sshh'" -- REMOTE_SUITES=sshh
expect_exit "Docker stopped" 1 \
  "Docker isn't running: start Docker Desktop (or your Docker engine); needed by over-ssh, over-ssh-systemd, docker-containers" \
  -- REMOTE_SUITES=rust,docker-containers
expect_exit "container stopped" 1 \
  "Apple's container isn't running: run 'container system start' (macOS 26+, Apple silicon); needed by apple-containers, host-drivers" \
  -- REMOTE_SUITES=apple-containers,host-drivers
# Every suite asked for is named, each under the runtime it needs, and the run says how to narrow.
expect_exit "both stopped" 1 "now: over-ssh,over-ssh-systemd,remote-host,ssh-host,ssh-host-systemd,docker-containers,apple-containers,host-drivers" \
  -- REMOTE_SUITES=all
expect_exit "fixture on container" 1 \
  "Apple's container isn't running: run 'container system start' (macOS 26+, Apple silicon); needed by ssh-host, apple-containers" \
  -- REMOTE_SUITES=ssh-host,apple-containers WR_FIXTURE_RUNTIME=container

# With the runtime up, a WR_LINUX_DAEMON that isn't there stops the run before any suite.
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/docker"
expect_exit "daemon missing" 1 "WR_LINUX_DAEMON=$TMP/no-daemon is no file" -- REMOTE_SUITES=over-ssh
# Nor does a Mac binary, which never starts in the container.
expect_exit "daemon not Linux" 1 "is no static Linux" -- REMOTE_SUITES=over-ssh WR_LINUX_DAEMON=/bin/sh

if [ "$fails" -ne 0 ]; then
  echo "remote-tests_test: $fails failure(s)" >&2
  exit 1
fi
echo "remote-tests_test: all cases passed"
