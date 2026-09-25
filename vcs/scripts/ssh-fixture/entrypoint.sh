#!/bin/sh
# Boots the ssh fixture: authorises the test's key, starts the agent's supervisor, then runs sshd.
#
# The loop below IS the fixture's supervisor, the per-driver piece the design doc puts on the far
# side. It starts the agent at boot and again whenever it exits, for any reason, so a crashed agent
# comes back without a client doing anything. A real host does the same with a systemd unit.
#
# Run it with `--init`: when the agent dies, its sessions' shells are orphaned, and something at
# PID 1 has to reap them.
set -eu

mkdir -p /run/sshd
install -d -o workroom -g workroom -m 700 /run/workroom /home/workroom/.ssh
printf '%s\n' "$AUTHORIZED_KEY" > /home/workroom/.ssh/authorized_keys
chown workroom:workroom /home/workroom/.ssh/authorized_keys
chmod 600 /home/workroom/.ssh/authorized_keys

# The agent the supervisor runs lives beside the socket, in the ssh user's own 0700 directory: that
# is where the app installs the one it bundles (issue #231, `AgentBootstrap`), by renaming a
# checked copy into place, and where the relay and the attach run from. The image's copy in
# /usr/local/bin is root's and stays: it seeds this one at boot, as a host that already had an
# agent, and it is the client run.sh and the Rust tests use over ssh. A test that removes the
# installed one models a host with no agent, and the loop idles until the app pushes one.
AGENT=/run/workroom/wr-agent
install -o workroom -g workroom -m 700 /usr/local/bin/wr-agent "$AGENT"

# `--idle-timeout never`: a remote agent must keep running with no client attached, because its
# BUSY/IDLE reports have to keep flowing while the Mac sleeps. Run as the ssh user, so the relay
# that user runs can reach the socket. `env -i`, because the agent's environment is what every git
# it runs gets (the app sends none from the Mac), and this script's own holds AUTHORIZED_KEY.
#
# `--screens`: each session's screen is kept, so a pane that reattaches after the box reboots is
# shown its last one (#232). In the home directory, never beside the socket: /run is tmpfs on a real
# host, so a reboot would take them.
(
  while :; do
    if [ -x "$AGENT" ]; then
      setpriv --reuid=workroom --regid=workroom --init-groups \
        env -i HOME=/home/workroom USER=workroom SHELL=/bin/bash PATH=/usr/local/bin:/usr/bin:/bin \
        "$AGENT" serve --socket /run/workroom/agent.sock --idle-timeout never \
          --screens /home/workroom/.local/state/workroom/screens || true
    fi
    sleep 1
  done
) &

exec /usr/sbin/sshd -D -e
