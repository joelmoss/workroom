# The Linux agent is a static musl binary: no OpenSSL, no async runtime

The app pushes a `workroomd` to remote hosts, so every build ships a static musl binary for both Linux arches whatever `ARCHS` says (a remote box's arch has nothing to do with the Mac's). To stay static the agent needs no C library beyond ring (SHA-256 for the layout store's file names) for its Rust dependencies (libghostty-vt is linked in separately), and has no async runtime. It makes no HTTPS requests of its own since the credential broker went (ADR 0049), so it carries no TLS stack and no CA roots; were one needed, it would be rustls on ring, never native-tls, with bundled roots, because a minimal provider image may have no OpenSSL or CA roots.

Source: [`vcs/crates/workroomd/Cargo.toml`](../../vcs/crates/workroomd/Cargo.toml) (dependency comments), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("Linux agents").
