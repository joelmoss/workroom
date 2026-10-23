#!/bin/sh
# The daemon bootstrap's check of a daemon its driver placed (issue #308; `DaemonBootstrap` in the
# app runs it in a container, once the container's runtime has copied the bundled `workroomd` in or
# mounted it from the Mac):
#
#   sh -c "$(cat placed.sh)" placed <binary> <socket> <hand-off 0|1>
#
# The second half of install.sh, for a binary that is already on the host: run it once (`protocol`:
# does it run here at all), then offer it to the running daemon (`hand-off`, issue #230). The app
# moves a staged binary into place, or removes it, by what this says: the daemon's folder is root's,
# and this runs as the remote user. Every line it prints is prefixed `WRB `:
#
#   WRB outcome installed | handed-off | current | kept-older <why> | refused <why> | does-not-run
#   WRB serving yes | no     when no daemon was listening: did one start within 10 s?
#
# The exit statuses of `hand-off`, and why each is kept or refused, are install.sh's.
set -u
binary=$1
socket=$2
handoff=$3

if ! "$binary" protocol > /dev/null 2>&1; then
  echo "WRB outcome does-not-run"
  exit 1
fi

outcome=installed
listening=no
if [ "$handoff" = 1 ] && [ -S "$socket" ]; then
  said=$("$binary" hand-off --socket "$socket" --binary "$binary" 2>&1)
  code=$?
  case $code in
    0)
      listening=yes
      case $said in
        current) outcome=current ;;
        *) outcome=handed-off ;;
      esac
      ;;
    3)
      listening=yes
      outcome="kept-older the daemon predates hand-off"
      ;;
    92)
      case $said in
        *"no daemon listening"*) ;;
        *)
          listening=yes
          outcome="kept-older the daemon did not greet"
          ;;
      esac
      ;;
    *)
      echo "WRB outcome refused $(printf '%s' "$said" | head -n 1)"
      exit 1
      ;;
  esac
elif [ -S "$socket" ]; then
  listening=yes
  outcome="kept-older hand-off is off"
fi
echo "WRB outcome $outcome"

# A container's daemon is its entrypoint, so one not listening yet is one still starting.
if [ "$listening" = no ]; then
  i=0
  while [ "$i" -lt 50 ]; do
    if "$binary" list --socket "$socket" > /dev/null 2>&1; then
      echo "WRB serving yes"
      exit 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "WRB serving no"
  exit 1
fi
