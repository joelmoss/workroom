#!/bin/bash
#
# OQ19 measurement runner. Runs the harness inside the measurement image (Linux), from any host.
#
#   vcs/scripts/oq19/run.sh --self-test
#   vcs/scripts/oq19/run.sh scenario <id> [--compressed] [--interval S] [--scale F] [--mode detached|attached] [--out DIR]
#   vcs/scripts/oq19/run.sh smoke [ids...]      # every scenario at a small scale + check_trace.py
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

in_container() { # in_container <out-dir-on-host> [runtime flags...] -- <cmd...>
  local out="$1"; shift
  local flags=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  mkdir -p "$out" && out="$(cd "$out" && pwd)"  # docker wants an absolute host path
  "$RUNTIME" run --rm --cpus=1 --memory=512m --cap-add=SYS_NICE ${flags[@]+"${flags[@]}"} \
    -v "$HERE:/oq19:ro" -v "$out:/out" -w /oq19 -e PYTHONDONTWRITEBYTECODE=1 \
    ${OQ19_VARIANT:+-e OQ19_VARIANT=$OQ19_VARIANT} "$IMAGE" "$@"
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
    EXTRA=()
    case "$ID" in
      3b | 4a | 4b | 9) # a peer in ANOTHER container: its traffic must cross the box's eth0, as a provider sees it
        NET="oq19-net-$$"; PEER="oq19-peer-$$"
        cleanup() { "$RUNTIME" rm -f "$PEER" >/dev/null 2>&1 || true; "$RUNTIME" network rm "$NET" >/dev/null 2>&1 || true; }
        trap cleanup EXIT
        "$RUNTIME" network create "$NET" >/dev/null
        "$RUNTIME" run -d --rm --name "$PEER" --network "$NET" --network-alias peer \
          -v "$HERE:/oq19:ro" -w /oq19 -e PYTHONDONTWRITEBYTECODE=1 "$IMAGE" python3 scenarios/tools/peer.py >/dev/null
        sleep 1
        EXTRA=(--network "$NET" --network-alias box -e OQ19_PEER=peer:9000)
        ;;
    esac
    in_container "$OUT" ${EXTRA[@]+"${EXTRA[@]}"} -- python3 driver.py --scenario "$ID" --out /out ${ARGS[@]+"${ARGS[@]}"}
    echo "trace: $OUT"
    ;;
  smoke)
    # Every scenario at a small scale, each followed by check_trace.py: proves the scenario did what its label
    # claims. PIPELINE CHECK ONLY (durations are scaled down); never a scored run.
    shift
    IDS=("$@")
    if [ ${#IDS[@]} -eq 0 ]; then
      IDS=($(python3 -c "import labels; print(' '.join(s.id for s in labels.SCENARIOS))"))
    fi
    FAILED=0
    mkdir -p "$HERE/traces/smoke"
    for ID in "${IDS[@]}"; do
      SCALE=0.05
      [ "$ID" = "17" ] && SCALE=0.02
      OUT="$HERE/traces/smoke/$ID"
      rm -rf "$OUT"
      if "$HERE/run.sh" scenario "$ID" --scale "$SCALE" --out "$OUT" >/dev/null 2>"$OUT.err"; then
        python3 check_trace.py "$OUT" || FAILED=$((FAILED + 1))
      else
        echo "FAIL $ID (the run itself failed)"; sed 's/^/   /' "$OUT.err" | tail -5; FAILED=$((FAILED + 1))
      fi
    done
    [ "$FAILED" -eq 0 ] && echo "smoke: all ${#IDS[@]} scenarios did what their labels say" || { echo "smoke: $FAILED failed"; exit 1; }
    ;;
  controls)
    # Negative controls for check_trace.py, over the traces `smoke` recorded: a run checked AS a scenario it is
    # not (same phase shape) must FAIL. A check that cannot fail proves nothing.
    BAD=0
    for pair in "4b:4a" "4a:4b" "2a:2b" "2b:2c" "2c:2a" "3a:3b" "8:13" "13:8"; do
      HAVE="${pair%%:*}"; AS="${pair##*:}"
      if python3 check_trace.py "$HERE/traces/smoke/$HAVE" --as "$AS" >/dev/null; then
        echo "NOT CAUGHT: the $HAVE trace passed as $AS"; BAD=$((BAD + 1))
      else
        echo "caught: the $HAVE trace fails as $AS"
      fi
    done
    [ "$BAD" -eq 0 ] && echo "controls: every wrong-scenario check failed, as it must" || { echo "controls: $BAD checks are vacuous"; exit 1; }
    ;;
  cost)
    in_container "$HERE/traces/cost" -- python3 cost.py /out
    ;;
  *)
    echo "usage: run.sh --self-test | scenario <id> [opts] | smoke [ids] | controls | cost" >&2
    exit 2
    ;;
esac
