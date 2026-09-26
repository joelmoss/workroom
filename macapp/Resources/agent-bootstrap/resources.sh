#!/bin/sh
# The agent bootstrap's resource push (issue #239; `AgentBootstrap` in the app runs it on a remote
# host over the driver's transport, when the probe reports a set other than the app's):
#
#   sh -c "$(cat resources.sh)" resources <dir> <size> <path> [<size> <path>...]  < the files
#
# It installs the part of the app's `Resources/ghostty` that a pane on this host needs: the
# `xterm-ghostty` terminfo and the shell integration, the set `CHECKSUMS` lists, with `CHECKSUMS`
# itself. The files arrive on stdin one after another, in the order and at the sizes the arguments
# give. The remote attach runs a pane as `xterm-ghostty` with the integration when the set is here,
# and as `xterm-256color` without it when it is not, so a set that is missing or cut short costs a
# pane its integration and nothing more. Every line it prints is prefixed `WRB `:
#
#   WRB receiving <path>     as each file lands, so the app's silence bound ticks during the push
#   WRB received
#   WRB outcome installed | write-failed | truncated <path> | bad-path <path> | no-sha256sum
#               | corrupt
#
# The set is staged beside <dir>, checked against its own `CHECKSUMS`, and renamed into place, so a
# pane never finds half of one. Shells already running keep their `TERMINFO` and integration paths
# into <dir>, which is why it is one fixed directory updated in place rather than one per set, and
# why the set it replaces is only ever removed once the new one is there: moved aside, it is put
# back if the rename that follows fails or is interrupted. A pane that starts in the instant
# between the two renames gets the `xterm-256color` fallback. Two
# pushes racing can rename one set into the other rather than over it (`mv` onto a directory moves
# into it); <dir> is still a whole set, with a stray staging directory in it until the next push.
# POSIX sh and coreutils only, as the other scripts: `dd bs=1` reads exactly the bytes a file has,
# where `head -c` may read ahead into the next one.
set -u
dir=$1
shift
staged="$dir.new.$$"
old="$dir.old.$$"
trap 'rm -rf "$staged"; if [ -e "$dir" ]; then rm -rf "$old"; elif [ -e "$old" ]; then mv "$old" "$dir"; fi' EXIT
trap 'exit 1' HUP PIPE TERM

umask 077
if ! mkdir "$staged"; then
  echo "WRB outcome write-failed"
  exit 1
fi
while [ "$#" -ge 2 ]; do
  size=$1
  path=$2
  shift 2
  case $path in
    '' | /* | *..*)
      echo "WRB outcome bad-path $path"
      exit 1
      ;;
    */*) mkdir -p "$staged/${path%/*}" ;;
  esac
  if ! dd bs=1 count="$size" of="$staged/$path" 2> /dev/null; then
    echo "WRB outcome write-failed"
    exit 1
  fi
  if [ "$(wc -c < "$staged/$path")" -ne "$size" ]; then
    echo "WRB outcome truncated $path"
    exit 1
  fi
  # The whole set fits in ssh's channel window, so the Mac's side goes quiet as soon as it is
  # queued: without this, the silence bound would time the whole transfer on a slow link.
  echo "WRB receiving $path"
done
echo "WRB received"

if ! command -v sha256sum > /dev/null 2>&1; then
  echo "WRB outcome no-sha256sum"
  exit 1
fi
if ! (cd "$staged" && sha256sum -c CHECKSUMS > /dev/null 2>&1); then
  echo "WRB outcome corrupt"
  exit 1
fi

# The app bundle's terminfo is in macOS's layout, a directory per first letter in hex
# (terminfo/78/xterm-ghostty). Linux's ncurses looks under the letter itself
# (terminfo/x/xterm-ghostty), so each entry is copied there too.
for entry in "$staged"/terminfo/??/*; do
  [ -f "$entry" ] || continue
  name=${entry##*/}
  letter=$(printf '%.1s' "$name")
  if ! mkdir -p "$staged/terminfo/$letter" || ! cp "$entry" "$staged/terminfo/$letter/"; then
    echo "WRB outcome write-failed"
    exit 1
  fi
done

if [ -e "$dir" ] && ! mv "$dir" "$old"; then
  echo "WRB outcome write-failed"
  exit 1
fi
if ! mv "$staged" "$dir"; then
  echo "WRB outcome write-failed"
  exit 1
fi
echo "WRB outcome installed"
