use super::*;
use std::process::Command;

#[test]
fn a_stream_that_ends_exactly_at_the_cap_is_not_flagged_but_one_byte_over_is() {
    let exact = Mutex::new(Vec::new());
    let flag = AtomicBool::new(false);
    drain_capped_flagged([7u8; 10].as_slice(), 10, &exact, &flag);
    assert_eq!(exact.lock().unwrap().len(), 10);
    assert!(!flag.load(Ordering::Acquire));
    let over = Mutex::new(Vec::new());
    drain_capped_flagged([7u8; 11].as_slice(), 10, &over, &flag);
    assert_eq!(over.lock().unwrap().len(), 10);
    assert!(flag.load(Ordering::Acquire));
}

/// Two separate properties, and the second is the one that matters. The cap bounds what is
/// KEPT; the loop must go on reading past it, because the child writes into a pipe whose buffer
/// is ~64 KiB — stop reading and the child blocks on write forever, which is a hang, not a
/// truncation. `StatusCommandRunner.readCapped` has the same shape for the same reason.
#[test]
fn drain_capped_bounds_what_it_keeps_and_still_reads_to_eof() {
    // A source larger than the cap AND larger than any pipe buffer.
    let cap = 1024;
    let source = vec![b'x'; 256 * 1024];
    let sink = Mutex::new(Vec::new());
    drain_capped(source.as_slice(), cap, &sink);
    assert_eq!(sink.lock().unwrap().len(), cap, "the cap did not hold");

    // Drained to EOF through a REAL pipe, which is where refusing to read past the cap would
    // deadlock rather than merely truncate. The writer completes only if the reader kept going.
    let (reader, mut writer) = std::io::pipe().unwrap();
    let payload = vec![b'y'; 512 * 1024];
    let expected = payload.len();
    let pump = std::thread::spawn(move || {
        std::io::Write::write_all(&mut writer, &payload).unwrap();
        expected
    });
    let piped = Mutex::new(Vec::new());
    drain_capped(reader, cap, &piped);
    assert_eq!(
        pump.join().unwrap(),
        expected,
        "the writer never finished, so the reader stopped short of EOF"
    );
    assert_eq!(piped.lock().unwrap().len(), cap);
}

/// `snapshot` must never walk init's own tree — a SIGKILL aimed at pid 1's descendants is the
/// worst outcome a bug here could have — and must terminate on a pid nothing can have.
#[test]
fn the_descendant_walk_refuses_init_and_terminates() {
    assert!(snapshot(0).is_empty());
    assert!(snapshot(1).is_empty());
    assert!(snapshot(-1).is_empty());
    assert!(snapshot(i32::MAX).is_empty());
    // Killing an empty set is a no-op, not a signal to the current process group.
    kill_recorded(&[]);
}

/// LOW 1: the bug this whole identity check exists for. `kill_recorded` used to SIGKILL by bare
/// pid, so a descendant that exited during the SIGTERM-to-SIGKILL grace period and whose pid was
/// handed to something else would be killed in its place. A `Descendant` whose recorded start
/// time cannot match anything real (`u64::MAX`) reproduces exactly that shape — the number is
/// right, the process behind it is not — without needing to actually win a real pid-reuse race.
#[test]
fn kill_recorded_never_signals_a_pid_whose_start_time_has_changed() {
    let mut child = Command::new("/bin/sleep")
        .arg("30")
        .spawn()
        .expect("spawn sleep");
    let pid = child.id() as i32;
    let impostor = Descendant {
        pid,
        started: u64::MAX,
    };
    kill_recorded(&[impostor]);
    // Give a real SIGKILL time to land before checking: without the identity check this reaps
    // almost immediately.
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        child.try_wait().expect("try_wait").is_none(),
        "kill_recorded signalled a pid it no longer identifies"
    );
    let _ = child.kill();
    let _ = child.wait();
}
