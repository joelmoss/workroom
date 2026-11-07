use super::*;

#[test]
fn a_status_reads_as_an_exit_or_a_signal() {
    assert_eq!(describe_status(0), "exited 0");
    assert_eq!(describe_status(7 << 8), "exited 7");
    assert_eq!(describe_status(libc::SIGHUP), "killed by signal 1 (SIGHUP)");
    assert_eq!(
        describe_status(libc::SIGKILL | 0o200),
        "killed by signal 9 (SIGKILL)"
    );
}

#[test]
fn a_message_cannot_start_a_line_of_its_own() {
    assert_eq!(
        one_line("hand-off to /tmp/x\n2026-10-01 session 1 killed\r\t"),
        "hand-off to /tmp/x\\n2026-10-01 session 1 killed\\r\\t"
    );
    assert_eq!(
        one_line("/Users/joël/it's \"fine\""),
        "/Users/joël/it's \"fine\""
    );
}

#[test]
fn a_log_past_its_limit_moves_aside_and_writing_carries_on_in_a_fresh_one() {
    let dir = std::env::temp_dir().join(format!("workroomd-log-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    let path = dir.join("workroomd.log");
    let file = open_log(&path).expect("log");
    // SAFETY: `file` is open for the call; dup takes and returns plain integers.
    let fd = unsafe { libc::dup(file.as_raw_fd()) };
    // SAFETY: the pointer and length come from one live slice, and `fd` stays open until the
    // close at the end of the test.
    let write = |bytes: &[u8]| unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };

    write(b"under\n");
    rotate(&path, fd, 10);
    assert!(
        !dir.join("workroomd.log.1").exists(),
        "rotated under the limit"
    );

    write(b"now over the limit\n");
    rotate(&path, fd, 10);
    write(b"after\n");
    let kept = std::fs::read_to_string(dir.join("workroomd.log.1")).expect("previous");
    let fresh = std::fs::read_to_string(&path).expect("fresh");
    // SAFETY: `fd` is the test's own duplicate, closed once and not used after.
    unsafe { libc::close(fd) };
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(kept, "under\nnow over the limit\n");
    assert_eq!(fresh, "after\n");
}

/// The open that fails is the fresh file's, and a directory in its place makes it fail.
#[test]
fn a_rotation_that_cannot_open_a_fresh_log_leaves_the_log_in_place() {
    let dir = std::env::temp_dir().join(format!("workroomd-log-stuck-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("workroomd.log.new")).expect("blocker");
    let path = dir.join("workroomd.log");
    let file = open_log(&path).expect("log");
    // SAFETY: `file` is open for the call; dup takes and returns plain integers.
    let fd = unsafe { libc::dup(file.as_raw_fd()) };
    // SAFETY: the pointer and length come from one live slice, and `fd` stays open until the
    // close at the end of the test.
    let write = |bytes: &[u8]| unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };

    write(b"over the limit\n");
    rotate(&path, fd, 5);
    write(b"still here\n");
    let log = std::fs::read_to_string(&path).unwrap_or_default();
    let moved = dir.join("workroomd.log.1").exists();
    // SAFETY: `fd` is the test's own duplicate, closed once and not used after.
    unsafe { libc::close(fd) };
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!moved, "the log moved aside with nothing to replace it");
    assert_eq!(log, "over the limit\nstill here\n");
}

#[test]
fn a_symlink_in_the_log_s_place_is_not_followed() {
    let dir = std::env::temp_dir().join(format!("workroomd-log-link-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    let target = dir.join("elsewhere");
    std::os::unix::fs::symlink(&target, dir.join("workroomd.log")).expect("link");
    let opened = open_log(&dir.join("workroomd.log")).is_ok();
    let followed = target.exists();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!opened && !followed, "opened {opened}, followed {followed}");
}

#[test]
fn the_log_sits_beside_the_socket() {
    assert_eq!(
        log_path(Path::new("/a/sessions/workroomd.sock")),
        Path::new("/a/sessions/workroomd.log")
    );
}
