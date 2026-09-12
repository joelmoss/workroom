//! The wire: a versioned multiplex envelope carrying per-service frames.
//!
//! Both codecs are deliberately dependency-free and synchronous. They own no I/O, no runtime and
//! no buffering policy beyond "keep what you cannot yet parse", so the same code serves a Unix
//! socket locally, an ssh pipe remotely, and a provider's exec channel — which is what the driver
//! contract means by "a bidirectional stream" (see docs/designs/remote-workrooms.md, Phase 3).

pub mod envelope;
pub mod frame;
