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
/// `commands` module, and of the compiler, so a daemon is handed off only for a change that is the
/// daemon's. See `build/daemon_build.rs` for what it reads. Fails the build when it cannot read
/// them, or run the compiler: a binary with no identity, or a wrong one, would hand off every
/// host's daemon on every update, or none. `WORKROOMD_COMPILER` is the compiler as it was hashed,
/// for `tests/daemon_build.rs` to hash the tree as this did.
fn daemon_build() {
    let workspace = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    // Only what changes the daemon's behaviour: `test-support` adds an API the tests call and
    // nothing the daemon runs.
    let features: &[&str] = if std::env::var_os("CARGO_FEATURE_TERMINAL_STATE").is_some() {
        &["terminal-state"]
    } else {
        &[]
    };
    // Cargo names the compiler it builds with in `RUSTC`.
    println!("cargo:rerun-if-env-changed=RUSTC");
    let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into());
    let report = std::process::Command::new(&rustc)
        .arg("-vV")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .unwrap_or_else(|| panic!("cannot run {} -vV", rustc.to_string_lossy()));
    let compiler = daemon_build::compiler(&String::from_utf8_lossy(&report.stdout));
    let build = daemon_build::daemon_build(&workspace, features, &compiler)
        .unwrap_or_else(|e| panic!("cannot hash the daemon's sources: {e}"));
    for root in &build.roots {
        println!("cargo:rerun-if-changed={}", root.display());
    }
    println!("cargo:rustc-env=WORKROOMD_DAEMON_BUILD={}", build.hash);
    println!("cargo:rustc-env=WORKROOMD_COMPILER={compiler}");
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
