#!/bin/sh
# Makes a fresh systemd machine a Workroom base (issue #256; shared by every provider driver since
# #259: `BoxdHostDriver.create` runs it as root over the driver's ssh, with this script on stdin):
#
#   sudo sh -s -- <user> <agent socket> <screens directory>  < systemd.sh
#
# It needs systemd as PID 1 and a hostname the provider gives each machine its own of (boxd names
# a machine on restore; exe.dev's `cp` boots the copy under its new name). Written for boxd, it runs
# unchanged on exe.dev (spike, 2026-10-08).
#
# It installs the two far-side pieces the design doc gives a provider (Phase 3, "A lifecycle shim";
# Phase 4, the derive sequence), both as systemd units, so they come back with every boot:
#
# - workroom-identity: mints the machine's identity once per machine, before the agent starts. A
#   workroom is derived from a snapshot of its base (`BoxdHostDriver.deriveFromBase`), and a
#   snapshot carries the base's disk: its ssh host keys, `/etc/machine-id` and whatever the agent
#   kept beside its socket. boxd gives every machine its own hostname, so the marker holds the
#   hostname the identity was minted for, and a machine whose hostname differs from it mints its
#   own. A stop and start keeps the hostname, so it keeps the identity, and with it the agent's
#   enrolment. The marker is written last: a boot that dies halfway mints again on the next one.
#   boot_id needs nothing here: the derive reboots the instance, which gives it a kernel of its own.
#   Renaming the machine (`boxd machine rename`) would mint a new identity and drop its enrolment.
# - workroom-agent: the agent's supervisor. It starts the agent the app installs beside its socket
#   (`AgentBootstrap`), at boot and again whenever it exits, and waits for one to be installed
#   when there is none yet, as the ssh fixture's loop does. `--idle-timeout never`, because a remote
#   agent must keep running with no client attached; `--screens` on the home disk, which outlives
#   a reboot (#232).
#
# Everything the agent keeps (its binary, socket, broker enrolment and token, and the screens) is
# on the home disk, not under the tmpfs `/run`: a boxd machine that is stopped and started keeps its
# enrolment, and its panes come back with their last screens.
#
# Safe to run again: it rewrites the units and restarts nothing that is running.
set -eu
user=$1
socket=$2
screens=$3
agent_dir=$(dirname "$socket")
agent="$agent_dir/wr-agent"
home=$(getent passwd "$user" | cut -d: -f6)

case "$socket$screens" in
  *[!A-Za-z0-9/._-]*)
    echo "workroom: refusing a path systemd would need quoted: $socket $screens" >&2
    exit 2
    ;;
esac

# The socket's directory is the trust boundary (a client of the socket can type into every
# session), so it is the user's own and 0700, as is every directory above it that this creates.
umask 077
# Made as the user, so every directory made on the way to them is the user's too: the agent keeps
# its layouts beside its screens (#255), and a parent left to root refuses them.
runuser -u "$user" -- mkdir -p "$agent_dir" "$screens"
chmod 700 "$agent_dir" "$screens"
install -d -m 755 /usr/local/libexec

cat > /usr/local/libexec/workroom-identity <<EOF
#!/bin/sh
# Installed by Workroom (issue #256). See workroom-identity.service.
set -eu
marker=/etc/workroom-identity
[ "\$(cat "\$marker" 2> /dev/null)" = "\$(hostname)" ] && exit 0
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
# Both copies: with only /etc/machine-id gone, systemd-machine-id-setup restores it from D-Bus's.
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id
# With the agent's interrupted saves (.broker.json.<pid>), which can hold a key.
rm -f "$agent_dir/broker.json" "$agent_dir/broker-token.json" "$agent_dir"/.broker*
rm -rf "$screens"
install -d -o "$user" -g "$user" -m 700 "$screens"
hostname > "\$marker"
EOF
chmod 755 /usr/local/libexec/workroom-identity

cat > /etc/systemd/system/workroom-identity.service <<EOF
# Installed by Workroom (issue #256).
[Unit]
Description=Workroom: mint this machine's identity once per machine
Before=workroom-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/workroom-identity

[Install]
WantedBy=multi-user.target
EOF

# Not with the app's environment or the user's: the agent's is what every git it runs gets, and the
# app sends none from the Mac. `StartLimitIntervalSec=0`, so a crashing agent is restarted for as
# long as it takes rather than given up on after five tries.
cat > /etc/systemd/system/workroom-agent.service <<EOF
# Installed by Workroom (issue #256).
[Unit]
Description=Workroom agent
Requires=workroom-identity.service
After=workroom-identity.service network.target
StartLimitIntervalSec=0

[Service]
User=$user
Group=$user
Environment=HOME=$home USER=$user SHELL=/bin/bash PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/sh -c 'while [ ! -x $agent ]; do sleep 1; done; exec $agent serve --socket $socket --idle-timeout never --screens $screens'
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now workroom-identity.service workroom-agent.service
