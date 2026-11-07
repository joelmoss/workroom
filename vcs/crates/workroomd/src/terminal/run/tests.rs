use super::{Grace, WAKE_GRACE, still_running};
use std::time::{Duration, Instant};

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
