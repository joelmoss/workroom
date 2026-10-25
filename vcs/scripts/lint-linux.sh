#!/bin/bash
# Run the canonical lint gate on Linux, including Linux-only tests and terminal-state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUST_VERSION="${1:?pass the Makefile VCS_RUST version}"
if [ "$(uname -s)" = Linux ]; then
  exec make -C "$ROOT" vcs-lint "VCS_RUST=$RUST_VERSION"
fi

runtime=""
for candidate in container docker podman; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  case "$candidate" in
    container) "$candidate" system status >/dev/null 2>&1 || continue ;;
    *) "$candidate" info >/dev/null 2>&1 || continue ;;
  esac
  runtime="$candidate"
  break
done
if [ -z "$runtime" ]; then
  echo "vcs-lint-linux: no working container runtime; start container, Docker or Podman and retry." >&2
  exit 1
fi

zig_version="$(sed -n 's/^ZIG_VERSION="\([^"]*\)"/\1/p' "$ROOT/vcs/scripts/build-ghostty-vt.sh")"
# Different workrooms can build different Dockerfiles at the same Rust version.
image_hash="$( { shasum -a 256 "$ROOT/vcs/scripts/linux-lint/Dockerfile" 2>/dev/null \
  || sha256sum "$ROOT/vcs/scripts/linux-lint/Dockerfile"; } | cut -c1-12)"
image="workroom-linux-lint:$RUST_VERSION-$zig_version-$image_hash"
"$runtime" build --build-arg "RUST_VERSION=$RUST_VERSION" \
  --build-arg "ZIG_VERSION=$zig_version" --tag "$image" "$ROOT/vcs/scripts/linux-lint"

# Linux caches stay separate from native Cargo output and personal Cargo credentials.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/workroom/linux-lint/$(uname -m)"
mkdir -p "$cache/home"
echo "vcs-lint-linux: $runtime, Rust $RUST_VERSION, Zig $zig_version; cache $cache"
# A linked checkout's .git points outside this mount. Fetches from a build script must
# not discover that host-only metadata; the engine's own cache remains a real git repo.
exec "$runtime" run --rm --init --memory 4G --user "$(id -u):$(id -g)" \
  --volume "$ROOT:/workroom:ro" --volume "$cache:/cache" \
  --workdir /workroom --env HOME=/cache/home --env CARGO_HOME=/cache/cargo \
  --env CARGO_TARGET_DIR=/cache/target --env WR_GHOSTTY_VT_CACHE=/cache/ghostty-vt \
  --env GIT_CEILING_DIRECTORIES=/workroom \
  --env WORKROOMD_BUILD=1 "$image" make vcs-lint "VCS_RUST=$RUST_VERSION"
