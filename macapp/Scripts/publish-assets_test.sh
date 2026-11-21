#!/bin/sh
#
# Dependency-free test for publish-assets.sh against a fake `gh` that keeps each release's state in
# files, and a stand-in for cli-archives.sh's check. Run: sh macapp/Scripts/publish-assets_test.sh
#
# What it pins: a tag's release is created as a draft and published only once every file is up,
# Latest for a clean tag and a pre-release otherwise; checksums.txt goes up after the archives; the
# nightly loses the Go CLI's Windows archives; a release whose archives are not exactly this
# build's (a stale Go archive, a Windows one) or whose archives fail the check is never published;
# and a dry run does all of it to a draft of its own, never published and then deleted, without
# one call that names the real release.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLISH="${PUBLISH_ASSETS:-$DIR/publish-assets.sh}"
fails=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-assets_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

# The fake gh. Every call goes to $FAKE_GH/calls, one per line. Each release is a directory,
# $FAKE_GH/rel-<tag>, holding `draft` (true/false) and `assets` (one name per line). `gh api
# …/releases/latest` answers $FAKE_GH/latest's tag.
cat >"$WORK/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_GH/calls"
if [ "$1" = api ]; then
  [ -f "$FAKE_GH/latest" ] || exit 1
  cat "$FAKE_GH/latest"
  exit 0
fi
[ "$1" = release ] || exit 2
sub="$2"
rel="$FAKE_GH/rel-$3"
shift 3
case "$sub" in
  view)
    [ -d "$rel" ] || { echo "release not found" >&2; exit 1; }
    case "$*" in
      *isDraft*) cat "$rel/draft" ;;
      *assets*) cat "$rel/assets" ;;
    esac
    ;;
  create)
    mkdir "$rel"
    : >"$rel/assets"
    case "$*" in *--draft*) echo true >"$rel/draft" ;; *) echo false >"$rel/draft" ;; esac
    ;;
  upload)
    [ -z "${FAKE_GH_UPLOAD_FAILS:-}" ] || { echo "upload failed" >&2; exit 1; }
    for arg in "$@"; do
      if [ -f "$arg" ]; then
        name="$(basename "$arg")"
        grep -qxF "$name" "$rel/assets" || echo "$name" >>"$rel/assets"
      fi
    done
    ;;
  delete-asset)
    grep -vxF "$1" "$rel/assets" >"$rel/assets.new" || true
    mv "$rel/assets.new" "$rel/assets"
    ;;
  delete)
    rm -r "$rel"
    ;;
  edit)
    case "$*" in *--draft=false*) echo false >"$rel/draft" ;; esac
    ;;
esac
EOF
chmod +x "$WORK/bin/gh"

# The check's stand-in: records what it was asked, and fails when CHECK_FAILS is set.
cat >"$WORK/bin/cli-archives" <<'EOF'
#!/bin/sh
echo "$1 $2 VERSION=$VERSION CHANNEL=$WORKROOM_RELEASE_CHANNEL${CLI_ARCHIVES_PLATFORMS+ PLATFORMS=$CLI_ARCHIVES_PLATFORMS}" >>"$FAKE_GH/checked"
[ -z "${CHECK_FAILS:-}" ]
EOF
chmod +x "$WORK/bin/cli-archives"

# archives <label>: a directory of this label's four archives and checksums.txt.
archives() {
  dir="$WORK/archives-$1"
  if [ ! -d "$dir" ]; then
    mkdir "$dir"
    for platform in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
      echo "$platform" >"$dir/workroom_$1_$platform.tar.gz"
    done
    echo sums >"$dir/checksums.txt"
  fi
  echo "$dir"
}
echo dmg >"$WORK/app.dmg"

# fresh <case>: a new fake GitHub with no releases. `seed` gives it one; `run [--dry-run] <tag>
# <label> [env assignments…]` runs publish-assets.sh against it and sets RC and OUT.
fresh() {
  FAKE_GH="$WORK/state-$1"
  mkdir "$FAKE_GH"
  : >"$FAKE_GH/calls"
  export FAKE_GH
}
# seed <tag> <draft true|false> [assets, one per line]
seed() {
  mkdir "$FAKE_GH/rel-$1"
  echo "$2" >"$FAKE_GH/rel-$1/draft"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" >"$FAKE_GH/rel-$1/assets"; else : >"$FAKE_GH/rel-$1/assets"; fi
}
run() {
  dry=""
  if [ "$1" = --dry-run ]; then dry=--dry-run; shift; fi
  tag="$1"
  label="$2"
  shift 2
  OUT="$(env PATH="$WORK/bin:$PATH" REPO=example/workroom CLI_ARCHIVES="$WORK/bin/cli-archives" \
    "$@" sh "$PUBLISH" $dry "$tag" "$(archives "$label")" "$WORK/app.dmg" 2>&1)"
  RC=$?
}

fail() {
  echo "FAIL: $1"
  [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/    /'
  fails=$((fails + 1))
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "$2: exited $RC, want $1"; }
expect_call() { grep -qF -- "$1" "$FAKE_GH/calls" || fail "$2: no gh call '$1'"; }
expect_no_call() { ! grep -qF -- "$1" "$FAKE_GH/calls" || fail "$2: gh was called with '$1'"; }
# expect_assets <case> <tag> <assets, one per line>
expect_assets() {
  want="$(printf '%s\n' "$3" | LC_ALL=C sort)"
  got="$(LC_ALL=C sort "$FAKE_GH/rel-$2/assets")"
  [ "$got" = "$want" ] || fail "$1: $2 holds '$(echo "$got" | tr '\n' ' ')'"
}
# The four archives of <label>, and checksums.txt, one per line.
shipped() {
  for platform in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
    echo "workroom_$1_$platform.tar.gz"
  done
  echo checksums.txt
}
# line <pattern>: the number of the first gh call matching it, or 0.
line() {
  n="$(grep -nE "$1" "$FAKE_GH/calls" | head -1 | cut -d: -f1)"
  echo "${n:-0}"
}
NIGHTLY_ASSETS="workroom_nightly_windows_amd64.zip
workroom_nightly_windows_arm64.zip
workroom_nightly_darwin_arm64.tar.gz
checksums.txt
workroom-macos-app_nightly.dmg"

# --- a new stable tag: a draft, every file, then Latest ---
fresh stable
run v2.1.0 2.1.0
expect_rc 0 "stable"
expect_call "release create v2.1.0 --verify-tag --draft --title v2.1.0 --generate-notes" "stable"
expect_call "release edit v2.1.0 --draft=false --latest --repo example/workroom" "stable"
expect_assets "stable" v2.1.0 "$(shipped 2.1.0; echo app.dmg)"
grep -qxF "check $WORK/archives-2.1.0 VERSION=2.1.0 CHANNEL=" "$FAKE_GH/checked" \
  || fail "stable: the archives were not checked as 2.1.0 on the main channel"
# checksums.txt after the archives, and the release published after both.
archives_at="$(line 'upload v2\.1\.0 .*workroom_2\.1\.0_linux_amd64')"
sums_at="$(line 'upload v2\.1\.0 .*checksums\.txt')"
published_at="$(line 'edit v2\.1\.0 --draft=false')"
[ "$archives_at" -gt 0 ] && [ "$archives_at" -lt "$sums_at" ] && [ "$sums_at" -lt "$published_at" ] \
  || fail "stable: want the archives (call $archives_at), then checksums.txt ($sums_at), then publishing ($published_at)"

# --- a prerelease tag: a pre-release, never Latest; and all four platforms are checked, whatever
# the environment narrows them to ---
fresh pre
run v2.1.0-beta.1 2.1.0-beta.1 CLI_ARCHIVES_PLATFORMS=darwin_arm64
grep -qxF "check $WORK/archives-2.1.0-beta.1 VERSION=2.1.0-beta.1 CHANNEL=" "$FAKE_GH/checked" \
  || fail "pre: the archives were checked with the platforms narrowed: $(cat "$FAKE_GH/checked")"
expect_rc 0 "pre"
expect_call "release edit v2.1.0-beta.1 --draft=false --prerelease --latest=false" "pre"
expect_no_call "--latest --repo" "pre"

# --- a re-run: the published release keeps its state, its files are replaced ---
fresh rerun
seed v2.1.0 false "$(shipped 2.1.0; echo app.dmg)"
run v2.1.0 2.1.0
expect_rc 0 "rerun"
expect_no_call "release create" "rerun"
expect_no_call "release edit" "rerun"
expect_call "--clobber" "rerun"

# --- the nightly: its Go CLI's Windows archives go ---
fresh nightly
seed nightly false "$NIGHTLY_ASSETS"
run nightly nightly VERSION=2.1.0-nightly.912
expect_rc 0 "nightly"
expect_call "release delete-asset nightly workroom_nightly_windows_amd64.zip --yes" "nightly"
expect_call "release delete-asset nightly workroom_nightly_windows_arm64.zip --yes" "nightly"
expect_assets "nightly" nightly "$(shipped nightly; echo app.dmg; echo workroom-macos-app_nightly.dmg)"
grep -qxF "check $WORK/archives-nightly VERSION=2.1.0-nightly.912 CHANNEL=nightly" "$FAKE_GH/checked" \
  || fail "nightly: the archives were not checked as 2.1.0-nightly.912 on the nightly channel"
expect_no_call "release create" "nightly"

# --- the nightly needs its version, and its release ---
fresh nightly-no-version
seed nightly false
run nightly nightly
expect_rc 1 "nightly without VERSION"
expect_no_call "upload" "nightly without VERSION"
fresh nightly-missing
run nightly nightly VERSION=2.1.0-nightly.912
expect_rc 1 "nightly with no release"
expect_no_call "upload" "nightly with no release"

# --- a stale archive on the release: refused, and a new release stays a draft ---
fresh stray
seed v2.1.0 true workroom_2.1.0_windows_amd64.zip
run v2.1.0 2.1.0
expect_rc 1 "a Windows archive on the release"
expect_no_call "release edit" "a Windows archive on the release"
case "$OUT" in *workroom_2.1.0_windows_amd64.zip*) ;; *) fail "a Windows archive on the release: the error does not name it" ;; esac

# --- archives that fail the check are never uploaded ---
fresh bad-archives
run v2.1.0 2.1.0 CHECK_FAILS=1
expect_rc 1 "failing archives"
expect_no_call "upload" "failing archives"
expect_no_call "release create" "failing archives"

# --- a tag of no channel ---
fresh appcast
run appcast 2.1.0
expect_rc 1 "the appcast tag"
expect_no_call "release" "the appcast tag"

# --- a dry run: its own draft, checked, never published, deleted; the nightly untouched ---
fresh dry
seed nightly false "$NIGHTLY_ASSETS"
cp -R "$FAKE_GH/rel-nightly" "$WORK/nightly-before"
echo v2.0.0 >"$FAKE_GH/latest"
run --dry-run nightly nightly VERSION=2.1.0-nightly.912 GITHUB_RUN_ID=4242 GITHUB_SHA=abc123
expect_rc 0 "dry run"
expect_call "release create nightly-dryrun-4242 --draft --title nightly-dryrun-4242 --target abc123" "dry run"
expect_call "release upload nightly-dryrun-4242" "dry run"
expect_call "release edit nightly-dryrun-4242 --notes" "dry run"
expect_call "api repos/example/workroom/releases/latest" "dry run"
expect_call "release delete nightly-dryrun-4242 --yes --cleanup-tag" "dry run"
expect_no_call "--draft=false" "dry run"
# Every release call named the dry run's draft, and the nightly is as it was.
others="$(grep '^release ' "$FAKE_GH/calls" | grep -v '^release [a-z-]* nightly-dryrun-4242 ' || true)"
[ -z "$others" ] || fail "dry run: gh calls on another release: $others"
[ ! -d "$FAKE_GH/rel-nightly-dryrun-4242" ] || fail "dry run: its draft was not deleted"
diff -r "$WORK/nightly-before" "$FAKE_GH/rel-nightly" >/dev/null || fail "dry run: the nightly release changed"
grep -qxF "check $WORK/archives-nightly VERSION=2.1.0-nightly.912 CHANNEL=nightly" "$FAKE_GH/checked" \
  || fail "dry run: the archives were not checked as the nightly's"

# --- a dry run that fails deletes its draft too, and never reuses one ---
fresh dry-fails
seed nightly-dryrun-77 true
run --dry-run nightly nightly VERSION=2.1.0-nightly.912 GITHUB_RUN_ID=77
expect_rc 1 "a dry run's draft already there"
expect_no_call "upload" "a dry run's draft already there"
fresh dry-upload-fails
run --dry-run nightly nightly VERSION=2.1.0-nightly.912 GITHUB_RUN_ID=88 FAKE_GH_UPLOAD_FAILS=1
expect_rc 1 "a dry run whose upload fails"
expect_call "release delete nightly-dryrun-88 --yes --cleanup-tag" "a dry run whose upload fails"
[ ! -d "$FAKE_GH/rel-nightly-dryrun-88" ] || fail "a failed dry run left its draft"

# --- a dry run needs a run id, so its draft can never be named like a real release ---
fresh dry-no-id
seed nightly false "$NIGHTLY_ASSETS"
run --dry-run nightly nightly VERSION=2.1.0-nightly.912 GITHUB_RUN_ID=
expect_rc 1 "a dry run with no run id"
expect_no_call "release" "a dry run with no run id"

if [ "$fails" -ne 0 ]; then
  echo "publish-assets_test: $fails failure(s)"
  exit 1
fi
echo "publish-assets_test: OK"
