#!/bin/sh
#
# Pins one invariant: the daemon still accepts the latest stable release's app. Release and Nightly
# share boxd and exe.dev hosts, and a host keeps the newest daemon any build pushed (#255, D13), so
# a Release app often talks to a daemon a Nightly installed. The daemon's only refusal of an app is
# `negotiate` (vcs/crates/wr-protocol/src/envelope.rs): min(app, daemon) below
# `MIN_SUPPORTED_VERSION`. So that constant must never rise above the `protocolVersion` the latest
# stable app sends (`DaemonHandshake.protocolVersion`, `DaemonControlClient.protocolVersion` before
# phase 5b moved it, read at that release's tag). Per-service
# minimums are the app's to check against the daemon's version, and a newer daemon always passes
# them, so they are not pinned here. Run: sh macapp/Scripts/daemon-protocol_test.sh
#
# Needs the repository's tags: CI checks out full history for it. No stable tag, or no constant at
# that tag, fails rather than passes: a check that cannot run must not read as one that passed.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
# Overridable so the test can be pointed at modified copies, to confirm it goes red.
ENVELOPE="${DAEMON_PROTOCOL_ENVELOPE:-$ROOT/vcs/crates/wr-protocol/src/envelope.rs}"
# Where the constant lives at a tag, newest layout first: the DaemonConnection package; before the
# wr-agent rename (#525), the AgentConnection package; before phase 5b moved it into a package,
# AgentControlClient.swift. A release tag holds it at exactly one of these.
CLIENT_PATHS="macapp/Packages/DaemonConnection/Sources/DaemonConnection/DaemonHandshake.swift
macapp/Packages/AgentConnection/Sources/AgentConnection/AgentHandshake.swift
macapp/WorkroomApp/Core/Session/AgentControlClient.swift"

# shellcheck source=channel-helper.sh
. "$DIR/channel-helper.sh"

fail() {
  echo "FAIL: $*"
  exit 1
}

stable=""
for tag in $(git -C "$ROOT" tag --list 'v*'); do
  channel="$(wr_classify_channel "$tag")" || continue
  [ "$channel" = stable ] && stable="$stable
${tag#v}"
done
latest="${DAEMON_PROTOCOL_RELEASE_TAG:-}"
if [ -z "$latest" ]; then
  [ -n "$stable" ] || fail "no stable release tag found (a shallow clone has none; fetch tags)"
  latest="v$(printf '%s\n' "$stable" | sed '/^$/d' | sort -V | tail -n 1)"
fi

released_from() {
  git -C "$ROOT" show "$latest:$1" 2>/dev/null |
    sed -n 's/.*static let protocolVersion: UInt16 = \([0-9][0-9]*\).*/\1/p'
}
released=""
for path in $CLIENT_PATHS; do
  [ -n "$released" ] || released="$(released_from "$path")"
done
[ -n "$released" ] || fail "no protocolVersion at $latest in any of:
$CLIENT_PATHS"

minimum="$(sed -n 's/^pub const MIN_SUPPORTED_VERSION: u16 = \([0-9][0-9]*\);.*/\1/p' "$ENVELOPE")"
[ -n "$minimum" ] || fail "no MIN_SUPPORTED_VERSION in $ENVELOPE"

if [ "$minimum" -gt "$released" ]; then
  fail "the daemon's MIN_SUPPORTED_VERSION is $minimum, but the latest stable app ($latest) speaks" \
    "protocol $released: it could no longer use a host a newer build's daemon runs on"
fi
echo "daemon-protocol_test: OK (daemon minimum $minimum <= $latest's protocol $released)"
