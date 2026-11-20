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
