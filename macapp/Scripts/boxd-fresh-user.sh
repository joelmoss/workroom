#!/bin/sh
#
# Launches this checkout's Debug app as a user boxd has never seen, to try the boxd setup flow
# (`BoxdSetupSheet`) without signing your own boxd out: every boxd command the app runs takes DIR
# as its HOME (`RemoteHosts.boxdHome`), so boxd's installer, its sign-in and the ssh files it
# writes all land there, and only DIR/.local/bin/boxd counts as installed. Signing in creates or
# uses a boxd account of its own, so give it another email or GitHub login.
#
#   boxd-fresh-user.sh "path/to/Workroom Dev.app" [DIR]
#
# DIR (default ~/.workroom-boxd-fresh) is kept between runs, so a run after setting up is a
# set-up user. Delete it to be new again.
set -eu

bundle="${1:?usage: boxd-fresh-user.sh path/to/App.app [DIR]}"
dir="${2:-$HOME/.workroom-boxd-fresh}"

if [ ! -d "$dir" ]; then
  mkdir -p "$dir"
  chmod 700 "$dir"
  echo "Made a fresh boxd home in $dir"
fi

sh "$(dirname "$0")/stop-dev-app.sh" "$bundle"
echo "Launching $bundle as a fresh boxd user ($dir)"
open --env "WR_BOXD_HOME=$dir" "$bundle"
