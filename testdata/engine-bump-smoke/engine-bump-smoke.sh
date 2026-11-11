#!/bin/sh
#
# Helpers for macapp/WorkroomAppUITests/EngineBumpSmokeUITests.swift, run from a Workroom pane's
# shell. The UI-test runner can read /tmp but cannot create files there or spawn processes, so a
# pane runs this and the runner reads what it writes into <dir>. Results are written through a temp
# file and renamed, so the runner never reads one half-written.
#
#   engine-bump-smoke.sh init <dir>           make <dir>, then write <dir>/ready
#   engine-bump-smoke.sh rss <dir> <label>    the app's resident size in KB -> <dir>/rss-<label>
#   engine-bump-smoke.sh leaks <dir> <label>  the bytes `leaks` finds leaked -> <dir>/leaks-<label>
#   engine-bump-smoke.sh kill <dir>           SIGKILL the app
#   engine-bump-smoke.sh crashwatch <dir>     wait for the app to exit, then <dir>/quit-result is
#                                             `clean` or `crash <report>`
set -u
cmd=$1
dir=$2

publish() { # publish <name> <value>
  printf '%s\n' "$2" > "$dir/$1.tmp" && mv "$dir/$1.tmp" "$dir/$1"
}

# The Workroom app this shell descends from: the first ancestor whose executable is named Workroom.
app_pid() {
  p=$$
  while [ "$p" -gt 1 ]; do
    case "$(ps -o comm= -p "$p")" in */Workroom*) echo "$p"; return 0 ;; esac
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  return 1
}

case "$cmd" in
  init)
    mkdir -p "$dir" && publish ready ok
    ;;
  rss)
    pid=$(app_pid) || exit 1
    publish "rss-$3" "$(ps -o rss= -p "$pid" | tr -d ' ')"
    ;;
  leaks)
    pid=$(app_pid) || exit 1
    leaks "$pid" > "$dir/leaks-$3.txt" 2>&1
    publish "leaks-$3" "$(sed -nE 's/.* ([0-9]+) total leaked bytes.*/\1/p' "$dir/leaks-$3.txt" | head -1)"
    ;;
  kill)
    pid=$(app_pid) || exit 1
    kill -9 "$pid"
    ;;
  crashwatch)
    pid=$(app_pid) || { publish quit-result "no app pid"; exit 0; }
    touch "$dir/quit-start"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    # ReportCrash takes a few seconds to write its report.
    sleep 5
    report=$(find "$HOME/Library/Logs/DiagnosticReports" -name '*Workroom*' \
      -newer "$dir/quit-start" 2>/dev/null | head -1)
    if [ -n "$report" ]; then publish quit-result "crash $report"; else publish quit-result clean; fi
    ;;
  *)
    echo "engine-bump-smoke.sh: unknown command $cmd" >&2
    exit 2
    ;;
esac
