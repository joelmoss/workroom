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

fn value_of(session: &HostSession, name: &str) -> Option<String> {
    session
        .environment
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.to_string_lossy().into_owned())
}

/// The login's PATH is the session's as it came: the daemon's bin folder goes first afterwards,
/// as for every session (`terminal::bin_path`, #695), not here.
#[test]
fn the_logins_path_is_kept_as_it_came() {
    for shell in ["/bin/sh", "/bin/dash", "/bin/bash", "/usr/bin/fish"] {
        let login = pairs(&[("PATH", "/home/u/bin:/usr/bin:/bin"), ("SHELL", shell)]);
        let session = build(&[], Some(&login), &origin(&[], shell), None);
        assert_eq!(session.shell, shell);
        assert_eq!(
            value_of(&session, "PATH").as_deref(),
            Some("/home/u/bin:/usr/bin:/bin"),
            "{shell}"
        );
    }
}

/// Ghostty's `path` feature is off: it would append its folder after the profile, where the bin
/// folder's hooks put the bin folder first.
#[test]
fn ghosttys_path_feature_is_not_asked_for() {
    let scratch = std::env::temp_dir().join(format!("wr-host-session-{}", std::process::id()));
    std::fs::create_dir(&scratch).expect("a scratch folder of this run's own");
    let terminfo = scratch.join("terminfo/x");
    std::fs::create_dir_all(&terminfo).unwrap();
    std::fs::write(terminfo.join(GHOSTTY_TERM), b"compiled").unwrap();
    let client = pairs(&[("TERM", GHOSTTY_TERM)]);
    let login = pairs(&[("PATH", "/usr/bin"), ("SHELL", "/bin/bash")]);
    let session = build(
        &client,
        Some(&login),
        &origin(&[], "/bin/bash"),
        Some(&scratch),
    );
    let _ = std::fs::remove_dir_all(&scratch);
    assert_eq!(
        value_of(&session, "GHOSTTY_SHELL_FEATURES").as_deref(),
        Some(SHELL_FEATURES)
    );
    assert_eq!(value_of(&session, "GHOSTTY_BIN_DIR"), None);
    assert_eq!(value_of(&session, "PATH").as_deref(), Some("/usr/bin"));
}
