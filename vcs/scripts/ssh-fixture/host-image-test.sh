#!/bin/bash
#
# Smoke-tests the `workroom-host` image (FIXTURE=0, `make remote-host-image`, #253, #288).
#
#   vcs/scripts/ssh-fixture/host-image-test.sh
#   WR_HOST_IMAGE=<image> vcs/scripts/ssh-fixture/host-image-test.sh   # test a built image (#309)
#
# run.sh only ever builds FIXTURE=1, so nothing else exercises the paths only this variant takes:
# the `[ "$FIXTURE" = 1 ] || exit 0` steps, the `wr-agen[t]` COPY with no agent in the context, and
# the entrypoint's agent and fake-GitHub guards. Built from this directory as it is, exactly as the
# make target builds it, so the context has no agent. Then it checks that sshd serves and that none
# of the fixture's pieces made it in.
#
# Each check looks for something being absent, which a renamed path would satisfy without testing
# anything. So a control comes first: the fixture variant, with an agent, where every one of them
# must be found. A check the control does not trip has gone stale against the Dockerfile or the
# entrypoint.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${WR_FIXTURE_RUNTIME:-docker}"
NAME="wr-host-image-test-$$"
CONTROL="$NAME-control"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wr-host-image.XXXXXX")"
# Removed by this run's own tags, never by ID. The image is the one `make remote-host-image` builds,
# so it can share an ID with a developer's `workroom-host`: `rmi <id>` would refuse it, and
# `rmi -f <id>` would strip that tag too.
cleanup() {
  "$RUNTIME" rm -f "$NAME" "$CONTROL" >/dev/null 2>&1 || true
  "$RUNTIME" rmi "$NAME" "$CONTROL" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

# The context must hold no agent, or the COPY's tolerance of a missing one goes untested. `-L` too:
# `-e` follows a symlink, so a dangling one would get past it.
if [ -e "$HERE/wr-agent" ] || [ -L "$HERE/wr-agent" ]; then
  echo "error: $HERE/wr-agent exists; the image must build without one" >&2
  exit 1
fi

# As run.sh, WR_FIXTURE_BUILD_FLAGS is word-split into extra build flags, for the host's build;
# WR_FIXTURE_CONTROL_BUILD_FLAGS, the same for the control's. Separate, because two exports to one
# cache scope replace each other. No FIXTURE build arg for the host: the make target passes none,
# so the Dockerfile's default is what ships. The control's agent only has to exist; the supervisor
# restarting it is harmless.
read -r -a BUILD_FLAGS <<< "${WR_FIXTURE_BUILD_FLAGS:-}"
read -r -a CONTROL_BUILD_FLAGS <<< "${WR_FIXTURE_CONTROL_BUILD_FLAGS:-}"
mkdir "$STAGE/control"
cp "$HERE/Dockerfile" "$HERE/entrypoint.sh" "$HERE/identity.sh" "$HERE/fake-github.py" "$STAGE/control/"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/control/wr-agent"
"$RUNTIME" build --quiet --tag "$CONTROL" --build-arg FIXTURE=1 \
  ${CONTROL_BUILD_FLAGS[@]+"${CONTROL_BUILD_FLAGS[@]}"} "$STAGE/control" >/dev/null
# WR_HOST_IMAGE names an image already built, to test it rather than build one (#309): CI tests the
# exact image it then publishes, since a second build could resolve other packages. Tagged with this
# run's name, so cleanup's `rmi` only takes that tag off and the image stays for the push.
if [ -n "${WR_HOST_IMAGE:-}" ]; then
  "$RUNTIME" tag "$WR_HOST_IMAGE" "$NAME"
else
  "$RUNTIME" build --quiet --tag "$NAME" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "$HERE" >/dev/null
fi

ssh-keygen -q -t ed25519 -N '' -C wr-host-image-test -f "$STAGE/id_ed25519"

# Starts a container of the image tagged $1, under the same name, and waits until sshd answers.
# sshd is the entrypoint's last step, so the checks see /etc/hosts after the fake-GitHub guard ran.
# Throwaway containers on loopback, so their host keys are neither pinned nor recorded. `-F
# /dev/null`: a user's ssh config could reroute the probe, and with ControlMaster the host's would
# ride the control's connection, since both are workroom@127.0.0.1. A minute in all, by the clock
# rather than a count of tries: a port that accepts and then stalls costs a whole ConnectTimeout per
# try, and the error and log below must still print before CI's step timeout ends the run.
boot() {
  local name="$1" port deadline=$((SECONDS + 60))
  # `--pull=never`: only the image this run built, never one a registry has under the same name.
  "$RUNTIME" run --pull=never --detach --init --name "$name" --publish 127.0.0.1::22 \
    --env "AUTHORIZED_KEY=$(cat "$STAGE/id_ed25519.pub")" "$name" >/dev/null
  # A container that died at boot has no port; its log goes before cleanup removes it.
  if ! port="$("$RUNTIME" port "$name" 22/tcp | head -1 | sed 's/.*://')" || [ -z "$port" ]; then
    echo "error: $name published no ssh port; its log:" >&2
    "$RUNTIME" logs "$name" >&2
    exit 1
  fi
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ssh -F /dev/null -i "$STAGE/id_ed25519" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      -o LogLevel=ERROR workroom@127.0.0.1 true 2>"$STAGE/ssh.err"; then
      return 0
    fi
    sleep 0.2
  done
  echo "error: $name never served ssh: $(cat "$STAGE/ssh.err"); its log:" >&2
  "$RUNTIME" logs "$name" >&2
  exit 1
}

# Each fixture piece, as a command that exits 0 when the piece is there and 1 when it is not. Any
# other status is the probe failing (git missing is 127, a broken git config 128), never an absence.
# The github.com mapping is matched as the entrypoint writes it, so a line some other way of making
# /etc/hosts carries over (podman seeds it from the machine's own) is not taken for it.
PIECES=(
  "python3"                     'command -v python3 >/dev/null || exit 1'
  "fixture certificate"         'test -e /etc/workroom-fixture'
  "fixture origin"              'test -e /srv/origin.git'
  "agent in the image"          'test -e /usr/local/bin/wr-agent'
  "agent installed at boot"     'test -e /run/workroom/wr-agent'
  "github.com mapping"          "grep -qx '127\.0\.0\.1 github\.com' /etc/hosts"
  "git trusting the fixture CA" 'git config --system --get-regexp sslCAInfo >/dev/null'
)

# What a real host needs, which both variants must keep. The fixture's own tests run only against
# FIXTURE=1, and it trusts just its own CA, so nothing else notices a host that lost one of these:
# without the CA bundle, every clone from the real github.com fails.
KEEPS=(
  "git"                         'command -v git >/dev/null || exit 1'
  "pgrep"                       'command -v pgrep >/dev/null || exit 1'
  "setpriv"                     'command -v setpriv >/dev/null || exit 1'
  "ssh-keygen"                  'command -v ssh-keygen >/dev/null || exit 1'
  "CA certificates"             'test -s /etc/ssl/certs/ca-certificates.crt'
)

# The sshd settings the Dockerfile writes to sshd_config.d (#299), as sshd itself resolves them:
# key login keeps working without them, so the ssh wait above would not notice them gone, as when a
# base image's sshd_config stops including sshd_config.d. Resolved for a login, by `-C`, so a
# `Match` block that turns one back on for that user counts too: workroom's, the one login there
# is, and root's for root login. Needs a booted container (/run/sshd). An `sshd -T` that fails is
# the probe failing, never a setting that is off.
sshd_for() {
  printf '%s %s' "t=\$(/usr/sbin/sshd -T -C user=$1,host=localhost,addr=127.0.0.1) || exit 2;" \
    "printf '%s\\n' \"\$t\" | grep -qx"
}
HARDENED=(
  "no password login"           "$(sshd_for workroom) 'passwordauthentication no'"
  "no keyboard-interactive"     "$(sshd_for workroom) 'kbdinteractiveauthentication no'"
  "only workroom may log in"    "$(sshd_for workroom) 'allowusers workroom'"
  "no root login"               "$(sshd_for root) 'permitrootlogin no'"
)

# Runs each piece's command in container $1, from the name/command pairs after $2, which is
# "present" or "absent", what each must find. The verdict is printed inside the container, from
# the probe's own status, since an `exec` that never ran, or ran in a dead container, fails too.
# Anything but a verdict is an error, never an absence. Stderr apart, so a runtime's warning does
# not spoil the verdict.
failed=0
unchecked=0
expect() {
  local name="$1" want="$2" found
  shift 2
  while [ "$#" -gt 0 ]; do
    found="$("$RUNTIME" exec "$name" sh -c "($2); rc=\$?
      case \$rc in 0) echo present ;; 1) echo absent ;; *) echo \"probe exited \$rc\" ;; esac" \
      2>"$STAGE/exec.err")" || true
    if [ "$found" = "$want" ]; then
      echo "ok: $name: $1 $want"
    elif [ "$found" = present ] || [ "$found" = absent ]; then
      echo "FAIL: $name: $1 $found, expected $want" >&2
      failed=1
    else
      echo "FAIL: $name: $1 could not be checked: $found $(cat "$STAGE/exec.err")" >&2
      failed=1
      unchecked=1
    fi
    shift 2
  done
}

# Prints $2 or, when a check could not run at all, says so instead, then container $1's log.
fail() {
  if [ "$unchecked" = 1 ]; then
    echo "error: some of $1's checks could not run; its log:" >&2
  else
    echo "error: $2; its log:" >&2
  fi
  "$RUNTIME" logs "$1" >&2
  exit 1
}

boot "$CONTROL"
expect "$CONTROL" present "${PIECES[@]}"
if [ "$failed" = 1 ]; then
  fail "$CONTROL" "the fixture image does not match the checks, so they prove nothing"
fi
expect "$CONTROL" present "${KEEPS[@]}" "${HARDENED[@]}"
if [ "$failed" = 1 ]; then
  fail "$CONTROL" "the image both variants are built from lacks what every host needs"
fi

boot "$NAME"
expect "$NAME" absent "${PIECES[@]}"
expect "$NAME" present "${KEEPS[@]}" "${HARDENED[@]}"
if [ "$failed" = 1 ]; then
  fail "$NAME" "the host image carries fixture pieces or lacks what a host needs"
fi

# A workroom-host boots with no agent and waits for the app's (#231, #253): the supervisor must
# start one pushed after boot. Every other test boots with an agent already installed, so a
# supervisor that only starts when there is one at boot would pass them all. The stub stands in
# for the agent: it records the arguments it was started with and stays up. Renamed into place,
# as the app installs its own.
"$RUNTIME" exec -u workroom "$NAME" sh -c '
  printf "#!/bin/sh\necho \"\$*\" > /run/workroom/stub-started\nexec sleep 300\n" \
    > /run/workroom/.wr-agent.new
  chmod 700 /run/workroom/.wr-agent.new
  mv /run/workroom/.wr-agent.new /run/workroom/wr-agent'
started=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  started="$("$RUNTIME" exec "$NAME" cat /run/workroom/stub-started 2>/dev/null)" && break
  sleep 0.5
done
case "$started" in
  "serve --socket /run/workroom/agent.sock "*) echo "ok: $NAME: agent pushed after boot started" ;;
  *)
    unchecked=0
    fail "$NAME" "the supervisor never started an agent pushed after boot (got: '$started')"
    ;;
esac
