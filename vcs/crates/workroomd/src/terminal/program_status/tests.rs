use super::*;

fn report(id: &str, state: State) -> Report {
    Report {
        id: id.into(),
        state,
        kind: Kind::None,
        progress: -1,
        app: String::new(),
        title: String::new(),
        message: String::new(),
    }
}

fn ids(store: &Store) -> Vec<&str> {
    store.records.iter().map(|r| r.id.as_str()).collect()
}

fn fixture(name: &str) -> &'static str {
    match name {
        "status" => include_str!("../../../../../../testdata/program-status/status.json"),
        "ended" => include_str!("../../../../../../testdata/program-status/ended.json"),
        "status-command" => {
            include_str!("../../../../../../testdata/program-status/status-command.json")
        }
        "status-run" => include_str!("../../../../../../testdata/program-status/status-run.json"),
        _ => include_str!("../../../../../../testdata/program-status/snapshot-complete.json"),
    }
    .trim_end()
}

fn uuid(text: &str) -> SessionId {
    wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(text)).unwrap()
}

const BOOT: &str = "6f1c2e0a-3b4d-4e5f-8a9b-0c1d2e3f4a5b";
const SESSION: &str = "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a";

/// The three events, byte for byte as the app's decoder tests read them.
/// Value: protects=the wire shape and field order the Swift decoder is pinned to; fails_when=a field is renamed, reordered or retyped; why_new=the fixtures are the cross-language contract; seam=none
#[test]
fn events_match_the_shared_fixtures() {
    let mut store = Store::default();
    store.apply(Event::Probed, 10);
    store.revision = 6;
    store.report(
        Report {
            kind: Kind::Permission,
            app: "claude-code".into(),
            message: "Apply?".into(),
            ..report("", State::Blocked)
        },
        10,
    );
    assert_eq!(store.commit(), Some(true));
    let event = store.event(uuid(BOOT), uuid(SESSION));
    assert_eq!(String::from_utf8(event).unwrap(), fixture("status"));
    assert_eq!(
        String::from_utf8(ended_event(uuid(BOOT), uuid(SESSION))).unwrap(),
        fixture("ended")
    );
    assert_eq!(
        String::from_utf8(snapshot_complete(uuid(BOOT), &[uuid(SESSION)])).unwrap(),
        fixture("snapshot-complete")
    );

    let mut store = Store::default();
    store.apply(command(1, limits::LONG_COMMAND), 10);
    store.commit();
    let event = store.event(uuid(BOOT), uuid(SESSION));
    assert_eq!(String::from_utf8(event).unwrap(), fixture("status-command"));

    let mut store = Store::default();
    store.set_run("exited 3".into());
    store.commit();
    let event = store.event(uuid(BOOT), uuid(SESSION));
    assert_eq!(String::from_utf8(event).unwrap(), fixture("status-run"));
}

/// Value: protects=a run's state is published only when it changes, so the watcher's re-reads
/// cost no events; fails_when=set_run marks the store dirty for the same line; why_new=the
/// watcher reads every run's file every tick; seam=none
#[test]
fn the_same_run_state_publishes_nothing() {
    let mut store = Store::default();
    store.set_run("running 7".into());
    assert!(store.commit().is_some());
    store.set_run("running 7".into());
    assert_eq!(store.commit(), None);
    store.set_run("stopped".into());
    assert!(store.commit().is_some());
}

/// A report replaces its record whole, and moves it to the newest end.
#[test]
fn a_report_replaces_its_record_completely() {
    let mut store = Store::default();
    store.report(
        Report {
            message: "first".into(),
            ..report("a", State::Working)
        },
        1,
    );
    store.report(report("b", State::Working), 1);
    store.report(report("a", State::Done), 1);
    assert_eq!(ids(&store), ["b", "a"]);
    assert_eq!(store.records[1].message, "", "a value left out is gone");
    assert_eq!(store.records[1].state, State::Done);
    assert_eq!(store.reporting, Some(1));
}

/// Value: protects=CLEAR removes the id and its subtree only, and an empty id removes all; fails_when=the subtree test is a bare prefix (`a` takes `ab`) or misses `a/b`; why_new=terminal.h's subtree rule has no other check; seam=none
#[test]
fn clear_removes_the_subtree_and_nothing_beside_it() {
    let mut store = Store::default();
    for id in ["a", "a/b", "a/b/c", "ab", "b"] {
        store.report(report(id, State::Working), 1);
    }
    store.clear("a");
    assert_eq!(ids(&store), ["ab", "b"]);
    store.clear("");
    assert!(store.records.is_empty());
}

#[test]
fn episodes_number_each_entry_into_blocked() {
    let mut store = Store::default();
    store.report(report("", State::Working), 1);
    assert_eq!(store.records[0].episode, 0, "0 until it first blocks");
    store.report(report("", State::Blocked), 1);
    assert_eq!(store.records[0].episode, 1);
    store.report(
        Report {
            message: "still".into(),
            ..report("", State::Blocked)
        },
        1,
    );
    assert_eq!(store.records[0].episode, 1, "staying blocked keeps it");
    store.report(report("", State::Working), 1);
    store.report(report("", State::Blocked), 1);
    assert_eq!(
        store.records[0].episode, 2,
        "a second permission in one turn"
    );
    // Across a CLEAR and a prompt the counter keeps going, so an old episode never repeats.
    store.clear("");
    store.report(report("", State::Blocked), 1);
    assert_eq!(store.records[0].episode, 3);
    store.drop_on_prompt();
    store.report(report("x", State::Blocked), 1);
    assert_eq!(store.records[0].episode, 4);
}

/// Only the group that was foreground when the daemon answered a probe is trusted to alert.
#[test]
fn notify_follows_the_probing_group() {
    let mut store = Store::default();
    store.report(report("", State::Blocked), 7);
    assert!(!store.records[0].notify, "nothing probed");
    store.apply(Event::Probed, 7);
    store.report(report("other", State::Blocked), 8);
    assert!(!store.records[1].notify, "another group probed");
    store.report(report("", State::Blocked), 7);
    assert!(store.records[1].notify);
    store.reset();
    assert_eq!((store.reporting, store.probed), (None, None));
}

/// A request from a program that never probed (Codex, #481) alerts once its sender has stayed
/// a running program for `GRACE` after it blocked; a tick before then leaves it alone.
/// Value: protects=Codex requests alert at all; fails_when=promotion is missing or ignores the grace; why_new=notify was probe-only; seam=none; no_claim=the tick thread and real pty groups (unit only)
#[test]
fn an_unprobed_request_alerts_once_its_sender_outlasts_the_grace() {
    let start = Instant::now();
    let mut store = Store::default();
    store.apply_read(vec![Event::Report(report("", State::Blocked))], 7, start);
    store.commit();
    store.promote_unprobed(start + limits::GRACE / 2, |_| true);
    assert!(!store.records[0].notify, "within the grace");
    assert_eq!(store.commit(), None);
    store.promote_unprobed(start + limits::GRACE, |_| false);
    assert!(
        !store.records[0].notify,
        "a sender gone or in the background"
    );
    store.promote_unprobed(start + limits::GRACE, |group| group == 7);
    assert!(store.records[0].notify);
    assert_eq!(store.commit(), Some(false), "published");
}

/// Codex re-sends its state after an external program returns: the same request from the
/// same sender keeps its grace start and, once promoted, its promotion.
/// Value: protects=one alert per request across re-reports; fails_when=report() recomputes notify from the probe alone or restarts the grace; why_new=no test re-reports an unprobed request; seam=none; no_claim=none beyond protects
#[test]
fn a_repeated_request_keeps_its_grace_and_its_promotion() {
    let start = Instant::now();
    let blocked = || vec![Event::Report(report("", State::Blocked))];
    let mut store = Store::default();
    store.apply_read(blocked(), 7, start);
    store.apply_read(blocked(), 7, start + limits::GRACE / 2);
    store.promote_unprobed(start + limits::GRACE, |_| true);
    assert!(
        store.records[0].notify,
        "the grace ran from the first report"
    );
    store.commit();
    store.apply_read(blocked(), 7, start + limits::GRACE * 2);
    assert!(store.records[0].notify, "still promoted");
    assert_eq!(store.commit(), None, "nothing changed");
    store.apply_read(blocked(), 8, start + limits::GRACE * 2);
    assert!(!store.records[0].notify, "another sender starts over");
}

/// A request restored without a grace start (a hand-off does not carry it) starts its grace at
/// the first tick, and a sender the daemon could not identify (group 0) never alerts.
/// Value: protects=a handed-off request alerts a grace later, never at once, and an unidentified sender never; fails_when=promote_unprobed treats a missing start as elapsed or drops the owner check; why_new=the other tests always set the start through apply_read; seam=none; no_claim=a real hand-off
#[test]
fn a_request_without_a_grace_start_waits_a_grace_from_the_tick() {
    let start = Instant::now();
    let mut store = Store::default();
    store.apply_read(vec![Event::Report(report("", State::Blocked))], 7, start);
    store.records[0].blocked_at = None;
    store.promote_unprobed(start + limits::GRACE * 5, |_| true);
    assert!(!store.records[0].notify, "the tick starts the grace");
    store.promote_unprobed(start + limits::GRACE * 6, |_| true);
    assert!(store.records[0].notify, "a grace after that tick");

    let mut store = Store::default();
    store.apply_read(vec![Event::Report(report("", State::Blocked))], 0, start);
    store.promote_unprobed(start + limits::GRACE * 5, |_| true);
    assert!(!store.records[0].notify, "an unidentified sender");
}

/// A probe and a report in one read (a `cat` of a recorded session) never alert; the same
/// report in a later read does, and a prompt after the probe voids it.
#[test]
fn a_probe_counts_only_after_the_reports_read_with_it() {
    let blocked = || Event::Report(report("", State::Blocked));
    let mut store = Store::default();
    store.apply_read(vec![Event::Probed, blocked()], 7, Instant::now());
    assert!(!store.records[0].notify, "probe and report in one read");
    store.apply_read(vec![blocked()], 7, Instant::now());
    assert!(
        store.records[0].notify,
        "the probe counts from the next read"
    );

    let mut store = Store::default();
    store.apply_read(vec![Event::Probed, Event::Prompt], 7, Instant::now());
    assert_eq!(store.probed, None, "a prompt ends the run that probed");
    store.apply_read(vec![Event::Prompt, Event::Probed], 7, Instant::now());
    assert_eq!(store.probed, Some(7));
}

#[test]
fn a_prompt_keeps_only_what_the_user_has_not_seen() {
    let mut store = Store::default();
    for (id, state) in [
        ("i", State::Idle),
        ("w", State::Working),
        ("b", State::Blocked),
        ("d", State::Done),
        ("e", State::Error),
    ] {
        store.report(report(id, state), 1);
    }
    let mut exited = store.clone();
    store.drop_on_prompt();
    assert_eq!(ids(&store), ["d", "e"]);
    assert_eq!(store.reporting, None);
    exited.drop_on_exit();
    assert_eq!(ids(&exited), ["i", "d", "e"]);
}

#[test]
fn only_a_real_change_is_a_revision() {
    let mut store = Store::default();
    assert_eq!(store.commit(), None);
    store.report(report("", State::Working), 1);
    assert_eq!(store.commit(), Some(false));
    assert_eq!(store.revision, 1);
    store.report(
        Report {
            progress: 40,
            ..report("", State::Working)
        },
        1,
    );
    assert_eq!(store.commit(), None, "progress alone");
    assert_eq!(store.records[0].progress, 40, "but it is kept");
    store.report(report("", State::Working), 1);
    assert_eq!(store.commit(), None, "the same report again");
    store.clear("missing");
    assert_eq!(store.commit(), None);
    store.report(report("", State::Blocked), 1);
    assert_eq!(store.commit(), Some(true));
    assert_eq!(store.revision, 2);
}

/// Value: protects=seen removes only what the app saw, as of the revision it names; fails_when=the `updated <= revision` gate is dropped, so a done that arrived after the focus goes unseen; why_new=the gate is what makes a focus racing a new report safe; seam=none
#[test]
fn seen_is_gated_on_the_revision_the_app_showed() {
    let mut store = Store::default();
    store.report(report("old", State::Done), 1);
    store.report(report("err", State::Error), 1);
    store.commit();
    let shown = store.revision;
    store.report(report("new", State::Done), 1);
    store.commit();
    let mut done_only = store.clone();
    store.seen(shown, &[State::Done, State::Error]);
    assert_eq!(ids(&store), ["new"]);
    assert_eq!(store.commit(), Some(false));
    done_only.seen(done_only.revision, &[State::Done]);
    assert_eq!(ids(&done_only), ["err"]);
}

fn command(exit_code: i32, ran: Duration) -> Event {
    Event::Command {
        exit_code,
        ran,
        line: "npm test".into(),
    }
}

fn result(store: &Store) -> Option<(State, i32)> {
    store.command.as_ref().map(|c| (c.state(), c.exit_code))
}

/// Value: protects=which command ends earn a mark (#473): long ones, passed or failed, never ^C; fails_when=the threshold, the 130 exemption or the exit-0 split goes; why_new=these rules exist nowhere else; seam=none
#[test]
fn only_a_long_command_that_was_not_interrupted_leaves_a_result() {
    let long = limits::LONG_COMMAND;
    for (exit_code, ran, expected) in [
        (0, long, Some((State::Done, 0))),
        (2, long, Some((State::Error, 2))),
        (137, long * 6, Some((State::Error, 137))),
        (143, long, Some((State::Error, 143))),
        (130, long * 60, None),
        (0, long - Duration::from_millis(1), None),
        (1, Duration::ZERO, None),
    ] {
        let mut store = Store::default();
        store.apply(command(exit_code, ran), 1);
        assert_eq!(result(&store), expected, "exit {exit_code} after {ran:?}");
        assert_eq!(store.commit().is_some(), expected.is_some());
    }
}

/// Value: protects=one result per session that only a later long command replaces; fails_when=a quick command or a ^C clears or replaces it, or a long one does not; why_new=the replace rule is new; seam=none
#[test]
fn only_a_later_long_command_replaces_the_result() {
    let long = limits::LONG_COMMAND;
    let mut store = Store::default();
    store.apply(command(2, long), 1);
    store.commit();
    store.apply(command(0, Duration::from_secs(1)), 1);
    store.apply(command(130, long), 1);
    assert_eq!(store.commit(), None, "neither is a change");
    assert_eq!(result(&store), Some((State::Error, 2)));
    store.apply(command(0, long), 1);
    assert_eq!(
        store.commit(),
        Some(false),
        "never counts as entering blocked"
    );
    assert_eq!(result(&store), Some((State::Done, 0)));
}

/// Value: protects=the result follows the seen rules and nothing a program sends clears it; fails_when=seen ignores its state or revision, or a prompt, CLEAR, RIS or exit drops it; why_new=it is kept apart from the records those rules walk; seam=none
#[test]
fn a_result_goes_only_when_seen_or_cleared_by_the_user() {
    let mut store = Store::default();
    store.apply(command(1, limits::LONG_COMMAND), 1);
    store.commit();
    let shown = store.revision;
    for event in [Event::Prompt, Event::Clear(String::new()), Event::Reset] {
        store.apply(event, 1);
    }
    store.drop_on_exit();
    store.drop_dead_owners(|_| false);
    store.seen(shown - 1, &[State::Done, State::Error]);
    store.seen(shown, &[State::Done]);
    assert_eq!(result(&store), Some((State::Error, 1)));
    store.seen(shown, &[State::Error]);
    assert_eq!(result(&store), None);
    assert_eq!(store.commit(), Some(false));

    store.apply(command(0, limits::LONG_COMMAND), 1);
    store.clear_all();
    assert_eq!(result(&store), None, "Clear status takes it too");
}

/// Value: protects=the result sits among the records in the order they changed, with an exitCode no program record has; fails_when=it always goes first or last, or the field leaks onto a program's record; why_new=the app's latest mark and its shell wording read these; seam=none
#[test]
fn the_result_is_sent_among_the_records_in_change_order() {
    let mut store = Store::default();
    store.report(report("a", State::Done), 1);
    store.commit();
    store.apply(command(1, limits::LONG_COMMAND), 1);
    store.commit();
    store.report(report("b", State::Done), 1);
    store.commit();
    let event: Value = serde_json::from_slice(&store.event(uuid(BOOT), uuid(SESSION))).unwrap();
    let records = event["records"].as_array().unwrap();
    let shape: Vec<_> = records
        .iter()
        .map(|r| (r["id"].as_str().unwrap(), r.get("exitCode").cloned()))
        .collect();
    assert_eq!(
        shape,
        [("a", None), (COMMAND_ID, Some(json!(1))), ("b", None)]
    );
    assert_eq!(records[1]["state"], "error");
    assert_eq!(records[1]["message"], "npm test");
}

#[test]
fn clear_all_ends_reporting_but_keeps_the_probe() {
    let mut store = Store::default();
    store.apply(Event::Probed, 3);
    store.report(report("", State::Error), 3);
    store.clear_all();
    assert!(store.records.is_empty());
    assert_eq!((store.reporting, store.probed), (None, Some(3)));
    // The same run's next request still notifies: it asked once, and is still running.
    store.report(report("", State::Blocked), 3);
    assert!(store.records[0].notify);
}

#[test]
fn the_oldest_record_goes_past_the_cap() {
    let mut store = Store::default();
    for n in 0..limits::MAX_RECORDS {
        store.report(report(&format!("r{n}"), State::Working), 1);
    }
    store.report(report("r0", State::Done), 1);
    assert_eq!(
        store.records.len(),
        limits::MAX_RECORDS,
        "an update adds none"
    );
    store.report(report("new", State::Working), 1);
    assert_eq!(store.records.len(), limits::MAX_RECORDS);
    assert_eq!(store.records[0].id, "r2", "r1 was updated longest ago");
    assert_eq!(store.records.last().unwrap().id, "new");
}

#[test]
fn keys_must_be_printable_ascii() {
    let mut store = Store::default();
    for (id, app) in [("a b", ""), ("é", ""), ("ok", "x\u{7}"), ("ok", "a b")] {
        store.report(
            Report {
                app: app.into(),
                ..report(id, State::Working)
            },
            1,
        );
    }
    assert!(store.records.is_empty());
    store.report(
        Report {
            app: "cargo".into(),
            ..report("build/test", State::Working)
        },
        1,
    );
    assert_eq!(ids(&store), ["build/test"]);
}

#[test]
fn text_is_made_safe_to_show_outside_the_terminal() {
    let mut store = Store::default();
    let hostile = "a\u{202E}b\u{200B}c\u{E0041}d\u{00AD}e\u{061C}f\u{180E}g\u{FFF9}h\u{FEFF}i\
                       \nj\rk\u{7f}l\u{85}m\u{2028}n";
    assert_eq!(
        store.sanitized(hostile, LOGGED_TITLE, 1),
        "abcdefghi j k l m n"
    );
    // Cut on a character boundary, never inside one.
    let long = "é".repeat(limits::MAX_TEXT);
    let cut = store.sanitized(&long, LOGGED_MESSAGE, 1);
    assert_eq!(cut.len(), limits::MAX_TEXT);
    assert!(cut.chars().all(|c| c == 'é'));
    let odd = format!("x{long}");
    assert_eq!(
        store.sanitized(&odd, LOGGED_MESSAGE, 1).len(),
        limits::MAX_TEXT - 1
    );
}

#[test]
fn a_record_without_an_app_takes_its_nearest_ancestors() {
    let mut store = Store::default();
    let with_app = |id: &str, app: &str| Report {
        app: app.into(),
        ..report(id, State::Working)
    };
    store.report(with_app("", "deploy"), 1);
    store.report(with_app("us-east", ""), 1);
    store.report(with_app("eu", "terraform"), 1);
    store.report(with_app("eu/a/b", ""), 1);
    let event: Value =
        serde_json::from_slice(&store.event(SessionId([0; 16]), SessionId([1; 16]))).unwrap();
    let apps: Vec<&str> = event["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["app"].as_str().unwrap())
        .collect();
    assert_eq!(apps, ["deploy", "deploy", "terraform", "terraform"]);
}

/// Value: protects=only a group that is gone loses its working/blocked records; fails_when=the liveness drop is removed, or it drops on a foreground change; why_new=owner death is the only way a killed daemon's blocked clears without a prompt; seam=alive
#[test]
fn a_dead_owner_loses_its_live_records_and_a_stopped_one_does_not() {
    let mut store = Store::default();
    store.apply(Event::Probed, 5);
    store.report(report("w", State::Working), 5);
    store.report(report("b", State::Blocked), 5);
    store.report(report("d", State::Done), 5);
    store.report(report("other", State::Blocked), 6);
    store.commit();
    store.drop_dead_owners(|_| true);
    assert_eq!(store.commit(), None, "nothing is gone");
    store.drop_dead_owners(|group| group != 5);
    assert_eq!(ids(&store), ["d", "other"]);
    assert_eq!(store.probed, None);
    assert_eq!(store.reporting, Some(6));
    assert!(store.commit().is_some());
}

/// A run that cleared its records on exit (Claude Code sends CLEAR) still reports until its
/// group is gone, so the liveness check keeps running for it: without OSC 133 no prompt ends
/// it, and while it reports, the pane ignores the next command's OSC 9;4.
#[test]
fn a_cleared_run_is_still_checked_until_its_group_is_gone() {
    let mut store = Store::default();
    store.report(report("", State::Working), 5);
    store.clear("");
    assert!(
        store.has_live(),
        "the reporting run still needs its liveness check"
    );
    store.drop_dead_owners(|_| false);
    assert_eq!(store.reporting, None);
    assert!(!store.has_live());
}

/// The liveness probe against real processes: a stopped group (^Z) and a zombie both still
/// exist; a reaped one does not; a group whose leader left lives on in its children (a wrapper
/// that forked the real program).
#[test]
fn the_liveness_probe_matches_real_process_groups() {
    use std::os::unix::process::CommandExt;
    let spawn = |script: &str| {
        std::process::Command::new("/bin/sh")
            .args(["-c", script])
            .process_group(0)
            .spawn()
            .unwrap()
    };
    let mut sleeper = spawn("exec sleep 30");
    let group = sleeper.id() as Group;
    assert!(group_alive(group));
    // SAFETY: `kill` takes no pointers; the group is this test's own child's.
    unsafe { libc::kill(-group, libc::SIGSTOP) };
    assert!(group_alive(group), "a stopped job is still there");
    sleeper.kill().unwrap();
    std::thread::sleep(Duration::from_millis(100));
    assert!(group_alive(group), "a zombie counts until it is reaped");
    sleeper.wait().unwrap();
    assert!(!group_alive(group), "a reaped group is gone");

    let mut wrapper = spawn("sleep 30 & exit 0");
    let group = wrapper.id() as Group;
    wrapper.wait().unwrap();
    assert!(group_alive(group), "the wrapper's child keeps the group");
    // SAFETY: as above.
    unsafe { libc::kill(-group, libc::SIGKILL) };
    assert!(group_alive(0), "an unknown group always counts");
}

#[test]
fn the_throttle_lets_the_first_change_and_blocked_through_at_once() {
    let mut throttle = Throttle::default();
    let t0 = Instant::now();
    assert_eq!(throttle.wait(t0, false), None, "first after quiet");
    throttle.last = Some(t0);
    let soon = t0 + Duration::from_millis(10);
    assert_eq!(throttle.wait(soon, false), Some(Duration::from_millis(40)));
    assert_eq!(throttle.wait(soon, true), None, "blocked skips it");
    assert_eq!(throttle.wait(t0 + limits::PUBLISH_THROTTLE, false), None);
}

/// The hand-off carries every field but the per-write ones.
#[test]
fn a_store_survives_serialization() {
    let mut store = Store::default();
    store.apply(Event::Probed, 4);
    store.report(report("", State::Blocked), 4);
    store.apply(command(1, limits::LONG_COMMAND), 4);
    store.commit();
    let back: Store = serde_json::from_slice(&serde_json::to_vec(&store).unwrap()).unwrap();
    assert_eq!(back, store);
    assert_eq!(
        result(&back),
        Some((State::Error, 1)),
        "a command result too"
    );
    assert_eq!((back.records[0].episode, back.records[0].notify), (1, true));
}
