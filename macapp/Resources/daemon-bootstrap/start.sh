#!/bin/sh
# Start the user's daemon on an SSH host, only if nothing is listening. No supervisor or root
# setup: the daemon stays until the server reboots or the user ends it (ADR 0056).
#
#   sh -c "$(cat start.sh)" start <binary> <socket> <screens> <idle timeout>
#
# WRB started <pid> identifies this connect's process for the kill/reconnect fixture test. All
# descriptors are detached from ssh; serve notices stderr is /dev/null and logs beside its socket.
#
# A user who lingers gets the daemon as a transient unit under their own systemd manager (#665):
# a process left in this ssh login's session scope dies at logout on a server whose logind has
# KillUserProcesses=yes, and lingering alone doesn't save it. Without linger the user manager stops
# soon after the last login, so everyone else gets today's detached start. When the unit can't be
# started, WRB systemd-run-failed says why and today's start runs instead.
set -u
binary=$1
socket=$2
screens=$3
idle=$4

if "$binary" list --socket "$socket" > /dev/null 2>&1; then
  echo "WRB serving yes"
  exit 0
fi

state=${socket%/*}
[ "${state##*/}" != daemon ] || state=${state%/*}
if ! (
  umask 077
  mkdir -p "${socket%/*}" "$screens" && chmod 700 "$state" "${socket%/*}" "$screens"
); then
  echo "WRB serving no"
  exit 1
fi

user=${USER:-$(id -un)}
# The daemon's command, the same on both paths: a fixed environment (the systemd unit's), never
# the ssh login's, and its fixed argv.
set -- "$(command -v env)" -i HOME="$HOME" USER="$user" SHELL="${SHELL:-/bin/sh}" \
  PATH=/usr/local/bin:/usr/bin:/bin \
  "$binary" serve --socket "$socket" --idle-timeout "$idle" --screens "$screens"
started=
unit_started=
if command -v systemd-run > /dev/null 2>&1 && command -v loginctl > /dev/null 2>&1 &&
  [ "$(loginctl show-user "$user" -p Linger 2> /dev/null)" = Linger=yes ]; then
  # An ssh login without pam_systemd has no XDG_RUNTIME_DIR; a lingering user's is always here.
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  export XDG_RUNTIME_DIR
  # Named from the socket, so Release and Nightly share one unit and a Dev build has its own. A
  # unit whose daemon died while a session's process lived on stays loaded until that process
  # ends, and nothing frees its name sooner without killing the process, so the second name is
  # this start's own.
  base=workroomd-$(printf %s "$socket" | cksum | cut -d' ' -f1)
  failure=
  for unit in "$base" "$base-$$"; do
    systemctl --user reset-failed "$unit.service" > /dev/null 2>&1
    if failure=$(systemd-run --user --quiet --collect --unit="$unit" \
      -p KillMode=process -p UMask="$(umask)" \
      -p StandardInput=null -p StandardOutput=null -p StandardError=null \
      -- "$@" < /dev/null 2>&1); then
      started=$(systemctl --user show -p MainPID --value "$unit.service" 2> /dev/null)
      [ "$started" != 0 ] || started=
      unit_started=yes
      break
    fi
  done
  [ -n "$unit_started" ] || echo "WRB systemd-run-failed $(printf '%s' "$failure" | tr '\n' ' ')"
fi

if [ -z "$unit_started" ]; then
  if ! command -v setsid > /dev/null 2>&1; then
    echo "WRB error install setsid on the host to start the daemon"
    echo "WRB serving no"
    exit 1
  fi
  nohup setsid "$@" < /dev/null > /dev/null 2>&1 &
  started=$!
fi
i=0
while [ "$i" -lt 50 ]; do
  if "$binary" list --socket "$socket" > /dev/null 2>&1; then
    [ -z "$started" ] || echo "WRB started $started"
    echo "WRB serving yes"
    exit 0
  fi
  sleep 0.2
  i=$((i + 1))
done
echo "WRB serving no"
exit 1
