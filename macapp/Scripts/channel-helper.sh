# shellcheck shell=sh
#
# Shared release-channel classification for Workroom's shell tooling (appcast.sh and the
# curl installers). Mirrors the Go `internal/channel` package and the Swift `ReleaseChannel`
# enum — the three MUST agree on what a tag's channel is. If you change a rule here, change
# all three.
#
# wr_classify_channel <tag>
#   Prints the channel name (stable | pre | nightly) and returns 0, or prints nothing and
#   returns 1 for a tag that belongs to no channel (the "appcast" feed release, or a tag that
#   is not a recognizable version).
#
#   Rules (identical to internal/channel.Classify):
#     appcast        -> excluded (return 1)
#     nightly        -> nightly   (the fixed rolling release)
#     vX.Y.Z         -> stable    (no prerelease component)
#     vX.Y.Z-<pre>   -> pre       (any semver prerelease suffix: -beta.N, -rc, -alpha, …)
#     anything else  -> excluded (return 1)

wr_classify_channel() {
  _wr_tag="$1"
  case "$_wr_tag" in
    appcast) return 1 ;;
    nightly)
      echo nightly
      return 0
      ;;
  esac

  # Strip a leading "v" and any "+build" metadata (never affects the channel).
  _wr_v="${_wr_tag#v}"
  _wr_v="${_wr_v%%+*}"
  _wr_core="${_wr_v%%-*}"

  # Core must be exactly three dot-separated numeric fields (MAJOR.MINOR.PATCH).
  case "$_wr_core" in
    *[!0-9.]*) return 1 ;; # a non-digit, non-dot character
  esac
  # Wrapping in dots turns a leading/trailing/doubled empty field into a literal "..".
  case ".$_wr_core." in
    *..*) return 1 ;; # empty field, e.g. "1..3", "1.2.", ".2.3", ""
  esac
  if [ "$(printf '%s' "$_wr_core" | tr -cd '.' | wc -c | tr -d ' ')" != "2" ]; then
    return 1 # wrong number of fields
  fi

  if [ "$_wr_v" != "$_wr_core" ]; then
    # Had a "-": the part after the FIRST one is the prerelease segment. A dangling
    # hyphen with nothing after it (e.g. "v1.2.3-") is not a valid prerelease tag.
    _wr_pre="${_wr_v#*-}"
    if [ -z "$_wr_pre" ]; then
      return 1
    fi
    echo pre
  else
    echo stable
  fi
  return 0
}
