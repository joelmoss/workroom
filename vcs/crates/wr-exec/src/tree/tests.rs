use super::*;

/// The listing comes back newest first, so a short read drops the oldest processes, launchd
/// (pid 1) among them, while this test's own recent pid survives.
#[test]
fn lists_every_process() {
    let pids = platform::all_pids();
    assert!(
        pids.contains(&(std::process::id() as i32)),
        "own pid missing"
    );
    assert!(
        pids.contains(&1),
        "launchd missing from {} pids",
        pids.len()
    );
}

/// A process's ancestry starts with it, then its parent, and stops short of launchd.
#[test]
fn ancestry_walks_up_to_init() {
    let own = std::process::id() as i32;
    // SAFETY: `getppid` takes no pointers and cannot fail.
    let parent = unsafe { libc::getppid() };
    let lineage = ancestry(own);
    assert_eq!(lineage.first(), Some(&own));
    if parent > 1 {
        assert_eq!(lineage.get(1), Some(&parent), "{lineage:?}");
    }
    assert!(!lineage.contains(&1), "{lineage:?}");
    assert!(ancestry(1).is_empty());
    assert!(ancestry(0).is_empty());
}
