# The Linux agent is a static musl binary: rustls on ring, no OpenSSL, no async runtime

The app pushes a `wr-agent` to remote hosts, so every build ships a static musl binary for both Linux arches whatever `ARCHS` says (a remote box's arch has nothing to do with the Mac's). To stay static the agent uses rustls on ring, never native-tls, needs no C library beyond ring for its Rust dependencies (libghostty-vt is linked in separately), and has no async runtime. A minimal provider image may have no OpenSSL or CA roots, so root certificates are bundled. `ureq` is held to a minor version because `broker.rs` rebuilds its connector chain from `ureq::unversioned`.

Source: [`vcs/crates/wr-agent/Cargo.toml`](../../vcs/crates/wr-agent/Cargo.toml) (dependency comments), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("Linux agents").
