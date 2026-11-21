#!/bin/sh
#
# Stops the session daemons of dev builds that no longer exist, and removes their /tmp socket
# directories, so deleting a workroom does not leave its daemon and shells running forever.
#
#   sweep-dev-orphans.sh [--quiet]
#
# Each workroom builds "<worktree>/macapp/DerivedData/…/Workroom Dev.app" under its own bundle id
# (dev-identity.sh), and that build's `workroom serve` outlives the app by design. Once the worktree
# is deleted nothing ever stops it. Two things go, and nothing else:
#
# - a `workroom serve` whose argv[0] is `Contents/Resources/workroom` (ADR 0078), or a
#   `workroomd serve` (or `wr-agent serve`, from a build before the rename, #525) whose argv[0] is
#   the executable in `Contents/MacOS/` (a build before #681), inside a
#   `…/Build/Products/<config>/Workroom Dev.app` (this repo's DerivedData, or Xcode's) whose bundle
#   directory is gone.
#   A daemon whose bundle still exists is never touched, whatever it serves: stop-dev-app.sh owns
#   that. A release or Nightly app is not called "Workroom Dev", so its daemon never matches.
# - a dev socket directory `/tmp/workroom-<uid>-com.developwithstyle.workroom.dev.<suffix>` that no
#   live process names in its arguments, older than a minute. The trailing `.<suffix>` keeps out
#   the project checkout's plain-id directory; the age keeps out one an app made a moment ago and is
#   about to start its daemon in. A daemon this run stops does not count as live, so its directory
#   goes in the same run.
#
# SIGTERM only, as stop-dev-app.sh: the daemon's handler ends its sessions. Always exits 0, so
# `make app-run` and `make app-test`, which run it first, never fail on housekeeping. --quiet prints
# only what it stopped or removed, and nothing when there was nothing to do.
#
# For tests: STOP_DEV_APP_PS names a FILE holding a process table to read instead of running `ps`
# (dev-daemons.sh), STOP_DEV_APP_DRY_RUN=1 prints `stop <pid>` and `remove <dir>` instead of acting,
# and SWEEP_DEV_ORPHANS_TMP replaces /tmp as the directory holding the socket directories.
set -u

# shellcheck source=dev-daemons.sh
. "$(dirname "$0")/dev-daemons.sh"

quiet=""
[ "${1:-}" = "--quiet" ] && quiet=1

root="${SWEEP_DEV_ORPHANS_TMP:-/tmp}"
root="${root%/}"
prefix="workroom-$(id -u)-com.developwithstyle.workroom.dev."
dry="${STOP_DEV_APP_DRY_RUN:-}"
did=""

processes="$(process_table 2>/dev/null)" || processes=""

stopped=""
while read -r pid cmdline; do
  [ -n "$pid" ] || continue
  # The daemon is `Contents/Resources/workroom serve` since #681 (ADR 0078), and
  # `Contents/MacOS/workroomd serve` when an earlier build started it.
  case "$cmdline" in
    /*/"Workroom Dev.app/Contents/MacOS/"*) folder=MacOS ;;
    /*/"Workroom Dev.app/Contents/Resources/workroom serve "*) folder=Resources ;;
    *) continue ;;
  esac
  # The bundle has to be argv[0]'s, a build product's. stop-dev-app.sh can rely on the bundle
  # existing to rule out `tail -f …/Workroom Dev.app/…`, where "the bundle" is the whole command up
  # to it; here a missing bundle is the trigger, so a command that reaches the path only through
  # its arguments (` -f`, ` /…`) is ruled out by shape.
  owner="${cmdline%%/Contents/"$folder"/*}"
  case "$owner" in
    *" -"* | *" /"*) continue ;;
    /*/Build/Products/*/"Workroom Dev.app") ;;
    *) continue ;;
  esac
  executable="${cmdline#"$owner/Contents/$folder/"}"
  served_socket "$executable" >/dev/null || continue
  [ -d "$owner" ] && continue

  did=1
  stopped="$stopped $pid "
  if [ -n "$dry" ]; then
    echo "stop $pid"
  else
    echo "Stopped orphaned ${executable%% *} $pid (its bundle is gone: $owner)"
    kill -TERM "$pid" 2>/dev/null || true
  fi
done <<EOF
$processes
EOF

for dir in "$root/$prefix"*; do
  [ -d "$dir" ] || continue
  [ -L "$dir" ] && continue
  # Made or changed in the last minute: an app may be about to start its daemon here.
  [ -z "$(find "$dir" -prune -mmin -1 2>/dev/null)" ] || continue

  live=""
  while read -r pid cmdline; do
    [ -n "$pid" ] || continue
    case "$stopped" in *" $pid "*) continue ;; esac
    case "$cmdline" in
      *"$dir/"*)
        live=1
        break
        ;;
    esac
  done <<EOF
$processes
EOF
  [ -z "$live" ] || continue

  did=1
  if [ -n "$dry" ]; then
    echo "remove $dir"
  else
    rm -rf -- "$dir" && echo "Removed unserved socket directory $dir"
  fi
done

[ -n "$did" ] || [ -n "$quiet" ] || echo "No orphaned dev daemons or socket directories."
exit 0
