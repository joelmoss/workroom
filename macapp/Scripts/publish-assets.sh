#!/bin/bash
#
# Publishes a release's downloads to its GitHub release: the standalone `workroom` archives and
# checksums.txt (cli-archives.sh) and the app's DMG. Run by release.yml for a `v*` tag and by
# nightly.yml for the fixed `nightly` release, after both are built.
#
#   publish-assets.sh <tag> <archives-dir> <dmg>
#   publish-assets.sh --dry-run <tag> <archives-dir> <dmg>
#
# Env: VERSION (the version the binaries are stamped with; a tag's own when unset), GH_TOKEN, and
# GITHUB_REPOSITORY or REPO for `gh`. A dry run also needs GITHUB_RUN_ID.
#
# - The archives are checked first (cli-archives.sh check): exactly the four Rust binaries and
#   their notices, no Go binary and no Windows build (ADR 0078); on Linux it runs the linux ones.
# - A tag's release is created here, as a draft, and published only once every file is on it, so
#   GitHub's "Latest", which install.sh and the stable updater read, never names a release without
#   its archives. A clean vX.Y.Z is marked Latest, a prerelease tag a pre-release
#   (channel-helper.sh). A re-run finds the release and replaces its files.
# - The nightly release already exists. The Go CLI's Windows archives are removed from it, by name:
#   no Nightly ships them now, and the release is reused every night.
# - checksums.txt goes up after the archives, so an updater never reads sums for archives still
#   being replaced: a mismatch makes it refuse, never install.
# - Last, the release's archive names are checked: exactly this build's, and no other file with an
#   `_<os>_<arch>.` in its name, which both updaters would take for an archive.
#
# A dry run does all of that to a draft of its own, `<tag>-dryrun-<run id>`, made here and never
# published, then checks it is not GitHub's Latest and deletes it, tag included: every `gh` call
# names that draft's tag and nothing else (gh_release refuses any other), so the real release, the
# appcast and the download stats are never touched.
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_ARCHIVES="${CLI_ARCHIVES:-$MACAPP_DIR/Scripts/cli-archives.sh}"
# shellcheck source=channel-helper.sh
. "$MACAPP_DIR/Scripts/channel-helper.sh"

DRY_RUN=""
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi
[ "$#" -eq 3 ] || { echo "usage: publish-assets.sh [--dry-run] <tag> <archives-dir> <dmg>" >&2; exit 1; }
TAG="$1"
ARCHIVES="$2"
DMG="$3"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
[ -n "$REPO" ] || { echo "error: REPO or GITHUB_REPOSITORY must name the repository." >&2; exit 1; }

CHANNEL="$(wr_classify_channel "$TAG")" \
  || { echo "error: '$TAG' is not a release tag (vX.Y.Z, vX.Y.Z-<pre> or nightly)." >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: $DMG not found." >&2; exit 1; }

# The release every `gh` call below acts on: the tag's own, or the dry run's draft.
TARGET="$TAG"
if [ -n "$DRY_RUN" ]; then
  case "${GITHUB_RUN_ID:-}" in
    "" | *[!0-9]*) echo "error: a dry run needs GITHUB_RUN_ID, the run's number." >&2; exit 1 ;;
  esac
  TARGET="${TAG}-dryrun-${GITHUB_RUN_ID}"
fi

case "$CHANNEL" in
  nightly)
    [ -n "${VERSION:-}" ] || { echo "error: VERSION must be the nightly version (X.Y.Z-nightly.N)." >&2; exit 1; }
    BAKED=nightly
    ;;
  *)
    VERSION="${VERSION:-${TAG#v}}"
    BAKED=""
    ;;
esac
# All four platforms, whatever the environment says: CLI_ARCHIVES_PLATFORMS is the tests' alone.
env -u CLI_ARCHIVES_PLATFORMS VERSION="$VERSION" WORKROOM_RELEASE_CHANNEL="$BAKED" \
  "$CLI_ARCHIVES" check "$ARCHIVES"

ARCHIVE_FILES=()
for file in "$ARCHIVES"/workroom_*.tar.gz; do
  ARCHIVE_FILES+=("$file")
done

# gh_release <subcommand> <tag> …: `gh release`, only ever on TARGET, and in a dry run only on a
# `-dryrun-<n>` draft's tag.
gh_release() {
  if [ "$2" != "$TARGET" ]; then
    echo "error: refusing 'gh release $1 $2': this run acts on $TARGET alone." >&2
    exit 1
  fi
  if [ -n "$DRY_RUN" ]; then
    case "$2" in
      *-dryrun-[0-9]*) ;;
      *) echo "error: a dry run refuses 'gh release $1 $2': not a dry run's draft." >&2; exit 1 ;;
    esac
  fi
  gh release "$@" --repo "$REPO"
}

# The release's state: "draft", "published" or "missing".
release_state() {
  local draft
  if ! draft="$(gh_release view "$TARGET" --json isDraft -q .isDraft 2>/dev/null)"; then
    echo missing
  elif [ "$draft" = "true" ]; then
    echo draft
  else
    echo published
  fi
}

STATE="$(release_state)"
case "${DRY_RUN:+dry}:$CHANNEL:$STATE" in
  dry:*:missing)
    echo "==> Dry run: creating the draft $TARGET (never published, deleted at the end)"
    # Deleted whatever happens below, the tag too. A draft's tag is made only on publishing, so
    # --cleanup-tag finds none; it is there in case GitHub ever makes one.
    trap 'gh_release delete "$TARGET" --yes --cleanup-tag || echo "::error::delete the draft release $TARGET by hand" >&2' EXIT
    gh_release create "$TARGET" --draft --title "$TARGET" --target "${GITHUB_SHA:-master}" \
      --notes "Dry run of publishing $TAG ($VERSION). Never published; deleted when the run ends."
    STATE="$(release_state)"
    [ "$STATE" = draft ] || { echo "error: the dry run's $TARGET is $STATE, not a draft." >&2; exit 1; }
    ;;
  dry:*)
    echo "error: $TARGET already exists; a dry run makes its own and never reuses one." >&2
    exit 1
    ;;
  :nightly:missing)
    echo "error: the nightly release does not exist; nightly.yml creates it before publishing." >&2
    exit 1
    ;;
  :*:missing)
    echo "==> Creating the $TARGET release (draft until its files are up)"
    gh_release create "$TARGET" --verify-tag --draft --title "$TARGET" --generate-notes
    STATE=draft
    ;;
esac

echo "==> Uploading the archives and the app to $TARGET"
gh_release upload "$TARGET" "${ARCHIVE_FILES[@]}" "$DMG" --clobber
gh_release upload "$TARGET" "$ARCHIVES/checksums.txt" --clobber

ASSETS="$(gh_release view "$TARGET" --json assets -q '.assets[].name')"
if [ "$CHANNEL" = nightly ]; then
  for stale in workroom_nightly_windows_amd64.zip workroom_nightly_windows_arm64.zip; do
    if printf '%s\n' "$ASSETS" | grep -qxF "$stale"; then
      echo "==> Removing $stale from the nightly release (no Windows build since ADR 0078)"
      gh_release delete-asset "$TARGET" "$stale" --yes
    fi
  done
  ASSETS="$(gh_release view "$TARGET" --json assets -q '.assets[].name')"
fi

# What the release holds that an updater or install.sh could take for an archive, or its sums.
want="$(for file in "${ARCHIVE_FILES[@]}"; do basename "$file"; done; echo checksums.txt)"
want="$(printf '%s\n' "$want" | LC_ALL=C sort)"
got="$(printf '%s\n' "$ASSETS" | grep -E '^workroom_|_(darwin|linux|windows)_|^checksums\.txt$' | LC_ALL=C sort || true)"
if [ "$got" != "$want" ]; then
  echo "error: $TARGET's archives are not exactly this build's. Want:" >&2
  printf '%s\n' "$want" >&2
  echo "Got:" >&2
  printf '%s\n' "$got" >&2
  exit 1
fi

if [ -n "$DRY_RUN" ]; then
  # The edit the real publish makes, without publishing: the draft stays a draft.
  gh_release edit "$TARGET" --notes "Dry run of publishing $TAG ($VERSION): its files checked out."
  [ "$(release_state)" = draft ] || { echo "error: the dry run's $TARGET is no longer a draft." >&2; exit 1; }
  latest="$(gh api "repos/$REPO/releases/latest" -q .tag_name 2>/dev/null || true)"
  if [ "$latest" = "$TARGET" ]; then
    echo "error: the dry run's draft $TARGET is GitHub's Latest release." >&2
    exit 1
  fi
  echo "==> Dry run: $TARGET held exactly this build's files, stayed a draft and is not Latest ($latest)"
  trap - EXIT
  gh_release delete "$TARGET" --yes --cleanup-tag
  if [ "$(release_state)" != missing ]; then
    echo "error: the dry run's draft $TARGET is still there; delete it by hand." >&2
    exit 1
  fi
  echo "==> Dry run: deleted $TARGET; $TAG was not touched"
  exit 0
fi

if [ "$STATE" = draft ]; then
  echo "==> Publishing the $TARGET release"
  case "$CHANNEL" in
    stable) gh_release edit "$TARGET" --draft=false --latest ;;
    pre) gh_release edit "$TARGET" --draft=false --prerelease --latest=false ;;
    nightly) gh_release edit "$TARGET" --draft=false --prerelease --latest=false ;;
  esac
fi
echo "==> $TARGET: $(printf '%s\n' "$want" | wc -l | tr -d ' ') files of workroom $VERSION published"
