#!/bin/bash
# Run a Rust gate on Linux: the canonical lint (`vcs-lint`, the default), including Linux-only code
# and terminal-state, or the tests (`vcs-test`, with VCS_TEST_FLAGS), as this user rather than
# root, so the tests that skip under root (a root daemon accepts no resume reports) run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUST_VERSION="${1:?pass the Makefile VCS_RUST version}"
TARGET="${2:-vcs-lint}"
case "$TARGET" in
  vcs-lint) label=vcs-lint-linux; make_args=("VCS_RUST=$RUST_VERSION") ;;
  vcs-test)
    label=vcs-test-linux
    make_args=("VCS_RUST=$RUST_VERSION" "VCS_TEST_FLAGS=${VCS_TEST_FLAGS:-}")
    ;;
  *) echo "lint-linux.sh: no gate '$TARGET'; use vcs-lint or vcs-test" >&2; exit 2 ;;
esac
if [ "$(uname -s)" = Linux ]; then
  exec make -C "$ROOT" "$TARGET" "${make_args[@]}"
fi

# Docker and Podman come before Apple's `container`. Measured 2026-11-20 in this image, with
# container 1.7.1 and Zig 0.17.1: deps.files.ghostty.org resolved to IPv6 and IPv4 addresses,
# `curl -4` reached it and `curl -6` didn't, and `zig fetch` of one of Ghostty's dependencies hung
# (inside the lint, the same fetch failed with TlsInitializationFailed). Under Docker `curl -6`
# failed too, yet that `zig fetch` succeeded and the whole lint passed. WR_LINT_RUNTIME names one
# runtime instead, with no fallback.
if [ -n "${WR_LINT_RUNTIME:-}" ]; then
  candidates=("$WR_LINT_RUNTIME")
else
  candidates=(docker podman container)
fi
runtime=""
for candidate in "${candidates[@]}"; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  case "$(basename "$candidate")" in
    container) "$candidate" system status >/dev/null 2>&1 || continue ;;
    *) "$candidate" info >/dev/null 2>&1 || continue ;;
  esac
  runtime="$candidate"
  break
done
if [ -z "$runtime" ] && [ -n "${WR_LINT_RUNTIME:-}" ]; then
  echo "$label: WR_LINT_RUNTIME=$WR_LINT_RUNTIME isn't working; start it, or unset WR_LINT_RUNTIME to try Docker, Podman and container in turn." >&2
  exit 1
fi
if [ -z "$runtime" ]; then
  echo "$label: no working container runtime; start Docker, Podman or container and retry." >&2
  exit 1
fi

zig_version="$(sed -n 's/^ZIG_VERSION="\([^"]*\)"/\1/p' "$ROOT/vcs/scripts/build-ghostty-vt.sh")"
# Different workrooms can build different Dockerfiles at the same Rust version.
image_hash="$( { shasum -a 256 "$ROOT/vcs/scripts/linux-lint/Dockerfile" 2>/dev/null \
  || sha256sum "$ROOT/vcs/scripts/linux-lint/Dockerfile"; } | cut -c1-12)"
image="workroom-linux-lint:$RUST_VERSION-$zig_version-$image_hash"
"$runtime" build --build-arg "RUST_VERSION=$RUST_VERSION" \
  --build-arg "ZIG_VERSION=$zig_version" --tag "$image" "$ROOT/vcs/scripts/linux-lint"

# Linux caches stay separate from native Cargo output and personal Cargo credentials. Cargo's
# registry, the home and libghostty-vt are shared by every checkout; the target dir is this
# checkout's own. Every checkout is mounted at the same /workroom, so in one shared target dir
# another workroom's older build of a crate looked fresh to cargo and was reused, and the lint
# failed on code this branch has ("cannot find type"; #832, three times).
cache="${XDG_CACHE_HOME:-$HOME/.cache}/workroom/linux-lint/$(uname -m)"
checkout="$( { printf '%s' "$ROOT" | shasum -a 256 2>/dev/null || printf '%s' "$ROOT" | sha256sum; } | cut -c1-12)"
mkdir -p "$cache/home"
# The daemon's build number, which build.rs reads from git: a linked checkout's metadata is outside
# the mount, so it is given. Any number does for the lint. The tests compare builds (an older one is
# refused), so they get HEAD's commit time, read here, as CI's build reads it from git.
build=1
tests=()
if [ "$TARGET" = vcs-test ]; then
  build="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null)" || build=1
  # The container runs as this user, whose uid the image has no account for (a Mac's 501), and
  # the tests that read their own account entry, as a host's daemon does, need one: root and this
  # user, home and shell as the container has them, as CI's runner has its own. Per checkout, so
  # two workrooms' runs never write the same file. Root is already the first entry, so a root
  # caller (a Linux dev container) adds no second uid 0.
  passwd="$cache/passwd-$checkout"
  {
    printf 'root:x:0:0:root:/root:/bin/bash\n'
    if [ "$(id -u)" != 0 ]; then
      printf '%s:x:%s:%s::/cache/home:/bin/bash\n' "$(id -un)" "$(id -u)" "$(id -g)"
    fi
  } > "$passwd.tmp"
  mv -f "$passwd.tmp" "$passwd"
  # The tests link every test binary, which the lint never does, and cargo starts one link per
  # CPU: 18 of them outgrew the container's 4G and ld was killed (2026-11-27), with full debug info
  # or line tables alike. Then 18 test threads, each with its own daemons and shells, starved the
  # relay and terminal API tests in two full runs (5 failures; each passes alone). Both are capped
  # at 4, as CI's Linux runners have, to fit the fixed --memory rather than this machine's CPUs,
  # at the cost of a slower run; raising --memory instead would depend on each Docker VM's size.
  jobs="${VCS_TEST_LINUX_JOBS:-4}"
  tests=(--volume "$passwd:/etc/passwd:ro" --env "CARGO_BUILD_JOBS=$jobs"
    --env "RUST_TEST_THREADS=$jobs")
fi
echo "$label: $runtime, Rust $RUST_VERSION, Zig $zig_version; cache $cache, target-$checkout for $ROOT"
# A linked checkout's .git points outside this mount. Fetches from a build script must
# not discover that host-only metadata; the engine's own cache remains a real git repo.
#
# Zig's caches stay inside the container, off the /cache mount. Docker Desktop's macOS bind
# mount does not make flock exclusive, and Zig's cache relies on it when several compile steps
# build the same entry at once: six concurrent builds sharing one fresh cache there left a
# compiler_rt without __divti3 and its kin in 1 round of 4, against 0 of 4 on the container's
# own filesystem (#599, measured 2026-11-08). That broken archive stayed cached and failed
# every later Ghostty pin.
# Zig runs only when libghostty-vt is not already built in /cache, so starting cold costs that
# one build.
exec "$runtime" run --rm --init --memory 4G --user "$(id -u):$(id -g)" \
  --volume "$ROOT:/workroom:ro" --volume "$cache:/cache" \
  --workdir /workroom --env HOME=/cache/home --env CARGO_HOME=/cache/cargo \
  --env "CARGO_TARGET_DIR=/cache/target-$checkout" --env WR_GHOSTTY_VT_CACHE=/cache/ghostty-vt \
  --env ZIG_GLOBAL_CACHE_DIR=/tmp/zig/global --env WR_GHOSTTY_VT_ZIG_CACHE=/tmp/zig \
  --env GIT_CEILING_DIRECTORIES=/workroom ${tests[@]+"${tests[@]}"} \
  --env "WORKROOMD_BUILD=$build" "$image" make "$TARGET" "${make_args[@]}"
