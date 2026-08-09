#!/bin/sh
#
# Dependency-free test for build-helper.sh's architecture handling. No bats/toolchain — just sh,
# go, and lipo. Run: sh macapp/Scripts/build-helper_test.sh   (exits non-zero on any mismatch).
#
# Why this exists: `ARCHS` is a SPACE-SEPARATED LIST, and build-helper.sh used to match it as a
# single token. A universal build hit the fallback and produced an arm64-only Go CLI inside a fat
# .app, with nothing louder than a `warn:` in the xcodebuild log. That shipped in every release from
# the app's first commit until it was caught by hand — on an Intel Mac the app launched and then
# failed at every workroom operation, since the app drives all of them through this binary.
#
# CI never catches it: `make app-test` builds Debug with a single native arch, so the multi-arch
# branch is only exercised by a real Release/Nightly build. Hence a standalone test.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# Overridable so the suite can be pointed at a modified copy — used to confirm these cases actually
# FAIL against the pre-fix single-token ARCHS logic rather than passing vacuously.
HELPER="${BUILD_HELPER:-${DIR}/build-helper.sh}"
fails=0

command -v go >/dev/null 2>&1 || { echo "build-helper_test: SKIP (go not on PATH)"; exit 0; }
command -v lipo >/dev/null 2>&1 || { echo "build-helper_test: SKIP (lipo not on PATH)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway Go module standing in for the repo root, so the test never depends on the real CLI
# building (or on its build time). build-helper.sh cds to $SRCROOT/.. to find the module.
mkdir -p "$WORK/module/macapp"
cat > "$WORK/module/go.mod" <<'EOF'
module buildhelpertest

go 1.21
EOF
cat > "$WORK/module/main.go" <<'EOF'
package main

var version = "dev"
var channel = ""

func main() {}
EOF

# run_helper <case-name> <ARCHS value> -> sets $OUT to the built helper path, $RC to the exit code
run_helper() {
  case_name="$1"
  archs="$2"
  dest="$WORK/out-$case_name"
  mkdir -p "$dest/Resources"
  OUT="$dest/Resources/workroom"
  SRCROOT="$WORK/module/macapp" \
  TARGET_BUILD_DIR="$dest" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" \
  ARCHS="$archs" \
  MARKETING_VERSION="0.0.0-test" \
    sh "$HELPER" >"$dest/log" 2>&1
  RC=$?
}

# expect_archs <case-name> <ARCHS value> <space-separated wanted archs>
expect_archs() {
  run_helper "$1" "$2"
  if [ "$RC" -ne 0 ]; then
    echo "FAIL: ARCHS='$2' exited $RC, want 0. Log:"
    sed 's/^/    /' "$WORK/out-$1/log"
    fails=$((fails + 1))
    return
  fi
  got="$(lipo -archs "$OUT" 2>/dev/null)"
  for want in $3; do
    case " $got " in
      *" $want "*) ;;
      *)
        echo "FAIL: ARCHS='$2' produced '$got', missing '$want'"
        fails=$((fails + 1))
        ;;
    esac
  done
  # No slice files may be left inside the bundle's Resources folder — they would be unsigned
  # binaries sealed into the shipped app.
  if ls "$(dirname "$OUT")"/workroom-slice-* >/dev/null 2>&1; then
    echo "FAIL: ARCHS='$2' left workroom-slice-* inside Resources"
    fails=$((fails + 1))
  fi
}

# expect_failure <case-name> <ARCHS value> <substring the error must contain>
expect_failure() {
  run_helper "$1" "$2"
  if [ "$RC" -eq 0 ]; then
    echo "FAIL: ARCHS='$2' succeeded, want non-zero exit"
    fails=$((fails + 1))
    return
  fi
  if ! grep -q "$3" "$WORK/out-$1/log"; then
    echo "FAIL: ARCHS='$2' error did not mention '$3'. Log:"
    sed 's/^/    /' "$WORK/out-$1/log"
    fails=$((fails + 1))
  fi
}

# The regression this file exists for: a universal build must produce BOTH slices.
expect_archs universal "arm64 x86_64" "arm64 x86_64"
# Order must not matter — Xcode does not promise one.
expect_archs reversed "x86_64 arm64" "arm64 x86_64"
# Single arch still works (the Debug path), and stays thin.
expect_archs solo_arm "arm64" "arm64"
expect_archs solo_intel "x86_64" "x86_64"
# An arch we cannot map is a hard error, not a silent arm64 fallback — that fallback IS the bug.
expect_failure unknown_arch "arm64 ppc64" "unsupported arch"
# Whitespace-only ARCHS survives `${ARCHS:-...}` and yields no iterations; on bash 3.2 an empty
# array under `set -u` is "unbound", so this must fail with the deliberate message.
expect_failure blank_arch "   " "yielded no architectures"

if [ "$fails" -ne 0 ]; then
  echo "build-helper_test: $fails failure(s)" >&2
  exit 1
fi
echo "build-helper_test: all cases passed"
