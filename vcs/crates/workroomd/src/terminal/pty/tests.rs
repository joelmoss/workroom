use super::*;
use std::os::unix::ffi::OsStringExt;
use std::time::{Duration, Instant};

fn env() -> Vec<(OsString, OsString)> {
    vec![
        (OsString::from("TERM"), OsString::from("xterm-256color")),
        (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
    ]
}

/// Reads until `needle` appears or the deadline passes. The master is non-blocking, so EAGAIN
/// is the normal "nothing yet" answer rather than an error.
fn read_until(pty: &Pty, needle: &str, timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    let mut seen = String::new();
    let mut buffer = [0u8; 4096];
    while Instant::now() < deadline {
        match pty.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                seen.push_str(&String::from_utf8_lossy(&buffer[..n]));
                if seen.contains(needle) {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => break,
        }
    }
    seen
}

/// The ordinary exec convention: argv[0] repeats the program path.
///
/// Wraps `Pty::spawn` so the tests that do not care about argv[0] do not have to say so. The
/// ones that DO care call `Pty::spawn` directly.
fn spawn(
    program: &OsStr,
    args: &[OsString],
    env: &[(OsString, OsString)],
    cwd: Option<&OsStr>,
    columns: u16,
    rows: u16,
) -> Result<Pty, PtyError> {
    Pty::spawn(program, None, args, env, cwd, columns, rows)
}

/// A single `write` to a pty master does NOT deliver a large payload, and that is the bug
/// `write_all` exists for: a paste bigger than the tty's input queue was silently truncated.
///
/// Lines are kept under `MAX_INPUT` (1024 on macOS) because the tty layer discards canonical
/// lines longer than that on its own — which would look like this bug while being something
/// else entirely.
#[test]
fn write_all_delivers_more_than_one_write_can() {
    let mut payload = Vec::new();
    for _ in 0..200 {
        payload.extend_from_slice(&b"x".repeat(99));
        payload.push(b'\n');
    }
    assert_eq!(payload.len(), 20_000);

    // The child sleeps first, so nothing is draining the input queue while we fill it.
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from("sleep 0.3; wc -c")],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");

    let short = pty.write(&payload).expect("write");
    assert!(
        short < payload.len(),
        "expected a short write to prove the queue is smaller than the payload, wrote all \
             {short} bytes"
    );
    pty.write_all(&payload[short..]).expect("write_all");
    pty.write_all(&[0x04]).expect("eof");

    let seen = read_until(&pty, "20000", Duration::from_secs(10));
    assert!(
        seen.contains("20000"),
        "the shell did not receive all 20000 bytes; saw {:?}",
        &seen[seen.len().saturating_sub(200)..]
    );
}

#[test]
fn argv0_is_what_the_caller_says_it_is() {
    // The whole point of the parameter: a shell reads argv[0] to decide it is a login shell,
    // and `$0` is how that is observable from inside it.
    let pty = Pty::spawn(
        OsStr::new("/bin/sh"),
        Some(OsStr::new("-sh")),
        &[OsString::from("-c"), OsString::from("printf %s \"$0\"")],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    assert_eq!(
        read_until(&pty, "-sh", Duration::from_secs(5)).trim(),
        "-sh"
    );
}

/// A descriptor this process holds without close-on-exec when a shell starts must not reach
/// the shell. That is the state of every socket and pipe another thread is creating at that
/// moment: on macOS, std opens it and only then marks it close-on-exec, so an accepted client
/// or a forward's listener could otherwise live on in a session's shell.
#[test]
fn the_shell_inherits_no_descriptor_but_its_terminal() {
    let mut fds = [-1; 2];
    // SAFETY: `fds` has room for the two descriptors pipe writes.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0, "pipe");
    // Well above anything the shell opens for itself, and left without close-on-exec.
    // SAFETY: F_DUPFD takes and returns plain integers.
    let stray = unsafe { libc::fcntl(fds[1], libc::F_DUPFD, 60) };
    assert!(stray >= 60, "dup: {}", std::io::Error::last_os_error());
    // SAFETY: the test's own pipe ends, closed once and not used after.
    unsafe {
        libc::close(fds[0]);
        libc::close(fds[1]);
    }

    let check = format!("if [ -e /dev/fd/{stray} ]; then echo LEAKED; else echo CLEAN; fi");
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from(check)],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    // SAFETY: the test's own duplicate, closed once and not used after.
    unsafe { libc::close(stray) };
    let output = read_until(&pty, "\n", Duration::from_secs(5));
    assert!(
        output.contains("CLEAN"),
        "the shell held descriptor {stray}: {output:?}"
    );
}

#[test]
fn runs_a_command_and_reads_its_output() {
    let pty = spawn(
        OsStr::new("/bin/echo"),
        &[OsString::from("hello-from-pty")],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    let output = read_until(&pty, "hello-from-pty", Duration::from_secs(5));
    assert!(output.contains("hello-from-pty"), "got {output:?}");
}

/// `wait_readable` sleeps through a quiet child and wakes for its output, and wakes again when
/// the child is gone, so a reader that blocks on it never misses the end of a session.
#[test]
fn wait_readable_wakes_for_output_and_for_the_end() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from("sleep 0.3; echo late")],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    let started = Instant::now();
    pty.wait_readable().expect("wait for output");
    assert!(
        started.elapsed() >= Duration::from_millis(200),
        "woke before the child spoke"
    );
    let output = read_until(&pty, "late", Duration::from_secs(5));
    assert!(output.contains("late"), "got {output:?}");
    // The child exits after its echo: the master reads as ended, and the wait says so too.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut buffer = [0u8; 64];
    loop {
        assert!(
            Instant::now() < deadline,
            "the end of the child never became readable"
        );
        pty.wait_readable().expect("wait for the end");
        match pty.read(&mut buffer) {
            Ok(0) => break,
            Err(e) if e.raw_os_error() == Some(libc::EIO) => break,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => panic!("unexpected read failure: {e}"),
        }
    }
}

/// Opening a watch after the child ended still observes its exit, does not reap it and cannot
/// leak the watch into an exec hand-off. Both early and late registration use the real kernel.
#[cfg(target_os = "linux")]
#[test]
fn the_exit_descriptor_observes_early_and_late_exits_without_reaping() {
    use std::os::fd::AsRawFd;
    for late in [false, true] {
        let pty = spawn(
            OsStr::new("/bin/sh"),
            &[OsString::from("-c"), OsString::from("sleep 0.1; exit 7")],
            &env(),
            None,
            80,
            24,
        )
        .expect("spawn");
        if late {
            pty.wait_readable().expect("child ends before registration");
        }
        let exit = pty.child_exit_fd().expect("pidfd_open on the test kernel");
        // SAFETY: F_GETFD reads the flags of our own live descriptor.
        let flags = unsafe { libc::fcntl(exit.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !pty.wait_readable_or_exit(&exit).expect("wait for child") {
            assert!(Instant::now() < deadline, "child exit never arrived");
        }
        assert_eq!(pty.wait(), Some(7 << 8), "only this wait reaps the child");
    }
}

/// The reason the self-pipe exists. Without it this spawn "succeeds" and the session closes
/// moments later, indistinguishable from a shell that exited on its own.
#[test]
fn reports_exec_failure_rather_than_a_live_session() {
    let result = spawn(OsStr::new("/nonexistent/shell"), &[], &env(), None, 80, 24);
    match result {
        Err(PtyError::Exec { program, source }) => {
            assert!(program.contains("nonexistent"));
            assert_eq!(source.raw_os_error(), Some(libc::ENOENT));
        }
        other => panic!("expected an exec failure, got {other:?}"),
    }
}

#[test]
fn spawns_in_the_requested_directory() {
    let pty = spawn(
        OsStr::new("/bin/pwd"),
        &[],
        &env(),
        Some(OsStr::new("/tmp")),
        80,
        24,
    )
    .expect("spawn");
    let output = read_until(&pty, "tmp", Duration::from_secs(5));
    assert!(output.contains("tmp"), "got {output:?}");
}

/// A workroom directory deleted while the session was detached must still yield a working
/// shell, not a dead session, and in `$HOME` rather than at `/`.
#[test]
fn falls_back_when_the_directory_is_gone() {
    let home = std::env::var("HOME").expect("HOME");
    let pty = spawn(
        OsStr::new("/bin/pwd"),
        &[],
        &env(),
        Some(OsStr::new("/definitely/not/here")),
        80,
        24,
    )
    .expect("a missing cwd must not fail the spawn");
    let output = read_until(&pty, &home, Duration::from_secs(5));
    assert!(output.contains(&home), "got {output:?}");
}

#[test]
fn reports_the_size_it_was_given() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from("stty size; exit")],
        &env(),
        None,
        120,
        40,
    )
    .expect("spawn");
    let output = read_until(&pty, "40 120", Duration::from_secs(5));
    assert!(output.contains("40 120"), "got {output:?}");
}

/// Zero is the "client has no size yet" sentinel, and a pty of 0x0 makes full-screen programs
/// misbehave rather than fail, so it is replaced rather than passed through.
#[test]
fn substitutes_a_default_for_a_zero_size() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from("stty size; exit")],
        &env(),
        None,
        0,
        0,
    )
    .expect("spawn");
    let output = read_until(&pty, "24 80", Duration::from_secs(5));
    assert!(output.contains("24 80"), "got {output:?}");
}

#[test]
fn resize_reaches_the_child() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[
            OsString::from("-c"),
            // Wait for the resize, then report. `stty size` before it would race.
            OsString::from("sleep 0.4; stty size; exit"),
        ],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    pty.resize(Size::cells(100, 30)).expect("resize");
    let output = read_until(&pty, "30 100", Duration::from_secs(5));
    assert!(output.contains("30 100"), "got {output:?}");
}

/// Value: protects=a pane reports its pixel size, which `kitten icat` refuses to run without
/// (#551); fails_when=resize stops setting the winsize pixels; why_new=stty only shows cells;
/// seam=none; no_claim=a program reading it (the attach tests cover the path to here)
#[test]
fn a_resize_reaches_the_kernel_with_its_pixels() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from("sleep 10")],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    assert_eq!(pty.pixels().expect("pixels"), (0, 0));
    let size = Size {
        columns: 100,
        rows: 30,
        x_pixels: 1000,
        y_pixels: 600,
    };
    pty.resize(size).expect("resize");
    assert_eq!(pty.size().expect("size"), (100, 30));
    assert_eq!(pty.pixels().expect("pixels"), (1000, 600));
}

#[test]
fn reports_the_foreground_process() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[OsString::from("-c"), OsString::from("sleep 10")],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    // The pty's foreground group exists as soon as the child is session leader — which is
    // BEFORE it execs, and a process between fork and exec has no arguments to read yet
    // (#224: read the name in that window and it is `None`). So wait for both, for up to 5 s
    // of the child's 10 (closing the master when `pty` drops hangs it up).
    let mut found = None;
    for _ in 0..250 {
        if let Some(pgid) = pty.foreground_pgid()
            && let Some(name) = crate::terminal::process::executable_name(pgid)
        {
            found = Some((pgid, name));
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let (pgid, _name) = found.expect("a foreground process group with a readable name");
    assert!(pgid > 0);
    // Not left to the hangup when `pty` drops: kill the child's whole group (it is a session
    // leader, so `sh` and a `sleep` it forked share it) and reap it.
    // SAFETY: `kill` takes no pointers, and `pty` has not been waited on, so the group is live.
    unsafe { libc::kill(-pty.child_pid(), libc::SIGKILL) };
    assert!(pty.wait().is_some(), "the child was not reaped");
}

#[test]
fn input_written_to_the_master_reaches_the_child() {
    let pty = spawn(
        OsStr::new("/bin/sh"),
        &[
            OsString::from("-c"),
            OsString::from("read line; echo got:$line"),
        ],
        &env(),
        None,
        80,
        24,
    )
    .expect("spawn");
    std::thread::sleep(Duration::from_millis(200));
    pty.write(b"ping\n").expect("write");
    let output = read_until(&pty, "got:ping", Duration::from_secs(5));
    assert!(output.contains("got:ping"), "got {output:?}");
}

#[test]
fn rejects_an_interior_nul_rather_than_truncating() {
    let bad = OsString::from_vec(b"/bin/sh\0extra".to_vec());
    assert!(matches!(
        spawn(&bad, &[], &env(), None, 80, 24),
        Err(PtyError::InteriorNul("program"))
    ));
}
