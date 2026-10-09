#!/bin/sh
#
# Pins one invariant: the agent still accepts the latest stable release's app. Release and Nightly
# share boxd and exe.dev hosts, and a host keeps the newest agent any build pushed (#255, D13), so
# a Release app often talks to an agent a Nightly installed. The agent's only refusal of an app is
# `negotiate` (vcs/crates/wr-agent/src/protocol/envelope.rs): min(app, agent) below
# `MIN_SUPPORTED_VERSION`. So that constant must never rise above the `protocolVersion` the latest
# stable app sends (`AgentControlClient.protocolVersion`, read at that release's tag). Per-service
# minimums are the app's to check against the agent's version, and a newer agent always passes
# them, so they are not pinned here. Run: sh macapp/Scripts/agent-protocol_test.sh
#
# Needs the repository's tags: CI checks out full history for it. No stable tag, or no constant at
# that tag, fails rather than passes: a check that cannot run must not read as one that passed.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
# Overridable so the test can be pointed at modified copies, to confirm it goes red.
ENVELOPE="${AGENT_PROTOCOL_ENVELOPE:-$ROOT/vcs/crates/wr-agent/src/protocol/envelope.rs}"
CLIENT_PATH="macapp/WorkroomApp/Core/Session/AgentControlClient.swift"

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
latest="${AGENT_PROTOCOL_RELEASE_TAG:-}"
if [ -z "$latest" ]; then
  [ -n "$stable" ] || fail "no stable release tag found (a shallow clone has none; fetch tags)"
  latest="v$(printf '%s\n' "$stable" | sed '/^$/d' | sort -V | tail -n 1)"
fi

released="$(git -C "$ROOT" show "$latest:$CLIENT_PATH" 2>/dev/null |
  sed -n 's/.*static let protocolVersion: UInt16 = \([0-9][0-9]*\).*/\1/p')"
[ -n "$released" ] || fail "no protocolVersion in $CLIENT_PATH at $latest"

minimum="$(sed -n 's/^pub const MIN_SUPPORTED_VERSION: u16 = \([0-9][0-9]*\);.*/\1/p' "$ENVELOPE")"
[ -n "$minimum" ] || fail "no MIN_SUPPORTED_VERSION in $ENVELOPE"

if [ "$minimum" -gt "$released" ]; then
  fail "the agent's MIN_SUPPORTED_VERSION is $minimum, but the latest stable app ($latest) speaks" \
    "protocol $released: it could no longer use a host a newer build's agent runs on"
fi
echo "agent-protocol_test: OK (agent minimum $minimum <= $latest's protocol $released)"
