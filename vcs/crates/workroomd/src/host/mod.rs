//! What a remote host's daemon does beyond terminals: port forwarding, the layout store, the git
//! credentials a container workroom borrows from the Mac, and becoming a container's remote user.

pub mod account;
pub mod credential;
pub mod forward;
pub(crate) mod layout;
