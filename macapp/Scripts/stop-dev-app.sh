#!/bin/sh
#
# Stops every running copy of the app that carries the same bundle id as BUNDLE, and the session
# helpers serving that id, so `make app-run` can open BUNDLE fresh.
#
#   stop-dev-app.sh "path/to/Workroom Dev.app"
#
# By bundle id, not by process name. `open` on a bundle whose id is already running activates the
# running copy instead of launching this one, so every copy with this id has to go first, including
# one Xcode built into its own DerivedData. Nothing else may: every workroom now builds its own id
# under the same process name (dev-identity.sh), so the `pkill -x "Workroom Dev"` this replaces also
# SIGTERMed other workrooms' dev apps, their unit-test hosts and their XCUITest apps mid-run, and
# its `pkill -f "Workroom Dev.app/Contents/MacOS/wr-agent"` ended every workroom's terminal sessions.
#
# SIGTERM throughout, as before: the app's SIGTERM handler is what flushes its session and stops its
# run commands gracefully (WorkroomApp.swift, installSigtermHandler).
#
# For tests: STOP_DEV_APP_PS replaces the `ps` command that lists processes, and
# STOP_DEV_APP_DRY_RUN=1 prints `stop <pid>` for each process instead of signalling it.
set -eu

bundle="${1:?usage: stop-dev-app.sh path/to/App.app}"
bundle="${bundle%/}"
name="$(basename "$bundle" .app)"

bundle_id() {
  plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

# The bundle id whose socket a `wr-agent serve` listens on, read from its `--socket` argument:
# `…/Application Support/<id>/sessions/agent.sock`, or PersistentSessionPaths' fallback
# `/tmp/workroom-<uid>-<id>/agent.sock`. Fails for any other shape. A hand-off keeps the arguments.
served_id() {
  case "$1" in
    "wr-agent serve "*"--socket "*) ;;
    *) return 1 ;;
  esac
  socket="${1#*--socket }"
  socket="${socket%% --*}"
  directory="${socket%/*}"
  case "$directory" in
    */sessions)
      directory="${directory%/sessions}"
      printf '%s\n' "${directory##*/}"
      ;;
    */workroom-*-*)
      directory="${directory##*/}"
      printf '%s\n' "${directory#workroom-*-}"
      ;;
    *) return 1 ;;
  esac
}

stop() {
  if [ -n "${STOP_DEV_APP_DRY_RUN:-}" ]; then
    echo "stop $1"
  else
    kill -TERM "$1" 2>/dev/null || true
  fi
}

if ! want="$(bundle_id "$bundle")" || [ -z "$want" ]; then
  echo "stop-dev-app: cannot read the bundle id of $bundle" >&2
  exit 1
fi

apps=""
stopped_helpers=""
# `-ww`: never truncate the command, which is where the path is. The COMMAND column is argv, so a
# process only counts when argv[0] is itself the executable inside a bundle: the part before the
# first `/Contents/MacOS/` must be an existing `<name>.app` directory. That keeps out a process
# that merely mentions such a path in its arguments (`tail -f …/wr-agent.log`).
processes="$(${STOP_DEV_APP_PS:-ps -ww -A -o pid= -o command=})"
while read -r pid cmdline; do
  case "$cmdline" in
    /*/"$name.app/Contents/MacOS/"*) ;;
    *) continue ;;
  esac
  owner="${cmdline%%/Contents/MacOS/*}"
  case "$owner" in
    */"$name.app") ;;
    *) continue ;;
  esac
  [ -d "$owner" ] || continue

  executable="${cmdline#"$owner/Contents/MacOS/"}"
  case "$executable" in
    "$name" | "$name "*)
      [ "$(bundle_id "$owner")" = "$want" ] || continue
      apps="$apps $pid"
      ;;
    wr-agent | "wr-agent "* | workroom-session | "workroom-session "*)
      # A helper belongs to the id whose socket it serves, and that is not always the id of the
      # bundle its binary lives in: an agent runs whichever copy spawned it or last handed it off,
      # so one still serving the plain id can run from a workroom's bundle that has since been
      # rebuilt under the workroom's own id — and stopping it would end the project checkout's
      # sessions. Only `wr-agent serve` names its socket; anything else (a pane's attach client,
      # an old Swift daemon) goes by its bundle.
      served="$(served_id "$executable")" || served="$(bundle_id "$owner")" || served=""
      [ "$served" = "$want" ] || continue
      helper="${executable%% *}"
      case " $stopped_helpers " in
        *" $helper "*) ;;
        *)
          echo "Stopping persisted $name $helper (its panes will come back empty)"
          stopped_helpers="$stopped_helpers $helper"
          ;;
      esac
      stop "$pid"
      ;;
  esac
done <<EOF
$processes
EOF

for pid in $apps; do
  stop "$pid"
done
[ -z "${STOP_DEV_APP_DRY_RUN:-}" ] || exit 0

# Give each copy up to 8s to run its SIGTERM handler, as `make app-run` always has.
i=0
while [ $i -lt 40 ]; do
  alive=""
  for pid in $apps; do
    if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
  done
  [ -n "$alive" ] || break
  apps="$alive"
  sleep 0.2
  i=$((i + 1))
done
