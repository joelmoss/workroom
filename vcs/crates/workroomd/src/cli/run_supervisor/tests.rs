use super::*;

fn strings(argv: Vec<OsString>) -> Vec<String> {
    argv.into_iter()
        .map(|arg| arg.into_string().unwrap())
        .collect()
}

/// A POSIX login shell runs the command login and interactive, so the user's rc PATH applies.
#[test]
fn a_posix_shell_runs_the_command_login_and_interactive() {
    let argv = strings(invocation("/s", "npm run dev", "/bin/zsh"));
    assert_eq!(argv[..2], ["/bin/sh", "-c"]);
    assert_eq!(
        argv[3..],
        [
            "workroom-run",
            "/s",
            "/bin/zsh",
            "-lic",
            "exec '/bin/zsh' -c 'npm run dev'"
        ]
    );
}

/// fish, nushell and csh have no trusted `-lic`, so a login `/bin/sh` runs the command.
#[test]
fn another_shell_falls_back_to_a_login_sh() {
    let argv = strings(invocation("/s", "make", "/opt/homebrew/bin/fish"));
    assert_eq!(argv[5..], ["/bin/sh", "-lc", "exec '/bin/sh' -c 'make'"]);
}

/// The command reaches the shell as one word, quotes and all.
#[test]
fn a_quote_in_the_command_survives() {
    let argv = strings(invocation("/s", "echo 'hi'", "/bin/sh"));
    assert_eq!(argv[7], r"exec '/bin/sh' -c 'echo '\''hi'\'''");
}
