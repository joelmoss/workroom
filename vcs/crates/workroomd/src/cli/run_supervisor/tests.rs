use super::*;

fn strings(argv: Vec<OsString>) -> Vec<String> {
    argv.into_iter()
        .map(|arg| arg.into_string().unwrap())
        .collect()
}

/// A POSIX login shell runs the command login and interactive, so the user's rc PATH applies.
#[test]
fn a_posix_shell_runs_the_command_login_and_interactive() {
    let argv = strings(invocation("/s", "npm run dev", "/bin/zsh", "/w".as_ref()));
    assert_eq!(argv[..2], ["/bin/sh", "-c"]);
    assert_eq!(
        argv[3..],
        [
            "workroom-run",
            "/s",
            "/w",
            "run-supervisor",
            "--child",
            "--",
            "/bin/zsh",
            "-lic",
            "exec '/bin/zsh' -c 'npm run dev'"
        ]
    );
}

/// fish, nushell and csh have no trusted `-lic`, so a login `/bin/sh` runs the command.
#[test]
fn another_shell_falls_back_to_a_login_sh() {
    let argv = strings(invocation(
        "/s",
        "make",
        "/opt/homebrew/bin/fish",
        "/w".as_ref(),
    ));
    assert_eq!(argv[9..], ["/bin/sh", "-lc", "exec '/bin/sh' -c 'make'"]);
}

/// The command reaches the shell as one word, quotes and all.
#[test]
fn a_quote_in_the_command_survives() {
    let argv = strings(invocation("/s", "echo 'hi'", "/bin/sh", "/w".as_ref()));
    assert_eq!(argv[11], r"exec '/bin/sh' -c 'echo '\''hi'\'''");
}

/// `--child --` is the supervisor's child, and only right before the `--`: a run's own command
/// may say anything.
#[test]
fn only_child_dash_dash_is_the_child() {
    let args = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
    let child = args(&[
        "workroomd",
        "run-supervisor",
        "--child",
        "--",
        "sh",
        "-c",
        "x",
    ]);
    assert_eq!(child_argv(&child), Some(&child[4..]));
    let run = args(&[
        "w",
        "run-supervisor",
        "--status",
        "/s",
        "--",
        "--child -- x",
    ]);
    assert_eq!(child_argv(&run), None);
    assert_eq!(
        child_argv(&args(&["w", "run-supervisor", "--child", "--"])),
        None
    );
}

/// The cut every 64th transition keeps the ones the daemon hasn't read yet: a restart that
/// writes `stopping` (63rd), `starting` (64th, the cut) and `running` between two of its reads
/// still leaves `stopping` in the log, and the log stays bounded.
#[test]
fn the_logs_cut_keeps_the_transitions_before_it() {
    let base = std::env::temp_dir();
    let dir = (0..)
        .map(|n| base.join(format!("wr-supervisor-log-{}-{n}", std::process::id())))
        .find(|dir| std::fs::create_dir(dir).is_ok())
        .unwrap();
    let status = dir.join("run.status");
    let start = SUPERVISOR.find("write_status() {").unwrap();
    let end = start + SUPERVISOR[start..].find("\n}\n").unwrap() + 3;
    let script = format!(
        "STATUS='{}'; TRANSITIONS=\"$STATUS.log\"; SEQ=0\n{}\
         i=1; while [ $i -le 62 ]; do write_status \"x $i\"; i=$((i + 1)); done\n\
         write_status stopping; write_status starting; write_status 'running 7'\n",
        status.display(),
        &SUPERVISOR[start..end]
    );
    let ran = std::process::Command::new("/bin/sh")
        .args(["-c", &script])
        .status()
        .unwrap();
    let log = crate::terminal::run::transitions(&status);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(ran.success());
    let log = log.expect("a log");
    let tail: Vec<_> = log.iter().rev().take(3).rev().cloned().collect();
    assert_eq!(
        tail,
        [
            (63, "stopping".to_string()),
            (64, "starting".to_string()),
            (65, "running 7".to_string())
        ]
    );
    assert!(log.len() <= 34, "bounded: {} lines", log.len());
}
