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
for target in app-build app-test app-uitest app-uitest-vm; do
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
# A Mac runs at most two macOS guests; a third `tart run` fails, so every guest boots in a slot.
if ! recipe app-uitest-vm | grep -q 'Scripts/uitest-vm.sh' \
  || ! grep -q 'gui-lock.py" vm-slot' "$DIR/uitest-vm.sh"; then
  echo "FAIL: app-uitest-vm no longer boots its guests through gui-lock.py vm-slot — runs from"
  echo "      several checkouts would start more guests than this Mac can run."
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

# --- the release and the Nightly ship the one Rust binary --------------------------------------
# ADR 0078: no release ships both binaries. The standalone archives are cli-archives.sh's, which
# refuses a Go binary and a Windows build, and publish-assets.sh puts them up, which refuses a
# release holding any other archive. Nothing builds the Go CLI or runs goreleaser beside them. The
# release runs the contract suite against the binary it ships; the Nightly cannot, as the suite's
# goldens are the main binary's and the nightly's baked channel differs by design.
expect_workflow_runs() {
  if ! grep -q -- "^[^#]*$2" "$WORKFLOWS_DIR/$1"; then
    echo "FAIL: $1 no longer runs '$2'; its standalone archives would not be the checked Rust"
    echo "      binary (ADR 0078)."
    fails=$((fails + 1))
  fi
}
[ -f "$WORKFLOWS_DIR/release.yml" ] && expect_workflow_runs release.yml '--test commands_contract'
for workflow in release.yml nightly.yml; do
  path="$WORKFLOWS_DIR/$workflow"
  [ -f "$path" ] || continue
  expect_workflow_runs "$workflow" 'macapp/Scripts/cli-archives.sh build'
  expect_workflow_runs "$workflow" 'macapp/Scripts/publish-assets.sh'
  if grep -q 'CLI_ARCHIVES_PLATFORMS' "$path"; then
    echo "FAIL: $workflow sets CLI_ARCHIVES_PLATFORMS, which narrows the archives it builds below"
    echo "      the four every release ships (it is cli-archives_test.sh's)."
    fails=$((fails + 1))
  fi
  if grep -Eq '^[^#]*(goreleaser|setup-go|go build|GOOS=)' "$path"; then
    echo "FAIL: $workflow builds the Go CLI or runs goreleaser; a release ships only the Rust"
    echo "      workroom (ADR 0078)."
    fails=$((fails + 1))
  fi
done

# --- the Nightly's contract suite skips exactly the main binary's channel cases ---------------
# The nightly's baked channel changes `version --json` and refuses `update --channel`, so these
# four goldens are the main binary's; any other skip would hide a contract break in the Nightly.
NIGHTLY_YML="$WORKFLOWS_DIR/nightly.yml"
if [ -f "$NIGHTLY_YML" ]; then
  want_skips="update_json_refuses_a_channel_it_cant_switch_to
version_json_flag_may_come_before_the_command
version_json_matches_the_golden
version_json_reports_the_configured_channel"
  got_skips="$(grep -o -- '--skip [A-Za-z0-9_]*' "$NIGHTLY_YML" | sed 's/^--skip //' | LC_ALL=C sort)"
  if [ "$got_skips" != "$want_skips" ] || ! grep -q -- '^[^#]*--include-ignored --exact' "$NIGHTLY_YML"; then
    echo "FAIL: nightly.yml's contract suite no longer skips exactly the four main-channel cases"
    echo "      (with --exact): got '$(echo "$got_skips" | tr '\n' ' ')'."
    fails=$((fails + 1))
  fi
fi

# --- a Nightly dry run never touches the real release ------------------------------------------
# The dry run (workflow_dispatch dry_run) uploads into a throwaway draft and deletes it. Its job is
# the only one that runs then; `publish`, which writes the nightly release, the appcast, the
# download stats and the skip marker, never does.
# job_block <workflow> <job>: the lines of that job, up to the next job.
job_block() {
  awk -v job="  $2:" '$0 == job {f=1; print; next} f && /^  [A-Za-z0-9_-]+:$/ {f=0} f' "$1"
}
if [ -f "$NIGHTLY_YML" ]; then
  dry_block="$(job_block "$NIGHTLY_YML" dry-run)"
  publish_block="$(job_block "$NIGHTLY_YML" publish)"
  only_dry="    if: \${{ inputs.dry_run }}"
  if ! printf '%s\n' "$dry_block" | grep -qxF "$only_dry" \
    || ! printf '%s\n' "$dry_block" | grep -q '^[^#]*macapp/Scripts/publish-assets.sh --dry-run nightly '; then
    echo "FAIL: nightly.yml's dry-run job no longer runs only on a dry run, through publish-assets.sh --dry-run."
    fails=$((fails + 1))
  fi
  if printf '%s\n' "$dry_block" | grep -Eq '^[^#]*(appcast|download-stats|gh release|publish-assets\.sh nightly)'; then
    echo "FAIL: nightly.yml's dry-run job touches the nightly release, the appcast or the download stats."
    fails=$((fails + 1))
  fi
  not_dry="    if: \${{ !inputs.dry_run }}"
  if ! printf '%s\n' "$publish_block" | grep -qxF "$not_dry"; then
    echo "FAIL: nightly.yml's publish job would run on a dry run and publish it."
    fails=$((fails + 1))
  fi
  if grep -v '^ *#' "$NIGHTLY_YML" | grep -q -- '--dry-run' \
    && [ "$(grep -v '^ *#' "$NIGHTLY_YML" | grep -c -- '--dry-run')" -ne "$(printf '%s\n' "$dry_block" | grep -v '^ *#' | grep -c -- '--dry-run')" ]; then
    echo "FAIL: nightly.yml runs publish-assets.sh --dry-run outside its dry-run job."
    fails=$((fails + 1))
  fi
fi

# --- a dry run's cleanup never fails on the tag its draft never had ----------------------------
# A draft has no git tag until it is published, and `gh release delete --cleanup-tag` then fails
# with a 422 once it has deleted the draft (run 44978170787). publish-assets.sh deletes the draft,
# then its tag only if one exists (delete_dry_run, pinned by publish-assets_test.sh).
if grep -q '^[^#]*--cleanup-tag' "$DIR/publish-assets.sh"; then
  echo "FAIL: publish-assets.sh deletes a dry run's draft with --cleanup-tag, which fails on its"
  echo "      missing tag; delete_dry_run deletes the tag only when there is one."
  fails=$((fails + 1))
fi

# --- every job that publishes can run the linux arm64 binary ------------------------------------
# publish-assets.sh runs cli-archives.sh check, which runs each linux binary on the job's Ubuntu
# runner, the arm64 one under `qemu-aarch64`. Ubuntu 26.04 (ubuntu-latest) has no
# `qemu-user-static`, so installing it fails the job before anything publishes; `qemu-user` is the
# package. Pinned per job: each job that runs publish-assets.sh installs exactly it.
for workflow in release.yml nightly.yml; do
  path="$WORKFLOWS_DIR/$workflow"
  [ -f "$path" ] || continue
  jobs="$(awk '/^  [A-Za-z0-9_-]+:$/ {sub(/:$/, ""); sub(/^  /, ""); print}' "$path")"
  while read -r job; do
    [ -n "$job" ] || continue
    block="$(job_block "$path" "$job")"
    printf '%s\n' "$block" | grep -q '^[^#]*macapp/Scripts/publish-assets.sh' || continue
    if ! printf '%s\n' "$block" | grep -qxF '        run: sudo apt-get update -qq && sudo apt-get install -y -qq qemu-user' \
      || printf '%s\n' "$block" | grep -q '^[^#]*qemu-user-static'; then
      echo "FAIL: $workflow's $job job runs publish-assets.sh without installing qemu-user, which"
      echo "      runs the linux arm64 binary (Ubuntu 26.04 has no qemu-user-static)."
      fails=$((fails + 1))
    fi
  done <<EOF
$jobs
EOF
done

# --- the swap's hand-off test runs against the pre-swap daemon ---------------------------------
# DaemonHandOffTests moves a daemon an app from before the swap (#681) started from
# Contents/MacOS/workroomd. ci-app.yml's `app` job builds that daemon from the commit
# build-pre-swap-daemon.sh pins and names it to the test, which fails in CI without it. The pin
# must stay the last commit before the swap: one whose build-daemon.sh still builds `workroomd`
# into Contents/MacOS, on this branch's history. Not checked in a clone without its history.
CI_APP_YML="$WORKFLOWS_DIR/ci-app.yml"
if [ -f "$CI_APP_YML" ]; then
  app_block="$(job_block "$CI_APP_YML" app)"
  if ! printf '%s\n' "$app_block" | grep -q '^[^#]*macapp/Scripts/build-pre-swap-daemon.sh "' \
    || ! printf '%s\n' "$app_block" | grep -q '^[^#]*TEST_RUNNER_WR_FORMER_DAEMON=".HOME/.cache/workroom/pre-swap-daemon/workroom"'; then
    echo "FAIL: ci-app.yml's app job no longer builds the pre-swap daemon and names it to"
    echo "      app-test as TEST_RUNNER_WR_FORMER_DAEMON."
    fails=$((fails + 1))
  fi
fi
pre_swap="$(bash "$DIR/build-pre-swap-daemon.sh" --commit)"
if git -C "$ROOT" rev-parse -q --verify "$pre_swap^{commit}" >/dev/null 2>&1; then
  if ! git -C "$ROOT" merge-base --is-ancestor "$pre_swap" HEAD \
    || ! git -C "$ROOT" show "$pre_swap:macapp/Scripts/build-daemon.sh" | grep -q '^HELPER_NAME="workroomd"$'; then
    echo "FAIL: build-pre-swap-daemon.sh's commit $pre_swap is not a pre-swap commit on this"
    echo "      branch: its app must run the daemon from Contents/MacOS/workroomd."
    fails=$((fails + 1))
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "test-invariants_test: $fails failure(s)" >&2
  exit 1
fi
echo "test-invariants_test: all cases passed"
