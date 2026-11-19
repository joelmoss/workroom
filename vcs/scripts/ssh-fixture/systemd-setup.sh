#!/bin/sh
# Boots the systemd fixture (#665), as a oneshot before sshd: mints the machine's identity on its
# first boot (entrypoint.sh says why), authorises the test's key, and installs the daemon where the
# app's bootstrap puts it, beside the socket. Nothing starts the daemon: that's the test's job.
#
# The runtime hands the container's environment to PID 1 only, so AUTHORIZED_KEY is read from it.
set -eu

IDENTITY=/etc/workroom-identity
if [ "$(cat "$IDENTITY" 2>/dev/null)" != "$(hostname)" ]; then
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  hostname > "$IDENTITY"
fi

key=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^AUTHORIZED_KEY=//p')
install -d -o workroom -g workroom -m 700 /home/workroom/.ssh
printf '%s\n' "$key" > /home/workroom/.ssh/authorized_keys
chown workroom:workroom /home/workroom/.ssh/authorized_keys
chmod 600 /home/workroom/.ssh/authorized_keys

# /run is a tmpfs: made again on every boot.
install -d -o workroom -g workroom -m 700 /run/workroom
if [ -x /usr/local/bin/workroomd ]; then
  install -o workroom -g workroom -m 700 /usr/local/bin/workroomd /run/workroom/workroomd
fi
