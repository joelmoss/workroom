#!/bin/bash
#
# OQ19 measurement runner. Runs the harness inside the measurement image (Linux), from any host.
#
#   vcs/scripts/oq19/run.sh --self-test
#   vcs/scripts/oq19/run.sh scenario <id> [--compressed] [--interval S] [--scale F] [--mode detached|attached] [--out DIR]
#   vcs/scripts/oq19/run.sh cost
#
# Like vcs/scripts/test-linux.sh this is a convenience with a clean skip: when no container runtime works it
# says so and exits 0. It never starts anybody's daemon. Runtime preference: `container` (Apple), `docker`,
# `podman`; availability is decided by whether the runtime actually WORKS, not by whether it is on PATH.
#
# Each run gets its own container with `--cpus=1 --memory=512m` (plan decision D7: its own cgroup, so its
# cpu.stat is its own) and `--cap-add=SYS_NICE`. The capability is not optional: Docker drops it by default,
# and without it `nice -n -5` fails even as root (measured in the pipeline check), leaving the sampler at
# normal priority under a CPU-bound scenario.
set -euo pipefail

cd "$(dirname "$0")"
HERE="$(pwd)"

if [ "${1:-}" = "--self-test" ]; then
  # By file name, never `unittest discover`: discover exits 0 with "Ran 0 tests" when a suite disappears.
  python3 tests/test_gates.py
  python3 tests/test_procfs.py
  exit 0
fi

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
  echo "oq19: SKIP — no working container runtime (tried container, docker, podman)." >&2
  exit 0
fi

IMAGE="${OQ19_IMAGE:-oq19}"
if [ -n "${OQ19_REBUILD:-}" ] || ! "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
  "$RUNTIME" build -q -t "$IMAGE" "$HERE" >/dev/null
fi

in_container() { # in_container <out-dir-on-host> <cmd...>
  local out="$1"; shift
  mkdir -p "$out"
  "$RUNTIME" run --rm --cpus=1 --memory=512m --cap-add=SYS_NICE \
    -v "$HERE:/oq19:ro" -v "$out:/out" -w /oq19 -e PYTHONDONTWRITEBYTECODE=1 "$IMAGE" "$@"
}

case "${1:-}" in
  scenario)
    shift
    ID="${1:?scenario id}"; shift
    OUT="$HERE/traces/$ID-$(date +%Y%m%d-%H%M%S)"
    ARGS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
      esac
    done
    mkdir -p "$OUT"
    in_container "$OUT" python3 driver.py --scenario "$ID" --out /out ${ARGS[@]+"${ARGS[@]}"}
    echo "trace: $OUT"
    ;;
  cost)
    in_container "$HERE/traces/cost" python3 cost.py /out
    ;;
  *)
    echo "usage: run.sh --self-test | scenario <id> [opts] | cost" >&2
    exit 2
    ;;
esac
