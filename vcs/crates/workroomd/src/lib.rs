//! The unified Workroom daemon.
//!
//! One binary serves local and remote workrooms alike: `workroomd serve` owns ptys and services,
//! `workroomd attach` is the relay libghostty forks. Local runs over a Unix socket, remote over
//! whatever bidirectional stream a driver opens — and because local is the same code path minus
//! the network, every local session is the remote path's test harness.
//!
//! See docs/designs/remote-workrooms.md. Phase 1 is the protocol and the terminal service; the VCS,
//! file, status and port-forwarding services are Phase 2 over the same envelope.

pub mod cli;
pub mod credential;
mod file;
pub mod forward;
mod handoff;
mod input;
mod layout;
mod log;
mod process;
pub mod program_status;
pub mod pty;
mod rpc;
pub mod screens;
pub mod serve;
pub mod session;
mod shadow;
mod shell;
pub mod transport;
mod vcs;
mod watch;

/// The shadow terminal that makes a reattaching client see the session instead of a blank screen.
/// Behind a feature because it links libghostty-vt — see the crate's Cargo.toml.
#[cfg(feature = "terminal-state")]
mod terminal;
