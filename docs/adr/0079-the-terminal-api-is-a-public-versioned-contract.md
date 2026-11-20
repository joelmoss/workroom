# The terminal API is a public, versioned contract: a JSON service on the daemon's stream that only ever adds fields, with `workroom` commands as thin clients

Decided 2026-11-19 (owner, terminal API design for #360); built from 2026-11-20 (#683). The points marked _(#683, to confirm)_ were chosen while building it and await the owner's confirmation. Extends [ADR 0013](0013-cli-json-contract.md) and [ADR 0078](0078-one-rust-binary-named-workroom.md). The socket stays the only security boundary ([ADR 0043](0043-agent-socket-trust-boundary-is-shell-grade.md)).

Coding agents and the user's scripts need to read, type into, wait on and watch a Workroom terminal from inside a pane, on the Mac and on hosts. Until now the only way into a session was the app's private binary protocol, which changes whenever the app needs it to. Callers outside the app can't keep up with that, and the app can't be held back by them. So the daemon gets a second, public way in, named the **terminal API**.

**How it works**
- **A service of its own.** It's `Service::TerminalApi` (byte `0x08`) on the daemon's multiplexed stream, added at protocol 12 (`MIN_TERMINAL_API_VERSION`). It isn't a new listener: the same socket, so the same trust.
  - A client checks the daemon's greeting before sending. An older daemon's envelope decoder fails the whole connection on a service byte it doesn't know.
  - The service never sends anything nobody asked for, so the app, which never calls it, sees no difference.
  - The app's handshake moves to protocol 12 with it. Negotiation still takes the lower version, so older apps and daemons are unaffected.
- **JSON request and reply, one stream per request.** A request is `{"method": "<namespace>.<name>", "params": {…}}`. The reply is `{"version": <revision>, "result": …}` or `{"version": <revision>, "error": {"kind", "message"}}`.
  - Methods are named in namespaces: `session.*`, `terminal.*`, `client.*` and `events.*`, and `api.*` for the API describing itself _(#683, to confirm)_.
  - Every method publishes the JSON Schema of its parameters and its result, and `api.describe` returns them, with the error's schema. So a caller can learn what a daemon supports without docs.
- **Fields are only ever added.** No field or method is removed, renamed or given another meaning. The API's **revision**, in every reply and in `api.describe`, counts the additions, and a caller that needs a later one checks it. It's the service's own number, separate from the protocol version, which only says whether the service exists.
- **The commands keep ADR 0013's contract.** `workroom sessions`, and each later command, prints one envelope on stdout with `schema_version` and passes the API's objects through as they are. Errors carry a `kind` from the registry every `workroom` command shares. The daemon replies with those codes by name, and the CLI exits with their numbers.
  - A missing or ambiguous target is 3.
  - Bad input is 2: `TooLarge`, and `InvalidRequest` for a request the daemon can't read, such as an unknown method _(#683, to confirm)_.
  - New exit codes: `DaemonUnreachable` is 7 and `WaitTimeout` is 8. `DaemonUnreachable` covers no daemon named, none listening, and one that predates the API _(the last, #683, to confirm)_.
  - Every other kind is 1, as #360 says: `AgentBusy`, `NotAnAgent`, `SessionEnded`, `AlternateScreen`, `NoShellIntegration` and `RefusedSelf` _(#683, to confirm: the CLI's other precondition errors are 3)_.
  - An ambiguous target's error lists its matches, in the envelope too.
- **Targets.** A session is named by its full id, then an id suffix of at least 4 characters, then its label, then its live title. At the first step with any match, more than one match is `TargetAmbiguous`, and nothing happens. The live title is what the program last set with OSC 0 or 2. The daemon reads it from the shadow terminal and carries it across a hand-off.
- **Finding the daemon.** For now a command reaches only the daemon `WORKROOM_DAEMON` names, the variable #684 gives every pane's shell. How a caller without it finds its daemon (the peer-pid fallback, and `new` starting one) is #684's and #693's to settle.

**Rejected**
- **Exposing the app's binary protocol.** It's private so it can change with the app. Freezing it for outside callers would freeze the app.
- **A second socket or a network listener.** A second socket adds a second thing to secure for no gain. A network listener needs authentication strong enough for shell access, which #360 leaves out of scope.
- **The session listing as `workroom list`.** That name is the workroom list (ADR 0013), and `list --socket` is the daemon's pinned listing (ADR 0057). The terminal API's is `workroom sessions`.
- **Versioning by protocol number alone.** Each addition would then bump the protocol, which also gates the app's services, for changes the app never uses.

Source: #360 (the terminal API spec), #683 (this service and `sessions`), [`vcs/crates/workroomd/src/terminal/api.rs`](../../vcs/crates/workroomd/src/terminal/api.rs), [`vcs/crates/workroomd/src/commands/terminal_api.rs`](../../vcs/crates/workroomd/src/commands/terminal_api.rs), [`vcs/crates/workroomd/src/commands/kind.rs`](../../vcs/crates/workroomd/src/commands/kind.rs).
