#!/bin/bash
#
# Runs the opt-in remote-host and container suites for real, as `make app-test-remote`, and fails
# when one of them ran no test or skipped every test it has. Each of these suites passes by skipping
# when the fixture or runtime it needs is missing, so a plain `make app-test` (and CI's macOS job)
# reports them green without running them. Their recipes are the ones vcs/scripts/ssh-fixture/run.sh
# and the test classes' doc comments give; this script is the one place that runs them all.
#
#   macapp/Scripts/remote-tests.sh                      every suite (REMOTE_SUITES=all)
#   REMOTE_SUITES=over-ssh,containers remote-tests.sh   some of them, by suite or group name
#   WR_LINUX_DAEMON=<linux workroom> remote-tests.sh    that daemon, rather than building one
#
# Suites, and what each needs (Docker is WR_FIXTURE_RUNTIME's runtime, docker by default):
#
#   over-ssh           run.sh's `over_ssh_*` Rust tests (remote_transport.rs)           Docker
#   over-ssh-systemd   the same with WR_FIXTURE_SYSTEMD=1: `over_ssh_systemd_*`           Docker
#   remote-host        RemoteHostIntegrationTests, RemoteProvisioningIntegrationTests   Docker
#   ssh-host           SSHHostIntegrationTests, WR_FIXTURE_SUPERVISOR=0                 Docker
#   ssh-host-systemd   SSHHostIntegrationTests, WR_FIXTURE_SYSTEMD=1 (its #665 tests)   Docker
#   docker-containers  ContainerProvisioningIntegrationTests                            Docker
#   apple-containers   AppleContainerIntegrationTests, ContainerCreateLiveTests          container
#   host-drivers       HostDrivers' ContainerHostDriverLiveTests (swift test)           container
#
# Groups: `all`; `rust` (the two over-ssh runs); `app` (the five that run through `make app-test`);
# `ssh` (the five on the ssh fixture); `containers` (the last three).
#
# The daemon is the Linux `workroom` for THIS Mac's architecture, static musl with terminal-state,
# built as macapp/Scripts/build-daemon.sh builds the app's (cargo-zigbuild, mk/vcs.mk's Rust, the
# Zig build-ghostty-vt.sh pins, from mise when it has it). Every suite runs even after one fails;
# then a table, one row per test class, and the exit status. A row passes only when its command
# exited 0, nothing failed, and at least one test ran rather than skipped: the counts come from
# `make app-test`'s per-class summary (test-summary.sh, TEST_SUMMARY_CLASSES=1), XCTest's last
# `Executed` line, or cargo's `test result:` lines.
#
# A runtime that isn't running fails the run before anything is built, naming the runtime and the
# suites that need it; this script starts nobody's runtime.
#
# `remote-tests.sh counts <xcode|swift|cargo> <log> [class]` prints one log's `passed failed
# skipped`, and `remote-tests.sh verdict <exit status> [passed failed skipped]` a row's verdict;
# remote-tests_test.sh checks both against canned output.
#
# bash 3.2 (macOS's /bin/bash): no associative arrays or mapfile, and every array expansion guarded.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MAKE="${MAKE:-make}"

ALL_SUITES="over-ssh over-ssh-systemd remote-host ssh-host ssh-host-systemd docker-containers apple-containers host-drivers"

# The test classes a suite reports, one row each; a cargo suite reports one row of its own name.
classes_of() {
  case "$1" in
    remote-host) echo "RemoteHostIntegrationTests RemoteProvisioningIntegrationTests" ;;
    ssh-host | ssh-host-systemd) echo "SSHHostIntegrationTests" ;;
    docker-containers) echo "ContainerProvisioningIntegrationTests" ;;
    apple-containers) echo "AppleContainerIntegrationTests ContainerCreateLiveTests" ;;
    host-drivers) echo "ContainerHostDriverLiveTests" ;;
    *) echo "" ;;
  esac
}

# The runtime a suite needs: `fixture` (run.sh's, WR_FIXTURE_RUNTIME), `docker` or `container`.
runtime_of() {
  case "$1" in
    over-ssh | over-ssh-systemd | remote-host | ssh-host | ssh-host-systemd) echo fixture ;;
    docker-containers) echo docker ;;
    *) echo container ;;
  esac
}

# counts <xcode|swift|cargo> <log> [class]: `passed failed skipped`, or nothing when the log has no
# count for it, which is a run that never got to its tests.
counts() {
  local kind="$1" log="$2" class="${3:-}"
  case "$kind" in
    xcode)
      # test-summary.sh's `  CLASS WorkroomAppTests/<class>: 2 passed, 0 failed, 1 skipped`.
      awk -v class="$class" '
        $1 == "CLASS" && $2 ~ ("/" class ":$") { line = $3 " " $5 " " $7 }
        END { if (line != "") print line }' "$log"
      ;;
    swift)
      # XCTest's last `Executed` line is the whole run's: "Executed 3 tests, with 1 test skipped and
      # 0 failures (0 unexpected)"; with nothing skipped, "Executed 3 tests, with 0 failures".
      awk '
        /Executed [0-9]+ tests?, with / {
          executed = $0; sub(/.*Executed /, "", executed); sub(/ .*/, "", executed)
          skipped = 0
          if ($0 ~ /tests? skipped/) {
            skipped = $0; sub(/.*, with /, "", skipped); sub(/ .*/, "", skipped)
          }
          failed = $0; sub(/ failures? .*/, "", failed); sub(/.* /, "", failed)
          line = (executed - skipped - failed) " " failed " " skipped
        }
        END { if (line != "") print line }' "$log"
      ;;
    cargo)
      # One "test result: ok. 9 passed; 0 failed; 2 ignored; ..." per test binary; ignored is
      # cargo's skip.
      awk '
        /^test result: / {
          for (i = 1; i <= NF; i++) {
            if ($(i + 1) ~ /^passed;/) passed += $i
            if ($(i + 1) ~ /^failed;/) failed += $i
            if ($(i + 1) ~ /^ignored;/) skipped += $i
          }
          seen = 1
        }
        END { if (seen) print passed + 0, failed + 0, skipped + 0 }' "$log"
      ;;
    *)
      echo "remote-tests: unknown log kind '$kind'" >&2
      return 2
      ;;
  esac
}

# verdict <exit status> [passed failed skipped]: PASS, or why the row fails.
verdict() {
  local status="$1" passed="${2:-}" failed="${3:-}" skipped="${4:-}"
  if [ -z "$passed" ]; then
    if [ "$status" != 0 ]; then echo "FAILED (exit $status)"; else echo "NO TESTS RAN"; fi
  elif [ "$status" != 0 ] || [ "$failed" -gt 0 ]; then
    echo "FAILED"
  elif [ $((passed + skipped)) -eq 0 ]; then
    echo "NO TESTS RAN"
  elif [ "$passed" -eq 0 ]; then
    echo "ALL SKIPPED"
  else
    echo "PASS"
  fi
}

case "${1:-}" in
  counts)
    shift
    counts "$@"
    exit
    ;;
  verdict)
    shift
    verdict "$@"
    exit
    ;;
  "") ;;
  *)
    echo "usage: remote-tests.sh | remote-tests.sh counts <kind> <log> [class] | remote-tests.sh verdict <status> [passed failed skipped]" >&2
    exit 2
    ;;
esac

# --- Which suites ---

SUITES=""
for name in $(printf '%s' "${REMOTE_SUITES:-all}" | tr ',' ' '); do
  case "$name" in
    all) add="$ALL_SUITES" ;;
    rust) add="over-ssh over-ssh-systemd" ;;
    app) add="remote-host ssh-host ssh-host-systemd docker-containers apple-containers" ;;
    ssh) add="over-ssh over-ssh-systemd remote-host ssh-host ssh-host-systemd" ;;
    containers) add="docker-containers apple-containers host-drivers" ;;
    *)
      add=""
      for suite in $ALL_SUITES; do [ "$suite" = "$name" ] && add="$name"; done
      if [ -z "$add" ]; then
        echo "remote-tests: no suite or group '$name'. Suites: ${ALL_SUITES// /, }; groups: all, rust, app, ssh, containers." >&2
        exit 2
      fi
      ;;
  esac
  for suite in $add; do
    case " $SUITES " in *" $suite "*) ;; *) SUITES="${SUITES:+$SUITES }$suite" ;; esac
  done
done
if [ -z "$SUITES" ]; then
  echo "remote-tests: REMOTE_SUITES names no suite." >&2
  exit 2
fi
# In the order ALL_SUITES lists them, whatever order they were asked for in.
ORDERED=""
for suite in $ALL_SUITES; do
  case " $SUITES " in *" $suite "*) ORDERED="${ORDERED:+$ORDERED }$suite" ;; esac
done
SUITES="$ORDERED"

# --- Runtimes, before anything is built ---

FIXTURE_RUNTIME="${WR_FIXTURE_RUNTIME:-docker}"

# runtime_up <cli>: whether that runtime answers, as test-linux.sh asks: its CLI on PATH is not
# enough, since Docker's daemon or `container`'s system service may be stopped.
runtime_up() {
  command -v "$1" >/dev/null 2>&1 || return 1
  case "$(basename "$1")" in
    container) "$1" system status >/dev/null 2>&1 ;;
    *) "$1" info >/dev/null 2>&1 ;;
  esac
}

# How to start one, for the error.
runtime_hint() {
  case "$(basename "$1")" in
    container) echo "Apple's container isn't running: run 'container system start' (macOS 26+, Apple silicon)" ;;
    docker) echo "Docker isn't running: start Docker Desktop (or your Docker engine)" ;;
    *) echo "$1 isn't running" ;;
  esac
}

missing=""
needing_fixture="" needing_docker="" needing_container=""
for suite in $SUITES; do
  case "$(runtime_of "$suite")" in
    fixture) needing_fixture="${needing_fixture:+$needing_fixture, }$suite" ;;
    docker) needing_docker="${needing_docker:+$needing_docker, }$suite" ;;
    container) needing_container="${needing_container:+$needing_container, }$suite" ;;
  esac
done
# The fixture's suites share a line with the other suites of the runtime it runs on.
case "$(basename "$FIXTURE_RUNTIME")" in
  docker)
    [ -n "$needing_docker" ] && needing_fixture="${needing_fixture:+$needing_fixture, }$needing_docker"
    needing_docker=""
    ;;
  container)
    [ -n "$needing_container" ] && needing_fixture="${needing_fixture:+$needing_fixture, }$needing_container"
    needing_container=""
    ;;
esac
if [ -n "$needing_fixture" ] && ! runtime_up "$FIXTURE_RUNTIME"; then
  missing="$missing
  $(runtime_hint "$FIXTURE_RUNTIME"); needed by $needing_fixture"
fi
if [ -n "$needing_docker" ] && ! runtime_up docker; then
  missing="$missing
  $(runtime_hint docker); needed by $needing_docker"
fi
if [ -n "$needing_container" ] && ! runtime_up container; then
  missing="$missing
  $(runtime_hint container); needed by $needing_container"
fi
if [ -n "$missing" ]; then
  echo "remote-tests: these suites would skip every test, so nothing ran:$missing" >&2
  echo "Start the runtime, or leave those suites out with REMOTE_SUITES=<suites> (now: ${SUITES// /,})." >&2
  exit 1
fi

# --- The Linux daemon ---

case "$(uname -m)" in
  arm64 | aarch64) ARCH=aarch64 FILE_ARCH="ARM aarch64" ;;
  x86_64) ARCH=x86_64 FILE_ARCH="x86-64" ;;
  *) echo "remote-tests: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
TARGET="$ARCH-unknown-linux-musl"

# static_linux <file>: fails, saying why, unless it is a static Linux ELF for this Mac's
# architecture, which is what the container runs: a dynamic or Mac binary never starts in it.
static_linux() {
  local description
  description="$(file -b "$1")"
  case "$description" in
    *ELF*"$FILE_ARCH"*"statically linked"*) ;;
    *)
      echo "remote-tests: $1 is no static Linux $ARCH binary: $description" >&2
      exit 1
      ;;
  esac
}

if [ -n "${WR_LINUX_DAEMON:-}" ]; then
  if [ ! -f "$WR_LINUX_DAEMON" ]; then
    echo "remote-tests: WR_LINUX_DAEMON=$WR_LINUX_DAEMON is no file." >&2
    exit 1
  fi
  DAEMON="$(cd "$(dirname "$WR_LINUX_DAEMON")" && pwd)/$(basename "$WR_LINUX_DAEMON")"
  static_linux "$DAEMON"
fi

# CI's Rust from the one place the repo pins it, ahead of any Homebrew cargo: cargo-zigbuild runs
# `cargo` from PATH, and run.sh's `cargo test` should be the Rust CI runs (test-linux.sh says why).
# MAKEFLAGS cleared, so a `make -n` above can't turn the answer into a dry run's.
TOOLCHAIN="$(MAKEFLAGS='' "$MAKE" -s -C "$ROOT" print-VCS_RUST 2>/dev/null || true)"
if [ -z "$TOOLCHAIN" ]; then
  echo "remote-tests: could not read VCS_RUST from mk/vcs.mk (make -s print-VCS_RUST)." >&2
  exit 1
fi
if ! cargo_bin="$(rustup which --toolchain "$TOOLCHAIN" cargo 2>/dev/null)"; then
  echo "remote-tests: Rust $TOOLCHAIN, the toolchain CI pins (mk/vcs.mk), is not installed: rustup toolchain install $TOOLCHAIN" >&2
  exit 1
fi
PATH="$(dirname "$cargo_bin"):$PATH"
export PATH

if [ -z "${WR_LINUX_DAEMON:-}" ]; then
  if ! command -v cargo-zigbuild >/dev/null 2>&1; then
    echo "remote-tests: building the Linux daemon needs cargo-zigbuild: cargo install cargo-zigbuild --locked (or pass WR_LINUX_DAEMON=)." >&2
    exit 1
  fi
  if ! rustup target list --installed --toolchain "$TOOLCHAIN" 2>/dev/null | grep -qx "$TARGET"; then
    echo "remote-tests: Rust $TOOLCHAIN has no $TARGET target: rustup target add --toolchain $TOOLCHAIN $TARGET" >&2
    exit 1
  fi
  # The Zig libghostty-vt is pinned to, from mise when it has it (build-daemon.sh's order), checked
  # either way: another Zig links a binary that may not start in the container.
  ZIG_VERSION="$(awk -F'"' '/^ZIG_VERSION=/{print $2}' "$ROOT/vcs/scripts/build-ghostty-vt.sh")"
  MISE=""
  command -v mise >/dev/null 2>&1 && MISE=mise
  [ -z "$MISE" ] && [ -x "$HOME/.local/bin/mise" ] && MISE="$HOME/.local/bin/mise"
  if [ -n "$MISE" ]; then
    "$MISE" install "zig@$ZIG_VERSION" >/dev/null 2>&1 || true
    ZIG_HOME="$("$MISE" where "zig@$ZIG_VERSION" 2>/dev/null || true)"
    for candidate in "$ZIG_HOME/bin" "$ZIG_HOME"; do
      if [ -n "$ZIG_HOME" ] && [ -x "$candidate/zig" ]; then
        PATH="$candidate:$PATH"
        break
      fi
    done
  fi
  if [ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
    echo "remote-tests: building the Linux daemon needs zig $ZIG_VERSION: install mise, or put zig $ZIG_VERSION on PATH (or pass WR_LINUX_DAEMON=)." >&2
    exit 1
  fi
  echo "remote-tests: building workroom for $TARGET (release, terminal-state)"
  (cd "$ROOT/vcs" && cargo zigbuild --release -p workroom --features terminal-state --target "$TARGET")
  # Where cargo put it: an outer CARGO_TARGET_DIR redirects the build (build-daemon.sh says why).
  DAEMON="${CARGO_TARGET_DIR:-$ROOT/vcs/target}/$TARGET/release/workroom"
  static_linux "$DAEMON"
fi
echo "remote-tests: daemon $DAEMON"

# --- Run ---

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/wr-remote-tests.XXXXXX")"
ROWS=""
failed_rows=0

# row <name> <exit status> [passed failed skipped]
row() {
  local name="$1" status="$2" passed="${3:-}" failed="${4:-}" skipped="${5:-}" result
  result="$(verdict "$status" "$passed" "$failed" "$skipped")"
  [ "$result" = PASS ] || failed_rows=$((failed_rows + 1))
  ROWS="$ROWS$(printf '%-58s %6s %7s %6s  %s' "$name" "${passed:--}" "${skipped:--}" "${failed:--}" "$result")
"
}

# run_logged <suite> <command...>: runs it from the repository root with its output both shown and
# kept in $LOGS/<suite>.log, and sets `status` to its exit status.
run_logged() {
  local suite="$1"
  shift
  echo
  echo "== remote-tests: $suite: $*"
  set +e
  (cd "$ROOT" && "$@") 2>&1 | tee "$LOGS/$suite.log"
  status="${PIPESTATUS[0]}"
  set -e
}

# only_testing <class...>: APP_TEST_FLAGS selecting those classes, serially, as their recipes run.
only_testing() {
  local flags="" class
  for class in "$@"; do flags="${flags:+$flags }-only-testing:WorkroomAppTests/$class"; done
  echo "$flags"
}

RUN_SH="vcs/scripts/ssh-fixture/run.sh"
status=0
for suite in $SUITES; do
  # shellcheck disable=SC2046 # classes_of prints a word list.
  set -- $(classes_of "$suite")
  case "$suite" in
    over-ssh)
      run_logged "$suite" env -u WR_FIXTURE_SYSTEMD -u WR_FIXTURE_SUPERVISOR "$RUN_SH" "$DAEMON"
      ;;
    over-ssh-systemd)
      run_logged "$suite" env WR_FIXTURE_SYSTEMD=1 "$RUN_SH" "$DAEMON"
      ;;
    remote-host)
      run_logged "$suite" env -u WR_FIXTURE_SYSTEMD -u WR_FIXTURE_SUPERVISOR TEST_SUMMARY_CLASSES=1 \
        "$RUN_SH" "$DAEMON" "$MAKE" app-test APP_TEST_FLAGS="$(only_testing "$@")"
      ;;
    ssh-host)
      run_logged "$suite" env -u WR_FIXTURE_SYSTEMD WR_FIXTURE_SUPERVISOR=0 TEST_SUMMARY_CLASSES=1 \
        "$RUN_SH" "$DAEMON" "$MAKE" app-test APP_TEST_FLAGS="$(only_testing "$@")"
      ;;
    ssh-host-systemd)
      run_logged "$suite" env WR_FIXTURE_SYSTEMD=1 TEST_SUMMARY_CLASSES=1 \
        "$RUN_SH" "$DAEMON" "$MAKE" app-test APP_TEST_FLAGS="$(only_testing "$@")"
      ;;
    docker-containers)
      run_logged "$suite" env TEST_SUMMARY_CLASSES=1 TEST_RUNNER_WR_DOCKER_CONTAINER_TESTS=1 \
        TEST_RUNNER_WR_LINUX_DAEMON="$DAEMON" "$MAKE" app-test APP_TEST_FLAGS="$(only_testing "$@")"
      ;;
    apple-containers)
      run_logged "$suite" env TEST_SUMMARY_CLASSES=1 TEST_RUNNER_WR_APPLE_CONTAINER_TESTS=1 \
        TEST_RUNNER_WR_LINUX_DAEMON="$DAEMON" "$MAKE" app-test APP_TEST_FLAGS="$(only_testing "$@")"
      ;;
    host-drivers)
      run_logged "$suite" env WR_APPLE_CONTAINER_TESTS=1 WR_LINUX_DAEMON="$DAEMON" \
        swift test --package-path macapp/Packages/HostDrivers --filter ContainerHostDriverLiveTests
      ;;
  esac
  log="$LOGS/$suite.log"
  case "$suite" in
    over-ssh | over-ssh-systemd)
      # shellcheck disable=SC2046 # counts prints three numbers, or nothing.
      row "$suite" "$status" $(counts cargo "$log")
      ;;
    host-drivers)
      # shellcheck disable=SC2046
      row "$suite: $1" "$status" $(counts swift "$log")
      ;;
    *)
      for class in "$@"; do
        # shellcheck disable=SC2046
        row "$suite: $class" "$status" $(counts xcode "$log" "$class")
      done
      ;;
  esac
done

echo
printf '%-58s %6s %7s %6s  %s\n' "Suite" "Passed" "Skipped" "Failed" "Verdict"
printf '%s' "$ROWS"
echo "Logs: $LOGS"
if [ "$failed_rows" -gt 0 ]; then
  echo "remote-tests: $failed_rows row(s) did not pass. A row passes only when at least one test ran, none failed and its command exited 0."
  exit 1
fi
echo "remote-tests: every suite ran and passed"
