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
    app_launch_file_in("app-resume", workspace, session, argv, cwd)
}

/// `app_launch_file`, in the workspace's folder `folder`: a second Mac's file for the same
/// session, which has the same name.
fn app_launch_file_in(
    folder: &str,
    workspace: &Workspace,
    session: &str,
    argv: &[&str],
    cwd: &Path,
) -> PathBuf {
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

    let dir = workspace.join(folder);
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
    restore_with(socket, session, shell, home, Some(file), &["--no-create"])
}

/// `restore` with the attach's `flags`, and `file` only when there is one.
fn restore_with(
    socket: &Path,
    session: &str,
    shell: &str,
    home: &Path,
    file: Option<&Path>,
    flags: &[&str],
) -> (common::Spawned, ClientReader) {
    let resources = resources();
    let history = home.join(".history");
    let mut env = vec![
        ("SHELL", shell),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_RESOURCES", resources.to_str().unwrap()),
        ("HOME", home.to_str().unwrap()),
        ("ZDOTDIR", home.to_str().unwrap()),
        ("HISTFILE", history.to_str().unwrap()),
        ("TERM", "xterm-256color"),
        ("TERM_PROGRAM", ""),
        ("ENV", ""),
        ("BASH_ENV", ""),
        ("PROMPT_COMMAND", ""),
    ];
    if let Some(file) = file {
        env.push(("WORKROOM_SESSION_RESUME", file.to_str().unwrap()));
    }
    let mut client = attach_with_env(socket, session, flags, &env);
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

/// Value: protects=a resume whose shell prints a prompt mark before Workroom's hook runs, as
/// Powerlevel10k's instant prompt does from the top of `.zshrc`, still starting its program
/// (#825): the hook said it loaded from `.zshenv` (bash: its `ENV`), so the daemon waits for the
/// helper past that mark; fails_when=the hook stops announcing itself before the user's startup
/// files, the daemon stops reading the announcement, or an early mark declines the resume again;
/// why_new=#825's third review (an instant prompt declined resumes that would have worked);
/// seam=none
#[test]
fn a_prompt_mark_before_the_hook_runs_still_resumes_the_program() {
    if is_root() || !common::has_terminal_state() {
        eprintln!("skipped: needs a daemon with terminal-state, not running as root");
        return;
    }
    for shell in hooked_shells() {
        resumes_past_an_early_prompt_mark(shell);
    }
}

fn resumes_past_an_early_prompt_mark(shell: &str) {
    let name = shell.rsplit('/').next().unwrap();
    let workspace = Workspace::new(&format!("resume-instant-{name}"));
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = home(&workspace, "instant");
    // The mark an instant prompt prints, then a pause, so the daemon reads it well before the
    // helper's report, which a mark in the same read would count as started.
    let early = "printf '\\033]133;A\\007'\nsleep 1\nPS1='PROMPT> '\n";
    std::fs::write(home.join(".zshrc"), early).unwrap();
    std::fs::write(home.join(".bashrc"), early).unwrap();
    let session = "ce5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e18";
    let file = app_launch_file(
        &workspace,
        session,
        &["/bin/echo", "RESUMED-PAST-THE-MARK"],
        &workspace,
    );
    let (_client, mut reader) = restore(&socket, session, shell, &home, &file);
    let seen = reader
        .read_until("RESUMED-PAST-THE-MARK", Duration::from_secs(30))
        .to_string();
    assert!(seen.contains("RESUMED-PAST-THE-MARK"), "{shell}: {seen}");
    assert!(!seen.contains("couldn't resume"), "{shell}: {seen}");
    let mut said = Value::Null;
    assert!(
        wait_for(Duration::from_secs(10), || {
            said = status(&socket, session);
            said["resumeStarted"] == true
        }),
        "{shell}: {said}"
    );
    assert!(said.get("resumeDeclined").is_none(), "{shell}: {said}");
}

/// Value: protects=the accepted limit of a resume whose shell loaded Workroom's hook but whose
/// startup files keep it from running (a `.zshrc` that resets `precmd_functions`, one that ends
/// in `exec fish`): nothing declines it at the first prompt, so the seeded record stays and the
/// app's own fallback speaks; the command never runs; and the session's end removes its launch
/// file, with or without a prompt mark; fails_when=the first prompt declines a shell whose hook
/// loaded, the seeded record goes, the command runs anyway, or the file is left behind;
/// why_new=#825's third review (a hook that loaded is waited for); seam=none
#[test]
fn a_hook_that_loaded_but_never_runs_keeps_the_record_until_its_session_ends() {
    if is_root() || !common::has_terminal_state() {
        eprintln!("skipped: needs a daemon with terminal-state, not running as root");
        return;
    }
    for shell in hooked_shells() {
        kept_past_the_first_prompt(shell);
    }
}

fn kept_past_the_first_prompt(shell: &str) {
    let name = shell.rsplit('/').next().unwrap();
    let workspace = Workspace::new(&format!("resume-kept-{name}"));
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = home(&workspace, "kept");
    // Only Workroom's hook goes, once it has loaded: zsh's is a precmd function by now, bash's is
    // installed after the startup files, from the variable this unsets.
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
    // Typed once the prompt has come, so its answer comes after the first prompt's mark.
    reader.read_until("PROMPT> ", Duration::from_secs(30));
    type_into(&mut client, "echo \"PLAIN-$((40+2))\"\n");
    let plain = reader
        .read_until("PLAIN-42", Duration::from_secs(10))
        .to_string();
    assert!(plain.contains("PLAIN-42"), "{shell}: {plain}");
    assert!(!plain.contains("SHOULD-NOT-RUN"), "{shell}: {plain}");
    let kept = status(&socket, session);
    assert!(kept.get("resumeDeclined").is_none(), "{shell}: {kept}");
    assert!(kept.get("resumeStarted").is_none(), "{shell}: {kept}");
    assert_eq!(
        kept["resume"]["cwd"],
        workspace.to_str().unwrap(),
        "{shell}: the seeded record stays: {kept}"
    );
    assert_eq!(
        left(),
        1,
        "{shell}: its launch file waits for a hook that may still run"
    );
    type_into(&mut client, "exit\n");
    assert!(
        wait_for(Duration::from_secs(10), || left() == 0),
        "{shell}: a session that ends removes its unclaimed launch file"
    );

    // A shell that sends no prompt mark (its precmd functions all gone, Ghostty's with them): its
    // file goes with it too.
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
    for shell in hooked_shells() {
        named_profiled_and_prompted_as_claude(shell);
    }
}

fn named_profiled_and_prompted_as_claude(shell: &str) {
    let name = shell.rsplit('/').next().unwrap();
    let workspace = Workspace::new(&format!("resume-claude-{name}"));
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

/// Value: protects=a remote pane's gone session (#826) made again on its FIRST attach
/// (`--no-create --no-spawn`, as a container's client inside it and, past the relay, a Mac's
/// dialed one), running its record, where the host's daemon kept its frozen last screen; two Macs
/// reconnecting at once making one session whose program runs once and which both show; a live
/// session never running a record it was sent, nor told it was declined; and a remote pane with
/// no record still shown its frozen screen; fails_when=the relay keeps a remote record for a retry
/// it never makes, the daemon shows the frozen screen or says "ended" instead, the losing create
/// of two is told it ended, a live session runs the record, or a pane with no record gets a new
/// shell; why_new=new (#826); seam=none
#[test]
fn a_remote_panes_gone_session_resumes_once_on_its_first_attach() {
    if is_root() {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    if let Some(shell) = hooked_shells().first() {
        resumes_on_its_first_remote_attach(shell);
    }
}

fn resumes_on_its_first_remote_attach(shell: &str) {
    const REMOTE: &[&str] = &["--no-create", "--no-spawn"];
    let workspace = Workspace::new("resume-remote");
    let socket = workspace.socket();
    let screens = workspace.join("screens");
    let flags = [std::ffi::OsStr::new("--screens"), screens.as_os_str()];
    let home = home(&workspace, "remote");
    let folder = workspace.join("the project");
    std::fs::create_dir(&folder).unwrap();
    let runs = workspace.join("runs");
    let program = workspace.join("fixture-remote");
    common::write_executable(
        &program,
        &format!(
            "#!/bin/sh\necho run >> '{}'\necho \"RESUMED-$1 IN=$(pwd)\"\nexec sleep 60\n",
            runs.display()
        ),
    );
    let resumed = "4e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e21";
    let unrecorded = "4e5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e22";

    // Before the restart: both sessions run, and with the terminal state their screens are kept.
    let mut daemon = common::start_daemon_with(&socket, &flags);
    let mut before = Vec::new();
    for session in [resumed, unrecorded] {
        let (mut client, mut reader) = restore_with(&socket, session, shell, &home, None, &[]);
        type_into(&mut client, "echo \"BEFORE-$((40+2))\"\n");
        reader.read_until("BEFORE-42", Duration::from_secs(30));
        before.push(client);
    }
    let kept = |session: &str| {
        std::fs::read(screens.join(format!("{session}.vt")))
            .is_ok_and(|bytes| String::from_utf8_lossy(&bytes).contains("BEFORE-42"))
    };
    if common::has_terminal_state() {
        assert!(
            wait_for(Duration::from_secs(10), || kept(resumed) && kept(unrecorded)),
            "the screens were kept"
        );
    }
    // The host restarts: the daemon and every shell die at once, and a new daemon starts over the
    // same screens.
    daemon.kill().unwrap();
    daemon.wait().unwrap();
    drop(before);
    std::fs::remove_file(&socket).unwrap();
    let _daemon = common::start_daemon_with(&socket, &flags);

    // Two Macs at once, each with the record its host layout gave it, in its own file.
    let argv = [program.to_str().unwrap(), "ONCE"];
    let first = app_launch_file_in("mac-a", &workspace, resumed, &argv, &folder);
    let second = app_launch_file_in("mac-b", &workspace, resumed, &argv, &folder);
    let (_a, mut seen_a) = restore_with(&socket, resumed, shell, &home, Some(&first), REMOTE);
    let (_b, mut seen_b) = restore_with(&socket, resumed, shell, &home, Some(&second), REMOTE);
    let here = format!("RESUMED-ONCE IN={}", folder.display());
    for (mac, reader) in [("first", &mut seen_a), ("second", &mut seen_b)] {
        let seen = reader.read_until(&here, Duration::from_secs(30)).to_string();
        assert!(
            seen.contains(&here),
            "the {mac} Mac shows the resumed program: {seen}"
        );
        assert!(
            !seen.contains("ended"),
            "the {mac} Mac isn't told it ended: {seen}"
        );
    }
    assert!(
        !first.exists() && !second.exists(),
        "each relay claimed its file"
    );
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        std::fs::read_to_string(&runs)
            .unwrap_or_default()
            .lines()
            .count(),
        1,
        "the program resumed once, in one session"
    );
    assert!(
        !list_sessions_line(&socket, resumed).is_empty(),
        "a listed daemon session, not the client's child"
    );

    // A live session given a record attaches as it is: nothing runs, and nothing is declined.
    let live = app_launch_file(
        &workspace,
        resumed,
        &["/bin/echo", "SHOULD-NOT-RUN"],
        &folder,
    );
    let (mut again, mut seen) = restore_with(&socket, resumed, shell, &home, Some(&live), REMOTE);
    type_into(&mut again, "\n");
    std::thread::sleep(Duration::from_millis(1000));
    assert!(!live.exists(), "the relay claimed it");
    assert!(
        !seen
            .read_until("SHOULD-NOT-RUN", Duration::from_secs(1))
            .contains("SHOULD-NOT-RUN"),
        "a live session ran a record"
    );
    if common::has_terminal_state() {
        let status = status(&socket, resumed);
        assert_eq!(status["resumeStarted"], true, "{status}");
        assert!(status.get("resumeDeclined").is_none(), "{status}");

        // No record: the frozen last screen, as before (ADR 0031), and no session behind it.
        let (_c, mut frozen) = restore_with(&socket, unrecorded, shell, &home, None, REMOTE);
        let seen = frozen
            .read_until("Close it to start again", Duration::from_secs(10))
            .to_string();
        assert!(
            seen.contains("BEFORE-42") && seen.contains("Close it to start again"),
            "{seen}"
        );
        assert!(list_sessions_line(&socket, unrecorded).is_empty());
    }
}
