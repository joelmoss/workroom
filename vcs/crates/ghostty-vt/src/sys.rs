//! The bindgen output for `ghostty/vt.h`, as `build.rs` generates it. The types and constants are
//! safe to name; the functions are the C API, and [`crate::Terminal`] is the safe way to call them.
#![allow(
    non_upper_case_globals,
    non_camel_case_types,
    non_snake_case,
    dead_code
)]
include!(concat!(env!("OUT_DIR"), "/ghostty_vt.rs"));
