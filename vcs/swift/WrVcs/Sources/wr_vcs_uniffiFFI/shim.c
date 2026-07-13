// Intentionally empty. This C target exists only to vend the `wr_vcs_uniffiFFI` Clang module
// (include/module.modulemap + the generated FFI header) to the Swift binding target. The actual
// symbols come from the WrVcsLib binaryTarget (the Rust static library). SPM requires at least one
// compilable source per C target, so this empty translation unit is that source.
