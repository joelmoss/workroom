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
