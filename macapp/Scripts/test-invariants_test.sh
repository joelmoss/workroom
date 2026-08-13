#!/bin/sh
#
# Dependency-free meta-test pinning two test-infra invariants that otherwise live only in Makefile
# comments (Muxy test-practices review, filed in TODOS.md): the `APP_UITEST_FLAGS` skip list, and
# that release/nightly/CI workflows still actually invoke `make app-test` somewhere. No toolchain —
# just sh + grep. Run: sh macapp/Scripts/test-invariants_test.sh   (exits non-zero on any mismatch).
#
# Why a shell script and not an XCTest class: an XCTest class would couple the expensive,
# host-app-launching WorkroomAppTests bundle to repository layout for what's really a spelling
# check, and reading the Makefile's dependency GRAPH (does app-release depend on app-test?) checks
# the wrong thing — app-release deliberately does NOT depend on app-test (Debug-only single-arch
# builds pin a different signing shape than the release artifact; see the Makefile's app-release
# comment). The real invariant lives in the CI workflows that run the xcodebuild suite as an
# explicit step instead.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
# Overridable so the suite can be pointed at modified copies — used to confirm these cases
# actually FAIL against a drifted Makefile/workflow rather than passing vacuously.
MAKEFILE="${TEST_INVARIANTS_MAKEFILE:-$ROOT/Makefile}"
WORKFLOWS_DIR="${TEST_INVARIANTS_WORKFLOWS_DIR:-$ROOT/.github/workflows}"
fails=0

# --- APP_UITEST_FLAGS skip list -------------------------------------------------------------
# Pinned literally: a refactor that silently drops or adds an entry re-enables (or newly skips) a
# flaky/expensive UI test in the default local `make app-uitest` run without anyone deciding to.
want_flags='-skip-testing:WorkroomAppUITests/AgentResumeUITests -skip-testing:WorkroomAppUITests/SessionRestoreUITests -skip-testing:WorkroomAppUITests/HistoryStressUITests/testLargeHistoryStaysInteractive -skip-testing:WorkroomAppUITests/WindowDragUITests/testDraggingWorkroomTabReordersTwoChips'
got_flags="$(sed -n 's/^APP_UITEST_FLAGS ?= //p' "$MAKEFILE")"
if [ "$got_flags" != "$want_flags" ]; then
  echo "FAIL: Makefile's APP_UITEST_FLAGS skip list changed."
  echo "  want: $want_flags"
  echo "  got:  $got_flags"
  fails=$((fails + 1))
fi

# --- app-test still wired into CI ------------------------------------------------------------
# Pin the workflows' actual invocation of the xcodebuild suite, not the Makefile's dependency
# graph (which deliberately excludes app-test from app-release). `([^-]|$)` excludes
# `app-test-scripts`/`app-test-supervisor`, which are different targets entirely.
for wf in ci.yml release.yml nightly.yml; do
  path="$WORKFLOWS_DIR/$wf"
  if [ ! -f "$path" ]; then
    echo "FAIL: workflow $wf not found at $path"
    fails=$((fails + 1))
    continue
  fi
  if ! grep -Eq 'make app-test([^-]|$)' "$path"; then
    echo "FAIL: $wf no longer invokes 'make app-test' — the unit-test safety net may be gone"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "test-invariants_test: $fails failure(s)" >&2
  exit 1
fi
echo "test-invariants_test: all cases passed"
