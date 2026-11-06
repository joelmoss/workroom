//! Stamps the daemon's build number. libghostty-vt, for `terminal-state`, is built and linked by
//! the ghostty-vt crate's own build.rs.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    build_number();
}

/// The daemon's build number, `WORKROOMD_BUILD`: the commit time of the checkout it is built from, in
/// seconds since the epoch, so a later commit is a larger number (#255, D13). The app pushes its
/// daemon to a host only when the host's is lower, and a daemon hands off only to one at least as
/// high, so two Macs on different builds never swap daemons. `WORKROOMD_BUILD` in the environment
/// wins; 0 when neither is available, which orders below every real build.
fn build_number() {
    use std::process::Command;
    println!("cargo:rerun-if-env-changed=WORKROOMD_BUILD");
    let git = |args: &[&str]| {
        Command::new("git")
            .arg("-C")
            .arg(env!("CARGO_MANIFEST_DIR"))
            .args(args)
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
    };
    let number = std::env::var("WORKROOMD_BUILD")
        .ok()
        .filter(|value| value.parse::<u64>().is_ok())
        .or_else(|| {
            // Rebuilt when the checkout moves: HEAD for a branch switch, its log for a commit.
            // Only when git is the source: with the number given, every checkout stamping these
            // files anew (CI's does) reran this script, and so rebuilt the crate, for nothing.
            if let Some(dir) = git(&["rev-parse", "--absolute-git-dir"]) {
                println!("cargo:rerun-if-changed={dir}/HEAD");
                println!("cargo:rerun-if-changed={dir}/logs/HEAD");
            }
            git(&["log", "-1", "--format=%ct"]).filter(|v| v.parse::<u64>().is_ok())
        })
        .unwrap_or_else(|| "0".to_string());
    println!("cargo:rustc-env=WORKROOMD_BUILD={number}");
}
