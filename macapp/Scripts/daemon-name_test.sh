#!/bin/sh
#
# The daemon is workroomd (#525). Fails on the old name, wr-agent (or wr_agent, WR_AGENT,
# WR-AGENT), anywhere in the tracked tree except:
#
# - history that keeps the names of its time: docs/designs/, docs/recently-done.md and the OQ19
#   measurement spike (vcs/scripts/oq19/);
# - the code that still has to know the old name, until #526 retires it: finding a v2.1.0 daemon
#   on agent.sock, refusing a host an older Nightly made (its `wr-agent`), the protocol test that
#   reads older release tags, and the tests and fixture of those;
# - a quoted issue title (`- #470: "wr-agent: …"`), which says what the issue says;
# - this file.
#
# Run: sh macapp/Scripts/daemon-name_test.sh. A planted `wr-agent` anywhere else turns it red.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

hits="$(git -C "$ROOT" grep --no-color -n -I -E 'wr-agent|wr_agent|WR_AGENT|WR-AGENT' -- . \
  ':!docs/designs' \
  ':!docs/recently-done.md' \
  ':!vcs/scripts/oq19' \
  ':!macapp/Scripts/daemon-name_test.sh' \
  ':!macapp/Scripts/daemon-protocol_test.sh' \
  ':!macapp/Packages/HostDrivers/Sources/HostDrivers/DaemonInstall.swift' \
  ':!macapp/Packages/HostDrivers/Sources/HostDrivers/SSHTransport.swift' \
  ':!macapp/Resources/daemon-bootstrap/probe.sh' \
  ':!macapp/WorkroomApp/Core/Session/DaemonBootstrap.swift' \
  ':!macapp/WorkroomApp/Core/Session/PersistentSessionPaths.swift' \
  ':!macapp/WorkroomApp/Core/Session/SessionBackend.swift' \
  ':!macapp/WorkroomAppTests/HostStreamTests.swift' \
  ':!macapp/WorkroomAppTests/Session/DaemonBootstrapScriptTests.swift' \
  ':!macapp/WorkroomAppTests/Session/DaemonBootstrapTests.swift' \
  ':!macapp/WorkroomAppTests/Session/DaemonUpdateCompatibilityTests.swift' \
  ':!macapp/WorkroomAppTests/Fixtures/wr-agent-v2.1.0' |
  grep -v -E '^[^:]+:[0-9]+:- #[0-9]+: "')"

if [ -n "$hits" ]; then
  echo "FAIL: the daemon is workroomd now (#525); the old name is still here:"
  printf '%s\n' "$hits"
  exit 1
fi
echo "daemon-name_test: OK"
