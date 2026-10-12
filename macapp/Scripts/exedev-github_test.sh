#!/bin/sh
#
# Runs macapp/Resources/host-setup/exedev-github.sh against a throwaway system git config and
# profile.d, and checks that every form of a GitHub remote (https, scp and ssh://) reaches exe.dev's
# integration host, that a second run leaves the rewrite as it was, and that gh is told the host.
# Run:
# sh macapp/Scripts/exedev-github_test.sh
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${EXEDEV_GITHUB_SCRIPT:-$DIR/../Resources/host-setup/exedev-github.sh}"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

mkdir "$WORK/profile.d"
GIT_CONFIG_SYSTEM="$WORK/system.gitconfig"
GIT_CONFIG_GLOBAL="$WORK/global.gitconfig"
export GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL
: > "$GIT_CONFIG_SYSTEM"
: > "$GIT_CONFIG_GLOBAL"

url() { git ls-remote --get-url "$1"; }

for run in 1 2; do
  sh "$SCRIPT" "$WORK/profile.d" || fail "run $run exited $?"
  [ "$(url https://github.com/o/r.git)" = https://github.int.exe.xyz/o/r.git ] \
    || fail "run $run: https origin -> $(url https://github.com/o/r.git)"
  [ "$(url git@github.com:o/r.git)" = https://github.int.exe.xyz/o/r.git ] \
    || fail "run $run: scp origin -> $(url git@github.com:o/r.git)"
  [ "$(url ssh://git@github.com/o/r.git)" = https://github.int.exe.xyz/o/r.git ] \
    || fail "run $run: ssh:// remote -> $(url ssh://git@github.com/o/r.git)"
  count=$(git config --system --get-all url.https://github.int.exe.xyz/.insteadOf | wc -l)
  [ "$count" -eq 3 ] || fail "run $run: $count rewrites, not 3"
done

[ "$(url https://gitlab.com/o/r.git)" = https://gitlab.com/o/r.git ] || fail "another host rewritten"
profile="$(cat "$WORK/profile.d/workroom-github.sh")"
[ "$profile" = 'export GH_HOST=github.int.exe.xyz' ] || fail "profile.d says '$profile'"

echo "ok: exedev-github.sh"
