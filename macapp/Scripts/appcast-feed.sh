# shellcheck shell=sh
# Shared by appcast.sh and appcast-notes.sh — sourced, not executed.
#
# wr_render_markdown <repo>
#   Renders the GFM on stdin to HTML with GitHub's /markdown API, the same rendering the release
#   page shows, and prints it. The notes travel in the request body on stdin, never as an argument:
#   Linux caps one argument or environment string at 128 KiB, and an uncurated GoReleaser body runs
#   past that (v3.0.0's was 125 KB for 1,552 commits).
wr_render_markdown() {
  python3 -c 'import json, sys
json.dump({"mode": "gfm", "context": sys.argv[1], "text": sys.stdin.read()}, sys.stdout)' "$1" |
    gh api --method POST /markdown --input -
}
#
# wr_fetch_feed <repo> <release-tag> <asset> <dest>
#   Downloads a published feed from its PUBLIC download URL, the same URL SUFeedURL points every
#   installed app at. Returns 0 when fetched, 2 when that URL is a clean 404 (the feed does not
#   exist), and 1 for anything else (a timeout, a 5xx, a refused connection), with a message on
#   stderr.
#
# Why not `gh release download`: it resolves the asset through the API's asset LISTING, and after a
# `--clobber` re-upload that listing can keep naming the deleted asset for minutes. The download then
# 404s on a feed that exists. v2.1.0 hit exactly this — the notes refresh read the 404 as "no feed
# yet", exited 0, and the update dialog kept the raw commit list while every run reported success.
# The public URL resolves the asset that is actually there.
#
# WR_FEED_BASE_URL overrides https://github.com, for the test only.
wr_fetch_feed() {
  _url="${WR_FEED_BASE_URL:-https://github.com}/$1/releases/download/$2/$3"
  _code=$(curl -sSL --retry 2 --max-time 60 -o "$4.part" -w '%{http_code}' "$_url" 2>/dev/null)
  case "$_code" in
    200)
      mv "$4.part" "$4"
      return 0
      ;;
    404)
      rm -f "$4.part"
      return 2
      ;;
    *)
      rm -f "$4.part"
      echo "error: fetching $_url failed (HTTP ${_code:-none})." >&2
      return 1
      ;;
  esac
}
