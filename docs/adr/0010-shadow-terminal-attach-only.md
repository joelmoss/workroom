# The shadow terminal is read only on attach, and raw pty bytes stay the live path

`wr-agent` feeds every pty byte to a libghostty-vt emulator but reads it only to answer what a client that just arrived should be shown. Connected clients get the bytes untouched, with full Ghostty fidelity (kitty keyboard, OSC 52, synchronized output, mouse). Rendering from state would put parse, state and re-synthesis between the child and the client for every session, local ones included, and degrade local behaviour to a remote limitation. The `terminal-state` cargo feature is off by default because it pulls in Zig, a Ghostty checkout and libclang, but it is mandatory in every app build: without it a reattaching pane repaints blank.

Source: [`vcs/crates/wr-agent/src/terminal.rs`](../../vcs/crates/wr-agent/src/terminal.rs) (module comment), [`macapp/Scripts/build-agent.sh`](../../macapp/Scripts/build-agent.sh) (`AGENT_FEATURES`).
