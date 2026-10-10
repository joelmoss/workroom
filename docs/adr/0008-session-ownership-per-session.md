# Which helper owns a terminal session is resolved per session, never per app, and there is no daemon fallback

Every new session goes to `wr-agent`. An existing session resolves to whichever helper owns it, once, and the answer is cached, because a pane asks twice (for the binary and for the socket) and the two must agree. An unanswered ownership probe resolves to neither and the pane opens a plain shell, and if the agent fails its own probe `preferred()` returns nil instead of falling back to the retired daemon. Both helpers create a session on attach for an id they do not hold, so every guess forks a second pty and orphans the user's shell: there is no safe direction to guess. An app-wide switch would strand the terminals running when it flipped.

Source: [`macapp/WorkroomApp/Core/Session/SessionBackend.swift`](../../macapp/WorkroomApp/Core/Session/SessionBackend.swift) (header comment), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("The migration is a drain, not a switch").
