#!/bin/sh
#
# Dependency-free test for red-proof.sh, with shell one-liners standing in for the test command.
# Run: sh macapp/Scripts/red-proof_test.sh   (exits non-zero on any failure).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# A named template, because template-less BSD `mktemp -d` ignores $TMPDIR (see build-agent_test.sh).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/red-proof_test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

src="$TMP/Source.swift"
original='let a = 1
guard ready else { return }
let b = 2
'
fails=0

# expect <description> <expected exit> <pattern> -- <command...>: resets the source, runs red-proof
# with RED_WHEN '^Tests: Failed', then checks the exit code and that the source is back as it was.
expect() {
  desc="$1"
  want="$2"
  pat="$3"
  shift 4
  printf '%s' "$original" >"$src"
  bash "$DIR/red-proof.sh" "$src" "$pat" "" '^Tests: Failed' -- "$@" >"$TMP/out" 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: $desc: exit $got, want $want. Output:"
    cat "$TMP/out"
    fails=$((fails + 1))
  fi
  if [ "$(cat "$src")" != "$(printf '%s' "$original")" ]; then
    echo "FAIL: $desc: the source was not restored"
    fails=$((fails + 1))
  fi
}

# The "test" fails only when the guard is gone, as a real test covering it would.
covers="grep -q 'guard ready' '$src' || { echo 'Tests: Failed - 0 passed, 1 failed'; exit 65; }"

expect "a covering test goes red" 0 "guard ready else { return }" -- sh -c "$covers"
expect "a passing test is green" 1 "guard ready else { return }" -- true
expect "a build error is inconclusive" 2 "guard ready else { return }" -- \
  sh -c 'echo "error: cannot find type"; exit 65'
expect "a missing pattern is refused" 2 "not in the file" -- true
expect "a repeated pattern is refused" 2 "let " -- true
expect "a killed run still restores" 143 "guard ready else { return }" -- \
  sh -c "kill -TERM \$PPID; sleep 1"

# The restored source must not be older than what the run built from the broken copy: cargo reuses
# any artifact newer than its source, so restoring the old mtime kept the broken build in use.
printf '%s' "$original" >"$src"
touch -t 200001010000 "$src"
artifact="$TMP/artifact"
bash "$DIR/red-proof.sh" "$src" "guard ready else { return }" "" '^Tests: Failed' -- \
  touch "$artifact" >"$TMP/out" 2>&1
if [ "$artifact" -nt "$src" ]; then
  echo "FAIL: the restored source is older than the build made from the broken copy"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "red-proof_test: $fails failure(s)"
  exit 1
fi
echo "red-proof_test: ok"
