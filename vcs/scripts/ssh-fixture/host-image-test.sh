#!/bin/bash
#
# Smoke-tests the `workroom-host` image (FIXTURE=0, `make remote-host-image`, #253, #288).
#
#   vcs/scripts/ssh-fixture/host-image-test.sh
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
# By this run's own tags, never by ID: the image is the same one `make remote-host-image` builds,
# so removing it by ID would take a developer's `workroom-host` tag with it.
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
"$RUNTIME" build --quiet --tag "$NAME" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} "$HERE" >/dev/null

ssh-keygen -q -t ed25519 -N '' -C wr-host-image-test -f "$STAGE/id_ed25519"

# Starts a container of the image tagged $1, under the same name, and waits until sshd answers.
# sshd is the entrypoint's last step, so the checks see /etc/hosts after the fake-GitHub guard ran.
# Throwaway containers on loopback, so their host keys are neither pinned nor recorded. `-F
# /dev/null`: a user's ssh config could reroute the probe, and with ControlMaster the host's would
# ride the control's connection, since both are workroom@127.0.0.1.
boot() {
  local name="$1" port tries=100
  # `--pull=never`: only the image this run built, never one a registry has under the same name.
  "$RUNTIME" run --pull=never --detach --init --name "$name" --publish 127.0.0.1::22 \
    --env "AUTHORIZED_KEY=$(cat "$STAGE/id_ed25519.pub")" "$name" >/dev/null
  # A container that died at boot has no port; its log goes before cleanup removes it.
  if ! port="$("$RUNTIME" port "$name" 22/tcp | head -1 | sed 's/.*://')" || [ -z "$port" ]; then
    echo "error: $name published no ssh port; its log:" >&2
    "$RUNTIME" logs "$name" >&2
    exit 1
  fi
  while [ "$tries" -gt 0 ]; do
    if ssh -F /dev/null -i "$STAGE/id_ed25519" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
      -o LogLevel=ERROR workroom@127.0.0.1 true 2>"$STAGE/ssh.err"; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.2
  done
  echo "error: $name never served ssh: $(cat "$STAGE/ssh.err"); its log:" >&2
  "$RUNTIME" logs "$name" >&2
  exit 1
}

# Each fixture piece, as a command that exits 0 when the piece is there and 1 when it is not. Any
# other status is the probe failing (git missing is 127, a broken git config 128), never an absence.
PIECES=(
  "python3"                     'command -v python3 >/dev/null || exit 1'
  "fixture certificate"         'test -e /etc/workroom-fixture'
  "fixture origin"              'test -e /srv/origin.git'
  "agent in the image"          'test -e /usr/local/bin/wr-agent'
  "agent installed at boot"     'test -e /run/workroom/wr-agent'
  "github.com mapping"          'grep -q github.com /etc/hosts'
  "git trusting the fixture CA" 'git config --system --get-regexp sslCAInfo >/dev/null'
)

# Runs every piece's command in container $1; $2 is "present" or "absent", what each must find.
# The verdict is printed inside the container, from the probe's own status, since an `exec` that
# never ran, or ran in a dead container, fails too. Anything but a verdict is an error, never an
# absence. Stderr apart, so a runtime's warning does not spoil the verdict.
failed=0
unchecked=0
expect() {
  local name="$1" want="$2" i found
  for ((i = 0; i < ${#PIECES[@]}; i += 2)); do
    found="$("$RUNTIME" exec "$name" sh -c "(${PIECES[i + 1]}); rc=\$?
      case \$rc in 0) echo present ;; 1) echo absent ;; *) echo \"probe exited \$rc\" ;; esac" \
      2>"$STAGE/exec.err")" || true
    if [ "$found" = "$want" ]; then
      echo "ok: $name: ${PIECES[i]} $want"
    elif [ "$found" = present ] || [ "$found" = absent ]; then
      echo "FAIL: $name: ${PIECES[i]} $found, expected $want" >&2
      failed=1
    else
      echo "FAIL: $name: ${PIECES[i]} could not be checked: $found $(cat "$STAGE/exec.err")" >&2
      failed=1
      unchecked=1
    fi
  done
}

boot "$CONTROL"
expect "$CONTROL" present
if [ "$failed" = 1 ]; then
  echo "error: a check no longer finds its piece in the fixture image, so it proves nothing; its log:" >&2
  "$RUNTIME" logs "$CONTROL" >&2
  exit 1
fi

boot "$NAME"
expect "$NAME" absent
if [ "$failed" = 1 ]; then
  if [ "$unchecked" = 1 ]; then
    echo "error: some of the host image's checks could not run; its log:" >&2
  else
    echo "error: the host image carries fixture pieces; its log:" >&2
  fi
  "$RUNTIME" logs "$NAME" >&2
  exit 1
fi
