use super::*;

fn pairs(entries: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    entries
        .iter()
        .map(|(k, v)| (OsString::from(k), OsString::from(v)))
        .collect()
}

fn origin(environment: &[(&str, &str)], shell: &str) -> HostOrigin {
    HostOrigin {
        environment: pairs(environment),
        shell: shell.to_string(),
        home: PathBuf::from("/home/u"),
        user: "u".to_string(),
        commands: Some(PathBuf::from("/run/workroom")),
    }
}

fn path_of(session: &HostSession) -> Option<String> {
    session
        .environment
        .iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.to_string_lossy().into_owned())
}

/// Every shell starts with the daemon's folder on its PATH (ADR 0078), sh and dash included, which
/// Ghostty's integration doesn't reach: after the login's entries, once.
#[test]
fn every_shell_starts_with_the_daemons_folder_after_the_logins_path() {
    for shell in ["/bin/sh", "/bin/dash", "/bin/bash", "/usr/bin/fish"] {
        let login = pairs(&[("PATH", "/home/u/bin:/usr/bin:/bin"), ("SHELL", shell)]);
        let session = build(&[], Some(&login), &origin(&[], shell), None);
        assert_eq!(session.shell, shell);
        assert_eq!(
            path_of(&session).as_deref(),
            Some("/home/u/bin:/usr/bin:/bin:/run/workroom"),
            "{shell}"
        );
    }
    let listed = pairs(&[("PATH", "/run/workroom:/usr/bin")]);
    let session = build(&[], Some(&listed), &origin(&[], "/bin/sh"), None);
    assert_eq!(path_of(&session).as_deref(), Some("/run/workroom:/usr/bin"));
}

/// A login with no PATH, or an empty one, gets the standard directories and then the folder: a PATH
/// of the folder alone would leave the shell no `ls`.
#[test]
fn a_login_with_no_path_gets_the_standard_directories_and_the_folder() {
    let want = format!("{}:/run/workroom", crate::host::environment::FLOOR_PATH);
    for login in [
        pairs(&[("PATH", ""), ("SHELL", "/bin/sh")]),
        pairs(&[("SHELL", "/bin/sh")]),
    ] {
        let session = build(&[], Some(&login), &origin(&[], "/bin/sh"), None);
        assert_eq!(path_of(&session).as_deref(), Some(want.as_str()));
    }
    // No login environment at all: the daemon's own, which has none either.
    let session = build(&[], None, &origin(&[("HOME", "/x")], "/bin/sh"), None);
    assert_eq!(path_of(&session).as_deref(), Some(want.as_str()));
}

/// A daemon with no `workroom` beside it leaves the login's PATH as it was.
#[test]
fn a_daemon_without_the_link_changes_no_path() {
    let login = pairs(&[("PATH", "/usr/bin"), ("SHELL", "/bin/sh")]);
    let mut without = origin(&[], "/bin/sh");
    without.commands = None;
    let session = build(&[], Some(&login), &without, None);
    assert_eq!(path_of(&session).as_deref(), Some("/usr/bin"));
}
