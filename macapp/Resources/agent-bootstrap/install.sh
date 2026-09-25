#!/bin/sh
# The agent bootstrap's install (issue #231; `AgentBootstrap` in the app runs it on a remote host
# over the driver's transport, with the Linux `wr-agent` the app bundles for the host's
# architecture on stdin):
#
#   sh -c "$(cat install.sh)" install <binary> <socket> <hand-off 0|1> <sha256>  < wr-agent-linux-<arch>
#
# It installs the binary beside the socket, which is where the supervisor starts the agent from
# and where the relay and the attach run. Every line it prints is prefixed `WRB `:
#
#   WRB receiving            every 10 s while the push drains, so the app's silence bound ticks
#   WRB received             the binary is on disk; what follows is this host's own work
#   WRB outcome installed | handed-off | current | kept-older <why> | refused <why>
#               | truncated <sha256 received> | no-sha256sum | does-not-run | write-failed
#   WRB serving yes | no     after an install with no agent listening: did the supervisor start it?
#
# The rename is the dangerous step, not the write. Relay, attach and the supervisor all execute the
# file at <binary>, so a bad one renamed into place breaks them even while the old agent lives, and
# the supervisor would restart a crasher forever. So the new binary is staged beside the socket,
# checked against the digest the app sent (a link that dies mid-push ends stdin, and a static ELF
# cut short can still run far enough to pass every other check), run once (`protocol`: does it
# run on this box at all), offered to the running agent (`hand-off`, issue #230: the agent checks
# that the new program can restore every session, then execs it), and renamed into place only when
# nothing refused it:
#
#   hand-off exit 0    current, or handed off: the agent runs it       -> rename
#   hand-off exit 3    the agent predates hand-off and keeps running   -> rename, for its next start
#   hand-off exit 92   nothing listening                               -> rename; the supervisor starts it
#   hand-off exit 1    refused: cannot restore, busy, or the new       -> remove; the old file and the old
#                      program died while restoring                      agent stay, the app connects to it
#
# A refusal is retried by the next connect, which pushes again: the price of never leaving an
# unchecked file where the supervisor starts from. `hand-off` exit 92 also covers an agent that
# accepted the connection but did not greet within 5s (one paused mid-hand-off for another
# client), so "nothing listening" is believed only when the command said so. The staged file is
# itself the hand-off client: the app's build asks, whatever is running.
set -u
binary=$1
socket=$2
handoff=$3
expected=$4
staged="$binary.new.$$"
# Whatever ends this, nothing staged is left where the next install, or a curious eye, finds it.
# After the rename there is nothing at that name, so this is a no-op on the way out of a success.
# A signal (SIGPIPE from a link that dropped mid-push, say) would end the shell without the EXIT
# trap; turned into an exit, it runs.
trap 'rm -f "$staged"' EXIT
trap 'exit 1' HUP PIPE TERM

# The app's silence bound ticks on bytes moving either way, and while the tail of the push drains
# through ssh's window (2 MB) nothing does: a slow link would be ended at the very end. So this
# side ticks while `cat` has it all, and only when the file grew: a tick that says "the shell is
# alive" would keep a push stuck on a wedged disk or a black-holed uplink from ever being ended.
# Not `sleep`'s own descriptors, or it would hold the session's output open for up to 10 s after
# the kill.
(
  prev=
  while sleep 10 > /dev/null 2>&1; do
    size=$(wc -c < "$staged" 2> /dev/null)
    [ "$size" != "$prev" ] && echo "WRB receiving $size"
    prev=$size
  done
) &
ticker=$!
# `-C`: the create fails rather than follows anything already at that name.
umask 077
set -C
cat > "$staged"
written=$?
set +C
kill "$ticker" 2> /dev/null
if [ "$written" != 0 ] || ! chmod 700 "$staged"; then
  echo "WRB outcome write-failed"
  exit 1
fi
# From here the wait is this host's work (the hash, `protocol` and a hand-off of up to 45 s), not
# the link's.
echo "WRB received"
if ! command -v sha256sum > /dev/null 2>&1; then
  echo "WRB outcome no-sha256sum"
  exit 1
fi
# From stdin, so the output is the hash alone: a path with a backslash makes sha256sum prefix it.
received=$(sha256sum < "$staged" | cut -c1-64)
if [ "$received" != "$expected" ]; then
  echo "WRB outcome truncated $received"
  exit 1
fi
if ! "$staged" protocol > /dev/null 2>&1; then
  echo "WRB outcome does-not-run"
  exit 1
fi

outcome=installed
listening=no
if [ "$handoff" = 1 ] && [ -S "$socket" ]; then
  said=$("$staged" hand-off --socket "$socket" --binary "$staged" 2>&1)
  code=$?
  case $code in
    0)
      listening=yes
      case $said in
        current) outcome=current ;;
        *) outcome=handed-off ;;
      esac
      ;;
    3)
      listening=yes
      outcome="kept-older the agent predates hand-off"
      ;;
    92)
      case $said in
        *"no agent listening"*) ;;
        *)
          listening=yes
          outcome="kept-older the agent did not greet"
          ;;
      esac
      ;;
    *)
      echo "WRB outcome refused $(printf '%s' "$said" | head -n 1)"
      exit 1
      ;;
  esac
elif [ -S "$socket" ]; then
  listening=yes
  outcome="kept-older hand-off is off"
fi

if ! mv -f "$staged" "$binary"; then
  echo "WRB outcome write-failed"
  exit 1
fi
echo "WRB outcome $outcome"

if [ "$listening" = no ]; then
  i=0
  while [ "$i" -lt 50 ]; do
    if "$binary" list --socket "$socket" > /dev/null 2>&1; then
      echo "WRB serving yes"
      exit 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "WRB serving no"
  exit 1
fi
