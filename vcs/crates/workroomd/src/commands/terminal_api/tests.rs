use super::*;

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

/// Anything else names none: another command, a daemon on stdio, a socket flag with no path.
#[test]
fn anything_but_a_daemon_serving_a_socket_names_none() {
    for other in [
        &["/bin/zsh", "-l"][..],
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
