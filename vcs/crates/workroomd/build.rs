//! Stamps the daemon's build number and its daemon build identity. libghostty-vt, for
//! `terminal-state`, is built and linked by the ghostty-vt crate's own build.rs.

#[path = "build/daemon_build.rs"]
mod daemon_build;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    build_number();
    daemon_build();
}

/// The daemon build identity, `WORKROOMD_DAEMON_BUILD` (#680): a hash of every source but the CLI's
/// `commands` module, so a daemon is handed off only for a change that is the daemon's. See
/// `build/daemon_build.rs` for what it reads. Fails the build when it cannot read them: a binary
/// with no identity, or a wrong one, would hand off every host's daemon on every update, or none.
fn daemon_build() {
    let workspace = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    // Only what changes the daemon's behaviour: `test-support` adds an API the tests call and
    // nothing the daemon runs.
    let features: &[&str] = if std::env::var_os("CARGO_FEATURE_TERMINAL_STATE").is_some() {
        &["terminal-state"]
    } else {
        &[]
    };
    let build = daemon_build::daemon_build(&workspace, features)
        .unwrap_or_else(|e| panic!("cannot hash the daemon's sources: {e}"));
    for root in &build.roots {
        println!("cargo:rerun-if-changed={}", root.display());
    }
    println!("cargo:rustc-env=WORKROOMD_DAEMON_BUILD={}", build.hash);
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
