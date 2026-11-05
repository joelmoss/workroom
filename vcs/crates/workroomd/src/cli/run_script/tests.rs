use super::*;
use crate::host::environment::FLOOR_PATH;
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
