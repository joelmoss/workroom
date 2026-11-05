//! The daemon itself: the accept loop and connections, the request envelope every service shares,
//! transports, hand-off and the log.

pub(crate) mod handoff;
pub(crate) mod log;
pub(crate) mod rpc;
pub(crate) mod serve;
pub(crate) mod transport;
