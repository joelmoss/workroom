use super::*;

fn git_repo(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("wr-vcs-exec-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    for args in [
        vec!["init", "-q", "-b", "main"],
        vec!["config", "user.name", "Test"],
        vec!["config", "user.email", "test@example.com"],
    ] {
        assert!(
            Command::new("git")
                .args(args)
                .current_dir(&root)
                .status()
                .unwrap()
                .success()
        );
    }
    root
}

#[test]
fn exec_times_out_and_kills_a_wedged_process_within_the_sigterm_grace() {
    let root = git_repo("timeout");
    let start = Instant::now();
    let captured = run_exec(
        &root,
        "sleep",
        &["30".into()],
        Duration::from_millis(100),
        None,
        &[],
    )
    .unwrap();
    assert!(captured.timed_out);
    assert!(captured.signaled);
    // SIGTERM at 100ms, grace to 2.1s, SIGKILL — must not run anywhere near the full 30s sleep.
    assert!(start.elapsed() < Duration::from_secs(5));
    std::fs::remove_dir_all(&root).unwrap();
}

/// The child's environment is EXACTLY the request's map — nothing of the daemon's own leaks
/// through. This is the property that keeps a daemon-routed commit from being authored under
/// the stale identity of whichever app launch first spawned this daemon; a key allowlist could
/// not provide it, because what git reads for identity, config, signing and hooks is
/// open-ended. `env` (not in the git allowlist) goes through `run_exec` directly, bypassing
/// `exec`'s executable restriction, specifically to observe what reaches the child.
#[test]
fn run_exec_replaces_the_daemons_environment_with_the_requests() {
    // A variable this process already has and the request does not set. Inherited rather than
    // set here: changing the environment of a test process whose other tests run on other
    // threads is unsound, which is why `set_var` is `unsafe` as of edition 2024.
    let request = [
        "PATH",
        "SSH_AUTH_SOCK",
        "GIT_AUTHOR_EMAIL",
        "GIT_CEILING_DIRECTORIES",
    ];
    let (inherited, _) = std::env::vars()
        .find(|(key, _)| !request.contains(&key.as_str()))
        .expect("the test process has a variable the request does not set");
    let root = git_repo("run-exec-env");
    let captured = run_exec(
        &root,
        "env",
        &[],
        Duration::from_secs(5),
        None,
        &[
            ("PATH", "/usr/local/bin:/usr/bin:/bin"),
            ("SSH_AUTH_SOCK", "/tmp/allowed.sock"),
            ("GIT_AUTHOR_EMAIL", "fresh@example.com"),
        ],
    )
    .unwrap();
    let stdout = String::from_utf8_lossy(&captured.stdout);
    assert!(stdout.contains("SSH_AUTH_SOCK=/tmp/allowed.sock"));
    assert!(stdout.contains("GIT_AUTHOR_EMAIL=fresh@example.com"));
    // The daemon's own environment must not reach the child at all.
    let leaked = format!("{inherited}=");
    assert!(
        !stdout.lines().any(|line| line.starts_with(&leaked)),
        "{inherited} reached the child"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

/// The regression that motivated bounding the drain: a child that exits promptly while leaving
/// a BACKGROUND descendant holding its stdout must not hold the exec thread (and with it one of
/// the 32 `ACTIVE` permits) for the descendant's lifetime. Before the bound, this returned in
/// ~4s instead of ~0s, and each occurrence leaked a permit permanently.
#[test]
fn exec_does_not_wait_on_a_descendant_that_outlives_the_child() {
    let root = git_repo("run-exec-straggler");
    let started = Instant::now();
    let captured = run_exec(
        &root,
        "sh",
        &["-c".to_string(), "sleep 5 & echo done; exit 0".to_string()],
        Duration::from_secs(30),
        None,
        &[("PATH", "/usr/bin:/bin")],
    )
    .unwrap();
    let elapsed = started.elapsed();
    assert_eq!(captured.exit_code, 0);
    assert!(!captured.timed_out);
    assert!(String::from_utf8_lossy(&captured.stdout).contains("done"));
    assert!(
        elapsed < Duration::from_secs(4),
        "run_exec waited {elapsed:?} on a background descendant"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

/// Native spawns `/usr/bin/env git`, so a missing tool exits 127 and `CLIVCSWriter.classify`
/// answers `.toolMissing`. Spawning the program directly used to raise an Io error instead,
/// which the client reported as `launchFailed` — the value whose own doc reserves it for
/// "nothing ran" and warns it would "misdiagnose a deleted workroom as a missing git/gh".
#[test]
fn exec_reports_a_missing_tool_as_127_not_a_service_error() {
    let root = git_repo("run-exec-missing");
    let empty = root.join("empty-bin");
    std::fs::create_dir_all(&empty).unwrap();
    let captured = run_exec(
        &root,
        "git",
        &["status".to_string()],
        Duration::from_secs(5),
        None,
        &[("PATH", empty.to_str().unwrap())],
    )
    .unwrap();
    assert_eq!(captured.exit_code, 127);
    assert!(!captured.signaled);
    std::fs::remove_dir_all(&root).unwrap();
}

/// A vanished working directory stays a service error — that IS "nothing ran", and conflating
/// it with 127 is the mirror of the bug above.
#[test]
fn exec_reports_a_vanished_directory_as_an_error_not_127() {
    let root = git_repo("run-exec-gone");
    let missing = root.join("not-there");
    let failed = run_exec(
        &missing,
        "git",
        &["status".to_string()],
        Duration::from_secs(5),
        None,
        &[("PATH", "/usr/bin:/bin")],
    );
    assert!(failed.is_err());
    std::fs::remove_dir_all(&root).unwrap();
}

/// The gap against native, which `ProcessTree.killTree` has covered since it was written ("helpers
/// spawned by git/gh can outlive the parent") and the daemon did not: a DESCENDANT that calls
/// `setsid` leaves the process group, so `kill(-pid, …)` never reaches it. It then goes on
/// running — and, if it inherited the pipes, holding this request's readers open — after the
/// result has released the caller's gate.
///
/// The leader itself cannot escape: `run_exec` sets `process_group(0)`, which makes it a group
/// leader, and `setsid` is EPERM for a group leader. So the descendant is the whole of the gap,
/// and asserting the leader's timing would prove nothing.
///
/// ENVIRONMENT: needs a real process table. Under a sandbox that hides other processes, `pgrep`
/// returns nothing, the snapshot comes back empty and this fails in a way indistinguishable from
/// the bug — measured, not guessed. If it fails, check `wr_exec::descendants` sees anything at all
/// before believing the kill path is broken.
#[test]
fn exec_kills_a_descendant_that_escaped_the_process_group() {
    let root = git_repo("setsid-escape");
    let marker = root.join("still-alive");
    // The grandchild leaves the group, waits out the whole escalation, and only THEN writes.
    // If it is still alive at that point the marker appears, which is the failure this catches.
    let program = format!(
        "import os,sys,time\n\
             if os.fork() == 0:\n\
             \x20   os.setsid()\n\
             \x20   time.sleep(6)\n\
             \x20   open({:?}, 'w').close()\n\
             \x20   sys.exit(0)\n\
             time.sleep(30)\n",
        marker.to_str().unwrap()
    );
    let captured = run_exec(
        &root,
        "python3",
        &["-c".into(), program],
        // Not 100ms: python's own start-up is ~50ms and the fork follows it, so a tighter
        // deadline races the grandchild into existence and the snapshot finds an empty tree —
        // which looks exactly like the bug this asserts against.
        Duration::from_millis(1500),
        None,
        &[("PATH", "/usr/bin:/bin")],
    )
    .unwrap();
    assert!(captured.timed_out, "the timeout was not reported");

    // Past the grandchild's own sleep, so its write would have happened by now if it survived.
    std::thread::sleep(Duration::from_secs(6));
    assert!(
        !marker.exists(),
        "a setsid descendant outlived the kill and kept running"
    );
    std::fs::remove_dir_all(&root).unwrap();
}
