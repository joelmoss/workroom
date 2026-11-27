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
    give_token(&mut command, false, true);
    assert!(
        tokens(&command).is_empty(),
        "a run or one-off command gets none"
    );
    // A shell whose app turned resume off (#827): none, and not the forwarded one either.
    let mut off = forwarded();
    give_token(&mut off, true, false);
    assert!(tokens(&off).is_empty(), "a shell with resume off gets none");
    assert!(
        Resume::for_session(&off).is_none(),
        "so it accepts no reports"
    );
    let mut shell = forwarded();
    give_token(&mut shell, true, true);
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

#[test]
fn only_off_turns_resume_off() {
    let env = |value: &str| vec![(OsString::from(SETTING_VARIABLE), OsString::from(value))];
    assert!(turned_on(&[]), "absent is on: an older app, a typed attach");
    assert!(!turned_on(&env(OFF)));
    assert!(turned_on(&env("on")));
    assert!(turned_on(&env("")));
}

/// The record a session is started to resume in these tests.
fn resumed_record() -> Whole {
    Whole {
        argv: vec!["claude".into(), "--resume".into(), "x".into()],
        cwd: Some("/w".into()),
        reported_at_ms: 0,
    }
}

/// The launch file a session resuming `resumed_record` was told of; never opened here.
fn launch_file() -> std::path::PathBuf {
    "/private/launch/resume-file.json".into()
}

/// The launch file a decline of `pending`, at a prompt or a deadline, would claim, with no
/// process able to be read: none for a resume whose shell said its hook loaded.
fn declined(pending: Option<Pending>) -> Option<std::path::PathBuf> {
    pending
        .filter(|pending| pending.declines(|_| None, |_| None))
        .map(|pending| pending.file)
}

/// Value: protects=a resume whose helper never reported being declinable (#825): its launch file
/// is the one the session was started with, overdue only once `DECLINE_AFTER` has passed, and a
/// decline after the helper reported (or a second one) declines nothing; fails_when=the file is
/// forgotten, the wait is shorter, or a started resume can still be declined; why_new=#825's
/// second review (a hook that never runs); seam=the injected instant
#[test]
fn a_resume_whose_helper_never_reported_is_declined_once() {
    let mut s = state();
    assert_eq!(s.waiting_file(), None, "a session that resumes nothing");
    s.resuming(&resumed_record(), launch_file(), None);
    let now = Instant::now();
    assert_eq!(s.waiting_file(), Some(launch_file()));
    assert_eq!(s.overdue(now), None);
    assert_eq!(
        declined(s.overdue(now + DECLINE_AFTER)),
        Some(launch_file())
    );
    assert_eq!(s.decline(), Some("claude".into()));
    assert_eq!(s.decline(), None, "once");
    assert_eq!(s.waiting_file(), None);

    let mut s = state();
    s.resuming(&resumed_record(), launch_file(), None);
    helper_reports(&mut s, 1, now);
    assert_eq!(s.waiting_file(), None, "it started");
    assert_eq!(s.overdue(now + DECLINE_AFTER), None);
    assert_eq!(s.decline(), None);
}

/// Value: protects=a resumed program reading as itself, not as its helper, wherever a session's
/// foreground is named (#825): the program's pane title, Claude detection, its profile and
/// `terminal.prompt`; only while the foreground group is the helper that runs it and both are the
/// processes that reported, and carried by a hand-off; fails_when=the helper's name is shown, a
/// reused pid or another group is renamed, or a hand-off forgets it; why_new=#825's second review
/// (the foreground was the helper's); seam=the injected process lookup
#[test]
fn a_resumed_programs_helper_group_is_named_for_the_program() {
    let shell = process(100, 1, 1, UID);
    let helper = process(200, 2, 100, UID);
    let program = process(300, 3, 200, UID);
    let table = |processes: Vec<Identity>| {
        move |pid: u32| processes.iter().copied().find(|process| process.pid == pid)
    };
    let mut s = state();
    s.resuming(&resumed_record(), launch_file(), None);
    let report = body(
        300,
        NOW,
        &format!("{}:cwd={}", argv(&["claude", "--resume", "x"]), b64("/w")),
    );
    let outcome = s.apply(1, &report, NOW, |_| {
        checked(
            Owner::from(program),
            &[Owner::from(helper), Owner::from(shell)],
        )
    });
    assert!(matches!(
        s.after(outcome, 1, &report, Instant::now()),
        Outcome::ResumeStarted { .. }
    ));
    let shared: SharedResume = Arc::new(Mutex::new(Some(s.clone())));
    let all = || table(vec![shell, helper, program]);
    assert_eq!(foreground_process(&shared, 200, all()), 300);
    assert_eq!(foreground_process(&shared, 100, all()), 100, "the shell");
    assert_eq!(foreground_process(&shared, 999, all()), 999, "another job");
    let gone = table(vec![shell, helper]);
    assert_eq!(foreground_process(&shared, 200, gone), 200, "it exited");
    let reused = table(vec![shell, helper, process(300, 9, 200, UID)]);
    assert_eq!(
        foreground_process(&shared, 200, reused),
        200,
        "a reused pid"
    );
    let other = table(vec![shell, process(200, 8, 100, UID), program]);
    assert_eq!(
        foreground_process(&shared, 200, other),
        200,
        "another helper"
    );

    let adopted: SharedResume = Arc::new(Mutex::new(Some(Resume::adopted(s.carried()))));
    assert_eq!(foreground_process(&adopted, 200, all()), 300, "a hand-off");
    let nothing: SharedResume = Arc::new(Mutex::new(Some(state())));
    assert_eq!(foreground_process(&nothing, 200, all()), 200);
}

/// The helper's report of `resumed_record`, from pid 4343, applied at `offset` and read at `at`.
fn helper_reports(s: &mut Resume, offset: u64, at: Instant) -> Outcome {
    let report = body(
        4343,
        NOW,
        &format!("{}:cwd={}", argv(&["claude", "--resume", "x"]), b64("/w")),
    );
    let outcome = s.apply(offset, &report, NOW, |_| checked(owner(4343, 1), &[]));
    s.after(outcome, offset, &report, at)
}

/// Value: protects=the app's "Resumed" toast coming once the helper's own report of the record is
/// accepted (#825), and only then; fails_when=another accepted record, a session that resumes
/// nothing, or a second report says it started; why_new=#825 review (`resumeStarted`);
/// seam=the injected instant
#[test]
fn the_helpers_report_of_the_resumed_record_says_it_started_once() {
    let start = Instant::now();
    let mut s = state();
    s.resuming(&resumed_record(), launch_file(), None);
    let other = body(4444, NOW, &argv(&["vim"]));
    let outcome = s.apply(1, &other, NOW, |_| checked(owner(4444, 1), &[]));
    assert!(
        matches!(s.after(outcome, 1, &other, start), Outcome::Accepted { .. }),
        "another program's record"
    );
    assert_eq!(
        helper_reports(&mut s, 2, start),
        Outcome::ResumeStarted {
            program: "claude".into()
        }
    );
    assert!(matches!(
        helper_reports(&mut s, 3, start),
        Outcome::Accepted { .. }
    ));
    assert!(matches!(
        helper_reports(&mut state(), 1, start),
        Outcome::Accepted { .. }
    ));
}

/// Value: protects=a resumed program that could not start, or exits with an error within
/// `FAILED_WITHIN` of its helper's report, turning the toast into "Couldn't resume" (#825), once,
/// the clock starting at that report and not at the session's start (a slow login shell);
/// fails_when=an exit after `FAILED_WITHIN` of starting, a success, a ^C, a session that resumed
/// nothing, or a second exit says it failed, the exit's clear stops being a clear, or a slow
/// shell's wait counts; why_new=#825 review (the clock); seam=the injected instant
#[test]
fn a_resumed_program_that_fails_at_once_says_so_once() {
    let start = Instant::now();
    let exit = |s: &mut Resume, offset: u64, status: i32, after: Duration| {
        let report = body(4242, NOW, &format!("clear=1:workroomexit={status}"));
        let outcome = s.apply(offset, &report, NOW, |_| unreachable!());
        s.after(outcome, offset, &report, start + after)
    };
    let failed = Outcome::ResumeFailed {
        program: "claude".into(),
        status: 1,
    };
    // A login shell that took a minute to reach its first prompt.
    let started = |s: &mut Resume| {
        s.resuming(&resumed_record(), launch_file(), None);
        helper_reports(s, 1, start + Duration::from_secs(60));
    };
    let mut s = state();
    started(&mut s);
    assert_eq!(exit(&mut s, 2, 1, Duration::from_secs(64)), failed);
    assert_eq!(
        exit(&mut s, 3, 1, Duration::from_secs(64)),
        Outcome::Cleared,
        "once"
    );
    let mut s = state();
    s.resuming(&resumed_record(), launch_file(), None);
    assert_eq!(
        exit(&mut s, 1, 127, Duration::from_secs(600)),
        Outcome::ResumeFailed {
            program: "claude".into(),
            status: 127
        },
        "it could not start"
    );

    for (status, after) in [
        (1, Duration::from_secs(60) + launch::FAILED_WITHIN),
        (0, Duration::from_secs(60)),
        (130, Duration::from_secs(60)),
    ] {
        let mut s = state();
        started(&mut s);
        assert_eq!(exit(&mut s, 2, status, after), Outcome::Cleared, "{status}");
    }
    assert_eq!(
        exit(&mut state(), 1, 1, Duration::ZERO),
        Outcome::Cleared,
        "a session that resumed nothing"
    );
    let plain = body(4242, NOW, "clear=1");
    assert_eq!(protocol::workroom_exit(&plain), None);
}

/// The shell's report, from pid 4100 at `offset`, that Workroom's hook loaded in it, with
/// `fields` for its body, read at `at`.
fn shell_says(s: &mut Resume, offset: u64, fields: &str, at: Instant) -> Outcome {
    let report = body(4100, NOW, fields);
    let outcome = s.apply(offset, &report, NOW, |_| {
        unreachable!("a clear checks no owner")
    });
    s.after(outcome, offset, &report, at)
}

/// Value: protects=a resume whose shell said Workroom's hook loaded in it never being declined
/// at a prompt or a deadline (#825): an instant prompt's mark, or a startup file waiting on a
/// passphrase, comes before the hook runs, and the helper's report minutes later still starts
/// it; the file stays the session's to remove at its end; and the announcement is a spec clear
/// that any other terminal reads as one; fails_when=the announcement is lost, read from a plain
/// clear, another value or an unsigned report, a hooked resume is still overdue, or a late
/// helper report no longer says it started; why_new=#825's third review (an instant prompt and a
/// passphrase declined resumes that would have worked); seam=the injected instant
#[test]
fn a_resume_whose_shell_said_its_hook_loaded_waits_for_its_helper() {
    let now = Instant::now();
    let hook = "clear=1:workroomhook=1";
    let authenticated = protocol::authenticate(&body(4100, NOW, hook), TOKEN, NOW).unwrap();
    assert_eq!(authenticated.action, Some(Action::Clear), "a spec clear");
    let mut s = state();
    s.resuming(&resumed_record(), launch_file(), None);
    assert_eq!(declined(s.pending()), Some(launch_file()));
    assert_eq!(shell_says(&mut s, 1, hook, now), Outcome::HookLoaded);
    assert_eq!(
        declined(s.pending()),
        None,
        "a prompt mark declines nothing"
    );
    let later = now + DECLINE_AFTER * 20;
    assert_eq!(declined(s.overdue(later)), None, "nor does any deadline");
    assert_eq!(s.waiting_file(), Some(launch_file()), "its end removes it");
    assert_eq!(s.whole(), None, "the hook's word is no record");
    assert_eq!(
        helper_reports(&mut s, 2, later),
        Outcome::ResumeStarted {
            program: "claude".into()
        },
        "a passphrase answered minutes later"
    );

    for (fields, why) in [
        ("clear=1", "a plain clear"),
        ("clear=1:workroomhook=0", "another value"),
    ] {
        let mut s = state();
        s.resuming(&resumed_record(), launch_file(), None);
        assert_eq!(
            shell_says(&mut s, 1, fields, now),
            Outcome::Cleared,
            "{why}"
        );
        assert_eq!(declined(s.pending()), Some(launch_file()), "{why}");
        // After it started waiting, so this is past its deadline.
        let due = Instant::now() + DECLINE_AFTER;
        assert_eq!(declined(s.overdue(due)), Some(launch_file()), "{why}");
    }
    let mut s = state();
    s.resuming(&resumed_record(), launch_file(), None);
    let forged = format!("pid=4100:time={NOW}:{hook}:mac={}", "0".repeat(64));
    let outcome = s.apply(1, forged.as_bytes(), NOW, |_| unreachable!());
    assert!(matches!(
        s.after(outcome, 1, forged.as_bytes(), now),
        Outcome::NotAccepted { .. }
    ));
    assert_eq!(
        declined(s.pending()),
        Some(launch_file()),
        "an unsigned report"
    );
    assert_eq!(
        shell_says(&mut state(), 1, hook, now),
        Outcome::HookLoaded,
        "said, though a session that resumes nothing waits for nothing"
    );
}

/// Value: protects=a resume whose shell said its hook loaded being declined once `exec` replaced
/// that shell (#825, a `.zshrc` that ends in `exec tmux`), and only on proof: its first process,
/// still the same one by pid and start time, runs another file than the shell it was started
/// from; an instant prompt (the same file), an image not read, a pid now another process's, or a
/// shell or first process not known declines nothing; fails_when=the check reads a name or a
/// path rather than the file, trusts a reused pid or an unread image, or the state stops
/// carrying the first process or the shell to it; why_new=#825 follow-up (a pane whose shell
/// `exec`s tmux toasted "new shell" after every restart); seam=injected process lookups
#[test]
fn a_hooked_resume_is_declined_only_once_exec_replaced_its_shell() {
    use crate::terminal::process::image_of;
    let shell = image_of(&std::env::current_exe().unwrap()).expect("a stand-in shell");
    let other = image_of(std::path::Path::new("/bin/sh")).expect("another file");
    assert_ne!(shell, other);
    let root = owner(4100, 7);
    let alive = |start: u64| {
        move |pid: u32| {
            Some(Identity {
                pid,
                start,
                parent: 1,
                uid: UID,
            })
        }
    };
    let pending = |hooked: bool, root: Option<Owner>, shell: Option<Image>| Pending {
        file: launch_file(),
        hooked,
        root,
        shell,
    };
    let hooked = pending(true, Some(root), Some(shell));
    assert!(
        !hooked.declines(|_| Some(shell), alive(7)),
        "still the shell it started as, as at an instant prompt"
    );
    assert!(
        hooked.declines(|_| Some(other), alive(7)),
        "exec replaced it"
    );
    assert!(!hooked.declines(|_| None, alive(7)), "an image not read");
    assert!(
        !hooked.declines(|_| Some(other), alive(8)),
        "the pid is another process's"
    );
    assert!(!hooked.declines(|_| Some(other), |_| None), "gone");
    assert!(
        !pending(true, Some(root), None).declines(|_| Some(other), alive(7)),
        "a shell not known"
    );
    assert!(
        !pending(true, None, Some(shell)).declines(|_| Some(other), alive(7)),
        "a first process not known"
    );
    assert!(
        pending(false, None, None).declines(|_| None, |_| None),
        "a shell that never said its hook loaded needs no proof"
    );

    // The state hands both on, and the hook's word marks it hooked.
    let mut s = state();
    s.root = Some(root);
    s.resuming(&resumed_record(), launch_file(), Some(shell));
    assert_eq!(s.pending(), Some(pending(false, Some(root), Some(shell))));
    shell_says(&mut s, 1, "clear=1:workroomhook=1", Instant::now());
    assert_eq!(s.pending(), Some(hooked.clone()));
    let due = Instant::now() + DECLINE_AFTER;
    assert_eq!(s.overdue(due), Some(hooked), "and at its deadline");
}

/// Value: protects=a hand-off from a daemon whose table predates `launched` (#822 to #825's)
/// still adopting each session's resume state; fails_when=`launched` stops defaulting, so the
/// next program can't read the table and drops every session's token and records;
/// why_new=#825's third review (no test decoded an older table); seam=none
#[test]
fn a_carried_state_from_a_table_without_launched_decodes() {
    let carried = Carried::for_test(TOKEN, 7);
    let mut json = serde_json::to_value(&carried).unwrap();
    assert!(
        json.as_object_mut().unwrap().remove("launched").is_some(),
        "today's table writes it"
    );
    let older: Carried = serde_json::from_value(json).expect("an older table's state decodes");
    assert_eq!(older, carried);
    assert_eq!(older.launched, None);
}

/// A hand-off table's resume state as version 6 writes it: one owner with a record, one whose
/// rejected report left it none, and the resumed program's helper. Written by the build this
/// test was added in, before its state was restructured.
const CARRIED_V6: &str = concat!(
    r#"{"token":"private-token","uid":501,"root":{"pid":4242,"start":1},"#,
    r#""words":{"4242":{"time":1795543200,"offset":7,"record":{"owner":{"pid":4242,"start":1},"#,
    r#""ancestors":[],"argv":["claude","--resume","a-session"],"reported_cwd":"/work","#,
    r#""owner_cwd":null,"reported_at":1795543200}},"#,
    r#""4343":{"time":1795543100,"offset":3,"record":null}},"#,
    r#""offset":7,"launched":{"helper":{"pid":4200,"start":2},"program":{"pid":4242,"start":1}}}"#
);

/// The same table from a build before `launched`: no such key.
const CARRIED_BEFORE_LAUNCHED: &str = concat!(
    r#"{"token":"private-token","uid":501,"root":{"pid":4242,"start":1},"#,
    r#""words":{"4242":{"time":1795543200,"offset":7,"record":{"owner":{"pid":4242,"start":1},"#,
    r#""ancestors":[],"argv":["claude","--resume","a-session"],"reported_cwd":"/work","#,
    r#""owner_cwd":null,"reported_at":1795543200}}},"offset":7}"#
);

/// Value: protects=the hand-off table's resume state (version 6) reading and writing exactly as
/// the shipped build does, field names, order and defaults alike, so a hand-off to or from it
/// keeps every session's token, records and stream position; fails_when=a field is renamed,
/// reordered, dropped or stops defaulting; why_new=the resume state's restructure (one persisted
/// struct); seam=none
#[test]
fn a_carried_state_reads_and_writes_the_shipped_tables_shape() {
    let carried: Carried = serde_json::from_str(CARRIED_V6).expect("today's table decodes");
    assert_eq!(serde_json::to_string(&carried).unwrap(), CARRIED_V6);
    let adopted = Resume::adopted(carried);
    assert_eq!(adopted.token(), TOKEN);
    assert_eq!(
        adopted
            .whole()
            .map(|whole| (whole.argv, whole.cwd, whole.reported_at_ms)),
        Some((
            vec!["claude".into(), "--resume".into(), "a-session".into()],
            Some("/work".into()),
            1_795_543_200_000,
        ))
    );
    let shared: SharedResume = Arc::new(Mutex::new(Some(adopted)));
    let table = [process(4200, 2, 1, UID), process(4242, 1, 4200, UID)];
    let lookup = |pid| table.iter().copied().find(|p| p.pid == pid);
    assert_eq!(foreground_process(&shared, 4200, lookup), 4242, "launched");

    let older: Carried =
        serde_json::from_str(CARRIED_BEFORE_LAUNCHED).expect("an older table decodes");
    assert_eq!(older, Carried::for_test(TOKEN, 7));
    let written = serde_json::to_string(&older).unwrap();
    assert_eq!(
        written,
        CARRIED_BEFORE_LAUNCHED.replace(r#""offset":7}"#, r#""offset":7,"launched":null}"#)
    );
}

/// Value: protects=the daemon's log saying why a resume was declined in the words it always has;
/// fails_when=a reason's wording changes or two reasons swap; why_new=the resume lifecycle's
/// restructure; seam=none
#[test]
fn a_decline_says_why_in_its_log() {
    let pending = |hooked: bool| Pending {
        file: launch_file(),
        hooked,
        root: None,
        shell: None,
    };
    assert_eq!(
        pending(false).why(true),
        "its shell's first prompt came before its helper reported, so it ran no Workroom hook"
    );
    assert_eq!(
        pending(false).why(false),
        "its shell never loaded Workroom's hook, and its helper never reported"
    );
    for at_prompt in [true, false] {
        assert_eq!(
            pending(true).why(at_prompt),
            "its shell loaded Workroom's hook, then exec replaced the shell before its helper ran"
        );
    }
}
