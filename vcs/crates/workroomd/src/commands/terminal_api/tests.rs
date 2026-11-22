use super::*;

/// A wait is given its own timeout and `TIMEOUT` more, or none when it has none, by `wait` and
/// `api call terminal.wait` alike; every other method, and a `timeout_ms` the daemon refuses at
/// once, gets `TIMEOUT`. Tested here rather than by a wait that outlasts `TIMEOUT`.
#[test]
fn a_wait_is_read_for_as_long_as_it_may_take() {
    let wait = |params: Value| answer_timeout("terminal.wait", &params);
    assert_eq!(
        wait(json!({"target": "x", "ended": true, "timeout_ms": 60_000})),
        Some(Duration::from_secs(70))
    );
    assert_eq!(wait(json!({"target": "x", "timeout_ms": 0})), Some(TIMEOUT));
    assert_eq!(wait(json!({"target": "x", "ended": true})), None);
    assert_eq!(wait(json!({"target": "x", "timeout_ms": null})), None);
    assert_eq!(
        wait(json!({"timeout_ms": u64::MAX})),
        Duration::from_millis(u64::MAX).checked_add(TIMEOUT)
    );
    for refused in [json!(-1), json!(1.5), json!("30s")] {
        assert_eq!(wait(json!({"timeout_ms": refused})), Some(TIMEOUT));
    }
    for method in ["session.list", "terminal.capture", "api.describe"] {
        assert_eq!(
            answer_timeout(method, &json!({"timeout_ms": 60_000})),
            Some(TIMEOUT)
        );
    }
}

/// A command (#691) types first, as a send does, and then waits, as a wait does: it is read for
/// its own timeout, the send's deadline and its grace, and `TIMEOUT` more, or with no limit when
/// it has none; and its request goes in chunks, as a send's does.
#[test]
fn a_command_is_read_for_its_typing_and_its_wait() {
    let command = |params: Value| answer_timeout(COMMAND, &params);
    let typing = crate::terminal::api::SEND_DEADLINE + crate::terminal::api::SEND_DEADLINE_GRACE;
    assert_eq!(
        command(json!({"target": "x", "command": "ls", "timeout_ms": 60_000})),
        Some(Duration::from_secs(60) + typing + TIMEOUT)
    );
    assert_eq!(command(json!({"target": "x", "command": "ls"})), None);
    assert_eq!(
        command(json!({"timeout_ms": u64::MAX})),
        Some(Duration::from_millis(u64::MAX) + typing + TIMEOUT)
    );
    assert_eq!(command(json!({"timeout_ms": "1m"})), Some(TIMEOUT));
    assert_eq!(max_request(COMMAND), crate::daemon::rpc::MAX_REQUEST);
}

/// A prompt types as a send does, so it is read for a send's time; with `wait`, for that and its
/// own timeout more, or with none, without a limit (#692).
#[test]
fn a_prompt_is_read_for_its_typing_and_its_wait() {
    let typing = crate::terminal::api::SEND_DEADLINE + crate::terminal::api::SEND_DEADLINE_GRACE;
    let prompt = |params: Value| answer_timeout("terminal.prompt", &params);
    assert_eq!(
        prompt(json!({"target": "x", "text": "hi"})),
        Some(typing + TIMEOUT)
    );
    assert_eq!(
        prompt(json!({"target": "x", "text": "hi", "wait": true, "timeout_ms": 60_000})),
        Some(Duration::from_secs(60) + typing + TIMEOUT)
    );
    assert_eq!(
        prompt(json!({"target": "x", "text": "hi", "wait": true})),
        None
    );
    assert_eq!(max_request(PROMPT), crate::daemon::rpc::MAX_REQUEST);
}

fn argv(arguments: &[&str]) -> Vec<String> {
    arguments
        .iter()
        .map(|argument| argument.to_string())
        .collect()
}

/// A daemon serving a socket names it, however it was started and whatever follows; a hand-off
/// keeps its arguments and adds its table.
#[test]
fn a_daemon_serving_a_socket_names_it() {
    for daemon in [
        &["/x/workroomd", "serve", "--socket", "/run/w/workroomd.sock"][..],
        &[
            "/Applications/Workroom.app/Contents/MacOS/workroomd",
            "serve",
            "--socket",
            "/Users/me/Library/Application Support/w/sessions/workroomd",
            "--handoff",
            "/tmp/table",
        ],
        &[
            "workroom",
            "serve",
            "--idle-timeout",
            "never",
            "--socket",
            "/run/w/workroomd.sock",
        ],
    ] {
        assert_eq!(
            served_socket(&argv(daemon)).as_deref(),
            Some(daemon[daemon.iter().position(|a| *a == "--socket").unwrap() + 1]),
            "{daemon:?}"
        );
    }
}

/// Anything else names none: another command, a daemon on stdio, a socket flag with no path, and
/// another program taking a daemon's arguments.
#[test]
fn anything_but_a_daemon_serving_a_socket_names_none() {
    for other in [
        &["/bin/zsh", "-l"][..],
        &["/usr/bin/devserver", "serve", "--socket", "/tmp/dev.sock"],
        &["/x/workroomd-helper", "serve", "--socket", "/tmp/dev.sock"],
        &[
            "/x/workroomd",
            "attach",
            "--socket",
            "/run/w/workroomd.sock",
        ],
        &["/x/workroomd", "relay", "--socket", "/run/w/workroomd.sock"],
        &["/x/workroomd", "serve", "--stdio"],
        &["/x/workroomd", "serve", "--socket"],
        &["serve", "--socket", "/a.sock"],
        &[],
    ] {
        assert_eq!(served_socket(&argv(other)), None, "{other:?}");
    }
}

/// `new`'s daemon on a Mac is where the app keeps it (`PersistentSessionPaths.daemonSocket`):
/// Application Support's `<bundle>/sessions/workroomd`, or the app's `/tmp` folder when that is
/// past `sun_path`, and the name before #525 under either. Never a path past `sun_path`.
#[test]
fn new_finds_the_macs_daemon_where_the_app_keeps_it() {
    let short = mac_daemon_socket("/Users/me", "com.developwithstyle.workroom.dev", 501);
    assert_eq!(
        short,
        MacDaemonSocket {
            standard: "/Users/me/Library/Application Support/com.developwithstyle.workroom.dev/\
                       sessions/workroomd"
                .into(),
            candidates: vec![
                "/Users/me/Library/Application Support/com.developwithstyle.workroom.dev/\
                 sessions/workroomd"
                    .into(),
                "/tmp/workroom-501-com.developwithstyle.workroom.dev/workroomd".into(),
                "/Users/me/Library/Application Support/com.developwithstyle.workroom.dev/\
                 sessions/agent.sock"
                    .into(),
                "/tmp/workroom-501-com.developwithstyle.workroom.dev/agent.sock".into(),
            ],
        }
    );
    let long_home = format!("/Users/{}", "m".repeat(60));
    let long = mac_daemon_socket(&long_home, "com.developwithstyle.workroom", 502);
    assert_eq!(
        long.standard,
        "/tmp/workroom-502-com.developwithstyle.workroom/workroomd"
    );
    assert!(
        long.candidates
            .iter()
            .all(|path| path.len() < SUN_PATH_LIMIT)
    );
    assert_eq!(long.candidates[0], long.standard);
}

/// The bundle id of the app a binary is in, from `Contents/Resources/<binary>`'s
/// `Contents/Info.plist`; none for a binary outside an app's resources.
#[test]
fn new_reads_its_apps_bundle_id_from_the_info_plist() {
    let plist = "<?xml version=\"1.0\"?>\n<plist><dict>\n\t<key>CFBundleName</key>\n\t\
                 <string>Workroom</string>\n\t<key>CFBundleIdentifier</key>\n\t\
                 <string>com.developwithstyle.workroom.nightly</string>\n</dict></plist>";
    assert_eq!(
        plist_string(plist, "CFBundleIdentifier").as_deref(),
        Some("com.developwithstyle.workroom.nightly")
    );
    assert_eq!(plist_string(plist, "CFBundleVersion"), None);
    assert_eq!(
        plist_string(
            "<key>CFBundleIdentifier</key><integer>1</integer>",
            "CFBundleIdentifier"
        ),
        None
    );
    assert_eq!(bundle_of(Path::new("/usr/local/bin/workroom")), None);
    assert_eq!(
        bundle_of(Path::new("/nonexistent/W.app/Contents/Resources/workroom")),
        None,
        "no Info.plist to read"
    );
}

/// `new` starts a daemon only where this Mac's app keeps its own: a socket `WORKROOM_DAEMON`
/// names, or the daemon above, is asked and never started, whatever the method; and no other
/// method looks for this Mac's daemon at all.
#[test]
fn new_starts_only_this_macs_own_daemon() {
    let local = || {
        Ok(Some(
            "/Users/me/Library/Application Support/b/sessions/workroomd".into(),
        ))
    };
    let never = || -> Result<Option<String>, CliError> { panic!("looked for this Mac's daemon") };
    assert_eq!(
        daemon_to_ask(NEW, Some("/elsewhere.sock".into()), never).ok(),
        Some((Some("/elsewhere.sock".into()), false))
    );
    assert_eq!(
        daemon_to_ask(NEW, None, local).ok(),
        Some((
            Some("/Users/me/Library/Application Support/b/sessions/workroomd".into()),
            true
        ))
    );
    assert_eq!(
        daemon_to_ask(NEW, None, || Ok(None)).ok(),
        Some((None, false))
    );
    assert_eq!(daemon_to_ask(WAIT, None, never).ok(), Some((None, false)));
}

/// The daemon `new` starts is given a login's variables and the locale, and nothing of the
/// script's own.
#[test]
fn a_started_daemon_gets_a_logins_variables_and_nothing_else() {
    let vars = [
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "PATH",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "CLAUDECODE",
        "WORKROOM_PANE",
        "WORKROOM_DAEMON",
        "AWS_SECRET_ACCESS_KEY",
        "TERM",
    ]
    .map(|key| (std::ffi::OsString::from(key), std::ffi::OsString::from("x")));
    let kept: Vec<String> = daemon_environment(vars.into_iter())
        .into_iter()
        .map(|(key, _)| key.to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        kept,
        [
            "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"
        ]
    );
}

/// The app's `/tmp` folder is trusted absent (it is made 0700), or as a real folder this user
/// owns that nobody else can reach; a link, a file or a folder others can reach is refused.
#[test]
fn the_tmp_folder_is_trusted_only_as_this_users_own() {
    use std::os::unix::fs::PermissionsExt;
    let base = std::env::temp_dir().join(format!("wr-693-trust-{}", std::process::id()));
    std::fs::create_dir(&base).expect("a folder of this run's own");
    // SAFETY: `getuid` takes nothing and cannot fail.
    let uid = unsafe { libc::getuid() };
    let own = base.join("own");
    std::fs::create_dir(&own).unwrap();
    std::fs::set_permissions(&own, std::fs::Permissions::from_mode(0o700)).unwrap();
    let open = base.join("open");
    std::fs::create_dir(&open).unwrap();
    std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o777)).unwrap();
    let link = base.join("link");
    std::os::unix::fs::symlink(&own, &link).unwrap();
    let file = base.join("file");
    std::fs::write(&file, b"").unwrap();
    let results = [
        trusted_folder(&base.join("absent"), uid),
        trusted_folder(&own, uid),
        trusted_folder(&open, uid),
        trusted_folder(&link, uid),
        trusted_folder(&file, uid),
        trusted_folder(&own, uid + 1),
    ];
    for path in [&link, &file] {
        std::fs::remove_file(path).unwrap();
    }
    for path in [&own, &open, &base] {
        std::fs::remove_dir(path).unwrap();
    }
    assert_eq!(results[0], Ok(()));
    assert_eq!(results[1], Ok(()));
    assert!(
        results[2].as_ref().is_err_and(|why| why.contains("others")),
        "{results:?}"
    );
    assert!(
        results[3].as_ref().is_err_and(|why| why.contains("link")),
        "{results:?}"
    );
    assert!(
        results[4]
            .as_ref()
            .is_err_and(|why| why.contains("no folder")),
        "{results:?}"
    );
    assert!(
        results[5]
            .as_ref()
            .is_err_and(|why| why.contains("another user")),
        "{results:?}"
    );
}
