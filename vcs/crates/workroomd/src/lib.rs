//! The unified Workroom daemon.
//!
//! One binary serves local and remote workrooms alike: `workroomd serve` owns ptys and services,
//! `workroomd attach` is the relay libghostty forks. Local runs over a Unix socket, remote over
//! whatever bidirectional stream a driver opens — and because local is the same code path minus
//! the network, every local session is the remote path's test harness.
//!
//! See docs/designs/remote-workrooms.md. Where each service lives:
//!
//! - Terminal: `terminal` (`terminal::session` is the store; `daemon::serve` handles its frames)
//! - Control: `daemon::serve`, beside Terminal's frames; a hand-off is `daemon::handoff`
//! - VCS: `vcs::service`
//! - File: `vcs::file`, with `vcs::watch`
//! - Forward: `host::forward`
//! - Layout: `host::layout`
//! - ProgramStatus: `terminal::program_status`

pub mod cli;
pub mod daemon;
pub mod host;
pub mod terminal;
mod vcs;
