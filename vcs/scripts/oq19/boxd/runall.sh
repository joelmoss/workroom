#!/bin/sh
# Runs a list of scenarios on the VM, one after another, detached from any exec session (the exec's own
# connection would count as network activity to the provider's idle timers). Writes /oq19-out/<id>/ per run,
# the shim's assert/release timeline to /oq19-out/shim.log, then /oq19-out/done.
#
#   runall.sh <role: treatment|control|fork> "<scenario ids>" <peer-host:port> [closed-loop-json-file]
role="$1"; ids="$2"; peer="$3"; closed_file="${4:-}"
cd /oq19 || exit 1
export OQ19_PROCS=all OQ19_PEER="$peer" PYTHONDONTWRITEBYTECODE=1
if [ "$role" != control ]; then
  # item 5's lever, once per transition: the in-VM CLI sets this machine's own idle timers to 0 while BUSY
  export OQ19_ASSERT='echo "$(date +%s) assert" >> /oq19-out/shim.log; boxd machine config set auto-hibernate.timeout 0 >> /oq19-out/shim.log 2>&1 && boxd machine config set auto-suspend.timeout 0 >> /oq19-out/shim.log 2>&1'
  export OQ19_RELEASE='echo "$(date +%s) release" >> /oq19-out/shim.log; boxd machine config set auto-hibernate.timeout 120 >> /oq19-out/shim.log 2>&1 && boxd machine config set auto-suspend.timeout 120 >> /oq19-out/shim.log 2>&1'
fi
for id in $ids; do
  out="/oq19-out/$id"
  mkdir -p "$out"
  echo "$(date +%s) start $id" >> /oq19-out/runall.log
  if [ -n "$closed_file" ]; then
    python3 driver.py --scenario "$id" --out "$out" --closed-loop "$(cat "$closed_file")" > "$out/driver.log" 2>&1
  else
    python3 driver.py --scenario "$id" --out "$out" > "$out/driver.log" 2>&1
  fi
  echo "$(date +%s) exit $? $id" >> /oq19-out/runall.log
  python3 check_trace.py "$out" > "$out/check.log" 2>&1 || true
done
date +%s > /oq19-out/done
