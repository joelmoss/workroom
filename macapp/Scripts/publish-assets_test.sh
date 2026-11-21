#!/bin/sh
#
# Dependency-free test for publish-assets.sh against a fake `gh` that keeps a release's state in
# files, and a stand-in for cli-archives.sh's check. Run: sh macapp/Scripts/publish-assets_test.sh
#
# What it pins: a tag's release is created as a draft and published only once every file is up,
# Latest for a clean tag and a pre-release otherwise; checksums.txt goes up after the archives; the
# nightly loses the Go CLI's Windows archives; and a release whose archives are not exactly this
# build's (a stale Go archive, a Windows one) or whose archives fail the check is never published.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLISH="${PUBLISH_ASSETS:-$DIR/publish-assets.sh}"
fails=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-assets_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

# The fake gh. State, per case, in $FAKE_GH: `exists`, `draft` (true/false), `assets` (one name per
# line) and `calls` (every call, one per line).
cat >"$WORK/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_GH/calls"
[ "$1" = release ] || exit 2
sub="$2"
tag="$3"
shift 3
case "$sub" in
  view)
    [ -f "$FAKE_GH/exists" ] || { echo "release not found" >&2; exit 1; }
    case "$*" in
      *isDraft*) cat "$FAKE_GH/draft" ;;
      *assets*) cat "$FAKE_GH/assets" ;;
    esac
    ;;
  create)
    : >"$FAKE_GH/exists"
    : >"$FAKE_GH/assets"
    case "$*" in *--draft*) echo true >"$FAKE_GH/draft" ;; *) echo false >"$FAKE_GH/draft" ;; esac
    ;;
  upload)
    for arg in "$@"; do
      if [ -f "$arg" ]; then
        name="$(basename "$arg")"
        grep -qxF "$name" "$FAKE_GH/assets" || echo "$name" >>"$FAKE_GH/assets"
      fi
    done
    ;;
  delete-asset)
    grep -vxF "$1" "$FAKE_GH/assets" >"$FAKE_GH/assets.new" || true
    mv "$FAKE_GH/assets.new" "$FAKE_GH/assets"
    ;;
  edit)
    case "$*" in *--draft=false*) echo false >"$FAKE_GH/draft" ;; esac
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

# fresh <case>: a new, empty fake release state. `seed` gives it a release; `run <tag> <label>
# [env assignments…]` runs publish-assets.sh against it and sets RC and OUT.
fresh() {
  FAKE_GH="$WORK/state-$1"
  mkdir "$FAKE_GH"
  : >"$FAKE_GH/calls"
  export FAKE_GH
}
# seed <draft true|false> [assets, one per line]
seed() {
  : >"$FAKE_GH/exists"
  echo "$1" >"$FAKE_GH/draft"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" >"$FAKE_GH/assets"; else : >"$FAKE_GH/assets"; fi
}
run() {
  tag="$1"
  label="$2"
  shift 2
  OUT="$(env PATH="$WORK/bin:$PATH" REPO=example/workroom CLI_ARCHIVES="$WORK/bin/cli-archives" \
    "$@" sh "$PUBLISH" "$tag" "$(archives "$label")" "$WORK/app.dmg" 2>&1)"
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
# expect_assets <case> <assets, one per line>
expect_assets() {
  want="$(printf '%s\n' "$2" | LC_ALL=C sort)"
  got="$(LC_ALL=C sort "$FAKE_GH/assets")"
  [ "$got" = "$want" ] || fail "$1: the release holds '$(echo "$got" | tr '\n' ' ')'"
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

# --- a new stable tag: a draft, every file, then Latest ---
fresh stable
run v2.1.0 2.1.0
expect_rc 0 "stable"
expect_call "release create v2.1.0 --verify-tag --draft --title v2.1.0 --generate-notes" "stable"
expect_call "release edit v2.1.0 --draft=false --latest --repo example/workroom" "stable"
expect_assets "stable" "$(shipped 2.1.0; echo app.dmg)"
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
seed false "$(shipped 2.1.0; echo app.dmg)"
run v2.1.0 2.1.0
expect_rc 0 "rerun"
expect_no_call "release create" "rerun"
expect_no_call "release edit" "rerun"
expect_call "--clobber" "rerun"

# --- the nightly: its Go CLI's Windows archives go ---
fresh nightly
seed false "workroom_nightly_windows_amd64.zip
workroom_nightly_windows_arm64.zip
workroom_nightly_darwin_arm64.tar.gz
checksums.txt
workroom-macos-app_nightly.dmg"
run nightly nightly VERSION=2.1.0-nightly.912
expect_rc 0 "nightly"
expect_call "release delete-asset nightly workroom_nightly_windows_amd64.zip --yes" "nightly"
expect_call "release delete-asset nightly workroom_nightly_windows_arm64.zip --yes" "nightly"
expect_assets "nightly" "$(shipped nightly; echo app.dmg; echo workroom-macos-app_nightly.dmg)"
grep -qxF "check $WORK/archives-nightly VERSION=2.1.0-nightly.912 CHANNEL=nightly" "$FAKE_GH/checked" \
  || fail "nightly: the archives were not checked as 2.1.0-nightly.912 on the nightly channel"
expect_no_call "release create" "nightly"

# --- the nightly needs its version, and its release ---
fresh nightly-no-version
seed false
run nightly nightly
expect_rc 1 "nightly without VERSION"
expect_no_call "upload" "nightly without VERSION"
fresh nightly-missing
run nightly nightly VERSION=2.1.0-nightly.912
expect_rc 1 "nightly with no release"
expect_no_call "upload" "nightly with no release"

# --- a stale archive on the release: refused, and a new release stays a draft ---
fresh stray
seed true workroom_2.1.0_windows_amd64.zip
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

if [ "$fails" -ne 0 ]; then
  echo "publish-assets_test: $fails failure(s)"
  exit 1
fi
echo "publish-assets_test: OK"
