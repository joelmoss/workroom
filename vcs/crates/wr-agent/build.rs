//! Builds and links `libghostty-vt` when the `terminal-state` feature is on.
//!
//! The library is produced by `vcs/scripts/build-ghostty-vt.sh`, which pins the Ghostty revision
//! to the one the app's GhosttyKit is built from and caches per (sha, target). Doing it from
//! build.rs rather than asking the developer to run the script first means `cargo test
//! --features terminal-state` simply works, and the cache makes the second build free.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=WR_GHOSTTY_VT_PREFIX");

    #[cfg(feature = "terminal-state")]
    link_ghostty_vt();
}

#[cfg(feature = "terminal-state")]
fn link_ghostty_vt() {
    use std::path::PathBuf;
    use std::process::Command;

    // An explicit prefix wins, so a packaging step can build the library once and point every
    // target at it rather than having each cargo invocation reach for the network.
    let prefix = match std::env::var_os("WR_GHOSTTY_VT_PREFIX") {
        Some(path) => PathBuf::from(path),
        None => {
            let script =
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/build-ghostty-vt.sh");
            // Map the cargo target to a zig triple. Unknown combinations are a hard error: a
            // silent fallback to the host would link the wrong architecture and fail at the far
            // end of the build with something unreadable.
            let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
            let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
            let env_abi = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
            let zig_target = match (arch.as_str(), os.as_str(), env_abi.as_str()) {
                ("aarch64", "macos", _) => "aarch64-macos",
                ("x86_64", "macos", _) => "x86_64-macos",
                ("x86_64", "linux", "musl") => "x86_64-linux-musl",
                ("aarch64", "linux", "musl") => "aarch64-linux-musl",
                ("x86_64", "linux", _) => "x86_64-linux-gnu",
                ("aarch64", "linux", _) => "aarch64-linux-gnu",
                _ => panic!("libghostty-vt: unsupported target {arch}-{os}-{env_abi}"),
            };
            let output = Command::new("sh")
                .arg(&script)
                .args(["--target", zig_target])
                .output()
                .unwrap_or_else(|e| panic!("running {}: {e}", script.display()));
            if !output.status.success() {
                panic!(
                    "build-ghostty-vt.sh failed:\n{}",
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            PathBuf::from(String::from_utf8_lossy(&output.stdout).trim().to_string())
        }
    };

    let lib = prefix.join("lib/libghostty-vt.a");
    assert!(lib.exists(), "no libghostty-vt.a at {}", lib.display());
    // Linked by absolute path rather than `-l static=`: on macOS the linker prefers a .dylib
    // sitting beside the archive in the same prefix, producing a binary with an @rpath dependency
    // the agent must not have — it ships as a single file.
    println!("cargo:rustc-link-arg={}", lib.display());

    let header = prefix.join("include/ghostty/vt.h");
    println!("cargo:rerun-if-changed={}", header.display());
    let bindings = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .clang_arg(format!("-I{}", prefix.join("include").display()))
        .allowlist_item("[Gg]hostty.*")
        .generate()
        .expect("bindgen libghostty-vt");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("ghostty_vt.rs");
    bindings.write_to_file(&out).expect("write bindings");
}
