//! The unified Workroom agent.
//!
//! One binary serves local and remote workrooms alike: `wr-agent serve` owns ptys and services,
//! `wr-agent attach` is the relay libghostty forks. Local runs over a Unix socket, remote over
//! whatever bidirectional stream a driver opens — and because local is the same code path minus
//! the network, every local session is the remote path's test harness.
//!
//! See docs/designs/remote-workrooms.md. Phase 1 is the protocol and the terminal service; VCS,
//! file and status services arrive in Phase 2 over the same envelope.

pub mod process;
pub mod protocol;
