#!/bin/sh
# Sets up a new Railway sandbox as a workroom's host (#629). Run as root over the relay, the
# script on stdin:
#
#   sh -s -- <host id> <daemon socket> <screens>
#
# A sandbox has no systemd and no sshd (the relay terminates ssh), so there is no identity unit or
# supervisor to install: the app starts the daemon from an ssh login, and it outlives that login
# (`DaemonBootstrap`, start.sh). Its /etc/machine-id is empty, on a fork too, so the host gets an
# identity of its own here: the workroom host's id, in Workroom's marker and as the machine id.
set -eu
id=$1
socket=$2
screens=$3

daemon_dir=${socket%/*}
(umask 077 && mkdir -p "$daemon_dir" "$screens")
chmod 700 "$daemon_dir" "$screens"

if [ ! -s /etc/machine-id ]; then
  printf '%s\n' "$id" | tr -d '-' > /etc/machine-id
  chmod 444 /etc/machine-id
fi
printf '%s\n' "$id" > /etc/workroom-identity
chmod 644 /etc/workroom-identity
