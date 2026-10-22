//! The command line an older daemon runs on this binary during a hand-off. An older build (one the
//! app shipped, and every remote host's older install) runs `protocol` to order builds, then
//! `handoff-check <table>`, then execs this binary with its own argv plus `--handoff <table>`. None
//! of that can be rebuilt to match a change here, so these names and the `build-number` line are a
//! frozen contract: the binary and its help text may be renamed, this may not.

mod common;

use std::process::Command;

#[test]
fn protocol_states_the_build_number_an_older_daemon_orders_by() {
    let output = Command::new(common::agent_binary())
        .arg("protocol")
        .output()
        .expect("run protocol");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.lines().any(|line| line.starts_with("protocol ")),
        "no `protocol <n>` line in {stdout:?}"
    );
    let number = stdout
        .lines()
        .find_map(|line| line.strip_prefix("build-number "))
        .unwrap_or_else(|| panic!("no `build-number <n>` line in {stdout:?}"));
    assert!(
        number.trim().parse::<u64>().is_ok(),
        "build-number {number:?} is not a number"
    );
}

#[test]
fn handoff_check_is_a_subcommand() {
    let workspace = common::Workspace::new("contract-check");
    let output = Command::new(common::agent_binary())
        .arg("handoff-check")
        .arg(workspace.dir.join("missing.handoff"))
        .output()
        .expect("run handoff-check");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "a missing table cannot check");
    assert!(
        !stderr.contains("usage:"),
        "handoff-check fell through to the usage text: {stderr}"
    );
}

#[test]
fn serve_takes_the_argv_a_hand_off_execs_it_with() {
    let workspace = common::Workspace::new("contract-serve");
    let output = Command::new(common::agent_binary())
        .args(["serve", "--socket"])
        .arg(workspace.socket())
        .args(["--idle-timeout", "never", "--screens"])
        .arg(workspace.dir.join("screens"))
        .arg("--handoff")
        .arg(workspace.dir.join("missing.handoff"))
        .output()
        .expect("run serve");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "a missing table cannot be adopted");
    assert!(
        stderr.contains("could not take over from the program handed off"),
        "serve did not read --handoff: {stderr}"
    );
}
