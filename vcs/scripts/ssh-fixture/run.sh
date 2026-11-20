#!/bin/bash
#
# Runs the remote-path tests over real ssh, into a container (issue #228).
#
#   vcs/scripts/ssh-fixture/run.sh <linux workroomd> [command...]
#
# The argument is a Linux workroomd for the CONTAINER's architecture, built the way the app bundles
# it: static musl, with terminal-state. CI passes the one its `daemon-linux` job just built. On an
# Apple Silicon Mac with Docker, build one with:
#
#   cargo zigbuild --manifest-path vcs/Cargo.toml --release -p workroomd \
#     --features terminal-state --target aarch64-unknown-linux-musl
#
# (with rustup's toolchain and the pinned Zig first on PATH; see test-linux.sh for why).
#
# What it does: builds the fixture image around that daemon, starts it with a per-run client key,
# pins the container's host key out of band, and runs the ignored `over_ssh_*` tests in
# remote_transport.rs against it with BatchMode ssh. The tests run on THIS machine; only the agent
# and sshd are in the container, as they will be on a real remote host.
#
# Given a command, it runs that instead, with the fixture's whereabouts in WR_SSH_FIXTURE_*. The
# app's tests take them from there, run from the repository root:
#
#   vcs/scripts/ssh-fixture/run.sh <linux workroomd> \
#     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/RemoteHostIntegrationTests
#
# To test the SSH driver starting its own daemon, set WR_FIXTURE_SUPERVISOR=0 and select
# WorkroomAppTests/SSHHostIntegrationTests instead.
#
# WR_FIXTURE_SYSTEMD=1 builds the systemd variant (Dockerfile.systemd, #665) instead: systemd as
# PID 1, logind with KillUserProcesses=yes, no supervisor, and only the `over_ssh_systemd_*` tests
# by default (the plain fixture runs every other one). Docker needs the host's cgroups, writable:
# systemd and the user's manager write there, and Docker mounts a container's own read-only, so
# with a private cgroup namespace systemd never boots. WR_FIXTURE_RUN_FLAGS replaces those flags
# (`--privileged` too, should a host's Docker refuse the mount). Apple's `container` runs each
# container in its own VM, so it needs only the tmpfs mounts and a tty.
#
# CI runs this under Docker only (ci-rust.yml's "ssh fixture" steps); WR_FIXTURE_RUNTIME=container
# is checked by hand. Each phase prints an `ssh-fixture:` line to stderr, so a stalled run shows
# where it stopped, and the image build ends after WR_FIXTURE_BUILD_TIMEOUT seconds (600).
#
# xcodebuild hands a test only the variables prefixed TEST_RUNNER_, so each is exported twice.
set -euo pipefail

DAEMON="${1:?usage: run.sh <path to a Linux workroomd for the container architecture>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VCS_DIR="$(cd "$HERE/../.." && pwd)"
RUNTIME="${WR_FIXTURE_RUNTIME:-docker}"
# Apple's `container` has no `port`, `ps`, `images` or `rmi`, and its `build --quiet` never returns
# (container 1.7.1), so it gets its own branches below. Each container is its own VM with its own
# address, so ssh reaches port 22 there and nothing is published.
APPLE=0
[ "$(basename "$RUNTIME")" = container ] && APPLE=1
BUILD_TIMEOUT="${WR_FIXTURE_BUILD_TIMEOUT:-600}"
SUPERVISOR="${WR_FIXTURE_SUPERVISOR:-1}"
SYSTEMD="${WR_FIXTURE_SYSTEMD:-0}"
# The systemd variant has no supervisor: the tests start the daemon.
[ "$SYSTEMD" = 1 ] && SUPERVISOR=0
NAME="wr-ssh-fixture-$$"
# Fixed by entrypoint.sh.
SOCKET="/run/workroom/workroomd.sock"
SCREENS="/home/workroom/.local/state/workroom/screens"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wr-ssh-fixture.XXXXXX")"
# The image goes too: built by ID, one would pile up per run. Its layers stay in the build cache.
# So does whatever the app's tests provisioned from it (#252), which carries this run's label:
# containers first, then the images committed from them, which the fixture's image is a parent of.
LABEL="workroom.fixture=$NAME"
cleanup() {
  if [ "$APPLE" = 1 ]; then
    # Only the fixture and its image: the provisioning tests that label their own need Docker.
    "$RUNTIME" delete --force "$NAME" >/dev/null 2>&1 || true
    if [ -n "${IMAGE:-}" ]; then
      "$RUNTIME" image delete --force "$IMAGE" >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE"
    return
  fi
  "$RUNTIME" rm -f "$NAME" >/dev/null 2>&1 || true
  for container in $("$RUNTIME" ps -aq --filter "label=$LABEL" 2>/dev/null); do
    "$RUNTIME" rm -f "$container" >/dev/null 2>&1 || true
  done
  # `-a`: a commit is untagged, and `images` lists an untagged image only with it.
  for image in $("$RUNTIME" images -aq --filter "label=$LABEL" 2>/dev/null); do
    "$RUNTIME" rmi -f "$image" >/dev/null 2>&1 || true
  done
  if [ -n "${IMAGE:-}" ]; then
    "$RUNTIME" rmi -f "$IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

# capped <seconds> <command...>: runs the command in a process group of its own, kills the whole
# group once <seconds> pass and exits 124. The whole group, because `container build` ignores
# SIGALRM and its build process outlives the CLI. INT and TERM are passed on to the group, which
# no longer gets the terminal's Ctrl-C or CI's cancel itself.
capped() {
  perl -e '
    my $limit = shift;
    my $pid = fork() // die "capped: fork: $!\n";
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127 }
    setpgrp($pid, $pid);
    my $end = sub { kill "KILL", -$pid; waitpid $pid, 0; exit $_[0] };
    $SIG{ALRM} = sub { $end->(124) };
    $SIG{INT} = sub { $end->(130) };
    $SIG{TERM} = sub { $end->(143) };
    alarm $limit;
    waitpid $pid, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}

cp "$DAEMON" "$STAGE/workroomd"
if [ "$SYSTEMD" = 1 ]; then
  cp "$HERE/Dockerfile.systemd" "$STAGE/Dockerfile"
  cp "$HERE/identity.sh" "$HERE/systemd-setup.sh" "$HERE/systemd-setup.service" "$STAGE/"
else
  cp "$HERE/Dockerfile" "$HERE/entrypoint.sh" "$HERE/identity.sh" "$HERE/fake-github.py" \
    "$HERE/git-credential-fixture" "$STAGE/"
fi
# By image ID, not a tag: a tag is shared, and another run building it between here and `run` below
# would swap in a different daemon. WR_FIXTURE_BUILD_FLAGS is word-split into extra build flags; CI
# passes a GitHub Actions layer cache there so the apt layer is not rebuilt on every run.
read -r -a BUILD_FLAGS <<< "${WR_FIXTURE_BUILD_FLAGS:-}"
echo "ssh-fixture: building the image with $RUNTIME (up to ${BUILD_TIMEOUT}s)" >&2
# The build's log stays out of the way unless the build fails or runs out of time.
status=0
if [ "$APPLE" = 1 ]; then
  # No image IDs to build by, so a tag this run alone uses.
  IMAGE="$NAME-image"
  capped "$BUILD_TIMEOUT" "$RUNTIME" build --progress plain --tag "$IMAGE" --build-arg FIXTURE=1 \
    ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "$STAGE" > "$STAGE/build.log" 2>&1 || status=$?
else
  IMAGE="$(capped "$BUILD_TIMEOUT" "$RUNTIME" build --quiet --build-arg FIXTURE=1 \
    ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "$STAGE" 2> "$STAGE/build.log")" || status=$?
fi
if [ "$status" = 124 ]; then
  echo "error: the image build ran past ${BUILD_TIMEOUT}s (WR_FIXTURE_BUILD_TIMEOUT); its log:" >&2
elif [ "$status" != 0 ]; then
  echo "error: the image build failed; its log:" >&2
fi
if [ "$status" != 0 ]; then
  cat "$STAGE/build.log" >&2
  exit 1
fi

# The daemon must run in there at all: an ELF for the wrong architecture would otherwise surface as
# a supervisor restarting it forever and a relay that never connects.
echo "ssh-fixture: $("$RUNTIME" run --rm --entrypoint workroomd "$IMAGE" protocol | head -1)"

ssh-keygen -q -t ed25519 -N '' -C wr-ssh-fixture -f "$STAGE/id_ed25519"
# `--init` reaps the plain fixture's orphans; the systemd variant's PID 1 is systemd itself.
if [ "$SYSTEMD" = 1 ]; then
  if [ -n "${WR_FIXTURE_RUN_FLAGS+set}" ]; then
    read -r -a RUN_FLAGS <<< "$WR_FIXTURE_RUN_FLAGS"
  elif [ "$APPLE" = 1 ]; then
    RUN_FLAGS=(--tmpfs /run --tmpfs /run/lock --tmpfs /tmp --tty)
  else
    # `exec`: the fixture's daemon lives beside its socket in /run/workroom, and Docker's tmpfs
    # is noexec otherwise.
    RUN_FLAGS=(--cgroupns=host --volume /sys/fs/cgroup:/sys/fs/cgroup:rw
      --tmpfs /run:exec --tmpfs /run/lock --tmpfs /tmp)
  fi
else
  RUN_FLAGS=(--init)
fi
PUBLISH=(--publish 127.0.0.1::22)
[ "$APPLE" = 1 ] && PUBLISH=()
"$RUNTIME" run --detach ${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"} --name "$NAME" \
  ${PUBLISH[@]+"${PUBLISH[@]}"} \
  --env "AUTHORIZED_KEY=$(cat "$STAGE/id_ed25519.pub")" \
  --env "WR_FIXTURE_SUPERVISOR=$SUPERVISOR" "$IMAGE" >/dev/null
if [ "$APPLE" = 1 ]; then
  ADDRESS="$("$RUNTIME" inspect "$NAME" | python3 -c \
    'import json, sys; print(json.load(sys.stdin)[0]["status"]["networks"][0]["ipv4Address"].split("/")[0])')"
  PORT=22
else
  ADDRESS=127.0.0.1
  PORT="$("$RUNTIME" port "$NAME" 22/tcp | head -1 | sed 's/.*://')"
fi
echo "ssh-fixture: started $NAME at $ADDRESS:$PORT; waiting for its host key" >&2

# BatchMode cannot prompt to accept a host key, so the expected key is delivered out of band (here,
# read straight out of the container) and pinned. That is the same policy a real driver needs.
# Pinned under an alias rather than the port: a restart publishes a new port (the reboot test,
# #232), and the key must still match. Read once the entrypoint has minted it (#252): until the
# marker names this container, the keys on disk are the image's or about to be replaced
# (identity.sh, which `ContainerHostDriver` reads the key through too).
HOST_KEY=""
for attempt in $(seq 1 100); do
  HOST_KEY="$("$RUNTIME" exec "$NAME" identity.sh 2>/dev/null || true)"
  [ -n "$HOST_KEY" ] && break
  sleep 0.2
done
if [ -z "$HOST_KEY" ]; then
  echo "error: the fixture never minted its identity; its log:" >&2
  "$RUNTIME" logs "$NAME" >&2
  exit 1
fi
printf 'wr-ssh-fixture %s\n' "$HOST_KEY" > "$STAGE/known_hosts"
cat > "$STAGE/ssh_config" <<EOF
Host fixture
  HostName $ADDRESS
  HostKeyAlias wr-ssh-fixture
  Port $PORT
  User workroom
  IdentityFile $STAGE/id_ed25519
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $STAGE/known_hosts
  HostKeyAlgorithms ssh-ed25519
  ConnectTimeout 10
  LogLevel ERROR
EOF

# Unsupervised SSH-driver tests must prove that the app starts the daemon. They wait for sshd
# alone; every existing suite still waits for the fixture's supervisor to serve.
if [ "$SUPERVISOR" = 0 ]; then
  echo "ssh-fixture: host key pinned; waiting for sshd" >&2
else
  echo "ssh-fixture: host key pinned; waiting for sshd and the supervisor's daemon" >&2
fi
for attempt in $(seq 1 100); do
  if [ "$SUPERVISOR" = 0 ]; then
    READY_COMMAND=true
  else
    READY_COMMAND="workroomd list --socket $SOCKET"
  fi
  if ssh -F "$STAGE/ssh_config" fixture "$READY_COMMAND" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = 100 ]; then
    echo "error: the fixture never served; its log:" >&2
    "$RUNTIME" logs "$NAME" >&2
    exit 1
  fi
  sleep 0.2
done

# DAEMON: the ELF itself, for the tests of the bootstrap that pushes it (#231). The app's tests
# take it as their bundled daemon. CONTAINER,
# RUNTIME and SCREENS: for the test that reboots the box (#232). IMAGE, RUNTIME_PATH, PUBLIC_KEY
# and LABEL: for the app's tests that provision containers of their own from the image (#252),
# and CLONE_TOKEN for the image's GitHub (fake-github.py).
CLONE_TOKEN=""
if [ "$SYSTEMD" != 1 ]; then
  CLONE_TOKEN="$("$RUNTIME" exec "$NAME" cat /etc/workroom-fixture/clone-token)"
fi
for pair in "CONFIG=$STAGE/ssh_config" "SOCKET=$SOCKET" "ADDRESS=$ADDRESS" "PORT=$PORT" \
  "USER=workroom" "IDENTITY=$STAGE/id_ed25519" "HOST_KEY=$HOST_KEY" "DAEMON=$STAGE/workroomd" \
  "CONTAINER=$NAME" "RUNTIME=$RUNTIME" "SCREENS=$SCREENS" "IMAGE=$IMAGE" \
  "RUNTIME_PATH=$(command -v "$RUNTIME")" "PUBLIC_KEY=$(cat "$STAGE/id_ed25519.pub")" \
  "LABEL=$LABEL" "CLONE_TOKEN=$CLONE_TOKEN" "SUPERVISOR=$SUPERVISOR" "SYSTEMD=$SYSTEMD"; do
  export "WR_SSH_FIXTURE_$pair" "TEST_RUNNER_WR_SSH_FIXTURE_$pair"
done

shift
if [ "$#" -eq 0 ]; then
  # One thread: the tests share one daemon, and the supervisor test kills it. The systemd
  # variant's tests switch the box's logind and linger, so they share it one at a time too.
  cd "$VCS_DIR"
  if [ "$SYSTEMD" = 1 ]; then
    set -- cargo test -p workroomd --test remote_transport over_ssh_systemd_ -- --ignored \
      --test-threads=1
  else
    set -- cargo test -p workroomd --test remote_transport -- --ignored \
      --skip over_ssh_systemd_ --test-threads=1
  fi
fi
echo "ssh-fixture: ready; running $*" >&2
if ! "$@"; then
  echo "error: the ssh fixture tests failed; the container's log:" >&2
  "$RUNTIME" logs "$NAME" >&2
  exit 1
fi
