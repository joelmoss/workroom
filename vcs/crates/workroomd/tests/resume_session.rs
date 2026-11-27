//! Resume (ADR 0082, #825) end to end: a restored pane whose session is gone, given its tab's
//! resume record by the app, gets a new session under the same id whose login shell runs the
//! recorded command in its folder, word for word, and is left at a shell prompt when it ends.
//!
//! A real daemon and a real attach client over a real socket, as `run_session` uses, with `/bin/sh`
//! as the user's shell and `/bin/sh` scripts standing in for the program.

#[allow(dead_code)] // not every helper is used here
mod common;

use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use common::{ClientReader, Workspace, attach_with_env, start_daemon, wait_for};
use serde_json::{Value, json};

/// Writes the app's launch file for `session` (as `PersistentSessionService` does): `0600`, in a
/// `0700` folder, named `resume-<session>-<32 hex>.json`.
fn app_launch_file(workspace: &Workspace, session: &str, argv: &[&str], cwd: &Path) -> PathBuf {
    let dir = workspace.join("app-resume");
    let _ = std::fs::DirBuilder::new().mode(0o700).create(&dir);
    let path = dir.join(format!(
        "resume-{session}-{}.json",
        "0123456789abcdef".repeat(2)
    ));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .expect("launch file");
    let record = json!({"argv": argv, "cwd": cwd, "reportedAt": 1_795_543_200_000u64});
    std::io::Write::write_all(&mut file, record.to_string().as_bytes()).unwrap();
    path
}

/// A restored pane's attach for `session`, as the app launches it, with the record in `file`.
fn restore(socket: &Path, session: &str, file: &Path) -> (common::Spawned, ClientReader) {
    let mut client = attach_with_env(
        socket,
        session,
        &["--no-create"],
        &[
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_RESUME", file.to_str().unwrap()),
        ],
    );
    let reader = ClientReader::new(&mut client);
    (client, reader)
}

fn type_into(client: &mut common::Spawned, text: &str) {
    use std::io::Write;
    let stdin = client.0.stdin.as_mut().expect("stdin");
    stdin.write_all(text.as_bytes()).unwrap();
    stdin.flush().unwrap();
}

/// What `workroom program-status --json` says of `session` (never the arguments), or `Null`.
fn status(socket: &Path, session: &str) -> Value {
    let output = Command::new(common::daemon_binary())
        .args(["program-status", "--json", "--socket"])
        .arg(socket)
        .output()
        .expect("program-status");
    let out: Value = serde_json::from_slice(&output.stdout).unwrap_or_default();
    out["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|status| status["session"] == session)
        .cloned()
        .unwrap_or_default()
}

fn is_root() -> bool {
    // SAFETY: no preconditions.
    unsafe { libc::geteuid() == 0 }
}

/// Value: protects=a gone session's program coming back as it reported itself, in its folder,
/// with no word split or expanded, owned by its own process so its record clears when it quits,
/// and a login shell left in that folder; fails_when=the relay stops sending the record, the
/// daemon runs it through a shell, in the wrong folder, owns it by the shell, or leaves the pane
/// with no shell or a shell that is not the login one; why_new=new (#825); seam=none
#[test]
fn a_gone_session_resumes_its_program_and_leaves_a_login_shell_in_its_folder() {
    if is_root() {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    let workspace = Workspace::new("resume");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let folder = workspace.join("the project");
    std::fs::create_dir(&folder).unwrap();
    let program = workspace.join("fixture-resume");
    common::write_executable(
        &program,
        "#!/bin/sh\nfor word in \"$@\"; do printf '[%s]' \"$word\"; done\necho\necho \"IN=$(pwd)\"\nread line\necho PROGRAM-DONE\n",
    );
    let session = "7e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e11";
    let file = app_launch_file(
        &workspace,
        session,
        &[
            program.to_str().unwrap(),
            "resumed",
            "two words",
            "a'\"b",
            "$(echo unexpected)",
            "",
        ],
        &folder,
    );
    let (mut client, mut reader) = restore(&socket, session, &file);

    let seen = reader
        .read_until(&format!("IN={}", folder.display()), Duration::from_secs(20))
        .to_string();
    assert!(
        seen.contains("[resumed][two words][a'\"b][$(echo unexpected)][]"),
        "the words arrive as reported: {seen}"
    );
    assert!(!file.exists(), "the relay claimed the app's file");
    let launches = socket.with_extension("resume");
    let left = || std::fs::read_dir(&launches).map_or(0, |dir| dir.count());
    assert_eq!(
        left(),
        1,
        "the helper claimed its launch file, not yet the shell's"
    );
    if common::has_terminal_state() {
        assert!(
            wait_for(Duration::from_secs(10), || {
                status(&socket, session)["resume"]["cwd"] == folder.to_str().unwrap()
            }),
            "the record is the session's while its program runs"
        );
    }

    type_into(&mut client, "\n");
    reader.read_until("PROGRAM-DONE", Duration::from_secs(10));
    type_into(&mut client, "echo \"SHELL-IS=$0 IN=$(pwd)\"\n");
    let shell = reader
        .read_until(
            &format!("SHELL-IS=-sh IN={}", folder.display()),
            Duration::from_secs(10),
        )
        .to_string();
    assert!(
        shell.contains(&format!("SHELL-IS=-sh IN={}", folder.display())),
        "a login shell in the program's folder: {shell}"
    );
    assert_eq!(left(), 0, "the shell claimed its file");
    if common::has_terminal_state() {
        assert!(
            wait_for(Duration::from_secs(15), || {
                type_into(&mut client, "\n");
                status(&socket, session)["resume"].is_null()
            }),
            "its owner was the program, so quitting it clears the record"
        );
    }
}

/// Value: protects=a recorded command that exits with an error at once saying so (the app's
/// "Couldn't resume" toast) and leaving a shell, and one whose folder is gone not resuming at
/// all; fails_when=the wrapper stops passing the status on, the daemon stops publishing it, a
/// failed start leaves no shell, or a gone folder still runs the command; why_new=new (#825);
/// seam=none
#[test]
fn a_program_that_fails_at_once_says_so_and_a_gone_folder_does_not_resume() {
    if is_root() {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    let workspace = Workspace::new("resume-fail");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);

    let failing = "8e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e12";
    let file = app_launch_file(
        &workspace,
        failing,
        &["/bin/sh", "-c", "echo FAILING; exit 3"],
        &workspace,
    );
    let (mut client, mut reader) = restore(&socket, failing, &file);
    reader.read_until("FAILING", Duration::from_secs(20));
    if common::has_terminal_state() {
        assert!(
            wait_for(
                Duration::from_secs(10),
                || status(&socket, failing)["resumeFailed"] == true
            ),
            "{}",
            status(&socket, failing)
        );
    }
    // Worked out by the shell, so the typed line's echo can't pass for it.
    type_into(&mut client, "echo \"SHELL-$((40+2))\"\n");
    let after = reader
        .read_until("SHELL-42", Duration::from_secs(10))
        .to_string();
    assert!(after.contains("SHELL-42"), "a shell is left: {after}");

    let gone = "9e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e13";
    let file = app_launch_file(
        &workspace,
        gone,
        &["/bin/echo", "SHOULD-NOT-RUN"],
        Path::new("/definitely/not/a/folder"),
    );
    let (mut client, mut reader) = restore(&socket, gone, &file);
    type_into(&mut client, "echo \"PLAIN-$((40+2))\"\n");
    let plain = reader
        .read_until("PLAIN-42", Duration::from_secs(20))
        .to_string();
    assert!(plain.contains("PLAIN-42"), "{plain}");
    assert!(!plain.contains("SHOULD-NOT-RUN"), "{plain}");
    if common::has_terminal_state() {
        assert!(status(&socket, gone)["resume"].is_null());
    }
}
