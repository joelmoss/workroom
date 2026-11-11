#!/bin/sh
#
# Dependency-free test for wr_fetch_feed (appcast-feed.sh), against a throwaway local HTTP server.
# Run: sh macapp/Scripts/appcast-feed_test.sh   (exits non-zero on any mismatch).
#
# Guards the three outcomes the appcast scripts branch on. The one that matters most is that a
# failure which is NOT a clean 404 never reads as "absent": appcast.sh would answer absence by
# publishing a fresh one-item feed over the live one.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
. "${DIR}/appcast-feed.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/appcast-feed-test.XXXXXX")"
mkdir -p "$ROOT/o/r/releases/download/appcast"
printf '<rss>live</rss>\n' >"$ROOT/o/r/releases/download/appcast/appcast.xml"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$ROOT"' EXIT
i=0
until curl -s -o /dev/null "http://127.0.0.1:$PORT/"; do
  i=$((i + 1))
  [ "$i" -gt 50 ] && { echo "FAIL: test server never started"; exit 1; }
  sleep 0.1
done

fails=0
expect() {
  label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $label — want $want, got $got"
    fails=$((fails + 1))
  fi
}

WR_FEED_BASE_URL="http://127.0.0.1:$PORT"
DEST="$ROOT/out.xml"

wr_fetch_feed o/r appcast appcast.xml "$DEST"
expect "an existing feed is fetched" 0 $?
expect "the fetched feed is the published one" "<rss>live</rss>" "$(cat "$DEST" 2>/dev/null)"

rm -f "$DEST"
wr_fetch_feed o/r appcast missing.xml "$DEST"
expect "a missing feed is a clean 404" 2 $?
expect "a 404 leaves nothing behind" "no" "$([ -e "$DEST" ] && echo yes || echo no)"

kill "$SERVER" 2>/dev/null
wait "$SERVER" 2>/dev/null
wr_fetch_feed o/r appcast appcast.xml "$DEST" 2>/dev/null
expect "an unreachable server is a failure, never absence" 1 $?

# wr_render_markdown sends the notes on stdin, so a body past Linux's 128 KiB argument cap still
# renders. A stub `gh` records its arguments and echoes the request body back.
mkdir -p "$ROOT/bin"
cat >"$ROOT/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$@" >"$(dirname "$0")/args"
cat
GH
chmod +x "$ROOT/bin/gh"
big=$(head -c 300000 /dev/zero | tr '\0' x)
req=$(printf '%s' "$big" | PATH="$ROOT/bin:$PATH" wr_render_markdown o/r)
expect "rendering posts to /markdown with the body on stdin" "api --method POST /markdown --input -" \
  "$(tr '\n' ' ' <"$ROOT/bin/args" | sed 's/ $//')"
expect "the whole body reaches the request" "gfm o/r 300000" \
  "$(printf '%s' "$req" | python3 -c 'import json, sys
r = json.load(sys.stdin); print(r["mode"], r["context"], len(r["text"]))')"

[ "$fails" -eq 0 ] && echo "appcast-feed: all cases pass"
exit "$fails"
