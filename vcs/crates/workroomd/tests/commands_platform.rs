//! The commands that read or write the Mac's config, run on a remote host (ADR 0078): each fails
//! with `MacOnly` and exit 3, and `--help` still lists it, marked "(Mac only)", so `--help` reads
//! the same on the Mac and a host. The real binary, on Linux, as a host runs it; the unit tests in
//! `commands` cover the same rule on any platform.

#[cfg(target_os = "linux")]
mod outside;

use std::path::PathBuf;
use std::process::Command;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_workroom"))
}

#[cfg(target_os = "linux")]
#[test]
fn a_mac_only_command_on_a_host_fails_with_mac_only() {
    for args in [
        &["create", "--json", "--no-editor"][..],
        &["list", "--json"],
        &["ls", "--json"],
        &["base", "set", "main", "--json"],
        // Ported: the gate comes before the branch name is checked or the project resolved.
        &["base", "clear", "--json", "--project", "/nonexistent/x"],
        &["base", "set", "a..b", "--json"],
        &["host", "set", "{}", "--json", "--project", "/nonexistent/x"],
        &["host", "set", "null", "--json"],
        &["host", "clear", "--json", "--workroom", "w"],
        &["add-project", "/tmp/x", "--json"],
        // Ported: the gate comes before the name and confirmation are checked, so nothing is
        // deleted.
        &[
            "delete",
            "calm-river",
            "--json",
            "--confirm",
            "calm-river",
            "--project",
            "/nonexistent/x",
        ],
        &["delete", "--json"],
        // Ported: the gate comes before the arguments and flags are read, so nothing is deleted,
        // and no config is read or written.
        &[
            "delete-project",
            "/nonexistent/x",
            "--json",
            "--confirm",
            "/nonexistent/x",
            "--from-disk",
        ],
        &["claim-provisioned", "--json"],
        // Ported: the gate comes before its own flags are read, and it writes no tar.
        &["include-archive", "--json"],
        &[
            "include-archive",
            "--json",
            "--project",
            "/nonexistent/x",
            "--output",
            "/nonexistent/x.tar",
        ],
    ] {
        // Outside this test's process tree, so a coding agent running the tests is none of its
        // parents: under one, `trust` and `delete` would be `NeedsTheUser` first (#793).
        let mut command = Command::new(binary());
        command
            .args(args)
            .env_clear()
            .stdin(std::process::Stdio::null());
        let output = outside::spawn(command, None).wait_with_output();
        assert_eq!(output.status.code(), Some(3), "{args:?}");
        let envelope: serde_json::Value =
            serde_json::from_slice(&output.stdout).expect("one JSON envelope");
        assert_eq!(envelope["ok"], false, "{args:?}");
        assert_eq!(envelope["error"]["kind"], "MacOnly", "{args:?}");
    }
}

#[test]
fn help_marks_the_mac_only_commands_and_lists_them_everywhere() {
    let output = Command::new(binary())
        .arg("--help")
        .env_clear()
        .output()
        .expect("run workroom --help");
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).expect("UTF-8");
    for name in ["base", "create", "delete", "list", "trust", "untrust"] {
        let line = help
            .lines()
            .find(|line| line.trim_start().starts_with(&format!("{name} ")))
            .unwrap_or_else(|| panic!("{name} isn't in --help:\n{help}"));
        assert!(line.ends_with(" (Mac only)"), "{line:?}");
    }
    for name in ["version", "update", "completion"] {
        assert!(
            help.lines()
                .any(|line| line.trim_start().starts_with(&format!("{name} "))
                    && !line.contains("(Mac only)")),
            "{name} should be listed unmarked:\n{help}"
        );
    }
}

/// `list --socket` stays the daemon's session listing (ADR 0057), which bootstrap reads the exit
/// status of: with no daemon there, it fails, and never as the CLI's workroom list.
#[test]
fn list_with_a_socket_is_still_the_daemons() {
    let socket =
        std::env::temp_dir().join(format!("workroom-no-daemon-{}.sock", std::process::id()));
    let output = Command::new(binary())
        .args(["list", "--socket"])
        .arg(&socket)
        .output()
        .expect("run workroom list --socket");
    assert!(!output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !stdout.contains("\"command\":\"list\""),
        "the CLI answered: {stdout}"
    );
}
