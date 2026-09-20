#!/usr/bin/env bash
# T7: the boxd confirmation run (plan section "boxd confirmation run"; owner-approved: creates cloud machines).
#
#   vcs/scripts/oq19/boxd/boxd.sh            # ~1.7 h; needs the boxd CLI signed in; run under caffeinate
#   vcs/scripts/oq19/analyze.py boxd         # afterwards: results/boxd.md
#
# Machines (all named oq19-*, all destroyed by the EXIT trap, `boxd machine list` checked empty afterwards):
#   oq19-peer       timers 0     the network peer for 3b/4b (a container sidecar in the local harness)
#   oq19-treatment  120 s/120 s  the frozen policy driving the item-5 shim; runs 4b, 3a, 3b, 5, 16
#   oq19-control    120 s/120 s  NO policy, no shim; runs 4b and must hibernate mid-wait (D11)
#   oq19-fork       120 s/120 s  a fork of the treatment after its run: clock check + scenario 1 closed loop
# Pass (analyze.py boxd): the treatment never hibernated inside a BUSY interval AND the control did; the
# treatment hibernated within the idle window + provider timeout after its last IDLE; CLOCK_MONOTONIC advanced
# at wall rate on the fork. Nothing execs into the treatment or the control while a run is in flight: the
# exec's own connection is network activity to the provider's timers. Status is polled from the control plane.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OQ19_BOXD_OUT:-$HERE/traces/boxd}
TIMEOUT=${OQ19_BOXD_TIMEOUT:-120}
POLL=30
TREATMENT_IDS="4b 3a 3b 5 16"
CONTROL_IDS="4b"
FROZEN="$HERE/results/frozen.json"

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$OUT/boxd.log"; }
machines() { boxd machine list --json 2>/dev/null | python3 -c '
import json, sys
rows = json.load(sys.stdin)
rows = rows if isinstance(rows, list) else rows.get("machines", rows.get("items", []))
for m in rows:
    n = m.get("name") or m.get("id")
    if n and n.startswith("oq19-"): print(n)'; }
status_of() { boxd machine get "$1" --json 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin)
for k in ("status", "state", "power_state"):
    if k in m: print(m[k]); break
else: print("?")'; }
cleanup() {
  set +e
  log "cleanup: destroying every oq19-* machine"
  for m in $(machines); do boxd machine rm -y "$m" >/dev/null 2>&1 && log "  removed $m" || log "  FAILED to remove $m"; done
  left=$(machines)
  if [ -n "$left" ]; then log "MACHINES LEFT RUNNING: $left"; else log "boxd machine list: no oq19-* machines"; fi
  [ -n "${POLLER:-}" ] && kill "$POLLER" 2>/dev/null
}
trap cleanup EXIT

command -v boxd >/dev/null || { echo "boxd CLI not found" >&2; exit 2; }
[ -f "$FROZEN" ] || { echo "no $FROZEN: freeze the tuning winner first" >&2; exit 2; }
if [ -n "$(machines)" ]; then echo "oq19-* machines already exist: $(machines)" >&2; exit 2; fi
mkdir -p "$OUT"
: > "$OUT/boxd.log"
CLOSED=$(python3 -c '
import json, sys
f = json.load(open(sys.argv[1]))
import os; sys.path.insert(0, os.path.dirname(sys.argv[1]) + "/..")
import gates
print(json.dumps({"config": f["config"], "window_s": gates.WINDOW_GRID_S[f["config"]["window"]]}))' "$FROZEN")
log "frozen config: $CLOSED"
git -C "$HERE" rev-parse HEAD > "$OUT/harness_commit"

# The harness as committed, never the working tree (record.py's rule), without traces/.
STAGE=$(mktemp -d)
git -C "$HERE" archive HEAD "$(git -C "$HERE" rev-parse --show-prefix)" | tar -x -C "$STAGE"
HARNESS="$STAGE/$(git -C "$HERE" rev-parse --show-prefix)"

new() { # name suspend hibernate
  log "creating $1 (timers $2/$3)"
  boxd machine new "$1" --auto-suspend-timeout "$2" --auto-hibernate-timeout "$3" --json > "$OUT/$1.create.json"
  boxd machine cp -r "$HARNESS" "$1:/oq19" >/dev/null   # `boxd machine cp --help`: <machine>:/path
  boxd machine exec "$1" --timeout 900 -- sh /oq19/setup.sh > "$OUT/$1.setup.log" 2>&1
  log "  $1 ready: $(tail -1 "$OUT/$1.setup.log")"
}
detach() { # name command...  (a detached job: the exec session ends at once; no quotes inside the command)
  local m="$1"; shift
  boxd machine exec "$m" --timeout 30 -- sh -c "setsid nohup $* >/dev/null 2>&1 </dev/null &"
}
put() { # name path content
  printf '%s' "$3" > "$STAGE/put.tmp" && boxd machine cp "$STAGE/put.tmp" "$1:$2" >/dev/null
}

new oq19-peer 0 0
PEER_IP=$(boxd machine exec oq19-peer -- sh -c "hostname -I | awk '{print \$1}'" | tr -d '[:space:]')
log "peer at $PEER_IP"
detach oq19-peer python3 /oq19/scenarios/tools/peer.py

new oq19-treatment "$TIMEOUT" "$TIMEOUT"
new oq19-control "$TIMEOUT" "$TIMEOUT"
for m in oq19-treatment oq19-control; do detach "$m" sh /oq19/boxd/ticks.sh /oq19-out/ticks.log; done

# Control-plane status poll, host wall clock, for as long as the script runs.
( while :; do for m in $(machines); do echo "$(date +%s) $m $(status_of "$m")"; done >> "$OUT/status.log"; sleep $POLL; done ) &
POLLER=$!

START=$(date +%s)
put oq19-treatment /oq19-out/closed.json "$CLOSED"
detach oq19-treatment sh /oq19/boxd/runall.sh treatment "'$TREATMENT_IDS'" "$PEER_IP:9000" /oq19-out/closed.json
detach oq19-control sh /oq19/boxd/runall.sh control "'$CONTROL_IDS'" "$PEER_IP:9000"
log "runs launched on the treatment ($TREATMENT_IDS) and the control ($CONTROL_IDS)"

# Expected wall time of the treatment's list plus the post-run idle window and provider timeout, then margin.
EXPECT=$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import labels
ids = sys.argv[2].split()
print(int(sum(labels.seconds(p) for i in ids for p in labels.BY_ID[i].phases) + 20 * len(ids)))' "$HERE" "$TREATMENT_IDS")
WAIT=$((EXPECT + 30 + TIMEOUT + 180))
log "waiting $WAIT s for the runs, the post-run idle and the provider timer"
while [ $(( $(date +%s) - START )) -lt $WAIT ]; do sleep $POLL; done

log "waking both machines to collect"
for m in oq19-treatment oq19-control; do boxd machine wake "$m" >/dev/null 2>&1 || true; done
sleep 5
for m in oq19-treatment oq19-control; do
  mkdir -p "$OUT/$m"
  boxd machine cp -r "$m:/oq19-out" "$OUT/$m/"
  log "  collected $m: $(ls "$OUT/$m/oq19-out" 2>/dev/null | tr '\n' ' ')"
done

# The fork: a derived machine, where the design doc says /proc/uptime lies.
log "forking the treatment"
boxd machine fork oq19-treatment oq19-fork --auto-suspend-timeout "$TIMEOUT" --auto-hibernate-timeout "$TIMEOUT" --json > "$OUT/oq19-fork.create.json"
boxd machine exec oq19-fork --timeout 120 -- sh -c "rm -rf /oq19-out; mkdir -p /oq19-out; sh /oq19/boxd/clockcheck.sh /oq19-out/clock.log" || true
put oq19-fork /oq19-out/closed.json "$CLOSED"
detach oq19-fork sh /oq19/boxd/ticks.sh /oq19-out/ticks.log
detach oq19-fork sh /oq19/boxd/runall.sh fork 1 "$PEER_IP:9000" /oq19-out/closed.json
FSTART=$(date +%s)
FWAIT=$((300 + 20 + 30 + TIMEOUT + 180))
log "fork: clock check done, scenario 1 launched; waiting $FWAIT s"
while [ $(( $(date +%s) - FSTART )) -lt $FWAIT ]; do sleep $POLL; done
boxd machine wake oq19-fork >/dev/null 2>&1 || true
sleep 5
mkdir -p "$OUT/oq19-fork"
boxd machine cp -r "oq19-fork:/oq19-out" "$OUT/oq19-fork/"
log "collected the fork; done. Now: analyze.py boxd"
