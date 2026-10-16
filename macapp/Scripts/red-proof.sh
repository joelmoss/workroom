#!/bin/bash
#
# Proves a test covers a line: replaces the one occurrence of <pattern> in <file> with <replace>,
# runs the test command, and restores <file> however the run ends (an EXIT trap, so a failed build,
# Ctrl-C or a killed run all put it back). One process holds the backup from break to restore,
# which a hand-rolled `cp`/`sed -i`/`cp` across separate shell calls cannot promise: with Claude
# Code's command sandbox on and off, `$TMPDIR` is two different directories.
#
# Usage: red-proof.sh <file> <pattern> <replace> <red-when> -- <command...>
#   <pattern> and <replace> are literal text, and <pattern> must occur exactly once in <file>.
#   <red-when> is an extended regex the command's output must match for its failure to count as
#   the test going red, so a build error is never mistaken for one.
#
# Exits 0 when RED (the test failed with the break in place), 1 when GREEN (it passed: nothing
# covers the line), 2 when INCONCLUSIVE or misused. `make red-proof` wraps it for app unit tests.
set -u -o pipefail

if [ "$#" -lt 6 ] || [ "$5" != "--" ]; then
  echo "usage: red-proof.sh <file> <pattern> <replace> <red-when> -- <command...>" >&2
  exit 2
fi
file="$1"
pattern="$2"
replace="$3"
red_when="$4"
shift 5

if [ ! -f "$file" ] || [ -z "$pattern" ]; then
  echo "red-proof: no file '$file', or an empty pattern" >&2
  exit 2
fi
count="$(PATTERN="$pattern" perl -0777 -ne 'my $n = () = /\Q$ENV{PATTERN}\E/g; print $n' "$file")"
if [ "$count" != 1 ]; then
  echo "red-proof: the pattern occurs $count times in $file; it must occur exactly once" >&2
  exit 2
fi

# A named template, because template-less BSD `mktemp` ignores $TMPDIR (see build-agent_test.sh).
backup="$(mktemp "${TMPDIR:-/tmp}/red-proof.XXXXXX")" || exit 2
log="$(mktemp "${TMPDIR:-/tmp}/red-proof-log.XXXXXX")" || exit 2
cp -p "$file" "$backup" || exit 2

restore() {
  if cp -p "$backup" "$file" && cmp -s "$backup" "$file"; then
    rm -f "$backup"
    echo "red-proof: restored $file"
  else
    echo "red-proof: COULD NOT RESTORE $file; the original is at $backup" >&2
  fi
}
trap 'restore; rm -f "$log"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PATTERN="$pattern" REPLACE="$replace" \
  perl -0777 -pi -e 's/\Q$ENV{PATTERN}\E/$ENV{REPLACE}/' "$file" || exit 2
echo "red-proof: broke $file (1 occurrence replaced); running: $*"

"$@" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"
# The run ended on its own: restore now, before the verdict (the trap is for aborts).
trap 'rm -f "$log"' EXIT
restore

if [ "$status" -eq 0 ]; then
  echo "red-proof: GREEN: the command passed with the break in place, so no test covers it"
  exit 1
fi
if grep -Eq "$red_when" "$log"; then
  echo "red-proof: RED: the test failed with the break in place (exit $status)"
  exit 0
fi
echo "red-proof: INCONCLUSIVE: the command failed (exit $status) but its output never matched" \
  "'$red_when'; a build error is not a red test"
exit 2
