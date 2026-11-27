//! Resume (ADR 0082, #825) end to end: a restored pane whose session is gone, given its tab's
//! resume record by the app, gets a new session under the same id whose own shell runs the
//! recorded command in its folder, word for word, as its first job, and is left at its prompt
//! when it ends.
//!
//! A real daemon and a real attach client over a real socket, as `run_session` uses, with a real
//! zsh or bash (each where this machine has one Workroom hooks) given Workroom's bundled Ghostty
//! integration and a home of the test's own, and `/bin/sh` scripts standing in for the program.

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

/// The bundled Ghostty resources, whose shell integration a pane's shell is given.
fn resources() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty")
}

/// The shell these tests run, as a pane would: zsh, else a bash that Ghostty's integration starts
/// (not macOS's `/bin/bash`, which it skips), so Workroom's hook runs the record; `None`, said,
/// when this machine has neither or the integration isn't here (a run with only `vcs/`).
fn hooked_shell() -> Option<&'static str> {
    if !resources().join("shell-integration").is_dir() {
        eprintln!("skipped: no bundled shell integration (a test run with only vcs/)");
        return None;
    }
    let found = [
        "/bin/zsh",
        "/usr/bin/zsh",
        "/opt/homebrew/bin/bash",
        "/usr/bin/bash",
        "/bin/bash",
    ]
    .into_iter()
    .filter(|path| !(cfg!(target_os = "macos") && *path == "/bin/bash"))
    .find(|path| Path::new(path).exists());
    if found.is_none() {
        eprintln!("skipped: no zsh, and no bash Ghostty's integration starts");
    }
    found
}

/// A home of the test's own for `shell`, whose startup files give the prompt `PROMPT> ` and set
/// nothing else, so no startup file of the developer's is read.
fn home(workspace: &Workspace, name: &str) -> PathBuf {
    let home = workspace.join(format!("home-{name}"));
    std::fs::create_dir_all(&home).unwrap();
    for (file, text) in [
        (".zshenv", "skip_global_compinit=1\n"),
        (".zshrc", "PS1='PROMPT> '\n"),
        (".bash_profile", ". ~/.bashrc\n"),
        (".bashrc", "PS1='PROMPT> '\n"),
    ] {
        std::fs::write(home.join(file), text).unwrap();
    }
    home
}

/// A restored pane's attach for `session` in `shell`, as the app launches it, with the record in
/// `file`.
fn restore(
    socket: &Path,
    session: &str,
    shell: &str,
    home: &Path,
    file: &Path,
) -> (common::Spawned, ClientReader) {
    let resources = resources();
    let mut client = attach_with_env(
        socket,
        session,
        &["--no-create"],
        &[
            ("SHELL", shell),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_RESUME", file.to_str().unwrap()),
            ("WORKROOM_SESSION_RESOURCES", resources.to_str().unwrap()),
            ("HOME", home.to_str().unwrap()),
            ("ZDOTDIR", home.to_str().unwrap()),
            ("HISTFILE", home.join(".history").to_str().unwrap()),
            ("TERM", "xterm-256color"),
            ("TERM_PROGRAM", ""),
            ("ENV", ""),
            ("BASH_ENV", ""),
            ("PROMPT_COMMAND", ""),
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
/// as a job of the pane's own shell that ^Z suspends to its prompt and `fg` brings back, the
/// command never in the shell's history, and `resumeStarted` once it starts; fails_when=the relay
/// stops sending the record, the daemon runs it through a shell, in the wrong folder, owns it by
/// the shell, ^Z strands it, the shell isn't the session's own, or the app is never told it
/// started; why_new=new (#825), job control and `resumeStarted` from its review; seam=none
#[test]
fn a_gone_session_resumes_its_program_as_its_shells_first_job() {
    if is_root() {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    let Some(shell) = hooked_shell() else { return };
    let workspace = Workspace::new("resume");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = home(&workspace, "resume");
    let folder = workspace.join("the project");
    std::fs::create_dir(&folder).unwrap();
    let program = workspace.join("fixture-resume");
    common::write_executable(
        &program,
        "#!/bin/sh\nfor word in \"$@\"; do printf '[%s]' \"$word\"; done\necho\necho \"IN=$(pwd)\"\nread line\necho \"PROGRAM-DONE $line\"\n",
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
    let (mut client, mut reader) = restore(&socket, session, shell, &home, &file);

    let seen = reader
        .read_until(&format!("IN={}", folder.display()), Duration::from_secs(30))
        .to_string();
    assert!(
        seen.contains("[resumed][two words][a'\"b][$(echo unexpected)][]"),
        "the words arrive as reported in {shell}: {seen}"
    );
    assert!(!file.exists(), "the relay claimed the app's file");
    let launches = socket.with_extension("resume");
    let left = || std::fs::read_dir(&launches).map_or(0, |dir| dir.count());
    assert_eq!(left(), 0, "the helper claimed the daemon's file");
    if common::has_terminal_state() {
        assert!(
            wait_for(Duration::from_secs(10), || {
                let status = status(&socket, session);
                status["resume"]["cwd"] == folder.to_str().unwrap()
                    && status["resumeStarted"] == true
            }),
            "the record is the session's while its program runs, which started: {}",
            status(&socket, session)
        );
    }

    // ^Z: the program stops, and the shell's prompt takes the next line, in the folder as the
    // session started there (a session's shell has its physical path, as any session's does).
    type_into(&mut client, "\x1a");
    std::thread::sleep(Duration::from_millis(500));
    type_into(&mut client, "echo \"STOPPED-$((40+2)) IN=$(pwd)\"\n");
    let here = format!("STOPPED-42 IN={}", folder.canonicalize().unwrap().display());
    let stopped = reader
        .read_until(&here, Duration::from_secs(10))
        .to_string();
    assert!(
        stopped.contains(&here),
        "^Z leaves {shell}'s prompt in the program's folder: {stopped}"
    );
    type_into(&mut client, "fg\n");
    std::thread::sleep(Duration::from_millis(500));
    type_into(&mut client, "back\n");
    reader.read_until("PROGRAM-DONE back", Duration::from_secs(10));
    let login = format!("SHELL-IS=-{}", shell.rsplit('/').next().unwrap());
    type_into(&mut client, "echo \"SHELL-IS=$0\"\n");
    let after = reader
        .read_until(&login, Duration::from_secs(10))
        .to_string();
    assert!(
        after.contains(&login),
        "the session's own login shell: {after}"
    );
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
/// "Couldn't resume" toast) and leaving a shell, and a resume the daemon declines (a folder that
/// is gone, a shell with no hook) never saying it started; fails_when=the helper stops passing
/// the status on, the daemon stops publishing it, a failed start leaves no shell, a gone folder
/// still runs the command, or a declined resume sends `resumeStarted`; why_new=new (#825),
/// `resumeStarted` from its review; seam=none
#[test]
fn a_program_that_fails_at_once_says_so_and_a_declined_resume_never_starts() {
    if is_root() {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    let Some(shell) = hooked_shell() else { return };
    let workspace = Workspace::new("resume-fail");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = home(&workspace, "fail");

    let failing = "8e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e12";
    let file = app_launch_file(
        &workspace,
        failing,
        &["/bin/sh", "-c", "echo FAILING; exit 3"],
        &workspace,
    );
    let (mut client, mut reader) = restore(&socket, failing, shell, &home, &file);
    reader.read_until("FAILING", Duration::from_secs(30));
    if common::has_terminal_state() {
        assert!(
            wait_for(Duration::from_secs(10), || {
                let status = status(&socket, failing);
                status["resumeFailed"] == true && status["resumeStarted"] == true
            }),
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

    for (session, shell, cwd) in [
        (
            "9e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e13",
            shell,
            Path::new("/definitely/not/a/folder"),
        ),
        // `/bin/sh` runs no Workroom hook, so the daemon can't run a record from it.
        (
            "9e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e14",
            "/bin/sh",
            &*workspace,
        ),
    ] {
        let file = app_launch_file(&workspace, session, &["/bin/echo", "SHOULD-NOT-RUN"], cwd);
        let (mut client, mut reader) = restore(&socket, session, shell, &home, &file);
        type_into(&mut client, "echo \"PLAIN-$((40+2))\"\n");
        let plain = reader
            .read_until("PLAIN-42", Duration::from_secs(30))
            .to_string();
        assert!(plain.contains("PLAIN-42"), "{shell}: {plain}");
        assert!(!plain.contains("SHOULD-NOT-RUN"), "{shell}: {plain}");
        if common::has_terminal_state() {
            let status = status(&socket, session);
            assert!(status["resume"].is_null(), "{shell}: {status}");
            assert!(status.get("resumeStarted").is_none(), "{shell}: {status}");
        }
    }
    let launches = socket.with_extension("resume");
    assert_eq!(
        std::fs::read_dir(&launches).map_or(0, |dir| dir.count()),
        0,
        "a declined resume writes no launch file"
    );
}
