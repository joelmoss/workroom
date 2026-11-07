#!/bin/sh
#
# Dependency-free meta-test pinning two test-infra invariants that otherwise live only in Makefile
# comments (Muxy test-practices review): the `APP_UITEST_FLAGS` skip list, and
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
# actually FAIL against a drifted Makefile/workflow rather than passing vacuously. MAKEFILE is a
# root Makefile; its includes resolve against its own directory.
MAKEFILE="${TEST_INVARIANTS_MAKEFILE:-$ROOT/Makefile}"
WORKFLOWS_DIR="${TEST_INVARIANTS_WORKFLOWS_DIR:-$ROOT/.github/workflows}"
MAKE_DIR="$(cd "$(dirname "$MAKEFILE")" && pwd)"
fails=0

# A variable's value as make has it (the root Makefile's `print-%`), wherever the line that sets
# it lives. A clean environment, so neither the caller's environment nor the overrides of a make
# that runs this test (`make app-test-preflight APP_UITEST_FLAGS=…`) stand in for the Makefile's.
make_value() {
  env -i PATH="$PATH" HOME="$HOME" \
    make -s --no-print-directory -C "$MAKE_DIR" -f "$MAKEFILE" "print-$1"
}
# Every file make reads, so a recipe is found in whichever one holds it.
MAKEFILES="$(make_value MAKEFILE_LIST)"

# --- APP_UITEST_FLAGS skip list -------------------------------------------------------------
# Pinned literally: a refactor that silently drops or adds an entry re-enables (or newly skips) a
# flaky/expensive UI test in the default local `make app-uitest` run without anyone deciding to.
want_flags='-skip-testing:WorkroomAppUITests/SessionRestoreUITests -skip-testing:WorkroomAppUITests/HistoryStressUITests/testLargeHistoryStaysInteractive -skip-testing:WorkroomAppUITests/WindowDragUITests/testDraggingWorkroomTabReordersTwoChips'
got_flags="$(make_value APP_UITEST_FLAGS)"
if [ "$got_flags" != "$want_flags" ]; then
  echo "FAIL: Makefile's APP_UITEST_FLAGS skip list changed."
  echo "  want: $want_flags"
  echo "  got:  $got_flags"
  fails=$((fails + 1))
fi

# --- app-test still wired into CI ------------------------------------------------------------
# Pin the workflows' actual invocation of the xcodebuild suite, not the Makefile's dependency
# graph (which deliberately excludes app-test from app-release). `([^-]|$)` excludes
# `app-test-scripts`/`app-test-supervisor`, which are different targets entirely, and `^[^#]*`
# the comments that name the target without running it. The local packages' tests run outside
# the app host, so app-test alone misses them. CI is ci.yml and every workflow it calls, wherever
# its jobs live; the release and the nightly each run both themselves.
#
# $1 = what runs them, $2.. = its workflow files; one of them invoking each target is enough.
check_runs_tests() {
  what="$1"
  shift
  runs_app_test=no
  runs_package_test=no
  for path in "$@"; do
    if [ ! -f "$path" ]; then
      echo "FAIL: workflow $(basename "$path") not found at $path"
      fails=$((fails + 1))
      continue
    fi
    if grep -Eq '^[^#]*make app-test([^-]|$)' "$path"; then runs_app_test=yes; fi
    if grep -q '^[^#]*make app-package-test' "$path"; then runs_package_test=yes; fi
  done
  if [ "$runs_app_test" != yes ]; then
    echo "FAIL: $what no longer invokes 'make app-test' — the unit-test safety net may be gone"
    fails=$((fails + 1))
  fi
  if [ "$runs_package_test" != yes ]; then
    echo "FAIL: $what no longer invokes 'make app-package-test' — the package tests would run nowhere"
    fails=$((fails + 1))
  fi
}
set -- "$WORKFLOWS_DIR/ci.yml"
while IFS= read -r called; do
  if [ -n "$called" ]; then set -- "$@" "$WORKFLOWS_DIR/$called"; fi
done <<EOF
$(sed -n 's|^ *uses: \./\.github/workflows/\([^ ]*\).*|\1|p' "$WORKFLOWS_DIR/ci.yml" 2>/dev/null)
EOF
check_runs_tests CI "$@"
check_runs_tests release.yml "$WORKFLOWS_DIR/release.yml"
check_runs_tests nightly.yml "$WORKFLOWS_DIR/nightly.yml"

# --- the appcast's minimum system version stays derived, never restated ---------------------
# appcast.sh hardcoded MIN_OS="14.0" and went stale when the app's minimum rose to 15.0
# (2a50af72), so beta.19 through the v2.0.0 GA all advertised 14.0 in
# <sparkle:minimumSystemVersion> — Sparkle offered macOS 14 users a 37 MB DMG their OS refuses to
# launch. Nothing else catches it: the value is only read by Sparkle on a user's machine, so both
# the release and the feed publish green. The fix was to read LSMinimumSystemVersion off the built
# bundle in release.sh and pass it through appcast-fields.env, so pin BOTH halves.
APPCAST_SH="${TEST_INVARIANTS_APPCAST_SH:-$ROOT/macapp/Scripts/appcast.sh}"
RELEASE_SH="${TEST_INVARIANTS_RELEASE_SH:-$ROOT/macapp/Scripts/release.sh}"
if grep -Eq '^[[:space:]]*MIN_OS=' "$APPCAST_SH"; then
  echo "FAIL: appcast.sh assigns MIN_OS itself — it must come from appcast-fields.env (release.sh"
  echo "      reads it off the built app), or the feed will drift from the app's real minimum."
  fails=$((fails + 1))
fi
if ! grep -q 'LSMinimumSystemVersion' "$RELEASE_SH"; then
  echo "FAIL: release.sh no longer reads LSMinimumSystemVersion from the built app; the appcast's"
  echo "      minimum system version would be unset or stale."
  fails=$((fails + 1))
fi
if ! grep -Eq '^[[:space:]]*echo "MIN_OS=' "$RELEASE_SH"; then
  echo "FAIL: release.sh no longer writes MIN_OS into appcast-fields.env; appcast.sh requires it."
  fails=$((fails + 1))
fi

# --- the appcast keeps Intel Macs off arm64-only builds --------------------------------------
# The minimum system version cannot do this: Intel Macs run macOS 15 and 26. Without this element,
# Sparkle offers every Intel install a DMG it cannot launch, and the feed still publishes green.
if ! grep -q '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>' "$APPCAST_SH"; then
  echo "FAIL: appcast.sh no longer marks items arm64-only; Sparkle would offer Intel Macs an app"
  echo "      they cannot launch."
  fails=$((fails + 1))
fi

# --- Workroom Nightly keeps its own Sparkle feed --------------------------------------------
# Sparkle offers every UNTAGGED item — the stable channel — to every client, whatever
# `allowedChannels` says. While Nightly shared appcast.xml it was therefore offered the main
# Workroom DMG the moment a stable build number outran the newest nightly item (v2.0.0 = 769 vs
# nightly 767 on 2026-09-10), then refused it at the code-signing check because the two apps have
# different bundle ids by design — surfacing to the user as "The update is improperly signed and
# could not be validated." Nothing else catches a regression here: both feeds publish green and
# the break only appears on a user's machine, in the window after a release tag. Pin all three
# halves — the per-config setting, the templated URL, and the publisher.
PROJECT_YML="${TEST_INVARIANTS_PROJECT_YML:-$ROOT/macapp/project.yml}"
if ! grep -q 'WORKROOM_APPCAST: appcast-nightly.xml' "$PROJECT_YML"; then
  echo "FAIL: project.yml's Nightly config no longer sets WORKROOM_APPCAST: appcast-nightly.xml —"
  echo "      Workroom Nightly would share the main feed and be offered the main Workroom DMG."
  fails=$((fails + 1))
fi
if ! grep -q 'SUFeedURL: .*[$](WORKROOM_APPCAST)' "$PROJECT_YML"; then
  echo "FAIL: project.yml's SUFeedURL no longer resolves \$(WORKROOM_APPCAST); the per-config"
  echo "      nightly feed override cannot take effect."
  fails=$((fails + 1))
fi
if ! grep -q 'appcast-nightly.xml' "$APPCAST_SH"; then
  echo "FAIL: appcast.sh no longer publishes appcast-nightly.xml — the Nightly app's feed would"
  echo "      404 and nightly installs would stop updating entirely."
  fails=$((fails + 1))
fi

# --- Several workrooms at once: one identity per workroom, one GUI session per Mac ------------
# docs/designs/parallel-workroom-testing.md. Each half hangs on a single Makefile or project.yml
# token that a refactor could drop with every build still green and every test still passing —
# just no longer safely alongside another workroom's run, which no test here can see.
recipe() {
  for file in $MAKEFILES; do
    case "$file" in
      /*) ;;
      *) file="$MAKE_DIR/$file" ;;
    esac
    sed -n "/^$1:/,/^\$/p" "$file"
  done
}
for target in app-build app-test app-uitest; do
  if ! recipe "$target" | grep -Eq 'build(-for-testing)? .*\$\(APP_ID_FLAGS\)'; then
    echo "FAIL: $target no longer passes \$(APP_ID_FLAGS) where it builds — every workroom's Debug"
    echo "      build would share one identity again (prefs, session helpers, 'already running')."
    fails=$((fails + 1))
  fi
done
# Benchmarks can request exclusive access; normal tests must still default to shared access.
# Check the default and its use, so an unused shared default cannot conceal a missing lock.
app_test_gui_mode="$(make_value APP_TEST_GUI_MODE)"
if [ "$app_test_gui_mode" != shared ] \
  || ! recipe app-test | grep -q '[$](call gui_lock,[$](APP_TEST_GUI_MODE),app-test)'; then
  echo "FAIL: app-test no longer runs its tests under the shared GUI lock — a unit run's host windows"
  echo "      would land on top of another workroom's XCUITest run."
  fails=$((fails + 1))
fi
if ! recipe app-uitest | grep -q '[$](call gui_lock,exclusive,app-uitest)'; then
  echo "FAIL: app-uitest no longer holds the GUI session exclusively — two workrooms' UI-test runs"
  echo "      would drive the one pointer and keyboard at once."
  fails=$((fails + 1))
fi
if recipe app-run | grep -q 'pkill'; then
  echo "FAIL: app-run kills by process name again — every workroom's app is 'Workroom Dev', so that"
  echo "      stops other workrooms' dev apps and test runs. Stop by identity (stop-dev-app.sh)."
  fails=$((fails + 1))
fi
if ! grep -qF "PRODUCT_BUNDLE_IDENTIFIER: \"com.developwithstyle.workroom.dev\$(WORKROOM_DEV_ID_SUFFIX)\"" \
  "$PROJECT_YML"; then
  echo "FAIL: project.yml's Debug bundle id no longer carries \$(WORKROOM_DEV_ID_SUFFIX), so the"
  echo "      Makefile's per-workroom identity reaches nothing."
  fails=$((fails + 1))
fi
if [ "$(grep -cF "\$(WORKROOM_DEV_ID_SUFFIX)" "$PROJECT_YML")" -ne 1 ]; then
  echo "FAIL: \$(WORKROOM_DEV_ID_SUFFIX) must reach the Debug bundle id and nothing else — above all"
  echo "      never the Release or Nightly bundle id, which Sparkle updates and TCC grants key on."
  fails=$((fails + 1))
fi

# --- Terminal programs can reach the microphone --------------------------------------------
# A program in a Workroom terminal (Claude Code's voice mode first of all) opens the mic, and
# macOS attributes that to the terminal app: the hardened runtime needs OUR audio-input
# entitlement before audio input is allowed at all, and TCC needs OUR usage string to show a
# prompt. Both were missing through v2.1.0, so voice failed silently in Workroom while working
# in Ghostty and iTerm2, which declare the same pair. Nothing else catches a regression: every
# build and test is green with either half gone; only a user's first voice attempt fails.
# The plist check compares the full string, so an edit in project.yml without regeneration is caught.
ENTITLEMENTS="${TEST_INVARIANTS_ENTITLEMENTS:-$ROOT/macapp/WorkroomApp/Workroom.entitlements}"
INFO_PLIST="${TEST_INVARIANTS_INFO_PLIST:-$ROOT/macapp/WorkroomApp/Info.plist}"
if ! grep -A1 '<key>com.apple.security.device.audio-input</key>' "$ENTITLEMENTS" | grep -q '<true/>'; then
  echo "FAIL: Workroom.entitlements no longer grants com.apple.security.device.audio-input — the"
  echo "      hardened runtime blocks the microphone for every program in a Workroom terminal."
  fails=$((fails + 1))
fi
if ! grep -q '^[[:space:]]*NSMicrophoneUsageDescription: "[^"]' "$PROJECT_YML"; then
  echo "FAIL: project.yml's Info.plist properties no longer set NSMicrophoneUsageDescription —"
  echo "      TCC cannot show a microphone prompt for Workroom and denies the request."
  fails=$((fails + 1))
fi
mic_value="$(sed -n 's/^[[:space:]]*NSMicrophoneUsageDescription: "\(.*\)"[[:space:]]*$/\1/p' "$PROJECT_YML")"
mic_line="<string>${mic_value}</string>"
if [ -z "$mic_value" ] \
  || ! grep -A1 '<key>NSMicrophoneUsageDescription</key>' "$INFO_PLIST" | grep -qF "$mic_line"; then
  echo "FAIL: the checked-in Info.plist's NSMicrophoneUsageDescription is missing or differs from project.yml —"
  echo "      project.yml changed without 'make app-generate', so the committed plist is stale."
  fails=$((fails + 1))
fi
if ! grep -q '^[[:space:]]*CODE_SIGN_ENTITLEMENTS: WorkroomApp/Workroom.entitlements$' "$PROJECT_YML" \
  || [ "$(grep -c '^[[:space:]]*CODE_SIGN_ENTITLEMENTS:' "$PROJECT_YML")" -ne 1 ]; then
  echo "FAIL: project.yml no longer signs every configuration with WorkroomApp/Workroom.entitlements"
  echo "      (or a config overrides it) — the audio-input and apple-events entitlements would vanish"
  echo "      from the signed app while every test stays green."
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "test-invariants_test: $fails failure(s)" >&2
  exit 1
fi
echo "test-invariants_test: all cases passed"
