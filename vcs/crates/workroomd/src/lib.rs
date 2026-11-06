//! The unified Workroom daemon.
//!
//! One binary serves local and remote workrooms alike: `workroomd serve` owns ptys and services,
//! `workroomd attach` is the relay libghostty forks. Local runs over a Unix socket, remote over
//! whatever bidirectional stream a driver opens — and because local is the same code path minus
//! the network, every local session is the remote path's test harness.
//!
//! See docs/designs/remote-workrooms.md. Where each service lives:
//!
//! - Terminal: `terminal` (`terminal::session` is the store; `terminal::dispatch` handles its
//!   frames, whose payloads are `wr_protocol::terminal`'s)
//! - Control: `terminal::dispatch`, beside Terminal's frames; a hand-off is `daemon::handoff`
//!
//! `daemon::serve` accepts connections and hands each envelope to its service.
//! - VCS: `vcs::service`
//! - File: `vcs::file`, with `vcs::watch`
//! - Forward: `host::forward`
//! - Layout: `host::layout`
//! - ProgramStatus: `terminal::program_status`
//!
//! What services share sits below them, and no service reaches into another: `daemon::rpc` (the
//! request/reply plumbing and reply budget), `exec` (running a git child for the VCS and File
//! services; ending process trees is the `wr-exec` crate), `host::environment` (the host's login
//! environment, for scripts and remote git) and `util`.

pub mod cli;
pub(crate) mod daemon;
pub(crate) mod exec;
pub(crate) mod host;
pub(crate) mod terminal;
pub(crate) mod util;
pub(crate) mod vcs;

/// What the integration tests in `tests/` use, and nothing else: every other module is
/// crate-private, so rustc reports what nothing calls. Only with `test-support`, which
/// workroomd's dev-dependency on itself turns on for `cargo test`.
#[cfg(any(test, feature = "test-support"))]
#[doc(hidden)]
pub mod testing {
    pub use crate::daemon::serve::{BUILD, handle_connection};
    pub use crate::daemon::transport::{FdStream, PipeTransport, close, set_nonblocking};
    pub use crate::host::credential::{
        CredentialError, configure_git, credential, helper_command, install_relay,
    };
    pub use crate::host::forward::{MAX_LISTENERS, MAX_PENDING, PENDING_TIMEOUT};
    pub use crate::terminal::program_status::{Connection, dispatch};
    pub use crate::terminal::pty::{Pty, Size};
    pub use crate::terminal::screens::Screens;
    pub use crate::terminal::session::{READ_CHUNK, SessionId, SessionSpec, SessionStore};
}
