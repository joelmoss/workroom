//! The unified Workroom agent.
//!
//! One binary serves local and remote workrooms alike: `wr-agent serve` owns ptys and services,
//! `wr-agent attach` is the relay libghostty forks. Local runs over a Unix socket, remote over
//! whatever bidirectional stream a driver opens — and because local is the same code path minus
//! the network, every local session is the remote path's test harness.
//!
//! See docs/designs/remote-workrooms.md. Phase 1 is the protocol and the terminal service; the VCS,
//! file, status and port-forwarding services are Phase 2 over the same envelope.

pub mod file;
pub mod forward;
pub mod handoff;
pub mod input;
pub mod process;
pub mod protocol;
pub mod pty;
pub mod screens;
pub mod serve;
pub mod session;
pub mod shadow;
pub mod shell;
pub mod transport;
pub mod vcs;
pub mod wakefulness;
pub mod watch;

/// The shadow terminal that makes a reattaching client see the session instead of a blank screen.
/// Behind a feature because it links libghostty-vt — see the crate's Cargo.toml.
#[cfg(feature = "terminal-state")]
pub mod terminal;
