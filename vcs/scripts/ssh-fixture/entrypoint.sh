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

# The machine's identity is minted on its first boot, never inherited (#252, open question 9). A
# container committed from another and run again (`ContainerHostDriver.deriveFromBase`) starts with
# its source's disk: the ssh host keys (which openssh-server's install also bakes into the image),
# `/etc/machine-id`, and the agent's broker files beside its socket. The marker holds the hostname
# the identity was minted for. A restart keeps the container's hostname, so a reboot keeps its
# identity and its pinned host key; a new container has a new hostname, so it mints its own. The
# marker is written last: a boot that dies halfway mints again on the next one.
#
# Not re-mintable here: `/proc/sys/kernel/random/boot_id` is the kernel's, which every container
# on one machine shares. A VM provider's derived instance boots a kernel of its own.
IDENTITY=/etc/workroom-identity
if [ "$(cat "$IDENTITY" 2>/dev/null)" != "$(hostname)" ]; then
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
  # With the agent's interrupted saves (`.broker.json.<pid>`), which can hold a key.
  rm -f /run/workroom/broker.json /run/workroom/broker-token.json /run/workroom/.broker*
  # The Mac's relay (#309): its port and secret are the base's, and the app installs its own.
  rm -f /run/workroom/relay.json /run/workroom/.relay*
  rm -rf /home/workroom/.local/state/workroom/screens
  hostname > "$IDENTITY"
fi

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
# Only the fixture's image has one; a `workroom-host` waits for the app's (#253).
if [ -x /usr/local/bin/wr-agent ]; then
  install -o workroom -g workroom -m 700 /usr/local/bin/wr-agent "$AGENT"
fi

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

# The fixture's GitHub and broker (fake-github.py, #252), as the ssh user, with only the capability
# it needs for 443. `/etc/hosts` is the runtime's, written afresh at every start and never
# committed, so the name is mapped here each boot.
# Only in the fixture's image: a `workroom-host` talks to the real github.com (#253).
if [ -f /etc/workroom-fixture/github.pem ]; then
  grep -q ' github.com$' /etc/hosts || echo '127.0.0.1 github.com' >> /etc/hosts
  setpriv --reuid=workroom --regid=workroom --init-groups \
    --inh-caps=+net_bind_service --ambient-caps=+net_bind_service \
    env -i PATH=/usr/bin:/bin python3 /usr/local/bin/fake-github.py &
fi

exec /usr/sbin/sshd -D -e
