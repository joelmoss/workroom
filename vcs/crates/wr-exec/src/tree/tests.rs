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

/// A root-owned process's parent is read for a user too, so a walk from a command under `sudo`
/// crosses it instead of stopping there. launchd is root's, and its parent is the kernel's 0.
#[test]
fn a_root_owned_process_has_a_parent_a_user_can_read() {
    // SAFETY: `geteuid` takes no pointers and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        // Root reads every process with either call, so there is nothing to tell apart.
        eprintln!("skipped: run as root");
        return;
    }
    assert_eq!(platform::parent(1), Some(0));
}
