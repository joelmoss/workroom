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
/// `0700` folder. Its name and its JSON are the shared fixture's (`testdata/resume-launch`, which
/// the app's `SavedLayoutStoreTests` checks is what its writer writes), with this test's session
/// in the name and its `argv` and `cwd` in place of the fixture's.
fn app_launch_file(workspace: &Workspace, session: &str, argv: &[&str], cwd: &Path) -> PathBuf {
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../testdata/resume-launch");
    let fixture = std::fs::read_dir(&fixtures)
        .expect("testdata/resume-launch")
        .map(|entry| entry.unwrap().path())
        .find(|path| path.extension().is_some_and(|ext| ext == "json"))
        .expect("the app's launch file fixture");
    let name = fixture.file_name().unwrap().to_str().unwrap();
    let fixture_session = name
        .strip_prefix("resume-")
        .and_then(|rest| rest.get(..36))
        .expect("named resume-<session>-<32 hex>.json");
    let mut record: Value = serde_json::from_slice(&std::fs::read(&fixture).unwrap()).unwrap();
    assert!(record["argv"].is_array(), "{record}");
    assert!(record["cwd"].is_string(), "{record}");
    assert!(record["reportedAt"].is_u64(), "{record}");
    record["argv"] = json!(argv);
    record["cwd"] = json!(cwd);

    let dir = workspace.join("app-resume");
    let _ = std::fs::DirBuilder::new().mode(0o700).create(&dir);
    let path = dir.join(name.replace(fixture_session, session));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .expect("launch file");
    std::io::Write::write_all(&mut file, record.to_string().as_bytes()).unwrap();
    path
}

/// The bundled Ghostty resources, whose shell integration a pane's shell is given.
fn resources() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty")
}

/// The shells these tests run, as a pane would: the first zsh and the first bash that Ghostty's
/// integration starts (not macOS's `/bin/bash`, which it skips) that this machine has, so
/// Workroom's hook runs the record; each one missing is said, and none when the integration
/// isn't here (a run with only `vcs/`).
fn hooked_shells() -> Vec<&'static str> {
    if !resources().join("shell-integration").is_dir() {
        eprintln!("skipped: no bundled shell integration (a test run with only vcs/)");
        return Vec::new();
    }
    let candidates: [(&str, &[&str]); 2] = [
        (
            "zsh",
            &["/opt/homebrew/bin/zsh", "/bin/zsh", "/usr/bin/zsh"],
        ),
        (
            "bash",
            &[
                "/opt/homebrew/bin/bash",
                "/usr/local/bin/bash",
                "/usr/bin/bash",
                "/bin/bash",
            ],
        ),
    ];
    candidates
        .into_iter()
        .filter_map(|(name, paths)| {
            let found = paths
                .iter()
                .copied()
                .filter(|path| !(cfg!(target_os = "macos") && *path == "/bin/bash"))
                .find(|path| Path::new(path).exists());
            if found.is_none() {
                eprintln!("skipped {name}: none here that Ghostty's integration starts");
            }
            found
        })
        .collect()
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
    for shell in hooked_shells() {
        resumes_as_its_shells_first_job(shell);
    }
}

fn resumes_as_its_shells_first_job(shell: &str) {
    let name = shell.rsplit('/').next().unwrap();
    let workspace = Workspace::new(&format!("resume-{name}"));
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
    // record names it.
    type_into(&mut client, "\x1a");
    std::thread::sleep(Duration::from_millis(500));
    type_into(&mut client, "echo \"STOPPED-$((40+2)) IN=$(pwd)\"\n");
    let here = format!("STOPPED-42 IN={}", folder.display());
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
    for shell in hooked_shells() {
        fails_at_once_or_is_declined(shell);
    }
}

fn fails_at_once_or_is_declined(shell: &str) {
    let name = shell.rsplit('/').next().unwrap();
    let workspace = Workspace::new(&format!("resume-fail-{name}"));
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
        // The record clears with the failure, not after the exit grace: the helper's clear is
        // signed for its child, the record's owner.
        let mut first = Value::Null;
        assert!(
            wait_for(Duration::from_secs(10), || {
                first = status(&socket, failing);
                first["resumeFailed"] == true
            }),
            "{first}"
        );
        assert_eq!(first["resumeStarted"], true, "{first}");
        assert!(first["resume"].is_null(), "cleared at once: {first}");
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
            assert_eq!(status["resumeDeclined"], true, "{shell}: {status}");
        }
    }
    let launches = socket.with_extension("resume");
    assert_eq!(
        std::fs::read_dir(&launches).map_or(0, |dir| dir.count()),
        0,
        "a declined resume writes no launch file"
    );
}

/// Value: protects=a resume whose shell never runs Workroom's hook (a `.zshrc` that resets
/// `precmd_functions`, one that ends in `exec fish`) being declined at its first prompt: the
/// daemon claims and removes its launch file, so nothing starts the command later, drops the
/// record it seeded and says `resumeDeclined`, so the app forgets the record rather than retry it
/// at every restart; and a session that ends before anything declined it removing its file;
/// fails_when=the first OSC 133 prompt stops declining, the seeded record stays, the file is left
/// behind, or the command runs anyway; why_new=#825's second review (a declined resume never
/// forgot its record); seam=none
#[test]
fn a_shell_that_never_runs_the_hook_declines_the_resume_at_its_first_prompt() {
    if is_root() || !common::has_terminal_state() {
        eprintln!("skipped: needs a daemon with terminal-state, not running as root");
        return;
    }
    for shell in hooked_shells() {
        declined_at_first_prompt(shell);
    }
}

fn declined_at_first_prompt(shell: &str) {
    let name = shell.rsplit('/').next().unwrap();
    let workspace = Workspace::new(&format!("resume-decline-{name}"));
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = home(&workspace, "decline");
    // Only Workroom's hook goes: zsh's is a precmd function by now, bash's is installed after the
    // startup files, from the variable this unsets.
    std::fs::write(
        home.join(".zshrc"),
        "PS1='PROMPT> '\nprecmd_functions=(${precmd_functions:#_workroom_resume})\n",
    )
    .unwrap();
    std::fs::write(
        home.join(".bashrc"),
        "PS1='PROMPT> '\nunset __workroom_resume_file\n",
    )
    .unwrap();
    let launches = socket.with_extension("resume");
    let left = || std::fs::read_dir(&launches).map_or(0, |dir| dir.count());

    let session = "ae5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e15";
    let file = app_launch_file(
        &workspace,
        session,
        &["/bin/echo", "SHOULD-NOT-RUN"],
        &workspace,
    );
    let (mut client, mut reader) = restore(&socket, session, shell, &home, &file);
    assert!(
        wait_for(
            Duration::from_secs(30),
            || status(&socket, session)["resumeDeclined"] == true
        ),
        "{shell}: {}",
        status(&socket, session)
    );
    let declined = status(&socket, session);
    assert!(declined["resume"].is_null(), "{shell}: {declined}");
    assert!(
        declined.get("resumeStarted").is_none(),
        "{shell}: {declined}"
    );
    assert_eq!(left(), 0, "{shell}: the daemon claimed its own launch file");
    type_into(&mut client, "echo \"PLAIN-$((40+2))\"\n");
    let plain = reader
        .read_until("PLAIN-42", Duration::from_secs(10))
        .to_string();
    assert!(plain.contains("PLAIN-42"), "{shell}: {plain}");
    assert!(!plain.contains("SHOULD-NOT-RUN"), "{shell}: {plain}");

    // A shell that sends no prompt mark (its precmd functions all gone, Ghostty's with them), and
    // ends before the daemon's wait runs out: its file goes with it.
    if name == "zsh" {
        std::fs::write(home.join(".zshrc"), "PS1='PROMPT> '\nprecmd_functions=()\n").unwrap();
        let session = "ae5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e16";
        let file = app_launch_file(
            &workspace,
            session,
            &["/bin/echo", "SHOULD-NOT-RUN"],
            &workspace,
        );
        let (mut client, mut reader) = restore(&socket, session, shell, &home, &file);
        type_into(&mut client, "echo \"QUIET-$((40+2))\"\n");
        reader.read_until("QUIET-42", Duration::from_secs(30));
        assert_eq!(left(), 1, "waiting on a hook that may still run");
        type_into(&mut client, "exit\n");
        assert!(
            wait_for(Duration::from_secs(10), || left() == 0),
            "a session that ends removes its unclaimed launch file"
        );
    }
}

/// The record that resumes the stand-in `claude` (`stand_in_claude`) with the Claude profile
/// `profile`, as Workroom's Claude hook writes one for a profile other than the default
/// (ADR 0082): `env CLAUDE_CONFIG_DIR=… claude …`.
fn claude_record(profile: &str, mark: &str) -> Vec<String> {
    [
        "env",
        &format!("CLAUDE_CONFIG_DIR={profile}"),
        &format!("{STAND_IN}={mark}"),
        "claude",
        "stand_in_claude",
        "--exact",
        "--ignored",
        "--nocapture",
    ]
    .map(str::to_string)
    .to_vec()
}

/// What makes `stand_in_claude` act as the stand-in, its mark the value.
const STAND_IN: &str = "WORKROOM_STAND_IN_CLAUDE";

/// Not a test: the stand-in `claude` that `a_resumed_claude_is_named_profiled_and_prompted_as_claude`
/// resumes, a copy of this test binary named `claude` running only this. A script would do but
/// for macOS, which keeps a platform binary's environment (`/bin/sh`'s) from the profile's read,
/// as it never does a real `claude`'s. With bracketed paste on, as Claude Code's prompt has it, it
/// says `AGENT-<mark>` and reads its input until it closes.
#[test]
#[ignore = "a stand-in program the resume tests run, not a test"]
fn stand_in_claude() {
    use std::io::Write;
    let Some(mark) = std::env::var_os(STAND_IN) else {
        return;
    };
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\x1b[?2004hAGENT-{}\r\n", mark.to_string_lossy());
    let _ = stdout.flush();
    let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
}

/// Value: protects=a resumed program reading as itself wherever its session's foreground is
/// named, though its helper leads the shell's job (#825): `claude` as the session list's command
/// (the pane's title and Claude detection after a restart), its profile (only ever read for a
/// confirmed `claude`), and `terminal.prompt` taking it as a coding agent; fails_when=the helper's
/// name (`workroom`) is shown, the profile is not read, or a prompt is `NotAnAgent`;
/// why_new=#825's second review (the foreground was the helper's); seam=a stand-in `claude` on
/// PATH (`stand_in_claude`)
#[test]
fn a_resumed_claude_is_named_profiled_and_prompted_as_claude() {
    if is_root() {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    let Some(shell) = hooked_shells().into_iter().next() else {
        return;
    };
    let workspace = Workspace::new("resume-claude");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = home(&workspace, "claude");
    let bin = workspace.join("bin");
    std::fs::create_dir(&bin).unwrap();
    std::fs::copy(std::env::current_exe().unwrap(), bin.join("claude")).unwrap();
    std::fs::write(
        home.join(".zshrc"),
        format!("PS1='PROMPT> '\npath=({} $path)\n", bin.display()),
    )
    .unwrap();
    std::fs::write(
        home.join(".bashrc"),
        format!("PS1='PROMPT> '\nPATH={}:$PATH\n", bin.display()),
    )
    .unwrap();
    let profile = workspace.join("claude-profile");
    let session = "be5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e17";
    let argv = claude_record(profile.to_str().unwrap(), "RESUMED");
    let words: Vec<&str> = argv.iter().map(String::as_str).collect();
    let file = app_launch_file(&workspace, session, &words, &workspace);
    let (_client, mut reader) = restore(&socket, session, shell, &home, &file);
    reader.read_until("AGENT-RESUMED", Duration::from_secs(30));

    let listed = || list_sessions_line(&socket, session);
    assert!(
        wait_for(Duration::from_secs(10), || listed().ends_with(" claude")),
        "{shell}: the program, not its helper: {}",
        listed()
    );
    let descriptors = common::control(
        &socket,
        wr_protocol::frame::Frame::control(wr_protocol::frame::FrameKind::List),
    );
    let payload = String::from_utf8_lossy(&descriptors.payload).into_owned();
    assert!(
        payload.contains("claude_profile") && payload.contains(profile.to_str().unwrap()),
        "{shell}: its Claude profile is read: {payload:?}"
    );
    if common::has_terminal_state() {
        let run = Command::new(common::daemon_binary())
            .args(["prompt", session, "hello", "--json"])
            .env("WORKROOM_DAEMON", &socket)
            .output()
            .expect("prompt");
        let envelope: Value = serde_json::from_slice(&run.stdout).unwrap_or_default();
        assert_eq!(envelope["ok"], true, "{shell}: {envelope}");
    }
}

/// `workroom list`'s line for `session`, or empty.
fn list_sessions_line(socket: &Path, session: &str) -> String {
    common::list_sessions(socket)
        .lines()
        .find(|line| line.starts_with(session))
        .unwrap_or_default()
        .trim_end()
        .to_string()
}
