//! `replay_…_prefer_an_ancestor` is ported from herdr-core's `resume.rs` tests (see the parent
//! module's header), Licensed under the Apache License, Version 2.0, and changed for Workroom to
//! send real report bodies through `apply`. The rest are Workroom's.

use super::*;
use crate::terminal::process::Identity;

const TOKEN: &str = "private-token";
const NOW: u64 = 1_795_543_200;
const UID: u32 = 501;

fn state() -> Resume {
    Resume::with_token(TOKEN.into(), UID)
}

fn owner(pid: u32, start: u64) -> Owner {
    Owner { pid, start }
}

fn b64(text: &str) -> String {
    crate::util::base64(text.as_bytes())
}

/// A report body from `pid` at `time`, authenticated with `TOKEN`.
fn body(pid: u32, time: u64, fields: &str) -> Vec<u8> {
    let body = format!("pid={pid}:time={time}:{fields}");
    format!("{body}:mac={}", protocol::mac(body.as_bytes(), TOKEN)).into_bytes()
}

fn argv(words: &[&str]) -> String {
    format!(
        "argv={}",
        words.iter().map(|w| b64(w)).collect::<Vec<_>>().join(",")
    )
}

fn checked(owner: Owner, ancestors: &[Owner]) -> Result<Checked, NotOwner> {
    Ok(Checked {
        owner,
        ancestors: ancestors.to_vec(),
        cwd: Some("/owner/folder".into()),
    })
}

fn set(state: &mut Resume, offset: u64, time: u64, owner: Owner, ancestors: &[Owner]) -> bool {
    let body = body(owner.pid, time, &argv(&["private-command"]));
    matches!(
        state.apply(offset, &body, time, |_| checked(owner, ancestors)),
        Outcome::Accepted { .. }
    )
}

fn chosen(state: &Resume) -> Option<Owner> {
    state.choice().map(|record| record.owner)
}

#[test]
fn replay_preserves_the_last_word_and_related_owners_prefer_an_ancestor() {
    let mut s = state();
    let (parent, child, other) = (owner(1, 1), owner(2, 2), owner(3, 3));
    let clear = || body(1, 60, "clear=1");
    assert!(set(&mut s, 10, 60, parent, &[]));
    assert!(set(&mut s, 20, 60, child, &[parent]));
    assert_eq!(chosen(&s), Some(parent));
    assert!(set(&mut s, 30, 60, other, &[]));
    assert_eq!(chosen(&s), Some(other));
    let rejected = body(3, 60, "argv=");
    assert_eq!(
        s.apply(40, &rejected, 60, |_| unreachable!()),
        Outcome::NotAccepted {
            reason: "malformed",
            program: None
        }
    );
    assert_eq!(chosen(&s), Some(parent));
    assert_eq!(
        s.apply(50, &clear(), 60, |_| unreachable!()),
        Outcome::Cleared
    );
    assert!(
        !set(&mut s, 10, 60, parent, &[]),
        "the tail repeats an already consumed report"
    );
    assert_ne!(
        s.apply(50, &clear(), 60, |_| unreachable!()),
        Outcome::Cleared,
        "it repeats the clear too"
    );
    assert!(
        !set(&mut s, 60, 59, parent, &[]),
        "older time is ignored even when emitted later"
    );
    assert_eq!(chosen(&s), Some(child));
    let reused = owner(1, 70);
    assert!(
        set(&mut s, 70, 60, reused, &[]),
        "new reports in the same second still apply"
    );
    assert!(set(&mut s, 80, 60, child, &[parent]));
    assert_eq!(chosen(&s), Some(child), "a reused PID is not its ancestor");
}

#[test]
fn an_accepted_report_is_the_sessions_record_without_its_arguments() {
    let mut s = state();
    let claude = owner(40, 4);
    let report = body(
        40,
        NOW,
        &format!(
            "{}:cwd={}",
            argv(&["claude", "--resume", "1b8f…", "--model", "opus"]),
            b64("/work/calm-dune")
        ),
    );
    assert_eq!(
        s.apply(100, &report, NOW, |_| checked(claude, &[])),
        Outcome::Accepted {
            program: "claude".into()
        }
    );
    assert_eq!(
        s.recorded(),
        Some(Recorded {
            program: "claude".into(),
            cwd: Some("/work/calm-dune".into()),
            reported_at_ms: NOW * 1000,
        })
    );
    assert!(!format!("{:?}{:?}", s, s.recorded()).contains("--resume"));
}

#[test]
fn a_report_without_a_folder_uses_its_owners() {
    let mut s = state();
    let report = body(41, NOW, &argv(&["nvim", "-S", "/state/session.vim"]));
    s.apply(1, &report, NOW, |_| checked(owner(41, 1), &[]));
    assert_eq!(
        s.recorded().and_then(|recorded| recorded.cwd),
        Some("/owner/folder".into())
    );
}

#[test]
fn reports_that_cannot_be_trusted_change_nothing_and_say_why() {
    let mut s = state();
    assert!(set(&mut s, 1, NOW, owner(7, 1), &[]));
    let mut forged = body(7, NOW, "clear=1");
    let last = forged.len() - 1;
    forged[last] = if forged[last] == b'0' { b'1' } else { b'0' };
    let stale = body(7, NOW - 61, "clear=1");
    for (report, reason) in [(forged, "bad_mac"), (stale, "stale_time")] {
        assert_eq!(
            s.apply(2, &report, NOW, |_| unreachable!()),
            Outcome::NotAccepted {
                reason,
                program: None
            }
        );
    }
    assert_eq!(chosen(&s), Some(owner(7, 1)));
}

#[test]
fn a_report_whose_owner_fails_its_check_is_not_accepted() {
    for (not, reason) in [
        (NotOwner::Gone, "owner_gone"),
        (NotOwner::OtherUser, "other_user"),
        (NotOwner::NotDescendant, "not_descendant"),
    ] {
        let mut s = state();
        let report = body(9, NOW, &argv(&["/usr/bin/lazygit"]));
        assert_eq!(
            s.apply(1, &report, NOW, |_| Err(not)),
            Outcome::NotAccepted {
                reason,
                program: Some("lazygit".into())
            }
        );
        assert_eq!(s.recorded(), None);
    }
}

#[test]
fn a_session_tracks_a_bounded_number_of_owners() {
    let mut s = state();
    for pid in 1..=MAX_OWNERS as u32 {
        assert!(set(&mut s, pid as u64, NOW, owner(pid, 1), &[]));
    }
    let extra = owner(MAX_OWNERS as u32 + 1, 1);
    let report = body(extra.pid, NOW, &argv(&["vim"]));
    assert_eq!(
        s.apply(1_000, &report, NOW, |_| checked(extra, &[])),
        Outcome::NotAccepted {
            reason: "too_many_owners",
            program: Some("vim".into())
        }
    );
}

fn process(pid: u32, start: u64, parent: u32, uid: u32) -> Identity {
    Identity {
        pid,
        start,
        parent,
        uid,
    }
}

#[test]
fn an_owner_must_run_under_the_sessions_first_process_as_the_daemons_user() {
    let table = [
        process(10, 100, 1, UID),  // the shell
        process(20, 200, 10, UID), // claude, under it
        process(30, 300, 20, UID), // its hook
        process(40, 400, 1, UID),  // a process elsewhere
        process(50, 500, 10, 0),   // root's, under the shell
        process(60, 50, 10, UID),  // "older than its parent": a reused pid
    ];
    let lookup = |pid| table.iter().copied().find(|p| p.pid == pid);
    let root = Some(owner(10, 100));
    let ok = check_owner(root, UID, 30, lookup).ok().unwrap();
    assert_eq!(ok.owner, owner(30, 300));
    assert_eq!(ok.ancestors, [owner(20, 200), owner(10, 100)]);
    assert!(
        check_owner(root, UID, 10, lookup).is_ok(),
        "the shell itself"
    );
    for (pid, not) in [
        (40, NotOwner::NotDescendant),
        (50, NotOwner::OtherUser),
        (60, NotOwner::NotDescendant),
        (99, NotOwner::Gone),
    ] {
        assert_eq!(
            check_owner(root, UID, pid, lookup).err(),
            Some(not),
            "{pid}"
        );
    }
    assert_eq!(
        check_owner(None, UID, 20, lookup).err(),
        Some(NotOwner::NotDescendant),
        "no first process known yet"
    );
}

#[test]
fn a_command_names_its_program_past_env() {
    let name =
        |words: &[&str]| program_name(&words.iter().map(|w| w.to_string()).collect::<Vec<_>>());
    assert_eq!(name(&["claude", "--resume", "x"]), "claude");
    assert_eq!(name(&["/opt/homebrew/bin/nvim", "-S", "f"]), "nvim");
    assert_eq!(
        name(&[
            "env",
            "CLAUDE_CONFIG_DIR=/Users/me/.claude-work",
            "claude",
            "--resume",
            "x"
        ]),
        "claude"
    );
    assert_eq!(name(&["/usr/bin/env", "-i", "A=1", "codex"]), "codex");
    assert_eq!(name(&["env"]), "env");
}

#[test]
fn a_hand_off_carries_the_token_records_and_stream_position() {
    let mut s = state();
    s.root = Some(owner(10, 100));
    let mut stream = Vec::new();
    stream.extend_from_slice(b"some output ");
    stream.extend_from_slice(protocol::OPEN);
    stream.extend_from_slice(&body(10, unix_now(), &argv(&["vim"])));
    stream.push(7);
    // The shell is not a real process here, so the owner check fails, but the report is still
    // read and its offset kept.
    s.feed(&stream);
    let carried = s.carried();
    let json = serde_json::to_vec(&carried).unwrap();
    let back: Carried = serde_json::from_slice(&json).unwrap();
    assert_eq!(back, carried);
    let adopted = Resume::adopted(back);
    assert_eq!(adopted.token(), TOKEN);
    assert_eq!(adopted.stream.offset, stream.len() as u64);
    assert_eq!(format!("{carried:?}"), "Carried([private])");
}

#[test]
fn a_new_shell_gets_its_own_token_in_place_of_a_forwarded_one() {
    let forwarded = || {
        vec![
            (OsString::from("PATH"), OsString::from("/usr/bin")),
            (
                OsString::from(TOKEN_VARIABLE),
                OsString::from("the-other-panes"),
            ),
        ]
    };
    let tokens = |environment: &[(OsString, OsString)]| {
        environment
            .iter()
            .filter(|(key, _)| key == TOKEN_VARIABLE)
            .map(|(_, value)| value.clone())
            .collect::<Vec<_>>()
    };
    let mut command = forwarded();
    give_token(&mut command, false);
    assert!(
        tokens(&command).is_empty(),
        "a run or one-off command gets none"
    );
    let mut shell = forwarded();
    give_token(&mut shell, true);
    let given = tokens(&shell);
    // A daemon running as root gives none (as a Linux CI container may).
    if daemon_user().is_some() {
        assert_eq!(given.len(), 1);
        assert_ne!(given[0], "the-other-panes");
        assert_eq!(given[0].len(), 32);
        let resume = Resume::for_session(&shell).expect("a state for the token");
        assert_eq!(resume.token(), given[0].to_str().unwrap());
    } else {
        assert!(given.is_empty());
    }
}
