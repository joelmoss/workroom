use super::{
    Grace, WAKE_GRACE, last_transition, remove_stale, status_file, still_running, transitions,
    transitions_file,
};
use crate::terminal::session::SessionId;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// A directory this run made itself (an exclusive `create_dir`, skipping any name already
/// there), and only that one is removed when it is dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let base = std::env::temp_dir();
        let dir = (0..)
            .map(|n| base.join(format!("wr-runs-{name}-{}-{n}", std::process::id())))
            .find(|dir| std::fs::create_dir(dir).is_ok())
            .unwrap();
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A run's log of transitions is read a whole line at a time, each by its number: a line still
/// being written is left for the next read, and a log started afresh keeps counting. No log is a
/// supervisor that writes none, which the watcher hears from its status file alone.
#[test]
fn a_runs_transitions_are_whole_numbered_lines() {
    let scratch = Scratch::new("log");
    let status = scratch.0.join("run.status");
    assert_eq!(
        transitions_file(&status).file_name().unwrap(),
        "run.status.log",
        "beside the status file, and not a `*.status` to whatever looks for those"
    );
    assert_eq!(transitions(&status), None);
    assert_eq!(last_transition(&status), None);

    std::fs::write(
        transitions_file(&status),
        "1 starting\n2 running 41\n3 stopp",
    )
    .unwrap();
    assert_eq!(
        transitions(&status),
        Some(vec![(1, "starting".into()), (2, "running 41".into())])
    );
    assert_eq!(last_transition(&status), Some(2));

    std::fs::write(
        transitions_file(&status),
        "64 stopping\nnot one\n65 starting\n",
    )
    .unwrap();
    assert_eq!(
        transitions(&status),
        Some(vec![(64, "stopping".into()), (65, "starting".into())])
    );
}

/// The sweep at the watcher's start keeps a live run's status file and its log, and removes a
/// gone run's, and what its supervisor left half-written.
#[test]
fn the_sweep_keeps_a_live_runs_log() {
    let scratch = Scratch::new("sweep");
    let (live, gone) = (SessionId([1; 16]), SessionId([2; 16]));
    let files: Vec<PathBuf> = [live, gone]
        .into_iter()
        .flat_map(|id| {
            let status = status_file(&scratch.0, id);
            [transitions_file(&status), status]
        })
        .collect();
    for file in &files {
        std::fs::write(file, "1 running 7\n").unwrap();
    }
    let temporary = scratch
        .0
        .join(format!("{}.status.tmp.42", live.to_hyphenated()));
    std::fs::write(&temporary, "running 7\n").unwrap();
    remove_stale(&scratch.0, &[live]);
    let left: Vec<bool> = files.iter().map(|file| file.exists()).collect();
    assert_eq!(left, [true, true, false, false]);
    assert!(!temporary.exists());
}

/// A restart counted while the watcher still polls for the signal before it gets a grace of
/// its own. The supervisor takes a moment to answer a signal, so without it the watcher can
/// stop polling on the old "stopped" and show a running command as stopped.
/// Value: protects=a run signalled near the end of an earlier grace is still polled; fails_when=only a wait starts a grace; why_new=no test drove the watcher's grace; seam=none; no_claim=the loop's wiring of count and polling
#[test]
fn a_signal_counted_while_polling_gets_its_own_grace() {
    let start = Instant::now();
    let mut grace = Grace {
        counted: 1,
        until: start,
    };
    assert!(!grace.polling(start), "nothing counted yet");
    grace.count(2, start);
    let late = start + WAKE_GRACE - Duration::from_millis(100);
    assert!(grace.polling(late));
    grace.count(3, late);
    assert!(
        grace.polling(start + WAKE_GRACE + Duration::from_millis(100)),
        "a signal counted while polling got no grace"
    );
    grace.count(3, start + WAKE_GRACE * 2);
    assert!(
        !grace.polling(start + WAKE_GRACE * 2),
        "nothing new counted, yet still polling"
    );
}

/// The watcher polls a run whose status can still change on its own and sleeps on one that
/// only a signal moves; a run without a status yet is polled.
#[test]
fn a_finished_run_is_not_polled_and_a_running_one_is() {
    assert!(still_running("running 11853"));
    assert!(still_running("restarting 2"));
    assert!(still_running(""));
    assert!(!still_running("exited 0 3"));
    assert!(!still_running("exited 130 1"));
    assert!(!still_running("stopped 1"));
}
