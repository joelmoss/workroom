#!/bin/sh
#
# Stops every running copy of the app that carries the same bundle id as BUNDLE, and the session
# helpers running from such a copy, so `make app-run` can open BUNDLE fresh.
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
set -eu

bundle="${1:?usage: stop-dev-app.sh path/to/App.app}"
bundle="${bundle%/}"
name="$(basename "$bundle" .app)"

bundle_id() {
  plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null
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
processes="$(ps -ww -A -o pid= -o command=)"
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
  [ "$(bundle_id "$owner")" = "$want" ] || continue

  executable="${cmdline#"$owner/Contents/MacOS/"}"
  case "$executable" in
    "$name" | "$name "*)
      apps="$apps $pid"
      ;;
    wr-agent | "wr-agent "* | workroom-session | "workroom-session "*)
      helper="${executable%% *}"
      case " $stopped_helpers " in
        *" $helper "*) ;;
        *)
          echo "Stopping persisted $name $helper (its panes will come back empty)"
          stopped_helpers="$stopped_helpers $helper"
          ;;
      esac
      kill -TERM "$pid" 2>/dev/null || true
      ;;
  esac
done <<EOF
$processes
EOF

for pid in $apps; do
  kill -TERM "$pid" 2>/dev/null || true
done

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
