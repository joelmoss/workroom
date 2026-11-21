#!/bin/sh
# The Ghostty resource set a remote host is pushed (#239) carries the GPL-3.0 Ghostty's bash and
# zsh integration are under, in a LICENSE beside them (#714). Pushes the bundle's real set through
# the real far-side script, as DaemonBootstrap does, into a scratch directory on this Mac, and
# checks what lands there.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SET="$ROOT/macapp/Resources/ghostty"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-licence.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0

# The arguments and stdin DaemonBootstrap.ensureResources builds: CHECKSUMS's files, then itself.
paths=$(sed 's/^[0-9a-f]*  //' "$SET/CHECKSUMS")
set --
for path in $paths CHECKSUMS; do
  set -- "$@" "$(wc -c < "$SET/$path" | tr -d ' ')" "$path"
done
output=$(for path in $paths CHECKSUMS; do cat "$SET/$path"; done \
  | sh "$ROOT/macapp/Resources/daemon-bootstrap/resources.sh" "$WORK/ghostty" "$@")
case $output in
  *"WRB outcome installed"*) ;;
  *) echo "FAIL: the push did not install: $output"; fails=$((fails + 1)) ;;
esac

for pair in "bash:ghostty.bash" "zsh:ghostty-integration" "zsh:.zshenv"; do
  dir="$WORK/ghostty/shell-integration/${pair%%:*}"
  file=${pair#*:}
  if [ ! -f "$dir/$file" ]; then
    echo "FAIL: $file did not land in ${dir#"$WORK/"}"
    fails=$((fails + 1))
  elif ! grep -q 'GNU General Public License' "$dir/$file"; then
    echo "FAIL: $file is no longer under the GPL; revisit its LICENSE"
    fails=$((fails + 1))
  fi
  if ! grep -q "GNU GENERAL PUBLIC LICENSE" "$dir/LICENSE" 2>/dev/null \
    || ! grep -q "Version 3, 29 June 2007" "$dir/LICENSE" \
    || ! grep -q "Ghostty" "$dir/LICENSE" \
    || ! grep -qF "$file" "$dir/LICENSE"; then
    echo "FAIL: ${dir#"$WORK/"}/LICENSE does not carry the GPL-3.0 naming Ghostty and $file"
    fails=$((fails + 1))
  fi
done
if ! grep -q "Ryan Caloras" "$WORK/ghostty/shell-integration/bash/LICENSE" 2>/dev/null; then
  echo "FAIL: shell-integration/bash/LICENSE does not carry bash-preexec's MIT notice"
  fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
  echo "ghostty-licence_test: OK"
  exit 0
fi
echo "ghostty-licence_test: $fails failure(s)"
exit 1
