//! The daemon's credential relay for a local container workroom (#309) against a stand-in for the
//! Mac on loopback, and its git configuration against real git.

#[allow(dead_code)] // not every helper is used here
mod common;
use common::{Workspace, daemon_binary};

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::Path;
use std::process::{Command, Stdio};

use workroomd::credential::{
    CredentialError, configure_git, credential, helper_command, install_relay,
};

/// boxd's two lines as system config, and a stand-in for its helper on PATH (design doc,
/// Phase 0 item 4). Returns what `git credential fill` answers for github.com.
fn fill(workspace: &Path, configure: bool) -> String {
    let system = workspace.join("system.gitconfig");
    std::fs::write(
        &system,
        "[credential \"https://github.com\"]\n\thelper = boxd\n\
         [url \"https://github.com/\"]\n\tinsteadof = git@github.com:\n",
    )
    .unwrap();
    let global = workspace.join("global.gitconfig");
    let _ = std::fs::remove_file(&global);
    std::fs::write(&global, "").unwrap();
    let helper = |name: &str, password: &str| {
        let path = workspace.join(name);
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\ntest \"$1\" = get && printf 'username=u\\npassword={password}\\n'\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        path
    };
    helper("git-credential-boxd", "boxd");
    let workroom = helper("workroom helper", "workroom");

    let path = format!(
        "{}:{}",
        workspace.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let git = || {
        let mut command = Command::new("git");
        command
            .env("GIT_CONFIG_SYSTEM", &system)
            .env("GIT_CONFIG_GLOBAL", &global)
            .env("PATH", &path)
            .env("GIT_TERMINAL_PROMPT", "0");
        command
    };
    if configure {
        let command = helper_command(&workroom).replace(" credential", "");
        configure_git(git, &command).unwrap();
        // Idempotent: a second connect leaves one reset and one helper, not two of each.
        configure_git(git, &command).unwrap();
        let listed = git()
            .args([
                "config",
                "--global",
                "--get-all",
                "credential.https://github.com.helper",
            ])
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8(listed.stdout).unwrap().lines().count(),
            2,
            "the reset and the helper"
        );
    }
    let mut child = git()
        .args(["credential", "fill"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"protocol=https\nhost=github.com\n\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn the_daemons_helper_beats_a_providers_system_helper() {
    let workspace = Workspace::new("credential-git-config");
    assert!(
        fill(&workspace.dir, false).contains("password=boxd"),
        "the control: boxd's helper answers when nothing is configured"
    );
    let answer = fill(&workspace.dir, true);
    assert!(answer.contains("password=workroom"), "{answer}");
}

/// A container's origin is cloned as the Mac has it, and git never asks a helper over ssh, so both
/// ssh forms of a GitHub remote must become HTTPS to reach the relay, while a rewrite the user
/// added under the same key survives every reconnect's reinstall. No system config here: a
/// container image ships no rewrite of its own.
#[test]
fn an_ssh_github_remote_is_rewritten_to_https() {
    let workspace = Workspace::new("credential-instead-of");
    let (system, global) = (
        workspace.dir.join("system.gitconfig"),
        workspace.dir.join("global.gitconfig"),
    );
    std::fs::write(&system, "").unwrap();
    // A rewrite of the user's own under the same key, which the relay must leave alone.
    std::fs::write(
        &global,
        "[url \"https://github.com/\"]\n\tinsteadOf = gh:\n",
    )
    .unwrap();
    let git = || {
        let mut command = Command::new("git");
        command
            .env("GIT_CONFIG_SYSTEM", &system)
            .env("GIT_CONFIG_GLOBAL", &global);
        command
    };
    let url = |remote: &str| {
        let output = git()
            .args(["ls-remote", "--get-url", remote])
            .output()
            .unwrap();
        String::from_utf8(output.stdout).unwrap().trim().to_string()
    };
    let https = "https://github.com/joelmoss/workroom.git";
    let scp = "git@github.com:joelmoss/workroom.git";
    let ssh = "ssh://git@github.com/joelmoss/workroom.git";
    assert_eq!(url(scp), scp, "the control");
    assert_eq!(url(ssh), ssh, "the control");

    configure_git(git, "helper").unwrap();
    configure_git(git, "helper").unwrap();
    assert_eq!(url(scp), https);
    assert_eq!(url(ssh), https);
    assert_eq!(
        url("gh:joelmoss/workroom.git"),
        https,
        "the user's own rewrite went"
    );
    let listed = git()
        .args([
            "config",
            "--global",
            "--get-all",
            "url.https://github.com/.insteadOf",
        ])
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8(listed.stdout).unwrap(),
        "gh:\ngit@github.com:\nssh://git@github.com/\n",
        "one of each, the user's kept"
    );
}

/// A stand-in for the Mac's end of a relay (#309): takes one connection, records what was sent,
/// and answers with `answer`.
fn relay_listener(answer: impl Into<String>) -> (u16, std::thread::JoinHandle<String>) {
    let answer = answer.into();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut sent = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 || line == "\n" {
                break;
            }
            sent.push_str(&line);
        }
        let mut stream = stream;
        stream.write_all(answer.as_bytes()).unwrap();
        sent
    });
    (port, thread)
}

#[test]
fn a_container_workroom_is_answered_through_the_relay() {
    let workspace = Workspace::new("credential-relay");
    let (port, mac) = relay_listener(
        "protocol=https\nhost=github.com\nusername=joel\npassword=gho_mac\nextra=dropped\n",
    );
    install_relay(&workspace.dir, port, "s3cret\n").unwrap();

    let mut output = Vec::new();
    credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\npath=joelmoss/workroom.git\n\n"[..],
        &mut output,
    )
    .unwrap();
    // Only the credential reaches git, and the Mac gets the secret and a github.com request only.
    assert_eq!(
        String::from_utf8(output).unwrap(),
        "username=joel\npassword=gho_mac\n"
    );
    assert_eq!(
        mac.join().unwrap(),
        "s3cret\nprotocol=https\nhost=github.com\n"
    );

    // Nothing but github.com over HTTPS is ever relayed, and `store`/`erase` ask nothing.
    for (action, input) in [
        ("get", &b"protocol=https\nhost=gitlab.com\n\n"[..]),
        (
            "store",
            &b"protocol=https\nhost=github.com\npassword=x\n\n"[..],
        ),
        ("erase", &b"protocol=https\nhost=github.com\n\n"[..]),
    ] {
        let mut output = Vec::new();
        credential(&workspace.dir, action, input, &mut output).unwrap();
        assert!(output.is_empty(), "{action}");
    }
}

#[test]
fn a_relay_the_mac_is_not_listening_on_says_to_open_the_workroom() {
    let workspace = Workspace::new("credential-relay-closed");
    let unused = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    install_relay(&workspace.dir, unused, "s3cret").unwrap();
    let mut output = Vec::new();
    match credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\n\n"[..],
        &mut output,
    ) {
        Err(CredentialError::Unreachable(message)) => {
            assert!(
                message.contains("isn't connected to this workroom"),
                "{message}"
            )
        }
        other => panic!("expected a transport error, got {other:?}"),
    }
    assert!(output.is_empty());

    // Nor is a workroom with no relay.
    let bare = Workspace::new("credential-relay-none");
    assert!(matches!(
        credential(
            &bare.dir,
            "get",
            &b"protocol=https\nhost=github.com\n\n"[..],
            Vec::new()
        ),
        Err(CredentialError::NoRelay)
    ));
}

#[test]
fn a_relay_needs_a_port_and_a_one_word_secret() {
    let workspace = Workspace::new("credential-relay-install");
    for (port, secret) in [(0, "s"), (1, ""), (1, "two words"), (1, "  \n")] {
        assert!(
            install_relay(&workspace.dir, port, secret).is_err(),
            "{port} {secret:?}"
        );
    }
}

/// The relay file holds the secret that tells the Mac which workroom is asking, so it is the daemon
/// user's alone, and the install every connect runs replaces it: the Mac makes a new secret each
/// launch, and a stale one would be refused.
// Value: protects=relay.json stays 0600 and a reinstall replaces its secret; fails_when=the mode
// or the temp-file rename changes; why_new=no test read the file itself; seam=none
#[test]
fn the_relay_file_is_private_and_a_reinstall_replaces_it() {
    use std::os::unix::fs::PermissionsExt;
    let workspace = Workspace::new("credential-relay-file");
    install_relay(&workspace.dir, 1234, "first").unwrap();
    install_relay(&workspace.dir, 1234, "second").unwrap();
    let path = workspace.dir.join("relay.json");
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let contents = std::fs::read_to_string(&path).unwrap();
    assert!(
        contents.contains("second") && !contents.contains("first"),
        "{contents}"
    );
}

/// `get` through the relay with `answer` from the Mac: what git is told, and what reached it.
fn relayed_get(name: &str, answer: impl Into<String>) -> (Result<(), CredentialError>, Vec<u8>) {
    let workspace = Workspace::new(name);
    let (port, mac) = relay_listener(answer);
    install_relay(&workspace.dir, port, "s3cret").unwrap();
    let mut output = Vec::new();
    let result = credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\n\n"[..],
        &mut output,
    );
    mac.join().unwrap();
    (result, output)
}

#[test]
fn a_relay_answer_with_an_error_is_the_error_and_gives_git_nothing() {
    // The credential before the error: the error still wins, and none of it reaches git.
    let (result, output) = relayed_get(
        "credential-relay-error",
        "username=joel\npassword=gho_mac\nerror=the Mac said no\n",
    );
    match result {
        Err(CredentialError::Invalid(message)) => assert_eq!(message, "the Mac said no"),
        other => panic!("expected the Mac's error, got {other:?}"),
    }
    assert!(output.is_empty());
}

#[test]
fn a_relay_answer_without_a_username_and_password_says_to_sign_in_to_gh() {
    for (name, answer) in [
        ("credential-relay-bare", "protocol=https\nhost=github.com\n"),
        ("credential-relay-half", "username=joel\n"),
        ("credential-relay-empty", ""),
    ] {
        let (result, output) = relayed_get(name, answer);
        match result {
            Err(CredentialError::Invalid(message)) => {
                assert!(message.contains("gh auth login"), "{name}: {message}")
            }
            other => panic!("{name}: expected a sign-in error, got {other:?}"),
        }
        assert!(output.is_empty(), "{name}");
    }
}

#[test]
fn a_relay_answer_is_read_only_up_to_the_cap() {
    // 16 KiB is RELAY_MAX: the password and an error sit past it, so neither is ever seen.
    let answer = format!(
        "username=joel\npad={}\npassword=gho_beyond\nerror=beyond\n",
        "a".repeat(16 * 1024)
    );
    let (result, output) = relayed_get("credential-relay-oversized", answer);
    match result {
        Err(CredentialError::Invalid(message)) => {
            assert!(message.contains("gh auth login"), "{message}")
        }
        other => panic!("expected a sign-in error, got {other:?}"),
    }
    assert!(output.is_empty());
}

/// `workroomd credential relay` with a missing or unusable `--port` fails before it touches stdin,
/// the daemon's directory or git config (a valid port would write beside this test binary's daemon).
#[test]
fn credential_relay_without_a_usable_port_fails() {
    for args in [
        &["credential", "relay"][..],
        &["credential", "relay", "--port"],
        &["credential", "relay", "--port", "abc"],
        &["credential", "relay", "--port", "70000"],
        &["credential", "relay", "--port", "-1"],
    ] {
        let output = Command::new(daemon_binary())
            .args(args)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(!output.status.success(), "{args:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("credential relay needs --port"),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
