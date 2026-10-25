//! The command line an older daemon runs on this binary during a hand-off. An older build (one the
//! app shipped, and every remote host's older install) runs `protocol` to order builds, then
//! `handoff-check <table>`, then execs this binary with its own argv plus `--handoff <table>`. None
//! of that can be rebuilt to match a change here, so these names and the `build-number` line are a
//! frozen contract: the binary and its help text may be renamed, this may not.

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// As `common::daemon_binary`, which this file doesn't pull in for one function.
fn daemon_binary() -> PathBuf {
    match std::env::var_os("WORKROOMD_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_workroomd")),
    }
}

/// A directory of the test's own, removed when it ends.
struct Workspace {
    dir: PathBuf,
}

impl Workspace {
    fn new(name: &str) -> Workspace {
        let dir = std::env::temp_dir().join(format!("workroomd-it-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        Workspace { dir }
    }

    fn socket(&self) -> PathBuf {
        self.dir.join("workroomd.sock")
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A start-command failure must not leave its daemon behind when an assertion unwinds.
struct Started(Child);

impl Drop for Started {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn protocol_states_the_build_number_an_older_daemon_orders_by() {
    let output = Command::new(daemon_binary())
        .arg("protocol")
        .output()
        .expect("run protocol");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.lines().any(|line| line.starts_with("protocol ")),
        "no `protocol <n>` line in {stdout:?}"
    );
    let number = stdout
        .lines()
        .find_map(|line| line.strip_prefix("build-number "))
        .unwrap_or_else(|| panic!("no `build-number <n>` line in {stdout:?}"));
    assert!(
        number.trim().parse::<u64>().is_ok(),
        "build-number {number:?} is not a number"
    );
}

#[test]
fn handoff_check_is_a_subcommand() {
    let workspace = Workspace::new("contract-check");
    let output = Command::new(daemon_binary())
        .arg("handoff-check")
        .arg(workspace.dir.join("missing.handoff"))
        .output()
        .expect("run handoff-check");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "a missing table cannot check");
    assert!(
        !stderr.contains("usage:"),
        "handoff-check fell through to the usage text: {stderr}"
    );
}

#[test]
fn serve_takes_the_argv_a_hand_off_execs_it_with() {
    let workspace = Workspace::new("contract-serve");
    let output = Command::new(daemon_binary())
        .args(["serve", "--socket"])
        .arg(workspace.socket())
        .args(["--idle-timeout", "never", "--screens"])
        .arg(workspace.dir.join("screens"))
        .arg("--handoff")
        .arg(workspace.dir.join("missing.handoff"))
        .output()
        .expect("run serve");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "a missing table cannot be adopted"
    );
    assert!(
        stderr.contains("could not take over from the program handed off"),
        "serve did not read --handoff: {stderr}"
    );
}

/// The app starts an unsupervised SSH daemon with this command. Neither a user session nor a
/// systemd unit owns its lifetime; it must accept `never` and persistent screens together.
#[test]
fn serve_accepts_the_unsupervised_ssh_start_command() {
    let workspace = Workspace::new("ssh");
    let socket = workspace.socket();
    let screens = workspace.dir.join("screens");
    let child = Command::new(daemon_binary())
        .args(["serve", "--socket"])
        .arg(&socket)
        .args(["--idle-timeout", "never", "--screens"])
        .arg(&screens)
        .env("SHELL", "/bin/sh")
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start SSH daemon");
    let mut daemon = Started(child);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if std::os::unix::net::UnixStream::connect(&socket).is_ok() {
            assert!(daemon.0.try_wait().unwrap().is_none());
            return;
        }
        assert!(
            daemon.0.try_wait().unwrap().is_none(),
            "serve rejected the SSH start command"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("SSH daemon never listened on {}", socket.display());
}
