#!/bin/sh
# Sets up a new Railway sandbox as a workroom's host (#629). Run as root over the relay, the
# script on stdin:
#
#   sh -s -- <host id> <daemon socket> <screens>
#
# <screens> is the daemon's own, beside its socket (`DaemonBootstrap.screens`), and its layouts
# are beside that.
#
# A sandbox has no systemd and no sshd (the relay terminates ssh), so there is no identity unit or
# supervisor to install: the app starts the daemon from an ssh login, and it outlives that login
# (`DaemonBootstrap`, start.sh). Its /etc/machine-id is empty, on a fork too, so the host gets an
# identity of its own here: the workroom host's id, in Workroom's marker and as the machine id.
#
# A host made from a checkpoint (#633) boots from a copy of a used host's disk: its source's
# identity, machine id, terminals and pane layouts are all there. So both ids
# (/etc/workroom-identity and /etc/machine-id) are always written,
# and the screens and layouts emptied, as boxd's identity unit does on a snapshot's first boot.
# WORKROOM_ETC points the ids elsewhere for a test only.
set -eu
id=$1
socket=$2
screens=$3
etc=${WORKROOM_ETC:-/etc}

daemon_dir=${socket%/*}
# The daemon keeps its layouts beside its screens (`layout::dir_beside`).
layouts="${screens%/*}/layouts"
rm -rf "$screens" "$layouts"
(umask 077 && mkdir -p "$daemon_dir" "$screens")
chmod 700 "$daemon_dir" "$screens"

rm -f "$etc/machine-id"
printf '%s\n' "$id" | tr -d '-' > "$etc/machine-id"
chmod 444 "$etc/machine-id"
printf '%s\n' "$id" > "$etc/workroom-identity"
chmod 644 "$etc/workroom-identity"
