#!/bin/sh
#
# Launches this checkout's Debug app as a user exe.dev has never seen, to try the exe.dev setup flow
# (`ExeDevSetupSheet`) without touching your own ssh: every exe.dev ssh the app runs takes
# `-F $DIR/config` (`ExeDevHostDriver.testConfig`), with a fresh key, no agent and an empty
# known_hosts. Signing that key up makes a second exe.dev account, so give it another email.
#
#   exedev-fresh-user.sh "path/to/Workroom Dev.app" [DIR]
#
# DIR (default ~/.workroom-exedev-fresh) is kept between runs, so a run after signing up is a
# signed-in user. Delete it to be new again.
set -eu

bundle="${1:?usage: exedev-fresh-user.sh path/to/App.app [DIR]}"
dir="${2:-$HOME/.workroom-exedev-fresh}"

if [ ! -f "$dir/config" ]; then
  mkdir -p "$dir"
  chmod 700 "$dir"
  ssh-keygen -q -t ed25519 -N '' -C workroom-exedev-fresh -f "$dir/id_ed25519"
  : >"$dir/known_hosts"
  cat >"$dir/config" <<CONFIG
Host *
  IdentityFile $dir/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $dir/known_hosts
CONFIG
  echo "Made a fresh exe.dev identity in $dir"
fi

sh "$(dirname "$0")/stop-dev-app.sh" "$bundle"
echo "Launching $bundle as a fresh exe.dev user ($dir)"
open --env "WR_EXEDEV_SSH_CONFIG=$dir/config" "$bundle"
