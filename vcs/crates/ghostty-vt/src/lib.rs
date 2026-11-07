//! libghostty-vt for workroomd's shadow terminal: the bindgen bindings (`sys`) and a safe
//! wrapper over them (`Terminal`). Every call into the library, and every `unsafe` that takes, is
//! here; what the shadow does with a terminal (what it keeps, what a repaint sends) is workroomd's
//! `terminal/vt.rs`, which holds none.
//!
//! Only with the `link` feature, which builds and links the library (`build.rs`). Without it the
//! crate is empty and needs no Zig. ADR 0010 says why it is off by default.
#![cfg(feature = "link")]

pub mod sys;
mod terminal;

pub use terminal::*;
