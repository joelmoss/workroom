//! The Go CLI's script tests (`internal/script`), ported as behaviour tests of the one runner
//! (#676): in-process, as a CLI command calls `workroom::script::run`, and through `run-script`,
//! a process of its own, for what needs this process's environment or a signal. Every login shell
//! here reads a profile in a throwaway HOME.
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use workroom::script::{self, Outcome, Output, Script};

fn binary() -> PathBuf {
    match std::env::var_os("WORKROOMD_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_workroom")),
    }
}

/// A fresh directory, canonical so `pwd -P` in it matches, removed when the test is done.
struct Scratch(PathBuf);

impl std::ops::Deref for Scratch {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A directory this run made itself: `create_dir` fails on any path that already exists, so a
/// leftover from a killed run, or another run's live one, is skipped rather than reused, and only
/// what this call created is ever removed.
fn scratch(name: &str) -> Scratch {
    let parent = std::env::temp_dir();
    let pid = std::process::id();
    for attempt in 0u32.. {
        let root = parent.join(format!("wr-script-runner-{name}-{pid}-{attempt}"));
        match std::fs::create_dir(&root) {
            Ok(()) => return Scratch(std::fs::canonicalize(&root).unwrap()),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => panic!("create {}: {error}", root.display()),
        }
    }
    unreachable!("u32 attempts ran out")
}

/// Written by `cp`, not by this process: a test on another thread that forks while this one holds
/// the file open for writing hands the child that descriptor, and running it then fails on Linux
/// with "Text file busy" (ETXTBSY).
fn executable(path: &Path, body: &str) -> PathBuf {
    let draft = path.with_extension("draft");
    std::fs::write(&draft, body).unwrap();
    assert!(
        Command::new("cp")
            .arg(&draft)
            .arg(path)
            .status()
            .unwrap()
            .success()
    );
    std::fs::remove_file(&draft).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_path_buf()
}

/// A workroom script that echoes `line`, which its shell expands.
fn printing(root: &Path, line: &str) -> PathBuf {
    executable(
        &root.join("workroom_script"),
        &format!("#!/bin/sh\necho \"{line}\"\n"),
    )
}

/// A POSIX "shell" that reads no profile and runs the probe's line, for in-process runs, which
/// can't give the shell a HOME of its own. Named `bash` so it is probed with `-lic`.
fn plain_shell(root: &Path, before: &str) -> String {
    let path = executable(
        &root.join("bash"),
        &format!("#!/bin/sh\n{before}exec /bin/sh -c \"$2\"\n"),
    );
    path.display().to_string()
}

fn in_process<'a>(
    script: &'a Path,
    dir: &'a Path,
    variables: &'a [(String, String)],
    shell: String,
) -> Script<'a> {
    let mut request = Script::new(script, dir, variables, None);
    request.shell = shell;
    request.probe_timeout = Duration::from_secs(5);
    request
}

fn combined(script: &Script) -> (Outcome, String) {
    let mut output = Vec::new();
    let outcome = script::run(script, Output::Combined(&mut output), |reason| {
        format!(
            "workroom: couldn't read the login shell's environment ({reason}); using the current one\n"
        )
    });
    (outcome, String::from_utf8(output).unwrap())
}

// In-process, as `create` and `delete` call it.

/// What a local workroom's script sees (`testdata/script-env/local.txt`), whose remote
/// expectations `tests/run_script.rs` checks.
#[test]
fn a_local_script_sees_the_local_contract() {
    let root = scratch("contract");
    let dir = root.join("room");
    std::fs::create_dir_all(&dir).unwrap();
    let contract = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../testdata/script-env");
    let want = std::fs::read_to_string(contract.join("local.txt"))
        .unwrap()
        .replace("{DIR}", dir.to_str().unwrap())
        .replace("{ROOT}", "/the/root");
    let variables = script::local_variables("contract", &dir, Path::new("/the/root"));
    let path = contract.join("workroom_script");
    let request = in_process(&path, &dir, &variables, plain_shell(&root, ""));

    let (outcome, output) = combined(&request);
    assert!(outcome.passed(), "{outcome:?}");
    assert_eq!(output, want);
}

/// stdout and stderr arrive in one sink, in the order printed, while the script is still running.
#[test]
fn output_streams_into_one_sink_while_the_script_runs() {
    let root = scratch("stream");
    let go = root.join("go");
    let path = executable(
        &root.join("workroom_setup"),
        &format!(
            "#!/bin/sh\necho one\necho two >&2\nwhile [ ! -e {} ]; do sleep 0.05; done\necho three\n",
            go.display()
        ),
    );
    let shell = plain_shell(&root, "");
    let (lines, received) = mpsc::channel::<String>();
    let runner = std::thread::spawn(move || {
        struct Sink(mpsc::Sender<String>);
        impl Write for Sink {
            fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
                let _ = self.0.send(String::from_utf8_lossy(data).into_owned());
                Ok(data.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let request = in_process(&path, &root, &[], shell);
        let mut sink = Sink(lines);
        script::run(&request, Output::Combined(&mut sink), |reason| {
            format!("fallback {reason}\n")
        })
    });
    let mut seen = String::new();
    let by = Instant::now() + Duration::from_secs(10);
    while seen != "one\ntwo\n" && Instant::now() < by {
        if let Ok(piece) = received.recv_timeout(Duration::from_millis(100)) {
            seen.push_str(&piece);
        }
    }
    assert_eq!(seen, "one\ntwo\n", "the output came only at exit");
    assert!(!runner.is_finished());
    std::fs::write(&go, "").unwrap();
    let outcome = runner.join().unwrap();
    assert!(outcome.passed(), "{outcome:?}");
    seen.extend(received.try_iter());
    assert_eq!(seen, "one\ntwo\nthree\n");
}

#[test]
fn a_failing_script_fails_with_its_output_kept() {
    let root = scratch("failure");
    let path = executable(
        &root.join("workroom_teardown"),
        "#!/bin/sh\necho I failed\nexit 3\n",
    );
    let request = in_process(&path, &root, &[], plain_shell(&root, ""));

    let (outcome, output) = combined(&request);
    assert!(!outcome.passed());
    assert_eq!(outcome.exit_code(), 3);
    assert_eq!(output, "I failed\n");
}

/// No script means nothing is about to run in that clone, so its rc-visible config isn't read.
#[test]
fn a_missing_script_passes_and_starts_no_login_shell() {
    let root = scratch("missing");
    let started = root.join("started");
    let shell = plain_shell(&root, &format!("touch {}\n", started.display()));
    let path = root.join("workroom_setup");
    let request = in_process(&path, &root, &[], shell);

    let (outcome, output) = combined(&request);
    assert!(matches!(outcome, Outcome::Absent), "{outcome:?}");
    assert!(outcome.passed());
    assert_eq!(output, "");
    assert!(!started.exists(), "the login shell started");
}

/// A script that can't start (here, no execute bit) is the script's failure, setup or teardown.
#[test]
fn a_script_that_cannot_start_is_not_started() {
    let root = scratch("noexec");
    let path = root.join("workroom_setup");
    std::fs::write(&path, "#!/bin/sh\necho hi\n").unwrap();
    let request = in_process(&path, &root, &[], plain_shell(&root, ""));

    let (outcome, output) = combined(&request);
    assert!(matches!(outcome, Outcome::NotStarted(_)), "{outcome:?}");
    assert!(!outcome.passed());
    assert_eq!(outcome.exit_code(), 126);
    assert_eq!(output, "");
}

/// The fallback note goes to the log, ahead of the script's own output.
#[test]
fn a_login_shell_that_fails_is_noted_in_the_log_and_the_script_still_runs() {
    let root = scratch("fallback");
    let path = printing(&root, "ran");
    let request = in_process(&path, &root, &[], plain_shell(&root, "exit 3\n"));

    let (outcome, output) = combined(&request);
    assert!(outcome.passed(), "{outcome:?}");
    assert_eq!(
        output,
        "workroom: couldn't read the login shell's environment (nonZeroExit); using the current one\nran\n"
    );
}

/// A background job the script left holding the pipe doesn't hold the run.
#[test]
fn a_background_job_holding_the_output_does_not_hold_the_run() {
    let root = scratch("background");
    let path = executable(
        &root.join("workroom_setup"),
        "#!/bin/sh\necho done\nsleep 30 &\n",
    );
    let request = in_process(&path, &root, &[], plain_shell(&root, ""));

    let started = Instant::now();
    let (outcome, output) = combined(&request);
    assert!(outcome.passed(), "{outcome:?}");
    assert_eq!(output, "done\n");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "took {:?}",
        started.elapsed()
    );
}

/// The wall clock, when given one, ends the tree, as `run-script`'s does. The script blocks until
/// the clock releases it, and has the whole 3 s clock to record its child.
#[test]
fn the_wall_clock_ends_an_in_process_run() {
    let root = scratch("clock");
    let pidfile = root.join("child.pid");
    let path = executable(
        &root.join("workroom_setup"),
        &format!(
            "#!/bin/sh\nsleep 60 &\necho $! > {}\nwait\n",
            pidfile.display()
        ),
    );
    let mut request = in_process(&path, &root, &[], plain_shell(&root, ""));
    request.timeout = Some(Duration::from_secs(3));
    request.kill_grace = Duration::from_millis(200);

    let (outcome, _) = combined(&request);
    assert!(matches!(outcome, Outcome::TimedOut), "{outcome:?}");
    assert_eq!(outcome.exit_code(), 124);
    let child: i32 = std::fs::read_to_string(&pidfile)
        .ok()
        .and_then(|pid| pid.trim().parse().ok())
        .expect("the script to record its child within the 3 s clock");
    wait_for("the script's child to end", || !alive(child));
}

// Through `run-script`, whose environment and signals are its own.

/// Killed when the test ends, panic or not.
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

fn wait_for(what: &str, done: impl Fn() -> bool) {
    let by = Instant::now() + Duration::from_secs(5);
    while !done() {
        assert!(Instant::now() < by, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// bash as the user's shell, with `profile` as its login profile in a fresh HOME.
fn run_script(root: &Path, profile: &str, script: &Path, dir: &Path) -> Command {
    run_script_within(root, profile, script, dir, "60")
}

fn run_script_within(
    root: &Path,
    profile: &str,
    script: &Path,
    dir: &Path,
    timeout: &str,
) -> Command {
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join(".bash_profile"), profile).unwrap();
    let mut command = Command::new(binary());
    command
        .args(["run-script", "--dir"])
        .arg(dir)
        .args(["--timeout", timeout, "--"])
        .arg(script)
        .env("HOME", &home)
        .env("SHELL", "/bin/bash");
    command
}

/// An rc that takes the shell over, ends it or fails must not cost the script its run: run through
/// the shell, these would skip it and report success. The script runs with the caller's
/// environment and the log says why.
#[test]
fn the_script_still_runs_when_the_login_shell_misbehaves() {
    let cases = [
        ("exec /usr/bin/true\n", "noMarkers"),
        ("exit 0\n", "noMarkers"),
        ("exit 3\n", "nonZeroExit"),
        ("sleep 30\n", "timedOut"),
        // `env` isn't found, so nothing is printed between the markers, which Go called noPath.
        ("unset PATH\n", "noMarkers"),
        (
            "export PATH=\nenv() { unset PATH; command /usr/bin/env \"$@\"; }\n",
            "noPath",
        ),
        ("head -c 2097152 /dev/zero\n", "noMarkers"),
    ];
    let runs: Vec<_> = cases
        .iter()
        .enumerate()
        .map(|(index, (profile, reason))| {
            let root = scratch(&format!("misbehaves-{index}"));
            let script = printing(&root, "ran with $FROM_THE_CALLER");
            let child = run_script(&root, profile, &script, &root)
                .env("FROM_THE_CALLER", "kept")
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            (profile, reason, child, root)
        })
        .collect();
    for (profile, reason, child, _root) in runs {
        let output = child.wait_with_output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(0), "{profile:?}: {stderr}");
        assert!(
            stdout.ends_with("ran with kept\n"),
            "{profile:?}: {stdout:?}"
        );
        assert!(
            stderr.contains(&format!(
                "workroomd run-script: couldn't read the login shell's environment ({reason}); using the daemon's own"
            )),
            "{profile:?}: {stderr:?}"
        );
    }
}

/// A shell that doesn't take -lic gets a login /bin/sh, as a fish user's does.
#[test]
fn an_unknown_shell_reads_a_login_sh() {
    let root = scratch("fish");
    let script = printing(&root, "profile=$FROM_PROFILE");
    let mut command = run_script(&root, "", &script, &root);
    std::fs::write(root.join("home/.profile"), "export FROM_PROFILE=yes\n").unwrap();
    let output = command.env("SHELL", "/nonexistent/fish").output().unwrap();
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "profile=yes\n");
}

#[test]
fn the_login_shells_own_output_stays_out_of_the_log() {
    let root = scratch("quiet");
    let script = printing(&root, "ran");
    let output = run_script(
        &root,
        "echo welcome to this machine\necho on stderr >&2\n",
        &script,
        &root,
    )
    .output()
    .unwrap();
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "ran\n");
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
}

/// git can't prompt or take optional locks, whatever an rc exports.
#[test]
fn git_stays_unable_to_prompt_whatever_an_rc_says() {
    let root = scratch("git");
    let script = printing(&root, "$GIT_TERMINAL_PROMPT$GIT_OPTIONAL_LOCKS");
    let output = run_script(
        &root,
        "export GIT_TERMINAL_PROMPT=1 GIT_OPTIONAL_LOCKS=1\n",
        &script,
        &root,
    )
    .env_remove("GIT_TERMINAL_PROMPT")
    .env_remove("GIT_OPTIONAL_LOCKS")
    .output()
    .unwrap();
    assert_eq!(String::from_utf8_lossy(&output.stdout), "00\n");
}

#[test]
fn the_login_shells_path_comes_first_and_the_callers_is_kept() {
    let root = scratch("path");
    let script = printing(&root, "$PATH");
    let caller = format!(
        "/only/the/caller:{}",
        std::env::var("PATH").unwrap_or_default()
    );
    let output = run_script(
        &root,
        "export PATH=/selected/for/workroom:$PATH\n",
        &script,
        &root,
    )
    .env("PATH", caller)
    .output()
    .unwrap();
    let path = String::from_utf8_lossy(&output.stdout).into_owned();
    assert!(path.starts_with("/selected/for/workroom:"), "{path}");
    assert!(path.contains(":/only/the/caller:"), "{path}");
}

/// A signal mid-read ends the shell, which has a session of its own and so isn't reached by a
/// terminal's Ctrl-C, and starts no script.
#[test]
fn a_signal_while_the_login_shell_is_read_ends_it_and_runs_no_script() {
    for signal in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT] {
        let root = scratch(&format!("probe-signal-{signal}"));
        let pidfile = root.join("shell.pid");
        let ran = root.join("ran");
        let script = executable(
            &root.join("workroom_setup"),
            &format!("#!/bin/sh\ntouch {}\n", ran.display()),
        );
        let profile = format!("echo $$ > {}\nsleep 30\n", pidfile.display());
        let mut run = Spawned(
            run_script(&root, &profile, &script, &root)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        wait_for("the shell to start", || {
            std::fs::read_to_string(&pidfile).is_ok_and(|pid| pid.trim().parse::<i32>().is_ok())
        });
        let shell: i32 = std::fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let sent = Instant::now();
        // SAFETY: `kill` takes no pointers.
        unsafe { libc::kill(run.0.id() as i32, signal) };
        let status = run.0.wait().unwrap();
        assert_eq!(status.code(), Some(128 + signal));
        assert!(
            sent.elapsed() < Duration::from_secs(3),
            "took {:?}",
            sent.elapsed()
        );
        wait_for("the shell to end", || !alive(shell));
        assert!(!ran.exists(), "the script ran after the cancel");
    }
}

/// A background shell job inherits an ignored SIGINT, and nohup an ignored SIGHUP. Ignored, they
/// aren't a cancel: the read and the script carry on as if nothing had been sent. The profile
/// waits for the test to send the signal, so it lands while the login shell is read.
#[test]
fn a_signal_ignored_at_start_is_no_cancel() {
    for (name, signal) in [("INT", libc::SIGINT), ("HUP", libc::SIGHUP)] {
        let root = scratch(&format!("ignored-{name}"));
        let pidfile = root.join("shell.pid");
        let sent = root.join("sent");
        let script = printing(&root, "read=$READ_FINISHED");
        let profile = format!(
            "echo $$ > {}\nwhile [ ! -e {} ]; do sleep 0.05; done\nexport READ_FINISHED=yes\n",
            pidfile.display(),
            sent.display()
        );
        let mut command = ignoring(name, &run_script(&root, &profile, &script, &root));
        let mut run = Spawned(command.stdout(Stdio::piped()).spawn().unwrap());
        wait_for("the shell to start", || pidfile.exists());
        // SAFETY: `kill` takes no pointers.
        unsafe { libc::kill(run.0.id() as i32, signal) };
        std::fs::write(&sent, "").unwrap();
        let stdout = run.0.stdout.take().unwrap();
        let status = run.0.wait().unwrap();
        let printed = std::io::read_to_string(stdout).unwrap();
        assert_eq!(status.code(), Some(0), "{name}");
        assert_eq!(printed, "read=yes\n", "{name}");
    }
}

/// Once the script runs, an ignored signal ends it as any other does, as both runners had it.
#[test]
fn a_signal_ignored_at_start_still_ends_the_script() {
    let root = scratch("ignored-script");
    let started = root.join("started");
    let script = executable(
        &root.join("workroom_setup"),
        &format!("#!/bin/sh\ntouch {}\nsleep 60\n", started.display()),
    );
    let mut command = ignoring("INT", &run_script(&root, "", &script, &root));
    let mut run = Spawned(command.stdout(Stdio::null()).spawn().unwrap());
    wait_for("the script to start", || started.exists());
    // SAFETY: `kill` takes no pointers.
    unsafe { libc::kill(run.0.id() as i32, libc::SIGINT) };
    assert_eq!(run.0.wait().unwrap().code(), Some(128 + libc::SIGINT));
}

/// `inner`, started with signal `name` ignored, as a background job or nohup starts one.
fn ignoring(name: &str, inner: &Command) -> Command {
    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(format!("trap '' {name}; exec \"$0\" \"$@\""))
        .arg(inner.get_program())
        .args(inner.get_args())
        .envs(
            inner
                .get_envs()
                .filter_map(|(key, value)| Some((key, value?))),
        );
    command
}

/// An in-process caller is told it was cancelled and carries on, with its own handling of the
/// signal back: Go's `Run` forwarded and returned, so `create` could still write its result. This
/// test binary, run again for `in_process_child`, is that caller.
#[test]
fn an_in_process_run_is_cancelled_and_its_caller_carries_on() {
    let root = scratch("in-process-cancel");
    let pidfile = root.join("child.pid");
    let mut caller = Spawned(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "in_process_child",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("WR_SCRIPT_RUNNER_CHILD", &*root)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    wait_for("the script to start", || {
        std::fs::read_to_string(&pidfile).is_ok_and(|pid| pid.trim().parse::<i32>().is_ok())
    });
    let child: i32 = std::fs::read_to_string(&pidfile)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // SAFETY: `kill` takes no pointers.
    unsafe { libc::kill(caller.0.id() as i32, libc::SIGTERM) };
    let stdout = caller.0.stdout.take().unwrap();
    let status = caller.0.wait().unwrap();
    let printed = std::io::read_to_string(stdout).unwrap();
    assert!(status.success(), "{status:?}: {printed}");
    assert!(printed.contains("outcome=Cancelled(15)"), "{printed}");
    assert!(printed.contains("restored=default"), "{printed}");
    wait_for("the script's child to end", || !alive(child));
}

#[test]
fn in_process_child() {
    let Some(root) = std::env::var_os("WR_SCRIPT_RUNNER_CHILD").map(PathBuf::from) else {
        return;
    };
    let path = executable(
        &root.join("workroom_setup"),
        &format!(
            "#!/bin/sh\nsleep 60 &\necho $! > {}\nwait\n",
            root.join("child.pid").display()
        ),
    );
    let mut request = in_process(&path, &root, &[], plain_shell(&root, ""));
    request.kill_grace = Duration::from_millis(500);
    let (outcome, _) = combined(&request);
    println!("outcome={outcome:?}");
    // SAFETY: an all-zero sigaction is valid to write into, and a null new action changes nothing.
    let mut current: libc::sigaction = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    unsafe { libc::sigaction(libc::SIGTERM, std::ptr::null(), &mut current) };
    if current.sa_sigaction == libc::SIG_DFL {
        println!("restored=default");
    }
}

/// SIGHUP and SIGINT end the tree as a SIGTERM does (`tests/run_script.rs`).
#[test]
fn a_hangup_or_interrupt_ends_the_scripts_tree() {
    for signal in [libc::SIGHUP, libc::SIGINT] {
        let root = scratch(&format!("tree-{signal}"));
        let pidfile = root.join("child.pid");
        let script = executable(
            &root.join("workroom_setup"),
            &format!(
                "#!/bin/sh\nsleep 60 &\necho $! > {}\nwait\n",
                pidfile.display()
            ),
        );
        let mut run = Spawned(
            run_script(&root, "", &script, &root)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        wait_for("the script to start", || {
            std::fs::read_to_string(&pidfile).is_ok_and(|pid| pid.trim().parse::<i32>().is_ok())
        });
        let child: i32 = std::fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        // SAFETY: `kill` takes no pointers.
        unsafe { libc::kill(run.0.id() as i32, signal) };
        assert_eq!(run.0.wait().unwrap().code(), Some(128 + signal));
        wait_for("the script's child to end", || !alive(child));
    }
}

/// 124 on the wall clock and 126 for a script that can't start, each said on stderr with the
/// prefix the app parses.
#[test]
fn the_wall_clock_and_a_script_that_cannot_start_exit_124_and_126() {
    let root = scratch("codes");
    let slow = executable(&root.join("slow"), "#!/bin/sh\nsleep 60\n");
    let output = run_script_within(&root, "", &slow, &root, "1")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(124));
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        format!(
            "workroomd run-script: {} timed out after 1 s\n",
            slow.display()
        )
    );

    let unrunnable = root.join("unrunnable");
    std::fs::write(&unrunnable, "#!/bin/sh\n").unwrap();
    let output = run_script(&root, "", &unrunnable, &root).output().unwrap();
    assert_eq!(output.status.code(), Some(126));
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        format!(
            "workroomd run-script: {} could not be started: Permission denied (os error 13)\n",
            unrunnable.display()
        )
    );
    let missing = root.join("missing");
    let output = run_script(&root, "", &missing, &root).output().unwrap();
    assert_eq!(output.status.code(), Some(126));
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        format!(
            "workroomd run-script: {} could not be started: No such file or directory (os error 2)\n",
            missing.display()
        )
    );
}

/// `workroom create` in a real terminal: an interactive zsh outside the terminal's foreground
/// group is stopped by SIGTTOU, which only a real controlling terminal shows, so this runs under
/// `script`'s pty.
#[test]
fn the_login_read_is_not_stopped_in_a_real_terminal() {
    if !Path::new("/bin/zsh").exists() && !Path::new("/usr/bin/zsh").exists() {
        eprintln!("skipped: needs zsh, as bash isn't stopped");
        return;
    }
    let zsh = if Path::new("/bin/zsh").exists() {
        "/bin/zsh"
    } else {
        "/usr/bin/zsh"
    };
    let root = scratch("terminal");
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join(".zshrc"), "export SELECTED_FOR=\"$(pwd -P)\"\n").unwrap();
    let dir = root.join("room");
    std::fs::create_dir_all(&dir).unwrap();
    let script = printing(&root, "selected=$SELECTED_FOR");
    let inner = format!(
        "'{}' run-script --dir '{}' --timeout 60 -- '{}'",
        binary().display(),
        dir.display(),
        script.display()
    );
    let mut command = Command::new("script");
    if cfg!(target_os = "linux") {
        command.args(["-qec", &inner, "/dev/null"]);
    } else {
        command.args(["-q", "/dev/null", "/bin/sh", "-c", &inner]);
    }
    let started = Instant::now();
    let output = command
        .env("HOME", &home)
        .env("ZDOTDIR", &home)
        .env("SHELL", zsh)
        .stdin(Stdio::null())
        .output();
    let Ok(output) = output else {
        eprintln!("skipped: no `script` to make a terminal with: {output:?}");
        return;
    };
    let printed = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() && !printed.contains("selected=") {
        eprintln!("skipped: no terminal to be had here: {printed}");
        return;
    }
    assert!(
        printed.contains(&format!("selected={}", dir.display())),
        "under a terminal: {printed:?}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(8),
        "the read was stopped: {:?}",
        started.elapsed()
    );
}
