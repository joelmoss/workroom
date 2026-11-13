//! The Terminal service and what shares its sessions' state: its frames (`dispatch`), the session
//! store, ptys and the shells and processes in them, input, the shadow screen, images, kept
//! screens, run sessions and program status.

pub(crate) mod dispatch;
pub(crate) mod host_session;
pub(crate) mod images;
pub(crate) mod input;
pub(crate) mod process;
pub(crate) mod program_status;
pub(crate) mod pty;
pub(crate) mod run;
pub(crate) mod screens;
pub(crate) mod session;
pub(crate) mod shadow;
pub(crate) mod shell;

/// The shadow terminal that makes a reattaching client see the session instead of a blank screen.
/// Behind a feature because it links libghostty-vt — see the crate's Cargo.toml.
#[cfg(feature = "terminal-state")]
pub(crate) mod vt;
