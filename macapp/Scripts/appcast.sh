#!/bin/bash
#
# Merge this release into the Sparkle appcast and publish it as an asset on the fixed `appcast`
# GitHub release — the stable SUFeedURL the app is built with. Run in CI after the DMG is
# uploaded; reads the fields Scripts/release.sh wrote to build/release/appcast-fields.env (which
# only exist when the DMG was EdDSA-signed, i.e. SPARKLE_PRIVATE_KEY is configured).
#
# Required env: TAG (e.g. v1.4.0), REPO (owner/repo), GH_TOKEN (for `gh`).
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${MACAPP_DIR}/build/release"
FIELDS="${BUILD}/appcast-fields.env"
FEED="${BUILD}/appcast.xml"
FEED_TAG="appcast"  # the fixed release that hosts appcast.xml (matches SUFeedURL)

# Shared channel classification (kept in lockstep with internal/channel + ReleaseChannel).
# shellcheck source=channel-helper.sh
. "${MACAPP_DIR}/Scripts/channel-helper.sh"

# release.sh always writes this file now, carrying an explicit SPARKLE_STATUS
# (unconfigured|missing-tool|signed) instead of the file's mere presence standing in for "signed" —
# a missing file here means release.sh itself never ran/wrote it, which is its own failure.
if [ ! -f "$FIELDS" ]; then
  echo "error: $FIELDS not found — Scripts/release.sh did not write it; cannot determine Sparkle signing status." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$FIELDS"  # SPARKLE_STATUS, SHORT_VERSION, BUILD_NUMBER, MIN_OS, ENCLOSURE_ATTRS
: "${SPARKLE_STATUS:?SPARKLE_STATUS required (missing from $FIELDS)}"
: "${TAG:?TAG required}"
: "${REPO:?REPO required}"

case "$SPARKLE_STATUS" in
unconfigured)
  # No SPARKLE_PRIVATE_KEY configured — intentional, documented state. Skip without failing the
  # release, so the DMG still ships and auto-update activates once the key is configured.
  echo "note: Sparkle signing unconfigured (set the SPARKLE_PRIVATE_KEY secret to enable the" \
    "appcast). Skipping appcast publish." >&2
  exit 0
  ;;
missing-tool)
  # sign_update was not found under SourcePackages — a packaging regression, not a config gap.
  # Fail loudly instead of silently shipping a DMG with no matching appcast item.
  echo "${GITHUB_ACTIONS:+::error::}Sparkle's sign_update tool was missing at release build time; the DMG was not EdDSA-signed. Refusing to publish an appcast with no signed enclosure." >&2
  exit 1
  ;;
signed) ;;
*)
  echo "error: unrecognized SPARKLE_STATUS '$SPARKLE_STATUS' in $FIELDS." >&2
  exit 1
  ;;
esac

# The feed's minimum system version must be what the app ACTUALLY requires, so release.sh reads it
# from the built bundle's LSMinimumSystemVersion rather than this script restating the deployment
# target. It used to be hardcoded here, and went stale the moment the minimum rose to 15.0
# (2a50af72): every item from beta.19 through the v2.0.0 GA advertised 14.0, offering macOS 14 users
# a 37 MB DMG their OS cannot run. Required — a silently absent value would re-advertise everything
# to every OS version.
: "${MIN_OS:?MIN_OS required (missing from $FIELDS — release.sh reads it from the built app)}"

# Classify the release into a Sparkle channel. Stable items ship untagged (Sparkle's default
# channel, offered to everyone); pre/nightly items carry <sparkle:channel> so only opted-in
# clients see them. A tag that classifies to nothing (e.g. "appcast") must never reach here.
if ! CHANNEL="$(wr_classify_channel "$TAG")"; then
  echo "error: tag '$TAG' is not a publishable channel release — refusing to append to the appcast." >&2
  exit 1
fi
echo "Publishing appcast item for $TAG on the '$CHANNEL' channel (build $BUILD_NUMBER)"

# Must match the asset name the release workflow uploads (workroom-macos-app_<version>.dmg,
# version without the tag's leading v).
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/workroom-macos-app_${TAG#v}.dmg"
NOTES_URL="https://github.com/${REPO}/releases/tag/${TAG}"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Embed the curated release notes, rendered to HTML, so Sparkle's update dialog shows the real notes
# inline instead of just a link. Best-effort: if the release body can't be fetched or rendered (e.g.
# notes not curated yet), NOTES_DESC stays empty and the item falls back to the <link> alone.
NOTES_DESC=""
if NOTES_MD="$(gh release view "$TAG" --repo "$REPO" --json body -q .body 2>/dev/null)" \
  && [ -n "$NOTES_MD" ]; then
  # GitHub renders the same GFM the release page shows.
  if NOTES_HTML="$(gh api --method POST /markdown -f mode=gfm -f context="$REPO" \
    -f text="$NOTES_MD" 2>/dev/null)" && [ -n "$NOTES_HTML" ]; then
    # A CDATA section can't contain the literal "]]>"; split any occurrence so it stays well-formed.
    NOTES_HTML="${NOTES_HTML//]]>/]]]]><![CDATA[>}"
    NOTES_DESC="<description><![CDATA[${NOTES_HTML}]]></description>"
  fi
fi

# Fetch the current feed, or start a skeleton if the appcast release/asset doesn't exist yet.
#
# A FAILED download must never read as "no feed yet". The skeleton below is uploaded with
# --clobber, so treating a timeout, a rate limit or a 502 as absence rewrites the live feed down to
# this run's single item — silently deleting every stable and prerelease entry, while the run still
# reports success and every installed app stops being offered updates.
#
# So the ONLY thing that authorizes the skeleton is gh reporting the release or its asset explicitly
# ABSENT. Every other failure is fatal: an outage takes out the probe as readily as the download, so
# "the probe also failed" must not fall through to initialize either.
if gh release download "$FEED_TAG" --repo "$REPO" --dir "$BUILD" -p appcast.xml --clobber 2>/dev/null; then
  echo "Fetched existing appcast.xml"
else
  if FEED_ASSETS=$(gh release view "$FEED_TAG" --repo "$REPO" --json assets -q '.assets[].name' 2>&1); then
    if printf '%s\n' "$FEED_ASSETS" | grep -qx 'appcast.xml'; then
      echo "error: $FEED_TAG lists an appcast.xml asset but it could not be downloaded." \
        "Refusing to overwrite the live feed with a fresh skeleton." >&2
      exit 1
    fi
  elif ! printf '%s\n' "$FEED_ASSETS" | grep -qiE 'release not found|not found|HTTP 404'; then
    echo "error: could not read the $FEED_TAG release, and it is not a clean 404." \
      "Refusing to overwrite the live feed with a fresh skeleton. gh said: $FEED_ASSETS" >&2
    exit 1
  fi
  echo "Initializing new appcast.xml"
  cat >"$FEED" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Workroom</title>
  </channel>
</rss>
XML
fi

# Stable items ship untagged (Sparkle's default channel); pre/nightly carry <sparkle:channel>.
CHANNEL_ELEM=""
if [ "$CHANNEL" != "stable" ]; then
  CHANNEL_ELEM="<sparkle:channel>${CHANNEL}</sparkle:channel>"
fi

ITEM=$(
  cat <<XML
    <item>
      <!-- wr:${CHANNEL}:${BUILD_NUMBER} -->
      <title>Workroom ${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      ${CHANNEL_ELEM}
      <link>${NOTES_URL}</link>
      ${NOTES_DESC}
      <enclosure url="${DMG_URL}" ${ENCLOSURE_ATTRS} type="application/octet-stream" />
    </item>
XML
)

# Insert as the newest item. Idempotency is keyed on the (channel, build) marker, NOT the build
# number alone — a same-commit prerelease and GA share a build number but are different items, so
# a build-only key would wrongly skip the second. Nightly is a single ROLLING item: any existing
# nightly item is removed first, so its enclosure URL/signature never goes stale (the DMG is
# clobbered in place each run).
ITEM="$ITEM" CHANNEL="$CHANNEL" BUILD_NUMBER="$BUILD_NUMBER" python3 - "$FEED" <<'PY'
import os, re, sys
path = sys.argv[1]
item = os.environ["ITEM"]
channel = os.environ["CHANNEL"]
build = os.environ["BUILD_NUMBER"]
marker = f"<!-- wr:{channel}:{build} -->"
xml = open(path, encoding="utf-8").read()

if channel == "nightly":
    # Drop the existing nightly item (matched by its channel tag) before inserting the new one.
    def drop_if_nightly(m):
        return "" if "<sparkle:channel>nightly</sparkle:channel>" in m.group(0) else m.group(0)
    xml = re.sub(r"[ \t]*<item>.*?</item>\n?", drop_if_nightly, xml, flags=re.S)
elif marker in xml:
    print(f"appcast already lists {channel} build {build}; leaving unchanged")
    sys.exit(0)

m = re.search(r"[ \t]*<item>", xml)          # newest-first: before the first existing item…
if m:
    xml = xml[: m.start()] + item + "\n" + xml[m.start():]
else:                                        # …or before </channel> when there are none yet
    xml = xml.replace("</channel>", item + "\n  </channel>", 1)
open(path, "w", encoding="utf-8").write(xml)
print(f"Inserted appcast item: {channel} build {build}")
PY

# Publish: ensure the feed release exists (not "Latest"), then re-upload the asset.
gh release view "$FEED_TAG" --repo "$REPO" >/dev/null 2>&1 ||
  gh release create "$FEED_TAG" --repo "$REPO" --title "Appcast" --prerelease \
    --notes "Sparkle update feed for the Workroom macOS app — not a download. Do not delete."
gh release upload "$FEED_TAG" "$FEED" --repo "$REPO" --clobber
echo "✅ Published appcast.xml to the '${FEED_TAG}' release"

# The Workroom Nightly app reads its OWN feed (Info.plist SUFeedURL → $(WORKROOM_APPCAST), set per
# configuration in project.yml). Sparkle offers every UNTAGGED item — the stable channel — to every
# client regardless of `allowedChannels`, so on the shared feed a Nightly install was offered the
# main Workroom DMG as soon as a stable build number outran the newest nightly item (v2.0.0 = 769
# vs nightly 767 on 2026-09-10) and then failed the code-signing check, because the two apps have
# different bundle ids by design: "The update is improperly signed and could not be validated."
#
# Always exactly one item, so this feed is rewritten whole rather than merged. The item keeps its
# <sparkle:channel>nightly</sparkle:channel> tag, so a main-app install pointed here by accident is
# still offered nothing.
#
# The nightly item is ALSO still written into the shared appcast.xml above: installs predating this
# change read that feed and need an item there to reach a build that knows the new URL. Drop the
# dual write once no such installs remain.
if [ "$CHANNEL" = "nightly" ]; then
  NIGHTLY_FEED="${BUILD}/appcast-nightly.xml"
  # printf, not a heredoc: $ITEM carries the release notes as HTML, which an unquoted heredoc
  # would try to expand.
  printf '%s\n' \
    '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
    '  <channel>' \
    '    <title>Workroom Nightly</title>' \
    "$ITEM" \
    '  </channel>' \
    '</rss>' >"$NIGHTLY_FEED"
  gh release upload "$FEED_TAG" "$NIGHTLY_FEED" --repo "$REPO" --clobber
  echo "✅ Published appcast-nightly.xml to the '${FEED_TAG}' release"
fi
