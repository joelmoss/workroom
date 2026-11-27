//! `replay_…_prefer_an_ancestor` and `an_owners_exit_gets_a_grace` are ported from herdr-core's
//! `resume.rs` tests (see the parent module's header), Licensed under the Apache License, Version
//! 2.0, and changed for Workroom: the first sends real report bodies through `apply`, and the
//! second runs on a monotonic clock and leaves out the rapid-loss guard. The rest are Workroom's.

use super::*;
use crate::terminal::process::Identity;
use std::sync::{Arc, Mutex};

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
fn a_newer_report_from_its_owner_replaces_the_record_and_a_clear_clears_it() {
    let mut s = state();
    let editor = owner(42, 1);
    for (offset, program) in [(1, "vim"), (2, "nvim")] {
        let report = body(42, NOW, &argv(&[program]));
        s.apply(offset, &report, NOW, |_| checked(editor, &[]));
        assert_eq!(s.recorded().map(|r| r.program), Some(program.into()));
    }
    let clear = body(42, NOW, "clear=1");
    assert_eq!(
        s.apply(3, &clear, NOW, |_| unreachable!()),
        Outcome::Cleared
    );
    assert_eq!(s.recorded(), None);
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
fn an_owners_exit_gets_a_grace() {
    let mut s = state();
    let (owner, t0) = (owner(1, 1), Instant::now());
    let at = |ms| t0 + Duration::from_millis(ms);
    set(&mut s, 10, 60, owner, &[]);
    assert_eq!(s.check_exit(owner, true, t0), Exit::Gone);
    assert_eq!(s.check_exit(owner, true, at(1_999)), Exit::Unchanged);
    assert!(s.choice().is_some(), "loss during the grace can resume");
    assert_eq!(
        s.check_exit(owner, true, at(2_000)),
        Exit::Cleared {
            program: "private-command".into()
        }
    );
    assert!(s.choice().is_none());
    assert!(
        !set(&mut s, 10, 60, owner, &[]),
        "the owner's word stays, so its report is still a replay"
    );
}

#[test]
fn an_owner_back_within_its_grace_starts_it_again_and_another_owners_record_is_left_alone() {
    let mut s = state();
    let (first, t0) = (owner(1, 1), Instant::now());
    let at = |ms| t0 + Duration::from_millis(ms);
    set(&mut s, 10, 60, first, &[]);
    assert_eq!(s.check_exit(first, true, t0), Exit::Gone);
    assert_eq!(s.check_exit(first, false, at(1_000)), Exit::Back);
    assert_eq!(s.check_exit(first, true, at(2_500)), Exit::Gone);
    assert_eq!(s.check_exit(first, true, at(4_000)), Exit::Unchanged);
    // Its pid reused by a program that reported: the look at the first owner changes nothing.
    let reused = owner(1, 70);
    assert!(set(&mut s, 20, 60, reused, &[]));
    assert_eq!(s.check_exit(first, true, at(9_000)), Exit::Unchanged);
    assert_eq!(chosen(&s), Some(reused));
}

/// A session whose first process is `shell`, with a record owned by `owner`, shared as a session
/// holds it.
fn shared_with(shell: Owner, owner: Owner) -> SharedResume {
    let mut s = state();
    s.root = Some(shell);
    assert!(set(&mut s, 10, NOW, owner, &[shell]));
    Arc::new(Mutex::new(Some(s)))
}

fn recorded(shared: &SharedResume) -> bool {
    shared
        .lock()
        .unwrap()
        .as_ref()
        .unwrap()
        .recorded()
        .is_some()
}

#[test]
fn a_record_clears_once_its_owner_has_been_gone_for_the_grace_while_the_shell_runs_on() {
    let (shell, claude, t0) = (owner(10, 100), owner(20, 200), Instant::now());
    let at = |ms| t0 + Duration::from_millis(ms);
    let shared = shared_with(shell, claude);
    let table = Mutex::new(vec![process(10, 100, 1, UID), process(20, 200, 10, UID)]);
    let lookup = |pid| table.lock().unwrap().iter().copied().find(|p| p.pid == pid);
    let watching = Watched {
        cleared: Vec::new(),
        watching: true,
    };
    assert_eq!(
        watch_owners(&shared, t0, lookup),
        Watched::default(),
        "it runs, so no look is owed before output"
    );
    table.lock().unwrap().retain(|p| p.pid != 20);
    assert_eq!(watch_owners(&shared, at(100), lookup), watching);
    assert_eq!(watch_owners(&shared, at(2_099), lookup), watching);
    assert!(recorded(&shared), "within the grace");
    assert_eq!(
        watch_owners(&shared, at(2_100), lookup),
        Watched {
            cleared: vec!["private-command".into()],
            watching: false
        }
    );
    assert!(!recorded(&shared));
}

#[test]
fn a_pid_that_names_another_process_is_its_owner_gone() {
    let (shell, claude, t0) = (owner(10, 100), owner(20, 200), Instant::now());
    let shared = shared_with(shell, claude);
    let table = [process(10, 100, 1, UID), process(20, 900, 10, UID)];
    let lookup = |pid| table.iter().copied().find(|p| p.pid == pid);
    watch_owners(&shared, t0, lookup);
    let watched = watch_owners(&shared, t0 + EXIT_GRACE, lookup);
    assert_eq!(watched.cleared, ["private-command"]);
}

/// The session ending: its shell exits, and the owner may well have gone just before it. Nothing
/// clears then, so a record whose owner died less than `EXIT_GRACE` before its session ended is
/// the session's last record.
#[test]
fn nothing_clears_while_the_sessions_shell_is_gone() {
    let (shell, claude, t0) = (owner(10, 100), owner(20, 200), Instant::now());
    let shared = shared_with(shell, claude);
    let table = Mutex::new(vec![process(10, 100, 1, UID)]);
    let lookup = |pid| table.lock().unwrap().iter().copied().find(|p| p.pid == pid);
    watch_owners(&shared, t0, lookup);
    table.lock().unwrap().clear();
    for ms in [1_500, 2_000, 60_000] {
        let watched = watch_owners(&shared, t0 + Duration::from_millis(ms), lookup);
        assert_eq!(watched, Watched::default(), "{ms}");
    }
    assert!(recorded(&shared));
}

#[test]
fn a_session_with_no_record_or_no_token_owes_no_look() {
    let none: SharedResume = Arc::new(Mutex::new(None));
    let empty: SharedResume = Arc::new(Mutex::new(Some(state())));
    for shared in [none, empty] {
        assert_eq!(
            watch_owners(&shared, Instant::now(), |_| unreachable!()),
            Watched::default()
        );
    }
}

/// The spec: a rejected report removes every record its owner has. A pid has one, and it goes,
/// whatever the reason the report was rejected; another owner's record stays, and the rejection
/// does not move the owner's time on.
#[test]
fn a_rejected_report_removes_its_owners_record_and_only_its() {
    let (vim, other) = (owner(7, 1), owner(8, 1));
    let malformed = body(7, NOW, "argv=");
    let not_owned = body(7, NOW, &argv(&["vim"]));
    type Reject = fn(u32) -> Result<Checked, NotOwner>;
    let rejections: [(&[u8], Reject); 2] = [
        (&malformed, |_| unreachable!()),
        (&not_owned, |_| Err(NotOwner::NotDescendant)),
    ];
    for (report, find_owner) in rejections {
        let mut s = state();
        assert!(set(&mut s, 1, NOW - 5, vim, &[]));
        assert!(set(&mut s, 2, NOW, other, &[]));
        assert!(matches!(
            s.apply(3, report, NOW, find_owner),
            Outcome::NotAccepted { .. }
        ));
        assert_eq!(s.owners(), [other], "only the rejected owner's record went");
        assert!(
            set(&mut s, 4, NOW - 5, vim, &[]),
            "a report as old as its last accepted one still counts"
        );
    }
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
