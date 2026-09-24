#!/bin/bash
#
# Runs the remote-path tests over real ssh, into a container (issue #228).
#
#   vcs/scripts/ssh-fixture/run.sh <linux wr-agent>
#
# The argument is a Linux wr-agent for the CONTAINER's architecture, built the way the app bundles
# it: static musl, with terminal-state. CI passes the one its `agent-linux` job just built. On an
# Apple Silicon Mac with Docker, build one with:
#
#   cargo zigbuild --manifest-path vcs/Cargo.toml --release -p wr-agent \
#     --features terminal-state --target aarch64-unknown-linux-musl
#
# (with rustup's toolchain and the pinned Zig first on PATH; see test-linux.sh for why).
#
# What it does: builds the fixture image around that agent, starts it with a per-run client key,
# pins the container's host key out of band, and runs the ignored `over_ssh_*` tests in
# remote_transport.rs against it with BatchMode ssh. The tests run on THIS machine; only the agent
# and sshd are in the container, as they will be on a real remote host.
set -euo pipefail

AGENT="${1:?usage: run.sh <path to a Linux wr-agent for the container architecture>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VCS_DIR="$(cd "$HERE/../.." && pwd)"
RUNTIME="${WR_FIXTURE_RUNTIME:-docker}"
NAME="wr-ssh-fixture-$$"
# Fixed by entrypoint.sh.
SOCKET="/run/workroom/agent.sock"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wr-ssh-fixture.XXXXXX")"
# The image goes too: built by ID, one would pile up per run. Its layers stay in the build cache.
cleanup() {
  "$RUNTIME" rm -f "$NAME" >/dev/null 2>&1 || true
  if [ -n "${IMAGE:-}" ]; then
    "$RUNTIME" rmi -f "$IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

cp "$AGENT" "$STAGE/wr-agent"
cp "$HERE/Dockerfile" "$HERE/entrypoint.sh" "$STAGE/"
# By image ID, not a tag: a tag is shared, and another run building it between here and `run` below
# would swap in a different agent. WR_FIXTURE_BUILD_FLAGS is word-split into extra build flags; CI
# passes a GitHub Actions layer cache there so the apt layer is not rebuilt on every run.
read -r -a BUILD_FLAGS <<< "${WR_FIXTURE_BUILD_FLAGS:-}"
IMAGE="$("$RUNTIME" build --quiet ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "$STAGE")"

# The agent must run in there at all: an ELF for the wrong architecture would otherwise surface as
# a supervisor restarting it forever and a relay that never connects.
echo "ssh-fixture: $("$RUNTIME" run --rm --entrypoint wr-agent "$IMAGE" protocol | head -1)"

ssh-keygen -q -t ed25519 -N '' -C wr-ssh-fixture -f "$STAGE/id_ed25519"
"$RUNTIME" run --detach --init --name "$NAME" --publish 127.0.0.1::22 \
  --env "AUTHORIZED_KEY=$(cat "$STAGE/id_ed25519.pub")" "$IMAGE" >/dev/null
PORT="$("$RUNTIME" port "$NAME" 22/tcp | head -1 | sed 's/.*://')"

# BatchMode cannot prompt to accept a host key, so the expected key is delivered out of band (here,
# read straight out of the container) and pinned. That is the same policy a real driver needs.
HOST_KEY="$("$RUNTIME" exec "$NAME" cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2)"
printf '[127.0.0.1]:%s %s\n' "$PORT" "$HOST_KEY" > "$STAGE/known_hosts"
cat > "$STAGE/ssh_config" <<EOF
Host fixture
  HostName 127.0.0.1
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

# Up means sshd answers AND the supervisor has the agent serving: `list` handshakes with it.
for attempt in $(seq 1 100); do
  if ssh -F "$STAGE/ssh_config" fixture wr-agent list --socket "$SOCKET" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = 100 ]; then
    echo "error: the fixture never served; its log:" >&2
    "$RUNTIME" logs "$NAME" >&2
    exit 1
  fi
  sleep 0.2
done

# One thread: the tests share one agent, and the supervisor test kills it.
cd "$VCS_DIR"
if ! WR_SSH_FIXTURE_CONFIG="$STAGE/ssh_config" WR_SSH_FIXTURE_SOCKET="$SOCKET" \
  cargo test -p wr-agent --test remote_transport -- --ignored --test-threads=1; then
  echo "error: the ssh fixture tests failed; the container's log:" >&2
  "$RUNTIME" logs "$NAME" >&2
  exit 1
fi
