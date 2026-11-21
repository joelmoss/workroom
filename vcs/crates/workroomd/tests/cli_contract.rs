//! The command line an older daemon runs on this binary during a hand-off. An older build (one the
//! app shipped, and every remote host's older install) runs `protocol` to order builds, then
//! `handoff-check <table>`, then execs this binary with its own argv plus `--handoff <table>`. None
//! of that can be rebuilt to match a change here, so these names and the `build-number` line are a
//! frozen contract: the binary and its help text may be renamed, this may not.
//!
//! ADR 0078 adds the subcommands an older app runs on a newer host's binary, which keeps the name
//! `workroomd` there: `attach`, `list --socket` (its exit status is how the bootstrap tells a
//! daemon is running), `hand-off` (its exit 92 and "no daemon listening"), `relay`,
//! `run-supervisor` and `run-script`, with `run-script`'s stderr prefix `workroomd run-script: `,
//! which the app parses (`RemoteProvisioning`).

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// As `common::daemon_binary`, which this file doesn't pull in for one function.
fn daemon_binary() -> PathBuf {
    match std::env::var_os("WORKROOMD_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_workroom")),
    }
}

/// A directory of the test's own, removed when it ends.
struct Workspace {
    dir: PathBuf,
}

impl Workspace {
    /// Made new by this run, so the removal on drop takes only what it made.
    fn new(name: &str) -> Workspace {
        let dir = std::env::temp_dir().join(format!("workroomd-it-{name}-{}", std::process::id()));
        std::fs::create_dir(&dir).expect("a workspace of this run's own");
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

/// A daemon serving `workspace`'s socket, with a plain shell for its sessions.
fn serve(workspace: &Workspace) -> Started {
    let socket = workspace.socket();
    let child = Command::new(daemon_binary())
        .args(["serve", "--socket"])
        .arg(&socket)
        .args(["--idle-timeout", "never"])
        .env("SHELL", "/bin/sh")
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start the daemon");
    let daemon = Started(child);
    let deadline = Instant::now() + Duration::from_secs(5);
    while std::os::unix::net::UnixStream::connect(&socket).is_err() {
        assert!(
            Instant::now() < deadline,
            "the daemon never listened on {}",
            socket.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    daemon
}

/// What the bootstrap runs against a host's socket: `list --socket` exits 0 only while a daemon
/// answers, and `hand-off` says "no daemon listening" with exit 92 when none does (`install.sh`
/// reads both), and `current` for a binary that is the running daemon already.
#[test]
fn list_and_hand_off_say_whether_a_daemon_answers_the_socket() {
    let workspace = Workspace::new("contract-list");
    let socket = workspace.socket();
    let run = |args: &[&str]| {
        Command::new(daemon_binary())
            .args(args)
            .stdin(Stdio::null())
            .output()
            .expect("run the binary")
    };
    let socket_arg = socket.to_str().expect("a UTF-8 socket path");
    let binary = daemon_binary();
    let binary_arg = binary.to_str().expect("a UTF-8 binary path");

    let listed = run(&["list", "--socket", socket_arg]);
    assert_eq!(listed.status.code(), Some(92), "{listed:?}");
    let handed = run(&["hand-off", "--socket", socket_arg, "--binary", binary_arg]);
    assert_eq!(handed.status.code(), Some(92), "{handed:?}");
    assert!(
        String::from_utf8_lossy(&handed.stderr).contains("no daemon listening"),
        "{handed:?}"
    );

    let _daemon = serve(&workspace);
    let listed = run(&["list", "--socket", socket_arg]);
    assert_eq!(listed.status.code(), Some(0), "{listed:?}");
    let handed = run(&["hand-off", "--socket", socket_arg, "--binary", binary_arg]);
    assert_eq!(handed.status.code(), Some(0), "{handed:?}");
    assert_eq!(String::from_utf8_lossy(&handed.stdout).trim(), "current");
}

/// A pane's child: `attach --socket <path> --session <uuid>` starts the session's shell and
/// carries it, and `relay --socket <path>` is the far end a remote pane dials (exit 92 with no
/// daemon, which the app reads as "start it").
#[test]
fn attach_and_relay_reach_the_daemon_on_a_socket() {
    let workspace = Workspace::new("contract-attach");
    let socket = workspace.socket();
    let relayed = Command::new(daemon_binary())
        .args(["relay", "--socket"])
        .arg(&socket)
        .stdin(Stdio::null())
        .output()
        .expect("run relay");
    assert_eq!(relayed.status.code(), Some(92), "{relayed:?}");

    let _daemon = serve(&workspace);
    let mut attach = Started(
        Command::new(daemon_binary())
            .args(["attach", "--socket"])
            .arg(&socket)
            .args(["--session", "7e0e7e0e-0000-4000-8000-000000000681"])
            .env("SHELL", "/bin/sh")
            .env("PATH", "/usr/bin:/bin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("run attach"),
    );
    // Split by the quotes, so the pty's echo of the line is not the answer.
    let typed = b"echo ATTACHED-\"\"OK; exit\n";
    std::io::Write::write_all(attach.0.stdin.as_mut().expect("stdin"), typed)
        .expect("type into the session");
    let deadline = Instant::now() + Duration::from_secs(10);
    while attach.0.try_wait().expect("attach status").is_none() {
        assert!(Instant::now() < deadline, "attach never ended");
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut seen = String::new();
    std::io::Read::read_to_string(attach.0.stdout.as_mut().expect("stdout"), &mut seen)
        .expect("read the session");
    assert!(seen.contains("ATTACHED-OK"), "{seen:?}");
}

/// What a run session's pty and a remote workroom's scripts run: both names reach the daemon's
/// side of the binary, and `run-script` says what went wrong under its pinned prefix.
#[test]
fn run_supervisor_and_run_script_are_subcommands_and_run_script_keeps_its_prefix() {
    let workspace = Workspace::new("contract-run");
    let supervisor = Command::new(daemon_binary())
        .arg("run-supervisor")
        .stdin(Stdio::null())
        .output()
        .expect("run run-supervisor");
    let stderr = String::from_utf8_lossy(&supervisor.stderr);
    assert!(
        stderr.contains("run-supervisor needs --status"),
        "run-supervisor did not reach the daemon's side: {stderr}"
    );

    let missing = workspace.dir.join("missing.sh");
    let script = Command::new(daemon_binary())
        .args(["run-script", "--dir"])
        .arg(&workspace.dir)
        .args(["--timeout", "5", "--"])
        .arg(&missing)
        .stdin(Stdio::null())
        .output()
        .expect("run run-script");
    assert_eq!(script.status.code(), Some(126), "{script:?}");
    let stderr = String::from_utf8_lossy(&script.stderr);
    assert!(
        stderr
            .lines()
            .any(|line| line.starts_with("workroomd run-script: ")),
        "{stderr}"
    );
}
