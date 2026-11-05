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
