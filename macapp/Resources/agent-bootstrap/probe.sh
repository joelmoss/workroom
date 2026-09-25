#!/bin/sh
# The agent bootstrap's probe (issue #231; `AgentBootstrap` in the app, which runs it on a remote
# host over the driver's transport before any service connects):
#
#   sh -c "$(cat probe.sh)" probe <binary> <socket> <hand-off 0|1> <sha256 aarch64> <sha256 x86_64> \
#     <resources>
#
# A sha256 is `-` for an architecture the app bundles no agent for (it never equals a hash).
# <resources> is where Ghostty's terminfo and shell integration go (resources.sh, issue #239).
#
# It answers four questions, one line each on stdout, every line prefixed `WRB ` so the app can
# tell them from whatever a shell startup file on the host prints ahead of them:
#
#   WRB host <uname -s> <uname -m>
#   WRB installed <sha256 of the binary beside the socket> | unknown (no sha256sum) | none
#   WRB resources <sha256 of <resources>/CHECKSUMS> | unknown (no sha256sum) | none
#   WRB hand-off <exit status of `wr-agent hand-off`> <its first line>
#                | off (hand-off is off) | no-socket | none (the installed binary is not this build)
#
# The hand-off is asked for only when the installed binary IS the one the app bundles for this
# architecture. Then the running agent answers `current` at once when it already runs it, and
# hands off to it when it does not: a file left by an install whose agent predated hand-off, or
# whose hand-off was off, or whose agent did not greet. The app never hands off to a binary it
# does not recognise: a different one is replaced by install.sh first, which does its own
# hand-off. POSIX sh and coreutils only, since the host may hold nothing of Workroom's yet; the
# login shell there must be a POSIX one, since this script arrives as one quoted word.
set -u
binary=$1
socket=$2
handoff=$3
sha_aarch64=$4
sha_x86_64=$5
resources=$6

arch=$(uname -m)
echo "WRB host $(uname -s) $arch"

installed=none
if [ -x "$binary" ]; then
  # From stdin, so the output is the hash alone (sha256sum prefixes a path with a backslash), and
  # `unknown` for a file it cannot read or hash, rather than an empty word that would read as
  # no agent.
  installed=
  if command -v sha256sum > /dev/null 2>&1; then
    installed=$(sha256sum < "$binary" 2> /dev/null | cut -c1-64)
  fi
  installed=${installed:-unknown}
fi
echo "WRB installed $installed"

# The resource set's manifest stands for the set: resources.sh checks every file against it before
# the set goes into place, and the app keys the set by the same hash of it. `unknown` for a host
# without sha256sum whether or not a set is there: resources.sh would refuse the push for that.
set_digest=none
if ! command -v sha256sum > /dev/null 2>&1; then
  set_digest=unknown
elif [ -r "$resources/CHECKSUMS" ]; then
  set_digest=$(sha256sum < "$resources/CHECKSUMS" 2> /dev/null | cut -c1-64)
  set_digest=${set_digest:-unknown}
fi
echo "WRB resources $set_digest"

case $arch in
  aarch64) bundled=$sha_aarch64 ;;
  x86_64) bundled=$sha_x86_64 ;;
  *) bundled= ;;
esac
if [ "$handoff" != 1 ]; then
  echo "WRB hand-off off"
elif [ ! -S "$socket" ]; then
  echo "WRB hand-off no-socket"
elif [ "$installed" != "$bundled" ]; then
  echo "WRB hand-off none"
else
  said=$("$binary" hand-off --socket "$socket" --binary "$binary" 2>&1)
  code=$?
  echo "WRB hand-off $code $(printf '%s' "$said" | head -n 1)"
fi
