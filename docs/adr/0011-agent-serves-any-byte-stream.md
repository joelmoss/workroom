# The agent is served over any bidirectional byte stream, and local use is the remote path's test harness

`wr-agent` takes a reader and a writer, not a socket. A Unix socket locally, and whatever bidirectional stream a driver opens remotely (ssh to `wr-agent relay --socket <path>`, a provider SDK's exec call, a WebSocket), satisfy the same contract. `serve --stdio` exists to test it over pipes without a remote; production reaches a supervised `serve --idle-timeout never` through `relay`. Without a stream-shaped contract, platforms that offer only an SDK could never be host drivers. A single instance is enforced by `flock`, and a local agent exits when idle, so the one thing that must outlive the app, a live terminal, is all that keeps it running.

Source: [`vcs/crates/wr-agent/src/transport.rs`](../../vcs/crates/wr-agent/src/transport.rs) and [`serve.rs`](../../vcs/crates/wr-agent/src/serve.rs) (module comments).
