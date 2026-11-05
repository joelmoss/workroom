//! What a remote host's daemon does beyond terminals: port forwarding, the layout store, the git
//! credentials a container workroom borrows from the Mac, becoming a container's remote user, and
//! the host's login environment that its scripts and git children get.

pub(crate) mod account;
pub(crate) mod credential;
pub(crate) mod environment;
pub(crate) mod forward;
pub(crate) mod layout;
