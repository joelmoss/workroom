//! `workroomd run-script` as the app runs it, a process of its own: its output arrives while the
//! script is still running, and a SIGTERM to it (the app ending its carrier) ends the script's tree.
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// As `common::daemon_binary`, which this file doesn't pull in for one function.
fn daemon_binary() -> PathBuf {
    match std::env::var_os("WORKROOMD_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_workroomd")),
    }
}

/// Killed when the test ends, panic or not, as `common::Spawned` is.
struct Spawned(Child);

impl Drop for Spawned {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 takes no pointers and only checks that the pid exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// The setup and teardown contract a remote workroom's script sees, as the app runs it here:
/// `testdata/script-env`'s fixture, whose local expectation (`local.txt`) the Go CLI's tests check.
#[test]
fn a_script_sees_the_remote_contract() {
    remote_contract("boxd", "remote.txt");
    remote_contract("ssh", "ssh.txt");
}

fn remote_contract(host: &str, fixture: &str) {
    let contract = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../testdata/script-env");
    let dir = std::env::temp_dir().join(format!("wr-run-script-contract-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    let want = std::fs::read_to_string(contract.join(fixture))
        .unwrap()
        .replace("{DIR}", dir.to_str().unwrap());

    let output = Command::new(daemon_binary())
        .args(["run-script", "--dir"])
        .arg(&dir)
        .args(["--timeout", "60"])
        .args(["--env", "WORKROOM_NAME=contract", "--env"])
        .arg(format!("WORKROOM_PATH={}", dir.display()))
        .args(["--env", &format!("WORKROOM_HOST={host}"), "--"])
        .arg(contract.join("workroom_script"))
        .env("SHELL", "/nonexistent/zsh")
        .env_remove("WORKROOM_ROOT_PATH")
        .env_remove("WORKROOM_PARENT_DIR")
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8(output.stdout).unwrap(), want);
}

#[test]
fn output_streams_while_the_script_runs_and_a_sigterm_ends_its_tree() {
    let dir = std::env::temp_dir().join(format!("wr-run-script-it-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pidfile = dir.join("child.pid");
    let script = dir.join("workroom_setup");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\nsleep 60 &\necho $! > {}\necho started\nwait\n",
            pidfile.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let mut daemon = Spawned(
        Command::new(daemon_binary())
            .args(["run-script", "--dir"])
            .arg(&dir)
            .args(["--timeout", "60", "--env", "WORKROOM_NAME=it", "--"])
            .arg(&script)
            // A shell that isn't there: the probe falls back at once instead of reading a profile.
            .env("SHELL", "/nonexistent/zsh")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut lines = BufReader::new(daemon.0.stdout.take().unwrap()).lines();
    assert_eq!(lines.next().unwrap().unwrap(), "started");
    assert!(
        daemon.0.try_wait().unwrap().is_none(),
        "the line came only at exit"
    );

    let child: i32 = std::fs::read_to_string(&pidfile)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // SAFETY: `kill` takes no pointers.
    unsafe { libc::kill(daemon.0.id() as i32, libc::SIGTERM) };
    let status = daemon.0.wait().unwrap();
    assert_eq!(status.code(), Some(128 + libc::SIGTERM));

    let gone_by = Instant::now() + Duration::from_secs(2);
    while alive(child) && Instant::now() < gone_by {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !alive(child),
        "the script's child {child} survived the SIGTERM"
    );
}
