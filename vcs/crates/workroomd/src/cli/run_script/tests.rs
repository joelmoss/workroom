use super::*;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("wr-run-script-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// Written by `cp`, not by this process: a test on another thread that forks while this one
/// holds the file open for writing hands the child that descriptor, and running the script
/// then fails on Linux with "Text file busy" (ETXTBSY).
fn script(dir: &Path, name: &str, body: &str, mode: u32) -> PathBuf {
    let path = dir.join(name);
    let draft = dir.join(format!(".{name}.draft"));
    std::fs::write(&draft, body).unwrap();
    assert!(
        Command::new("cp")
            .arg(&draft)
            .arg(&path)
            .status()
            .unwrap()
            .success()
    );
    std::fs::remove_file(&draft).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
    path
}

fn plain_env() -> BTreeMap<String, String> {
    BTreeMap::from([("PATH".to_string(), FLOOR_PATH.to_string())])
}

#[test]
fn the_payload_is_read_between_the_first_pair_of_markers() {
    let data = b"noiseMARKA=1\0B=x=y\0MARKtrailingMARKjunk";
    let parsed = parse_probe_output(data, "MARK").unwrap();
    assert_eq!(parsed.get("A").map(String::as_str), Some("1"));
    assert_eq!(parsed.get("B").map(String::as_str), Some("x=y"));
    assert!(parse_probe_output(b"no markers here", "MARK").is_none());
    assert!(parse_probe_output(b"MARK only one", "MARK").is_none());
}

#[test]
fn merging_drops_the_probes_state_and_puts_the_overrides_on_top() {
    let probed = BTreeMap::from([
        ("PATH".to_string(), "/home/u/bin:/usr/bin".to_string()),
        ("WORKROOM_SHELL_PROBE".to_string(), "1".to_string()),
        ("SHLVL".to_string(), "2".to_string()),
        ("GIT_TERMINAL_PROMPT".to_string(), "1".to_string()),
        ("EDITOR".to_string(), "vim".to_string()),
    ]);
    let merged = merge(probed, "/usr/bin:/bin");
    assert_eq!(merged["PATH"], "/home/u/bin:/usr/bin:/bin");
    assert!(!merged.contains_key("WORKROOM_SHELL_PROBE"));
    assert!(!merged.contains_key("SHLVL"));
    assert_eq!(merged["GIT_TERMINAL_PROMPT"], "0");
    assert_eq!(merged["GIT_OPTIONAL_LOCKS"], "0");
    assert_eq!(merged["EDITOR"], "vim");
}

#[test]
fn a_posix_shell_is_probed_login_and_interactive_and_anything_else_through_sh() {
    assert_eq!(probe_invocation("/usr/bin/zsh"), ("/usr/bin/zsh", "-lic"));
    assert_eq!(probe_invocation("/bin/bash"), ("/bin/bash", "-lic"));
    assert_eq!(probe_invocation("/usr/bin/fish"), ("/bin/sh", "-lc"));
    assert_eq!(probe_invocation(""), ("/bin/sh", "-lc"));
}

/// A fake POSIX shell (named `bash`) that exports a variable and runs the probe's line, as a
/// login shell reading its profile would.
#[test]
fn the_probe_reads_what_the_login_shell_exports() {
    let dir = scratch("probe");
    let shell = script(
        &dir,
        "bash",
        "#!/bin/sh\nexport FROM_PROFILE=yes\necho \"probe=$WORKROOM_SHELL_PROBE\" >&2\nexec /bin/sh -c \"$2\"\n",
        0o755,
    );
    let env = probe(shell.to_str().unwrap(), &dir, PROBE_TIMEOUT).unwrap();
    assert_eq!(env.get("FROM_PROFILE").map(String::as_str), Some("yes"));
    assert_eq!(
        env.get("WORKROOM_SHELL_PROBE").map(String::as_str),
        Some("1")
    );
}

#[test]
fn a_probe_that_hangs_gives_up() {
    let dir = scratch("probe-hang");
    let shell = script(&dir, "zsh", "#!/bin/sh\nsleep 30\n", 0o755);
    let started = Instant::now();
    assert_eq!(
        probe(shell.to_str().unwrap(), &dir, Duration::from_millis(300)),
        Err("timedOut")
    );
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn a_failed_login_read_reports_the_reason_and_uses_the_own_environment() {
    let dir = scratch("probe-fallback");
    let shell = script(&dir, "bash", "#!/bin/sh\nexit 4\n", 0o755);
    let mut reported = None;
    let env = login_environment(shell.to_str().unwrap(), &dir, PROBE_TIMEOUT, |reason| {
        reported = Some(reason.to_string());
    });
    assert_eq!(reported.as_deref(), Some("nonZeroExit"));
    assert_eq!(env, fallback());
}

#[test]
fn a_shell_that_execs_something_else_gives_no_environment() {
    let dir = scratch("probe-exec");
    let shell = script(&dir, "zsh", "#!/bin/sh\nexec true\n", 0o755);
    assert_eq!(
        probe(shell.to_str().unwrap(), &dir, PROBE_TIMEOUT),
        Err("noMarkers")
    );
}

#[test]
fn the_scripts_exit_status_is_passed_through() {
    let dir = scratch("status");
    let path = script(&dir, "workroom_setup", "#!/bin/sh\nexit 3\n", 0o755);
    assert_eq!(
        run(&path, &dir, plain_env(), &[], Duration::from_secs(10)),
        3
    );
    let ok = script(&dir, "ok", "#!/bin/sh\nexit 0\n", 0o755);
    assert_eq!(run(&ok, &dir, plain_env(), &[], Duration::from_secs(10)), 0);
}

#[test]
fn the_script_runs_in_its_directory_with_the_variables_it_was_given() {
    let dir = scratch("env");
    let out = dir.join("out");
    let body = format!(
        "#!/bin/sh\n{{ pwd; echo \"$WORKROOM_NAME\"; echo \"${{WORKROOM_SHELL_PROBE:-unset}}\"; }} > {}\n",
        out.display()
    );
    let path = script(&dir, "workroom_setup", &body, 0o755);
    let extra = vec![("WORKROOM_NAME".to_string(), "jade-crest".to_string())];
    assert_eq!(
        run(&path, &dir, plain_env(), &extra, Duration::from_secs(10)),
        0
    );
    let written = std::fs::read_to_string(out).unwrap();
    let lines: Vec<&str> = written.lines().collect();
    assert_eq!(lines, [dir.to_str().unwrap(), "jade-crest", "unset"]);
}

#[test]
fn a_script_that_cannot_start_is_not_started() {
    let dir = scratch("noexec");
    let path = script(&dir, "workroom_teardown", "#!/bin/sh\nexit 0\n", 0o644);
    assert_eq!(
        run(&path, &dir, plain_env(), &[], Duration::from_secs(10)),
        NOT_STARTED
    );
}

/// The wall clock ends the whole tree, including a grandchild that left the process group.
#[test]
fn the_wall_clock_kills_the_tree_including_a_setsid_escaper() {
    let dir = scratch("timeout");
    let pidfile = dir.join("escaper.pid");
    // The script waits for the escaper's pid before sleeping, and the clock leaves room for
    // perl to start on a loaded CI runner: at 1 s it was sometimes killed before writing it.
    let body = format!(
        "#!/bin/sh\nperl -MPOSIX -e 'POSIX::setsid(); open(my $f, \">\", \"{0}.tmp\"); print $f $$; close($f); rename(\"{0}.tmp\", \"{0}\"); sleep 60' &\nwhile [ ! -s {0} ]; do sleep 0.05; done\nsleep 60\n",
        pidfile.display()
    );
    let path = script(&dir, "workroom_setup", &body, 0o755);
    let started = Instant::now();
    assert_eq!(
        run(&path, &dir, plain_env(), &[], Duration::from_secs(4)),
        TIMED_OUT
    );
    assert!(started.elapsed() < Duration::from_secs(10));
    let pid: i32 = std::fs::read_to_string(&pidfile)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // An orphan is reaped by init a moment after its SIGKILL, so give that a second.
    let gone_by = Instant::now() + Duration::from_secs(1);
    // SAFETY: signal 0 only checks that the pid exists.
    while unsafe { libc::kill(pid, 0) } == 0 && Instant::now() < gone_by {
        std::thread::sleep(Duration::from_millis(20));
    }
    // SAFETY: as above.
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    assert!(!alive, "the setsid grandchild {pid} survived the timeout");
}
