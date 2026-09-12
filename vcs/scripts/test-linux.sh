#!/bin/bash
#
# Runs the agent's test suite against a LINUX target, from any host.
#
#   vcs/scripts/test-linux.sh [--features terminal-state]
#
# Why this exists: the agent's pty, its `/proc` introspection and its socket handling are the parts
# most likely to differ between Darwin and Linux, and a bug that only appears on one of them has
# already happened — an output pump that never noticed a closed socket, which macOS hid because the
# shell happened to emit a prompt.
#
# **This is a convenience, not the gate.** CI runs these same tests natively on `ubuntu-latest`,
# which is what actually blocks a merge. If this script cannot run — no runtime installed, no
# cross-compilation toolchain — it says so and exits 0, because a developer without a Linux runtime
# on their Mac should not be stopped by a check CI already performs.
set -euo pipefail

cd "$(dirname "$0")/.."

# macOS still ships bash 3.2, where an EMPTY array is "unbound" under `set -u` and neither
# `mapfile` nor `declare -A` exists. build-helper.sh documents the same trap. So: expand arrays
# with the `${a[@]+...}` guard, and avoid bash-4 builtins entirely.
FEATURES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --features) FEATURES=(--features "$2"); shift 2 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# On Linux the whole question is moot: run them.
if [ "$(uname -s)" = "Linux" ]; then
  echo "test-linux: running natively"
  exec cargo test -p wr-agent ${FEATURES[@]+"${FEATURES[@]}"}
fi

# The Linux artifact is a fully STATIC musl binary — no glibc, no distro userland — so anything
# that can boot a Linux kernel can run it. That is why this prefers Apple's `container` (macOS 26+,
# one lightweight VM per container, no daemon, no Docker Desktop licensing) over Docker, and why
# the image below can be the smallest one available rather than a matching distro.
#
# Preference order, but availability is decided by whether the runtime actually WORKS, not by
# whether the binary is on PATH: Apple's `container` needs a system service running, and Docker
# needs its daemon. Picking an installed-but-stopped runtime would fail with the runtime's own
# error rather than a useful one — and this script deliberately does not start anybody's daemon
# for them, because a test helper should not leave a background service running on your machine.
RUNTIME=""
for candidate in container docker podman; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  case "$candidate" in
    container) container system status >/dev/null 2>&1 || continue ;;
    docker | podman) "$candidate" info >/dev/null 2>&1 || continue ;;
  esac
  RUNTIME="$candidate"
  break
done
if [ -z "$RUNTIME" ]; then
  echo "test-linux: SKIP — no working container runtime." >&2
  if command -v container >/dev/null 2>&1; then
    echo "            'container' is installed; start it with 'container system start'." >&2
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "            'docker' is installed; start Docker and retry." >&2
  fi
  echo "            CI runs these same tests on ubuntu-latest; this check is local convenience." >&2
  exit 0
fi

TARGET="${WR_LINUX_TARGET:-x86_64-unknown-linux-musl}"
if ! command -v cargo-zigbuild >/dev/null 2>&1; then
  echo "test-linux: SKIP — cargo-zigbuild not installed ('cargo install cargo-zigbuild')." >&2
  exit 0
fi
if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  echo "test-linux: SKIP — rust target $TARGET not installed ('rustup target add $TARGET')." >&2
  exit 0
fi

echo "test-linux: building tests for $TARGET"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wr-test-linux.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Ask cargo WHICH binaries are tests rather than guessing from filenames.
#
# Guessing does not work: `deps/` holds two `wr_agent-<hash>` files — the lib's test binary and
# another artifact of the same crate name — plus every previous build's leftovers. An earlier
# version of this script picked the newest by mtime and ran the ordinary binary, which printed its
# usage text and exited 0, reporting success while running no tests at all.
#
# `--message-format=json` emits one `compiler-artifact` per target; the ones with
# `profile.test == true` and an `executable` are exactly the test binaries.
cargo zigbuild -p wr-agent ${FEATURES[@]+"${FEATURES[@]}"} --target "$TARGET" --tests \
  --message-format=json 2>/dev/null \
  | python3 -c '
import json, os, shutil, sys
stage = sys.argv[1]
staged = []
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("reason") != "compiler-artifact":
        continue
    if not msg.get("profile", {}).get("test"):
        continue
    exe = msg.get("executable")
    if not exe:
        continue
    # Name by target AND kind. Naming by target alone is not enough and silently loses tests:
    # the lib and the bin are BOTH called "wr-agent", so one overwrote the other in staging and
    # the lib suite — 63 tests — vanished while the run still reported success.
    kind = "_".join(msg["target"].get("kind", [])) or "bin"
    name = "{}__{}".format(msg["target"]["name"].replace("-", "_"), kind)
    shutil.copy2(exe, os.path.join(stage, name))
    staged.append(name)
print("\n".join(staged))
' "$STAGE" > "$STAGE/.manifest"

if [ ! -s "$STAGE/.manifest" ]; then
  echo "error: cargo reported no test binaries for $TARGET." >&2
  exit 1
fi
echo "test-linux: staged $(tr '\n' ' ' < "$STAGE/.manifest")"

# The agent binary itself, for the integration tests: WR_AGENT_BIN overrides the absolute host path
# cargo bakes in at compile time, which does not exist inside the container.
cargo zigbuild -p wr-agent ${FEATURES[@]+"${FEATURES[@]}"} --target "$TARGET" >/dev/null 2>&1
cp "target/${TARGET}/debug/wr-agent" "$STAGE/wr-agent"

IMAGE="${WR_LINUX_IMAGE:-docker.io/library/debian:stable-slim}"
echo "test-linux: running on $RUNTIME ($IMAGE)"
# bash, because one test reproduces an argv[0] rewrite with `exec -a`, which is a bashism and skips
# itself where /bin/bash is absent — silently losing the coverage it exists to provide.
"$RUNTIME" run --rm \
  --volume "$STAGE:/tests" \
  --env WR_AGENT_BIN=/tests/wr-agent \
  --env "WR_AGENT_HAS_TERMINAL_STATE=${WR_AGENT_HAS_TERMINAL_STATE:-}" \
  --env "WR_TEST_SHELL=/bin/sh" \
  "$IMAGE" \
  /bin/sh -c 'set -e
    # Run exactly what cargo said were tests, in the order it reported them.
    while read -r name; do
      [ -n "$name" ] || continue
      echo "== $name"
      "/tests/$name"
    done < /tests/.manifest'
