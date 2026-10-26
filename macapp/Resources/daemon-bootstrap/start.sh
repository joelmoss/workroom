#!/bin/sh
# Start the user's daemon on an SSH host, only if nothing is listening. No supervisor or root
# setup: the daemon stays until the server reboots or the user ends it (ADR 0056).
#
#   sh -c "$(cat start.sh)" start <binary> <socket> <screens> <idle timeout>
#
# WRB started <pid> identifies this connect's process for the kill/reconnect fixture test. All
# descriptors are detached from ssh; serve notices stderr is /dev/null and logs beside its socket.
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
if ! command -v setsid > /dev/null 2>&1; then
  echo "WRB error install setsid on the host to start the daemon"
  echo "WRB serving no"
  exit 1
fi

nohup setsid env -i HOME="$HOME" USER="${USER:-$(id -un)}" SHELL="${SHELL:-/bin/sh}" \
  PATH=/usr/local/bin:/usr/bin:/bin \
  "$binary" serve --socket "$socket" --idle-timeout "$idle" --screens "$screens" \
  < /dev/null > /dev/null 2>&1 &
started=$!
i=0
while [ "$i" -lt 50 ]; do
  if "$binary" list --socket "$socket" > /dev/null 2>&1; then
    echo "WRB started $started"
    echo "WRB serving yes"
    exit 0
  fi
  sleep 0.2
  i=$((i + 1))
done
echo "WRB serving no"
exit 1
