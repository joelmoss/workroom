use super::attached::{apply_size, repaint_budget, terminal_envelope};
#[cfg(feature = "terminal-state")]
use super::freeze::{HANDOFF_IMAGE_BYTES, HANDOFF_TOTAL_BYTES, carry_images, carry_listed};
use super::reader::{child_exited, child_gone};
use super::refusals::{REFUSALS_MAGIC, REFUSED_ID_WINDOW, wall_now, write_refusals};
use super::store::{RECORD_GRACE, RECORD_WAIT};
use super::*;
use crate::daemon::transport::WRITE_TIMEOUT;
#[cfg(feature = "terminal-state")]
use crate::terminal::images::{self, ImageRef};
use std::io::Write;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use wr_protocol::frame::{Frame, FrameKind};

fn id(byte: u8) -> SessionId {
    SessionId([byte; 16])
}

/// The reader's one look at a kill's id: nothing to wait for only when the id is neither a
/// session nor one being ended, so a kill racing in from another connection is never waited
/// on there (#283).
#[test]
fn only_an_id_neither_live_nor_ending_is_absent() {
    let store = SessionStore::new();
    let id = id(0x52);
    assert!(store.end_if_absent(id), "an unknown id");
    let ending = store.mark_ending(vec![id]);
    assert!(!store.end_if_absent(id), "an id still being ended");
    drop(ending);
    assert!(store.end_if_absent(id), "once ended");
}

/// A session ended twice over, as an id is created again while its first kill still runs, stays
/// marked as being ended until both are done: the first finishing must not let a third kill be
/// acknowledged early (#283).
#[test]
fn an_id_ended_twice_stays_marked_until_both_end() {
    let store = SessionStore::new();
    let id = id(0x51);
    let first = store.mark_ending(vec![id]);
    let second = store.mark_ending(vec![id]);
    drop(first);
    assert!(
        store.is_ending(id),
        "unmarked while the second is still ending"
    );
    drop(second);
    assert!(!store.is_ending(id), "still marked once both ended");
}

/// Waiting for kills returns as soon as none is in flight, and gives up at its deadline while
/// one still is (#283).
#[test]
fn waiting_for_kills_ends_with_them_or_at_its_deadline() {
    let store = SessionStore::new();
    assert!(
        store.wait_for_kills(Instant::now()),
        "nothing in flight to wait for"
    );
    let in_flight = store.kill_in_flight();
    let started = Instant::now();
    assert!(!store.wait_for_kills(started + Duration::from_millis(50)));
    assert!(
        started.elapsed() >= Duration::from_millis(50),
        "gave up before its deadline"
    );
    let releasing = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        drop(in_flight);
    });
    assert!(store.wait_for_kills(Instant::now() + Duration::from_secs(5)));
    releasing.join().unwrap();
}

/// A kill counted in flight is given back when its guard drops: a count that leaked would keep
/// the daemon from ever idle-exiting and every hand-off refused (#283). Counted, not flagged, so
/// one kill ending does not clear another's.
#[test]
fn a_kill_in_flight_is_given_back_when_its_guard_drops() {
    let store = SessionStore::new();
    assert!(!store.is_killing());
    let first = store.kill_in_flight();
    let second = store.kill_in_flight();
    drop(first);
    assert!(store.is_killing(), "one kill ending cleared another's");
    drop(second);
    assert!(!store.is_killing(), "the count leaked");
}

fn env() -> Vec<(OsString, OsString)> {
    vec![
        (OsString::from("TERM"), OsString::from("xterm-256color")),
        (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
    ]
}

fn spec<'a>(
    session: SessionId,
    args: &'a [OsString],
    env: &'a [(OsString, OsString)],
) -> SessionSpec<'a> {
    SessionSpec {
        id: session,
        program: OsStr::new("/bin/sh"),
        argv0: None,
        args,
        env,
        cwd: None,
        columns: 80,
        rows: 24,
        metadata: &[],
        interactive: false,
    }
}

/// A retag changes only `workroom`, adds it when absent, and what the list and a hand-off then
/// report is the new tag, not the one the session was created with.
/// Value: protects=a live session's workroom tag follows a Retag in the list and in a hand-off while title and created stay; fails_when=set_workroom changes a copy, drops another key, or ignores an absent workroom; why_new=metadata was fixed at creation, so nothing exercised a change; seam=none
#[test]
fn a_retag_changes_the_workroom_the_list_and_a_hand_off_report() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 2")];
    let e = env();
    let tagged = [
        ("workroom".to_string(), "old".to_string()),
        ("title".to_string(), "t".to_string()),
    ];
    let untagged = [("title".to_string(), "u".to_string())];
    for (n, metadata) in [(1, &tagged[..]), (2, &untagged[..])] {
        let mut s = spec(id(n), &args, &e);
        s.metadata = metadata;
        store.create(s).expect("create");
    }

    assert!(store.set_workroom(id(1), "new"));
    assert!(store.set_workroom(id(2), "added"));
    assert!(!store.set_workroom(id(3), "x"), "an unknown id");

    let value = |metadata: &[(String, String)], key: &str| {
        metadata
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.clone())
    };
    let listed = store.list();
    for (n, workroom, title) in [(1, "new", "t"), (2, "added", "u")] {
        let info = listed.iter().find(|i| i.id == id(n)).expect("listed");
        assert_eq!(value(&info.metadata, "workroom").as_deref(), Some(workroom));
        assert_eq!(value(&info.metadata, "title").as_deref(), Some(title));
        assert!(value(&info.metadata, CREATED_KEY).is_some(), "created kept");
        assert_eq!(
            info.metadata
                .iter()
                .filter(|(k, _)| k == "workroom")
                .count(),
            1
        );
    }

    let frozen = store
        .frozen(Duration::from_secs(2), |all| {
            all.iter()
                .find(|s| s.id == id(1))
                .map(|s| value(&s.metadata, "workroom"))
        })
        .expect("frozen")
        .expect("session frozen");
    assert_eq!(frozen.as_deref(), Some("new"));
    store.kill_all();
}

/// A hand-off's session with only what `adopt` reads from it: an 80x24 `screen`.
fn frozen_with(session: SessionId, screen: &[u8]) -> FrozenSession {
    FrozenSession {
        id: session,
        pid: 0,
        master: -1,
        columns: 80,
        rows: 24,
        screen: screen.to_vec(),
        metadata: Vec::new(),
        program_status: Store::default(),
    }
}

/// Everything the session sent to its attached client.
///
/// Tests read through this rather than off the pty, because the pty has exactly one reader now
/// — the session's own — and a test competing with it for bytes would make both flaky.
#[derive(Clone, Default)]
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().expect("capture").extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Capture {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().expect("capture")).into_owned()
    }
}

/// Attaches a capturing client, returning it and the attachment's token.
fn attach_capture(store: &SessionStore, session: SessionId) -> (Capture, u64) {
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (_, token) = store
        .attach(session, writer, 1, Size::cells(80, 24))
        .expect("attach");
    (capture, token)
}

/// Polls a capture until the needle shows up. The bytes carry envelope and frame headers
/// around the payload, and a substring search sees straight through them.
fn wait_for(capture: &Capture, needle: &str, timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    loop {
        let seen = capture.text();
        if seen.contains(needle) || Instant::now() >= deadline {
            return seen;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_command_that_writes_before_registration_still_delivers_output_and_exit() {
    let store = SessionStore::new();
    let args = [
        OsString::from("-c"),
        OsString::from("echo EARLY-OUTPUT; exit 7"),
    ];
    let e = env();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    store
        .create_then(spec(id(80), &args, &e), |info| {
            // Wait for pending output without consuming it. Waiting for child exit instead
            // deadlocks on macOS, where PTY close can wait for the output to be drained.
            let (pty, _, _) = store.parts(info.id).expect("new session");
            let mut descriptor = libc::pollfd {
                fd: pty.master_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "command produced no output");
                // SAFETY: one live pollfd, for a master descriptor `pty` keeps open.
                let ready =
                    unsafe { libc::poll(&mut descriptor, 1, remaining.as_millis() as libc::c_int) };
                if ready < 0
                    && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
                {
                    continue;
                }
                assert!(ready > 0, "command produced no output");
                break;
            }
            assert_ne!(descriptor.revents & libc::POLLIN, 0, "no pending output");
            store.attach(id(80), writer, 1, Size::cells(80, 24))
        })
        .expect("create and attach");
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.contains(id(80)) {
        assert!(Instant::now() < deadline, "exited session was not removed");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(capture.text().contains("EARLY-OUTPUT"));
    let exit = terminal_envelope(
        1,
        Frame::new(FrameKind::Exited, 7i32.to_be_bytes().to_vec()),
    );
    // Waited for, not asserted at once: the reader removes the session before it sends the
    // exit, so a test that sees it gone can still be a moment ahead of the frame.
    let deadline = Instant::now() + Duration::from_secs(5);
    while !capture.0.lock().unwrap().ends_with(&exit) {
        assert!(Instant::now() < deadline, "missing final exit frame");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn failed_initial_registration_still_drains_and_retires_the_session() {
    let store = SessionStore::new();
    // More than the PTY buffer: without a reader this child cannot finish.
    let args = [
        OsString::from("-c"),
        OsString::from("head -c 131072 /dev/zero"),
    ];
    let e = env();
    let result: Result<(), SessionError> = store.create_then(spec(id(81), &args, &e), |_| {
        Err(SessionError::RepaintFailed(id(81).to_hyphenated()))
    });
    assert!(matches!(result, Err(SessionError::RepaintFailed(_))));
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.contains(id(81)) {
        assert!(
            Instant::now() < deadline,
            "failed attach stranded its session"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn creates_and_lists_a_session() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 2")];
    let e = env();
    store.create(spec(id(1), &args, &e)).expect("create");

    let listed = store.list();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, id(1));
    // Stamped with when it was made, which orders the sessions a layout does not name (#255).
    let created: u128 = listed[0]
        .metadata
        .iter()
        .find(|(key, _)| key == CREATED_KEY)
        .and_then(|(_, value)| value.parse().ok())
        .expect("a created stamp");
    assert!(
        created.abs_diff(wall_now().as_millis()) < 60_000,
        "{created}"
    );
    // Created, but nobody is holding it yet: the session exists and its pty is already being
    // drained, and a client becomes attached only by attaching.
    assert!(!listed[0].attached);

    let (_client, _) = attach_capture(&store, id(1));
    assert!(store.list()[0].attached);
    store.kill_all();
}

/// The runs watcher sleeps on `Runs::wait_for_wake` while the map holds no run session; a run
/// session's creation wakes it, a shell's does not.
#[test]
fn a_run_session_wakes_the_runs_watcher_and_a_shell_does_not() {
    let store = SessionStore::new();
    let seen = store.hooks().runs.wake();
    let args = [OsString::from("-c"), OsString::from("sleep 2")];
    let e = env();
    store.create(spec(id(93), &args, &e)).expect("a shell");
    assert_eq!(store.hooks().runs.wake(), seen, "a shell is not a run");

    let (done, woke) = std::sync::mpsc::channel();
    let waiting = store.clone();
    std::thread::spawn(move || {
        waiting.hooks().runs.wait_for_wake(seen);
        let _ = done.send(());
    });
    assert!(
        woke.recv_timeout(Duration::from_millis(200)).is_err(),
        "nothing to wake for yet"
    );
    let run = [(
        crate::terminal::run::KIND_KEY.to_string(),
        crate::terminal::run::RUN_KIND.to_string(),
    )];
    store
        .create(SessionSpec {
            metadata: &run,
            ..spec(id(94), &args, &e)
        })
        .expect("a run");
    assert!(
        woke.recv_timeout(Duration::from_secs(5)).is_ok(),
        "woken by the run session"
    );

    // A signal to a finished run is what makes its supervisor write a new status: the watcher
    // asleep on the old one must hear of it, or a restarted run tab keeps showing "exited".
    let before = store.hooks().runs.wake();
    store
        .signal_run(id(94), wr_protocol::frame::RunSignal::Stop)
        .expect("signal the run");
    assert_ne!(
        store.hooks().runs.wake(),
        before,
        "a signal did not wake the watcher"
    );

    // A run that ends, on its own or killed, must wake it too: the watcher asleep on its
    // finished status is what removes its status file, which otherwise outlives the run.
    let brief = [OsString::from("-c"), OsString::from("sleep 0.5")];
    store
        .create(SessionSpec {
            metadata: &run,
            ..spec(id(99), &brief, &e)
        })
        .expect("a run that ends");
    let before = store.hooks().runs.wake();
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.hooks().runs.wake() == before {
        assert!(
            Instant::now() < deadline,
            "a run ending did not wake the watcher"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let long = [OsString::from("-c"), OsString::from("sleep 30")];
    store
        .create(SessionSpec {
            metadata: &run,
            ..spec(id(100), &long, &e)
        })
        .expect("a run to kill");
    let before = store.hooks().runs.wake();
    assert!(store.kill(id(100)), "fixture: the run was there to kill");
    assert_ne!(
        store.hooks().runs.wake(),
        before,
        "killing a run did not wake the watcher"
    );
    // A run of its own for `kill_all`: the Stop above ended id(94) (its `sh` has no handler).
    store
        .create(SessionSpec {
            metadata: &run,
            ..spec(id(101), &long, &e)
        })
        .expect("a run for kill_all");
    let before = store.hooks().runs.wake();
    store.kill_all();
    assert_ne!(
        store.hooks().runs.wake(),
        before,
        "killing every run did not wake the watcher"
    );
}

/// The screens thread sleeps on `KeptScreens::wait_for_work` until a session prints, is resized or
/// ends; a session that has nothing to say does not wake it.
#[test]
fn output_wakes_the_screens_thread_and_silence_does_not() {
    let store = SessionStore::new();
    let seen = store.hooks().screens.work();
    let e = env();
    let quiet = [OsString::from("-c"), OsString::from("sleep 10")];
    store
        .create(spec(id(95), &quiet, &e))
        .expect("a quiet session");

    let (done, woke) = std::sync::mpsc::channel();
    let waiting = store.clone();
    std::thread::spawn(move || {
        waiting.hooks().screens.wait_for_work(seen);
        let _ = done.send(());
    });
    assert!(
        woke.recv_timeout(Duration::from_millis(300)).is_err(),
        "a session with nothing to say woke the screens thread"
    );
    // Long-lived, so within the wait only its output can be what wakes the thread, not its end.
    let talks = [OsString::from("-c"), OsString::from("echo hi; sleep 10")];
    store
        .create(spec(id(96), &talks, &e))
        .expect("a session that prints");
    assert!(
        woke.recv_timeout(Duration::from_secs(3)).is_ok(),
        "output did not wake the screens thread"
    );

    // A session ending on its own is a change too (a `kill` drops its record itself): the
    // record goes on the next pass, which the thread asleep must be woken for.
    let brief = [OsString::from("-c"), OsString::from("sleep 0.5")];
    store
        .create(spec(id(97), &brief, &e))
        .expect("a session that ends");
    let before = store.hooks().screens.work();
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.hooks().screens.work() == before {
        assert!(
            Instant::now() < deadline,
            "a session ending did not wake the screens thread"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    store.kill_all();
}

/// The screens thread sleeps until something wakes it, so two things that leave it work with
/// no output must wake it themselves: an attach's repaint, which re-inflates the shadow's
/// compressed history even when the client claims no size, and a record skipped because the
/// session's attachment was held past the pass's budget.
/// Value: protects=a quiet session's history is recompressed after a second client attaches, and its record is retried after a busy pass; fails_when=either raise is dropped; why_new=the other wake tests cover output, resize and session end only; seam=none; no_claim=the compression and the record write themselves (screens tests)
#[test]
fn an_attach_and_a_skipped_record_wake_the_screens_thread() {
    let store = SessionStore::new();
    let e = env();
    let quiet = [OsString::from("-c"), OsString::from("sleep 10")];
    store
        .create(spec(id(98), &quiet, &e))
        .expect("a quiet session");
    let (_first, _) = attach_capture(&store, id(98));
    // The first client took the size; the second claims none, so only the repaint is left.
    let before = store.hooks().screens.work();
    let (_second, _) = attach_capture(&store, id(98));
    assert_ne!(
        store.hooks().screens.work(),
        before,
        "an attach that claimed no size did not wake the screens thread"
    );

    let (_, _, attached) = store.parts(id(98)).expect("the session");
    let mut held = attached.lock().expect("attachment");
    held.changed = true;
    let before = store.hooks().screens.work();
    assert!(
        store.changed_screens().is_empty(),
        "fixture: a held attachment's record was taken"
    );
    assert_ne!(
        store.hooks().screens.work(),
        before,
        "a record skipped on a held attachment did not wake the screens thread"
    );
    drop(held);
    assert_eq!(
        store.changed_screens().len(),
        1,
        "the skipped record on the next pass"
    );
    store.kill_all();
}

#[test]
fn refuses_a_duplicate_id() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 2")];
    let e = env();
    store.create(spec(id(2), &args, &e)).expect("create");
    assert!(matches!(
        store.create(spec(id(2), &args, &e)),
        Err(SessionError::AlreadyExists(_))
    ));
    store.kill_all();
}

/// A refused id is not created again until the window has passed, and other ids are not held
/// up by it.
#[test]
fn a_refused_id_is_not_created_until_its_window_passes() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 2")];
    let e = env();
    store.refuse(id(40));
    assert!(matches!(
        store.create(spec(id(40), &args, &e)),
        Err(SessionError::Ended(_))
    ));
    store.create(spec(id(41), &args, &e)).expect("another id");
    store.refused.lock().unwrap().insert(id(40), Instant::now());
    store
        .create(spec(id(40), &args, &e))
        .expect("after the window");
    store.kill_all();
}

/// The next program to serve the socket refuses what this one did: the refusals file carries
/// them, an ended one is left behind, and a file that is not one costs only its refusals.
#[test]
fn refusals_outlive_the_store_that_made_them() {
    let dir = std::env::temp_dir().join(format!("wr-refusals-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = refusals_path(&dir.join("workroomd.sock"));

    let first = SessionStore::new();
    first.refuse(id(42));
    assert!(!path.exists(), "a store with no file wrote one");
    first.keep_refusals(path.clone());
    first.refuse(id(43));
    assert!(first.is_refused(id(42)) && first.is_refused(id(43)));

    let next = SessionStore::new();
    next.keep_refusals(path.clone());
    assert!(
        next.is_refused(id(42)),
        "the refusal made before the file was lost"
    );
    assert!(
        next.is_refused(id(43)),
        "the refusal did not reach the next store"
    );
    assert!(!next.is_refused(id(44)));

    let mut ended = HashMap::new();
    ended.insert(id(45), Instant::now());
    let later = Instant::now() + Duration::from_secs(1);
    write_refusals(&path, &ended, later).unwrap();
    let after = SessionStore::new();
    after.keep_refusals(path.clone());
    assert!(!after.is_refused(id(45)), "an ended refusal was taken up");

    // A clock set back, or a program whose clock was ahead, cannot stretch a refusal past a
    // window from now.
    let mut ahead = REFUSALS_MAGIC.to_vec();
    ahead.extend_from_slice(&id(46).0);
    let hour = wall_now() + Duration::from_secs(3600);
    ahead.extend_from_slice(&(hour.as_millis() as u64).to_be_bytes());
    std::fs::write(&path, ahead).unwrap();
    let clamped = SessionStore::new();
    clamped.keep_refusals(path.clone());
    let until = clamped.refused.lock().unwrap()[&id(46)];
    assert!(
        until <= Instant::now() + REFUSED_ID_WINDOW,
        "a refusal from a clock ahead outlasts the window"
    );

    std::fs::write(&path, b"WRRF and then nonsense").unwrap();
    let damaged = SessionStore::new();
    damaged.keep_refusals(path.clone());
    assert!(damaged.refused.lock().unwrap().is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A refusal that cannot be written still refuses: the file only carries it further.
#[test]
fn a_refusal_that_cannot_be_kept_still_refuses() {
    let store = SessionStore::new();
    store.keep_refusals(std::env::temp_dir().join("wr-no-such-dir/workroomd.refused"));
    store.refuse(id(47));
    assert!(store.is_refused(id(47)));
}

/// Value: protects=a hand-off keeps an image's rows, with no pixels in the table (#551);
/// fails_when=adopt stops reading the pixels from the pty; why_new=no adoption test had an
/// image; seam=none; no_claim=a real exec, which tests/hand_off.rs covers without images
#[cfg(feature = "terminal-state")]
#[test]
fn adopting_takes_the_pixels_from_the_pty_before_the_screen() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    let pty = Pty::spawn(OsStr::new("/bin/sh"), None, &args, &e, None, 80, 24).expect("pty");
    pty.resize(Size {
        columns: 80,
        rows: 24,
        x_pixels: 800,
        y_pixels: 480,
    })
    .expect("resize");
    // 40x40 pixels, so 2 rows tall at 10x20 a cell: BELOW is on the third row.
    let mut screen = b"\x1b_Ga=T,f=24,s=40,v=40,i=7,q=2;".to_vec();
    screen.extend_from_slice(&[b'A'; 6400]);
    screen.extend_from_slice(b"\x1b\\\r\nBELOW");
    store
        .adopt(pty, frozen_with(id(10), &screen))
        .expect("adopt");

    let mut client = crate::terminal::vt::ShadowTerminal::new(80, 24).expect("client");
    client.write(&store.replay_bytes(id(10)));
    let row = client
        .visible_text()
        .lines()
        .position(|line| line.contains("BELOW"));
    assert_eq!(row, Some(2));
    store.kill_all();
}

/// What a client was sent, out of its envelopes and frames.
#[cfg(feature = "terminal-state")]
fn sent_bytes(capture: &Capture) -> Vec<u8> {
    use wr_protocol::envelope::EnvelopeDecoder;
    use wr_protocol::frame::FrameDecoder;
    let mut envelopes = EnvelopeDecoder::new();
    envelopes.push(&capture.0.lock().expect("capture"));
    let mut frames = FrameDecoder::new();
    while let Ok(Some(envelope)) = envelopes.next_envelope() {
        frames.push(&envelope.payload);
    }
    let mut out = Vec::new();
    while let Ok(Some(frame)) = frames.next_frame() {
        if frame.kind == FrameKind::Output {
            out.extend_from_slice(&frame.payload);
        }
    }
    out
}

/// A raw 2x2 image, shown where the cursor is.
#[cfg(feature = "terminal-state")]
fn program_image(id: u32) -> Vec<u8> {
    let mut out = format!("\x1b_Ga=T,f=24,s=2,v=2,i={id},q=2;").into_bytes();
    out.extend_from_slice(&[b'A'; 16]);
    out.extend_from_slice(b"\x1b\\");
    out
}

/// Noise, so its PNG takes several chunks and leaves a load open between them.
#[cfg(feature = "terminal-state")]
fn noise_image(id: u32) -> Vec<u8> {
    let mut noise = format!("\x1b_Ga=T,f=24,s=100,v=100,i={id},q=2;").into_bytes();
    let mut seed = 0x2545_F491_u32;
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    noise.extend((0..40_000).map(|_| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        alphabet[(seed % 64) as usize]
    }));
    noise.extend_from_slice(b"\x1b\\");
    noise
}

/// 10x20 pixels a cell, as a client's: an image covers no cells at zero.
#[cfg(feature = "terminal-state")]
const PIXEL_SIZE: Size = Size {
    columns: 80,
    rows: 24,
    x_pixels: 800,
    y_pixels: 480,
};

/// `attach_capture` for a client that says its pixels, as a real one does.
#[cfg(feature = "terminal-state")]
fn attach_with_pixels(store: &SessionStore, session: SessionId) -> (Capture, u64) {
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (_, token) = store
        .attach(session, writer, 1, PIXEL_SIZE)
        .expect("attach");
    (capture, token)
}

#[cfg(feature = "terminal-state")]
fn shadow_write(store: &SessionStore, session: SessionId, bytes: &[u8]) {
    let shadow = store.shadow(session).expect("shadow");
    let mut shadow = shadow.lock().expect("shadow");
    shadow.resize(PIXEL_SIZE);
    shadow.write(bytes);
}

/// Lets a test act between a client's first image chunk and the rest.
#[cfg(feature = "terminal-state")]
#[derive(Clone)]
struct GatedCapture {
    capture: Capture,
    reached: Arc<std::sync::atomic::AtomicBool>,
    open: Arc<std::sync::atomic::AtomicBool>,
}

#[cfg(feature = "terminal-state")]
impl Write for GatedCapture {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let written = self.capture.write(bytes)?;
        if has(bytes, b"a=t,f=100") {
            self.reached.store(true, Ordering::SeqCst);
            while !self.open.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        Ok(written)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Value: protects=an image on screen comes back after a reattach, after its text (#551);
/// fails_when=the transfer, its order or its placement breaks; why_new=no test restored an
/// image; seam=none; no_claim=the app's drawing, checked in the app
#[cfg(feature = "terminal-state")]
#[test]
fn a_reattaching_client_gets_its_text_then_its_image() {
    let store = SessionStore::new();
    sized_session(&store, id(37));
    shadow_write(&store, id(37), &program_image(7));
    shadow_write(&store, id(37), b"\r\nBELOW");

    let (capture, _) = attach_with_pixels(&store, id(37));
    let sent = wait_for_bytes(b"a=p,i=7", || sent_bytes(&capture));
    let at = |needle: &[u8]| sent.windows(needle.len()).position(|w| w == needle);
    let text = at(b"BELOW").expect("the text");
    let chunk = at(b"a=t,f=100,i=7").expect("the image");
    let placed = at(b"a=p,i=7").expect("its placement");
    assert_eq!(at(images::ABORT), Some(0), "first, for a cut-off transfer");
    assert!(text < chunk && chunk < placed, "{sent:?}");

    let mut client = crate::terminal::vt::ShadowTerminal::new(80, 24).expect("client");
    client.set_cell_pixels(10, 20);
    client.resize(80, 24);
    client.write(&sent);
    assert_eq!(client.visible_images().len(), 1);
    assert!(client.visible_text().contains("BELOW"));
    store.kill_all();
}

/// Value: protects=a session with no images sends no image bytes; fails_when=a transfer starts
/// regardless; why_new=new; seam=none; no_claim=none beyond protects
#[cfg(feature = "terminal-state")]
#[test]
fn a_session_without_images_starts_no_transfer() {
    let store = SessionStore::new();
    sized_session(&store, id(38));
    shadow_write(&store, id(38), b"text");
    let (capture, _) = attach_capture(&store, id(38));
    let (_, _, attached) = store.parts(id(38)).expect("parts");
    assert!(attached.lock().expect("lock").clients[0].transfer.is_none());
    assert!(!has(&sent_bytes(&capture), b"a=t"));
    store.kill_all();
}

/// Value: protects=image bytes never land inside a long sequence (#551); fails_when=the
/// reader's ground check goes, or uses the capped continuation; why_new=the terminal test
/// covers the check, not the reader's use of it; seam=none; no_claim=none beyond protects
#[cfg(feature = "terminal-state")]
#[test]
fn image_data_waits_through_an_unfinished_8_kb_sequence() {
    let store = SessionStore::new();
    sized_session(&store, id(39));
    shadow_write(&store, id(39), &program_image(7));
    let mut long = b"\x1b]52;c;".to_vec();
    long.extend(std::iter::repeat_n(b'A', 8192));
    shadow_write(&store, id(39), &long);

    let (capture, _) = attach_with_pixels(&store, id(39));
    std::thread::sleep(Duration::from_millis(300));
    store
        .with_pty(id(39), |pty| pty.wake_reader())
        .expect("session");
    std::thread::sleep(Duration::from_millis(100));
    assert!(!has(&sent_bytes(&capture), b"a=t"), "mid-sequence");

    shadow_write(&store, id(39), b"\x07");
    store
        .with_pty(id(39), |pty| pty.wake_reader())
        .expect("session");
    assert!(has(
        &wait_for_bytes(b"a=t", || sent_bytes(&capture)),
        b"a=t"
    ));
    store.kill_all();
}

/// A session that prints `image` when it is sent a line.
#[cfg(feature = "terminal-state")]
fn session_printing_on_input(store: &SessionStore, session: SessionId, image: &[u8]) {
    let octal: String = image.iter().map(|byte| format!("\\{byte:03o}")).collect();
    // No echo, which would be output of its own ahead of the image.
    let script = format!("stty -echo; read line; printf '{octal}'; sleep 30");
    let args = [OsString::from("-c"), OsString::from(script)];
    let e = env();
    store.create(spec(session, &args, &e)).expect("create");
}

/// Value: protects=a program's image survives our transfer, the one case that can lose its
/// data (#551); fails_when=the stop or its abort goes; why_new=new; seam=none;
/// no_claim=real Ghostty, the same engine at the same revision
#[cfg(feature = "terminal-state")]
#[test]
fn a_programs_image_ends_a_transfer_with_an_abort_ahead_of_it() {
    let store = SessionStore::new();
    session_printing_on_input(&store, id(40), &program_image(99));
    shadow_write(&store, id(40), &noise_image(7));

    let gate = GatedCapture {
        capture: Capture::default(),
        reached: Arc::default(),
        open: Arc::default(),
    };
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(gate.clone())));
    let (_, token) = store.attach(id(40), writer, 1, PIXEL_SIZE).expect("attach");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !gate.reached.load(Ordering::SeqCst) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(gate.reached.load(Ordering::SeqCst), "no transfer began");
    store.write_input(id(40), token, b"go\n");
    std::thread::sleep(Duration::from_millis(100));
    gate.open.store(true, Ordering::SeqCst);

    let sent = wait_for_bytes(b"i=99", || sent_bytes(&gate.capture));
    let at = |needle: &[u8]| sent.windows(needle.len()).rposition(|w| w == needle);
    let program = at(b"i=99").expect("the program's image");
    assert!(at(images::ABORT) < Some(program), "the abort goes first");
    assert!(!has(&sent[program..], b"m=1"), "no chunk after it");

    let mut client = crate::terminal::vt::ShadowTerminal::new(80, 24).expect("client");
    client.set_cell_pixels(10, 20);
    client.resize(80, 24);
    client.write(&sent);
    let stored = client.visible_images();
    assert!(stored.iter().any(|image| image.id == 99), "{stored:?}");
    store.kill_all();
}

/// Value: protects=a stopped transfer sends no more, and the program's image is stored;
/// fails_when=the reader keeps sending, or an abort lands late; why_new=new; seam=none;
/// no_claim=none beyond protects
#[cfg(feature = "terminal-state")]
#[test]
fn a_held_transfer_is_dropped_when_a_program_sends_an_image() {
    let store = SessionStore::new();
    // Finishes the sequence below in the same read as its image.
    let output = [b"1m".as_slice(), &program_image(99)].concat();
    session_printing_on_input(&store, id(41), &output);
    shadow_write(&store, id(41), &program_image(7));
    // Held from the start, so the program's image arrives before any chunk.
    shadow_write(&store, id(41), b"\x1b[3");
    let (capture, token) = attach_with_pixels(&store, id(41));
    std::thread::sleep(Duration::from_millis(200));

    store.write_input(id(41), token, b"go\n");
    let sent = wait_for_bytes(b"i=99", || sent_bytes(&capture));
    assert!(has(&sent, b"i=99"), "{sent:?}");
    store
        .with_pty(id(41), |pty| pty.wake_reader())
        .expect("session");
    std::thread::sleep(Duration::from_millis(200));
    assert!(!has(&sent_bytes(&capture), b"i=7,"), "dropped");

    let (_, _, attached) = store.parts(id(41)).expect("parts");
    assert!(attached.lock().expect("lock").clients[0].transfer.is_none());
    store.kill_all();
}

/// Value: protects=a hand-off carries images, ahead of the continuation (#551);
/// fails_when=carry_images goes, or splices after the continuation; why_new=new; seam=none;
/// no_claim=a real exec and its check, which tests/hand_off.rs runs without images
#[cfg(feature = "terminal-state")]
#[test]
fn a_hand_off_carries_images_ahead_of_the_continuation() {
    let store = SessionStore::new();
    sized_session(&store, id(42));
    shadow_write(&store, id(42), &program_image(7));
    shadow_write(&store, id(42), b"\r\nBELOW\x1b[3");

    let screen = store
        .frozen(Duration::from_secs(1), |sessions| {
            sessions[0].screen.clone()
        })
        .expect("frozen");
    assert!(has(&screen, b"a=t,f=100,i=7"), "the pixels");
    assert!(has(&screen, b"a=p,i=7"), "the placement");
    assert!(screen.ends_with(b"\x1b[3"), "the continuation stays last");
    store.kill_all();

    let adopted = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    let pty = Pty::spawn(OsStr::new("/bin/sh"), None, &args, &e, None, 80, 24).expect("pty");
    pty.resize(PIXEL_SIZE).expect("resize");
    adopted
        .adopt(pty, frozen_with(id(42), &screen))
        .expect("adopt");
    let shadow = adopted.shadow(id(42)).expect("shadow");
    assert_eq!(shadow.lock().expect("shadow").visible_images().len(), 1);
    adopted.kill_all();
}

/// Value: protects=a hand-off out of time keeps its text; fails_when=carry_images ignores its
/// deadline; why_new=new; seam=none; no_claim=the measured freeze, reported in the PR
#[cfg(feature = "terminal-state")]
#[test]
fn a_hand_off_past_its_image_deadline_keeps_the_text() {
    let shadow = Arc::new(Mutex::new(Shadow::new(80, 24)));
    {
        let mut shadow = shadow.lock().expect("shadow");
        shadow.resize(PIXEL_SIZE);
        shadow.write(&program_image(7));
    }
    let mut sessions = [frozen_with(id(43), b"text")];
    carry_images(
        &[&shadow],
        &mut sessions,
        Instant::now(),
        HANDOFF_IMAGE_BYTES,
    );
    assert_eq!(sessions[0].screen, b"text");

    let later = Instant::now() + Duration::from_secs(5);
    carry_images(&[&shadow], &mut sessions, later, 10);
    assert_eq!(sessions[0].screen, b"text", "past its total");

    carry_images(&[&shadow], &mut sessions, later, HANDOFF_IMAGE_BYTES);
    assert!(has(&sessions[0].screen, b"a=t,f=100,i=7"), "fixture");
}

/// Value: protects=an image that cannot be sent costs that image alone; fails_when=one failure
/// ends the pass; why_new=the other test has one image; seam=none; no_claim=none beyond protects
#[cfg(feature = "terminal-state")]
#[test]
fn a_hand_off_skips_an_image_it_cannot_send_and_carries_the_rest() {
    let broken = Arc::new(Mutex::new(Shadow::new(80, 24)));
    let good = Arc::new(Mutex::new(Shadow::new(80, 24)));
    for (shadow, id) in [(&broken, 7), (&good, 8)] {
        let mut shadow = shadow.lock().expect("shadow");
        shadow.resize(PIXEL_SIZE);
        shadow.write(&program_image(id));
    }
    let mut sessions = [frozen_with(id(44), b""), frozen_with(id(45), b"")];
    let later = Instant::now() + Duration::from_secs(5);
    // Replaced since it was listed, so it has nothing to send.
    let stale = ImageRef {
        id: 7,
        generation: u64::MAX,
    };
    let listed = good.lock().expect("shadow").visible_images()[0];
    carry_listed(
        &[&broken, &good],
        &mut sessions,
        vec![(0, stale), (1, listed)],
        later,
        HANDOFF_IMAGE_BYTES,
    );
    assert_eq!(sessions[0].screen, b"", "that image alone");
    assert!(has(&sessions[1].screen, b"i=8"));
}

/// Value: protects=a program image split across two reads survives an open load (#551), the
/// one way left to lose it; fails_when=a read ending on ESC does not close the load;
/// why_new=the other test has the whole string in one read; seam=none; no_claim=real Ghostty
#[cfg(feature = "terminal-state")]
#[test]
fn a_programs_image_split_after_its_escape_still_survives_a_transfer() {
    let store = SessionStore::new();
    let rest = &program_image(99)[1..];
    let octal: String = rest.iter().map(|byte| format!("\\{byte:03o}")).collect();
    let script =
        format!("stty -echo; read line; printf '\\033'; sleep 0.3; printf '{octal}'; sleep 30");
    let args = [OsString::from("-c"), OsString::from(script)];
    let e = env();
    store.create(spec(id(46), &args, &e)).expect("create");
    shadow_write(&store, id(46), &noise_image(7));

    let gate = GatedCapture {
        capture: Capture::default(),
        reached: Arc::default(),
        open: Arc::default(),
    };
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(gate.clone())));
    let (_, token) = store.attach(id(46), writer, 1, PIXEL_SIZE).expect("attach");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !gate.reached.load(Ordering::SeqCst) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(gate.reached.load(Ordering::SeqCst), "no transfer began");
    store.write_input(id(46), token, b"go\n");
    std::thread::sleep(Duration::from_millis(100));
    gate.open.store(true, Ordering::SeqCst);

    let sent = wait_for_bytes(b"i=99", || sent_bytes(&gate.capture));
    let mut client = crate::terminal::vt::ShadowTerminal::new(80, 24).expect("client");
    client.set_cell_pixels(10, 20);
    client.resize(80, 24);
    client.write(&sent);
    let stored = client.visible_images();
    assert!(stored.iter().any(|image| image.id == 99), "{stored:?}");
    store.kill_all();
}

/// Adopting a hand-off's session under an id already in use is refused, as creating one is.
#[test]
fn adopt_refuses_a_duplicate_id() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 2")];
    let e = env();
    store.create(spec(id(9), &args, &e)).expect("create");
    let pty = Pty::spawn(OsStr::new("/bin/sh"), None, &args, &e, None, 80, 24).expect("pty");
    let pid = pty.child_pid();
    assert!(matches!(
        store.adopt(pty, frozen_with(id(9), b"")),
        Err(SessionError::AlreadyExists(_))
    ));
    // The refused pty was dropped, which hangs its shell up; reap it so no zombie is left.
    // SAFETY: a null status pointer is allowed, and `pid` is this test's own child.
    unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) };
    store.kill_all();
}

/// A hand-off keeps the busy indicator: the screen a session is frozen with, adopted by the
/// next program, replays its last OSC 9;4 report, so a client that attaches afterwards is told
/// the session is busy (#359). Unlike the on-disk record, a hand-off's screen is the live
/// replay (`live_replay`), which keeps the report while its sender owns the pty.
/// Value: protects=a session adopted from a frozen screen replays the progress report it was frozen with; fails_when=frozen() captures record() instead of the live replay, or adopt() drops the report; why_new=hand_off.rs checks pids and exit codes, not what an adopted screen replays; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn an_adopted_session_replays_the_progress_report_it_was_frozen_with() {
    let before = SessionStore::new();
    let args = [
        OsString::from("-c"),
        OsString::from("printf 'WORKING\\033]9;4;3\\033\\\\'; sleep 5"),
    ];
    let e = env();
    before.create(spec(id(81), &args, &e)).expect("create");
    let started = Instant::now();
    let screen = loop {
        let frozen = before
            .frozen(Duration::from_secs(2), |all| all[0].screen.clone())
            .expect("frozen");
        if has(&frozen, b"WORKING") || started.elapsed() > Duration::from_secs(5) {
            break frozen;
        }
        std::thread::sleep(Duration::from_millis(50));
    };

    let after = SessionStore::new();
    let sleep = [OsString::from("-c"), OsString::from("sleep 5")];
    let pty = Pty::spawn(OsStr::new("/bin/sh"), None, &sleep, &e, None, 80, 24).expect("pty");
    after
        .adopt(pty, frozen_with(id(81), &screen))
        .expect("adopt");

    let replay = after.replay_bytes(id(81));
    assert!(
        has(&replay, b"WORKING"),
        "fixture: nothing was frozen; got {replay:?}"
    );
    assert!(
        has(&replay, b"\x1b]9;4;3"),
        "the adopted session lost its progress report; got {replay:?}"
    );
    before.kill_all();
    after.kill_all();
}

/// `line {n}`, then cells alternating between two truecolour styles to 80 columns: about
/// 1.3 KB a row once formatted, so 3,000 rows are more than a sixth of `HANDOFF_TOTAL_BYTES`.
#[cfg(feature = "terminal-state")]
fn dense_line(n: usize) -> String {
    let cells: String = (13..80)
        .map(|c| {
            if c % 2 == 0 {
                "\x1b[38;2;255;128;0mx"
            } else {
                "\x1b[38;2;0;128;255mx"
            }
        })
        .collect();
    format!("\x1b[mline {n:<6} {cells}\x1b[m\r\n")
}

/// Taking a session's record compresses its shadow in the same hold, so the pages the record
/// re-inflated are not kept through every record's disk write and sync that follow.
///
/// Value: protects=changed_screens leaves each recorded shadow compressed; fails_when=the
/// compress after record() is dropped (the tick's later pass hides it); why_new=the tick test
/// runs both passes; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn taking_a_record_leaves_the_shadow_compressed() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 10")];
    let e = env();
    store.create(spec(id(120), &args, &e)).expect("create");
    let shadow = store.shadow(id(120)).expect("shadow");
    {
        let mut shadow = shadow.lock().expect("shadow");
        for n in 0..20_000 {
            shadow.write(format!("line {n} {}\r\n", "z".repeat(60)).as_bytes());
        }
        shadow.compress();
    }
    store.mark_changed(id(120));
    let taken = store.changed_screens();
    let memory = shadow.lock().expect("shadow").memory().expect("memory");
    store.kill_all();
    assert_eq!(taken.len(), 1, "fixture: the record was not taken");
    assert!(
        memory.primary_resident_bytes < 4 << 20,
        "{} bytes resident after taking the record",
        memory.primary_resident_bytes
    );
}

/// A hand-off shares `HANDOFF_TOTAL_BYTES` between its sessions, each carrying the newest
/// history that fits its share, and one that runs out of time still happens: the sessions it
/// reaches late carry their screen alone, and one under a full-screen program its alternate
/// screen alone, without the primary's paint and the copy of the terminal it costs.
///
/// Value: protects=hand-off screens within their share with their newest history, and a late
/// hand-off that still happens; fails_when=the share is not applied, the deadline is not
/// checked, or a late hand-off drops a session or is refused; why_new=hand-off screens were
/// never bounded; seam=frozen_formatting's deadline
#[cfg(feature = "terminal-state")]
#[test]
fn a_hand_off_shares_its_budget_and_still_happens_out_of_time() {
    const SESSIONS: u8 = 6;
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 10")];
    let e = env();
    for n in 0..SESSIONS {
        store.create(spec(id(100 + n), &args, &e)).expect("create");
        let shadow = store.shadow(id(100 + n)).expect("shadow");
        let mut shadow = shadow.lock().expect("shadow");
        for line in 0..3_000 {
            shadow.write(dense_line(line).as_bytes());
        }
        if n == 0 {
            shadow.write(b"\x1b[?1049h\x1b[HVIM");
        }
    }
    let screens = |all: &[FrozenSession]| -> Vec<(SessionId, Vec<u8>)> {
        all.iter().map(|s| (s.id, s.screen.clone())).collect()
    };

    let share = HANDOFF_TOTAL_BYTES / usize::from(SESSIONS);
    let frozen = store
        .frozen(Duration::from_secs(2), screens)
        .expect("frozen");
    assert_eq!(frozen.len(), usize::from(SESSIONS));
    for (session, screen) in &frozen {
        assert!(
            screen.len() <= share,
            "{session:?}: {} bytes, share {share}",
            screen.len()
        );
        assert!(
            has(screen, b"line 2999 ") && has(screen, b"line 2900 "),
            "{session:?}: the newest history is missing"
        );
        assert!(
            !has(screen, b"line 0 "),
            "{session:?}: fixture: the whole history fit its share"
        );
    }
    let full_screen = frozen.iter().find(|(session, _)| *session == id(100));
    assert!(
        full_screen.is_some_and(|(_, screen)| has(screen, b"VIM")),
        "the full-screen session lost its alternate screen"
    );

    let late = store
        .frozen_formatting(Duration::from_secs(2), Duration::ZERO, screens)
        .expect("a hand-off out of time still happens");
    assert_eq!(late.len(), usize::from(SESSIONS));
    for (session, screen) in &late {
        assert!(
            !has(screen, b"line 2900 "),
            "{session:?}: history carried past the deadline"
        );
        if *session == id(100) {
            assert!(
                has(screen, b"VIM") && !has(screen, b"line 2999 "),
                "the full-screen session painted its primary past the deadline"
            );
            assert!(
                has(screen, b"\x1b[?1049h"),
                "the full-screen session lost its switch to the alternate screen"
            );
        } else {
            assert!(
                has(screen, b"line 2999 "),
                "{session:?}: the screen is missing"
            );
        }
    }
    store.kill_all();
}

/// Not a test: prints how long a hand-off of ten full-history sessions under full-screen
/// programs takes to capture its screens, and to encode and write its table: the case
/// `HANDOFF_FORMAT_DEADLINE` and `TABLE_WRITE_ALLOWANCE` bound. Run it in release:
/// `WORKROOMD_HAS_TERMINAL_STATE=1 cargo test --manifest-path vcs/Cargo.toml -p workroomd
/// --features terminal-state --release --lib measure_hand_off -- --ignored --nocapture`
#[cfg(feature = "terminal-state")]
#[test]
#[ignore = "a measurement, run by hand in release"]
fn measure_hand_off() {
    const SESSIONS: u8 = 10;
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 60")];
    let e = env();
    for n in 0..SESSIONS {
        store.create(spec(id(150 + n), &args, &e)).expect("create");
        let shadow = store.shadow(id(150 + n)).expect("shadow");
        let mut shadow = shadow.lock().expect("shadow");
        shadow.resize(Size::cells(200, 50));
        for line in 0..150_000 {
            let pad = "x".repeat(line % 120);
            shadow.write(format!("\x1b[3{}mline {line}\x1b[0m {pad}\r\n", line % 8).as_bytes());
        }
        shadow.write(b"\x1b[?1049h\x1b[H");
        for line in 0..49 {
            shadow.write(dense_line(line).as_bytes());
        }
        shadow.compress();
    }
    let started = Instant::now();
    let (captured, frozen) = store
        .frozen(Duration::from_secs(2), |all| {
            (started.elapsed(), all.to_vec())
        })
        .expect("frozen");
    let painted = frozen
        .iter()
        .filter(|session| has(&session.screen, b"line 149999"))
        .count();
    let bytes: usize = frozen.iter().map(|session| session.screen.len()).sum();
    println!(
        "captured {SESSIONS} sessions in {captured:?}: {painted} with their primary's \
             history, {:.2} MiB in all",
        bytes as f64 / f64::from(1 << 20)
    );
    let table = crate::daemon::handoff::Table {
        listener: -1,
        lock: -1,
        boot: None,
        sessions: frozen,
    };
    let path = std::env::temp_dir().join(format!("wr-measure-table-{}", std::process::id()));
    let started = Instant::now();
    std::fs::write(&path, table.encode()).expect("write");
    println!("encoded and wrote the table in {:?}", started.elapsed());
    let _ = std::fs::remove_file(&path);
    store.kill_all();
}

/// `/bin/sh -c` for a session whose job-controlled child (reporting busy first when `report`)
/// waits for `gate` to exist and then exits without a REMOVE, as a killed daemon does. `set -m` puts the
/// child in its own foreground group, as a program started from an interactive shell is. The
/// gate, not a sleep, decides when it exits, so a loaded test run cannot outpace it.
#[cfg(feature = "terminal-state")]
fn reporter_args(gate: &std::path::Path, report: bool) -> [OsString; 2] {
    let report = if report {
        r#"printf "\033]9;4;3\033\\\\"; "#
    } else {
        ""
    };
    [
        OsString::from("-c"),
        OsString::from(format!(
            r#"set -m; /bin/sh -c '{report}until [ -e "{}" ]; do sleep 0.02; done'; echo GONE; sleep 5"#,
            gate.display()
        )),
    ]
}

#[cfg(feature = "terminal-state")]
fn has(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// Polls `read` for up to 5 s until `needle` is in it, and returns the last read.
#[cfg(feature = "terminal-state")]
fn wait_for_bytes(needle: &[u8], mut read: impl FnMut() -> Vec<u8>) -> Vec<u8> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut bytes = read();
    while !has(&bytes, needle) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
        bytes = read();
    }
    bytes
}

/// Whether `id`'s first record may alert, as the app is told: polls until the session reports.
#[cfg(feature = "terminal-state")]
fn first_record_notifies(store: &SessionStore, id: SessionId) -> Option<bool> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let notify = store
            .program_status_events()
            .into_iter()
            .find(|(session, _)| *session == id)
            .and_then(|(_, event)| {
                let event: serde_json::Value = serde_json::from_slice(&event).ok()?;
                event["records"][0]["notify"].as_bool()
            });
        if notify.is_some() || Instant::now() > deadline {
            return notify;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// An unprobed request alerts once the tick finds its sender still running in the foreground
/// after the grace, unless the sender is the session's interactive shell itself (#481): a
/// `printf` from a shell is not a program waiting. A run command's child is the program.
/// Value: protects=Codex requests alert and a shell's printf never does; fails_when=the tick never promotes, or excludes a run command's child, or not a shell's; why_new=the Store tests inject eligibility; seam=none; no_claim=Codex itself (a printf stands in)
#[cfg(feature = "terminal-state")]
#[test]
fn the_tick_promotes_a_running_sender_but_never_the_shell() {
    let store = SessionStore::new();
    let args = [
        OsString::from("-c"),
        // Longer than any loaded run can take to get here; `kill_all` ends it.
        OsString::from(r#"printf "\033]7501;state=blocked\033\\"; sleep 60"#),
    ];
    let e = env();
    for (n, interactive) in [(91, true), (92, false)] {
        store
            .create(SessionSpec {
                interactive,
                ..spec(id(n), &args, &e)
            })
            .expect("create");
        assert_eq!(
            first_record_notifies(&store, id(n)),
            Some(false),
            "fixture: no unprobed request"
        );
    }
    // Requests waiting out their grace owe the screens thread another pass, or it sleeps on
    // them and the alert never comes for a program that prints nothing more.
    assert!(
        store.promote_unprobed(Instant::now()),
        "a request within its grace left no pass owed"
    );
    store.promote_unprobed(Instant::now() + crate::terminal::program_status::limits::GRACE);
    let shell = first_record_notifies(&store, id(91));
    let command = first_record_notifies(&store, id(92));
    store.kill_all();
    assert_eq!(shell, Some(false), "the interactive shell's own report");
    assert_eq!(command, Some(true), "a run command's program");
}

/// A program killed or crashed mid-turn never sends its REMOVE. The app clears its spinner at
/// the shell's next command end (OSC 133 D); `/bin/sh` sends none, so the replay says idle
/// once the program that sent the report no longer owns the pty (#359).
/// Value: protects=a reattach after the reporting program died is not told busy; fails_when=replay_for ignores the foreground or the owner is never noted; why_new=every other progress test has the reporter still alive or a clean REMOVE; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn a_report_from_a_program_that_has_gone_is_not_replayed() {
    let gate = std::env::temp_dir().join(format!("wr-gone-{}", std::process::id()));
    let _ = std::fs::remove_file(&gate);
    let store = SessionStore::new();
    let args = reporter_args(&gate, true);
    let e = env();
    store.create(spec(id(82), &args, &e)).expect("create");
    let busy = b"\x1b]9;4;3";

    let replay = wait_for_bytes(busy, || store.replay_bytes(id(82)));
    assert!(
        has(&replay, busy),
        "fixture: the live reporter was never replayed as busy; got {replay:?}"
    );
    std::fs::write(&gate, b"").expect("open the gate");
    let replay = wait_for_bytes(b"GONE", || store.replay_bytes(id(82)));
    store.kill_all();
    let _ = std::fs::remove_file(&gate);
    assert!(
        has(&replay, b"GONE"),
        "fixture: the reporter never exited; got {replay:?}"
    );
    assert!(
        !has(&replay, busy),
        "a report from a program that has gone was replayed; got {replay:?}"
    );
}

/// A hand-off of a session whose reporter has gone freezes it idle, so the new daemon cannot
/// hand the dead program's report to the shell at its prompt (#359).
/// Value: protects=a hand-off after the reporter died does not resurrect busy; fails_when=frozen() captures the whole replay() instead of the live one; why_new=the other hand-off tests keep the reporter alive; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn a_hand_off_after_the_reporter_has_gone_is_frozen_idle() {
    let gate = std::env::temp_dir().join(format!("wr-frozen-gone-{}", std::process::id()));
    let _ = std::fs::remove_file(&gate);
    let store = SessionStore::new();
    let args = reporter_args(&gate, true);
    let e = env();
    store.create(spec(id(84), &args, &e)).expect("create");
    let busy = b"\x1b]9;4;3";
    let replay = wait_for_bytes(busy, || store.replay_bytes(id(84)));
    assert!(has(&replay, busy), "fixture: never busy; got {replay:?}");
    std::fs::write(&gate, b"").expect("open the gate");
    wait_for_bytes(b"GONE", || store.replay_bytes(id(84)));

    let screen = store
        .frozen(Duration::from_secs(2), |all| all[0].screen.clone())
        .expect("frozen");
    store.kill_all();
    let _ = std::fs::remove_file(&gate);
    assert!(
        has(&screen, b"GONE"),
        "fixture: the reporter never exited; got {screen:?}"
    );
    assert!(
        !has(&screen, busy),
        "a dead reporter's report was frozen into the hand-off; got {screen:?}"
    );
}

/// A hand-off keeps the processes, so `adopt` notes who owns the pty as the sender of the
/// report in the frozen screen; when that program later goes, the replay says idle (#359).
/// Value: protects=an adopted session whose reporter dies stops replaying busy; fails_when=adopt writes the screen without noting the owner; why_new=the other adopt test keeps its reporter alive, so it passes with no owner at all; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn an_adopted_report_is_dropped_once_its_sender_goes() {
    let gate = std::env::temp_dir().join(format!("wr-adopt-gone-{}", std::process::id()));
    let _ = std::fs::remove_file(&gate);
    // The report reaches this daemon only in the frozen screen, as after a hand-off: the program
    // sent it to the old daemon, so nothing the new one reads names its sender.
    let args = reporter_args(&gate, false);
    let e = env();
    let pty = Pty::spawn(OsStr::new("/bin/sh"), None, &args, &e, None, 80, 24).expect("pty");
    // Adopt only once the reporter owns the pty, as it would mid-turn.
    let deadline = Instant::now() + Duration::from_secs(5);
    while pty.foreground_pgid() == Some(pty.child_pid()) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_ne!(
        pty.foreground_pgid(),
        Some(pty.child_pid()),
        "fixture: the reporter never took the foreground"
    );
    let store = SessionStore::new();
    store
        .adopt(pty, frozen_with(id(83), b"working\r\n\x1b]9;4;3\x1b\\"))
        .expect("adopt");
    let busy = b"\x1b]9;4;3";
    assert!(
        has(&store.replay_bytes(id(83)), busy),
        "fixture: the adopted report was not replayed while its sender lives"
    );

    std::fs::write(&gate, b"").expect("open the gate");
    let replay = wait_for_bytes(b"GONE", || store.replay_bytes(id(83)));
    store.kill_all();
    let _ = std::fs::remove_file(&gate);
    assert!(
        has(&replay, b"GONE"),
        "fixture: the reporter never exited; got {replay:?}"
    );
    assert!(
        !has(&replay, busy),
        "an adopted report outlived its sender; got {replay:?}"
    );
}

/// A session whose attachment lock stays held (a slow client's repaint) is left for the next
/// record rather than waited on, and the other sessions' records are taken meanwhile.
#[test]
fn a_session_taking_a_repaint_is_left_for_the_next_record() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(11), &args, &e)).expect("create");
    store.create(spec(id(12), &args, &e)).expect("create");
    let (_, _, attached) = store.parts(id(11)).expect("parts");

    let repainting = attached.lock().expect("lock");
    let started = Instant::now();
    let taken: Vec<SessionId> = store.changed_screens().into_iter().map(|r| r.id).collect();
    assert!(
        started.elapsed() < RECORD_WAIT * 3,
        "waited {:?} on the busy session",
        started.elapsed()
    );
    assert_eq!(
        taken,
        vec![id(12)],
        "the free session's record was not taken"
    );

    drop(repainting);
    let taken: Vec<SessionId> = store.changed_screens().into_iter().map(|r| r.id).collect();
    assert_eq!(
        taken,
        vec![id(11)],
        "the busy session was not taken next time"
    );
    store.kill_all();
}

/// Busy sessions share one pass's `RECORD_WAIT` rather than each waiting it out, so however many
/// are repainting at once, a pass stays well inside the screens thread's interval.
#[test]
fn several_busy_sessions_share_one_wait() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    let ids = [id(21), id(22), id(23), id(24)];
    for session in ids {
        store.create(spec(session, &args, &e)).expect("create");
    }
    let locks: Vec<_> = ids
        .iter()
        .map(|session| store.parts(*session).expect("parts").2)
        .collect();
    let repainting: Vec<_> = locks
        .iter()
        .map(|lock| lock.lock().expect("lock"))
        .collect();
    let started = Instant::now();
    let taken = store.changed_screens();
    let elapsed = started.elapsed();
    drop(repainting);
    store.kill_all();
    assert!(taken.is_empty());
    assert!(
        elapsed < RECORD_WAIT + RECORD_GRACE * ids.len() as u32 + RECORD_WAIT / 2,
        "four busy sessions took {elapsed:?}"
    );
}

/// A screen taken of one session is not taken for a later session under the same id, so the
/// screens thread can tell a record it wrote belongs to a session that has since been
/// replaced.
#[test]
fn a_screen_is_held_only_by_the_session_it_was_taken_of() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(14), &args, &e)).expect("create");
    let taken = store.changed_screens().pop().expect("taken");
    assert!(store.still_holds(id(14), taken.session));

    store.kill(id(14));
    assert!(
        !store.still_holds(id(14), taken.session),
        "an ended session held it"
    );
    store.create(spec(id(14), &args, &e)).expect("create again");
    assert!(
        !store.still_holds(id(14), taken.session),
        "a later session held it"
    );
    store.kill_all();
}

/// A session killed and then created again under the same id: the old session's reader, which
/// ends after the new session exists, must not remove it from the store. Holding the old
/// session's attachment lock keeps its reader from noticing the end until the new session is
/// in the store, which is the order the race needs.
#[test]
fn an_old_reader_does_not_end_the_next_session_under_its_id() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(15), &args, &e)).expect("create");
    let (_, _, attached) = store.parts(id(15)).expect("parts");
    let reader_held = attached.lock().expect("lock");
    store.kill(id(15));
    store.create(spec(id(15), &args, &e)).expect("create again");
    drop(reader_held);
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        store.contains(id(15)),
        "the old reader removed the new session"
    );
    store.kill_all();
}

/// A resize changes the screen even when the program prints nothing after it, so the record
/// is taken again at the new size.
#[test]
fn a_resize_alone_makes_the_screen_changed() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(13), &args, &e)).expect("create");
    assert_eq!(
        store.changed_screens().len(),
        1,
        "a new session has no record yet"
    );
    assert!(
        store.changed_screens().is_empty(),
        "an idle session was taken again"
    );

    let (pty, shadow, attached) = store.parts(id(13)).expect("parts");
    let size = Some(Size::cells(100, 30));
    apply_size(&pty, &shadow, &attached, size, &Hooks::default());
    let taken: Vec<(SessionId, u16, u16)> = store
        .changed_screens()
        .into_iter()
        .map(|r| (r.id, r.columns, r.rows))
        .collect();
    assert_eq!(
        taken,
        vec![(id(13), 100, 30)],
        "the resized screen was not taken at its new size"
    );
    store.kill_all();
}

/// A session whose attachment lock stays held (a slow client's repaint) refuses a freeze
/// within its deadline rather than holding the whole store until the lock comes free.
#[test]
fn a_freeze_that_cannot_take_every_lock_gives_up() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(10), &args, &e)).expect("create");
    let (_, _, attached) = store.parts(id(10)).expect("parts");

    let repainting = attached.lock().expect("lock");
    let started = Instant::now();
    assert!(store.frozen(Duration::from_millis(50), |_| ()).is_none());
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(50) && waited < Duration::from_millis(300),
        "gave up after {waited:?}"
    );
    assert!(!store.is_empty(), "the store lock was released");

    drop(repainting);
    // Generous: `TERMINATING` is shared with every other test in the crate, and a kill
    // holds it for `SIGHUP_GRACE`.
    let frozen = store.frozen(Duration::from_secs(5), |sessions| sessions.len());
    assert_eq!(frozen, Some(1));
    store.kill_all();
}

/// The same when what is held is the store lock: `list` holds it while it waits on a
/// repainting session, so a freeze that waited on the store without its deadline waited out
/// the whole repaint.
#[test]
fn a_freeze_behind_a_list_waiting_on_a_repaint_gives_up() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(11), &args, &e)).expect("create");
    let (_, _, attached) = store.parts(id(11)).expect("parts");

    std::thread::scope(|scope| {
        let (locked, is_locked) = std::sync::mpsc::channel();
        scope.spawn(move || {
            let _repainting = attached.lock().expect("lock");
            locked.send(()).expect("send");
            std::thread::sleep(Duration::from_secs(2));
        });
        is_locked.recv().expect("recv");
        let listing = scope.spawn(|| store.list().len());
        // Long enough for `list` to be holding the store lock, waiting on the repaint.
        std::thread::sleep(Duration::from_millis(100));

        let started = Instant::now();
        let frozen = store.frozen(Duration::from_millis(50), |_| ());
        let waited = started.elapsed();
        assert!(
            frozen.is_none() && waited < Duration::from_millis(300),
            "{frozen:?} after {waited:?}"
        );
        assert_eq!(listing.join().expect("list"), 1);
    });
    store.kill_all();
}

/// The property the whole feature exists for: a client going away must not take the shell
/// with it, and coming back must find the same one still running.
#[test]
fn a_session_survives_detach_and_reattach() {
    let store = SessionStore::new();
    let args = [
        OsString::from("-c"),
        OsString::from("echo ready; sleep 5; echo done"),
    ];
    let e = env();
    // Attached before the reader starts, as the daemon attaches a pane's first client: attached
    // after `create`, the shell's `echo ready` could be read, with nobody to send it to, first.
    let first = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(first.clone())));
    let (_, token) = store
        .create_then(spec(id(3), &args, &e), |_| {
            store.attach(id(3), writer, 1, Size::cells(80, 24))
        })
        .expect("create and attach");
    let before = wait_for(&first, "ready", Duration::from_secs(5));
    assert!(before.contains("ready"), "got {before:?}");

    let pid_before = store.with_pty(id(3), |pty| pty.child_pid()).expect("pty");
    store.detach(id(3), token);
    assert!(store.contains(id(3)), "detaching must not end the session");
    assert!(!store.list()[0].attached);

    std::thread::sleep(Duration::from_millis(300));

    let (_second, _) = attach_capture(&store, id(3));
    assert!(store.list()[0].attached);
    let pid_after = store.with_pty(id(3), |pty| pty.child_pid()).expect("pty");
    assert_eq!(
        pid_before, pid_after,
        "must be the SAME shell, not a new one"
    );
    store.kill_all();
}

/// A sentinel typed before the detach must still reach the shell that comes back — the
/// integration property the design doc names for Phase 1.
#[test]
fn input_survives_a_detach() {
    let store = SessionStore::new();
    let args = [
        OsString::from("-c"),
        OsString::from("read line; sleep 1; echo got:$line; sleep 5"),
    ];
    let e = env();
    store.create(spec(id(4), &args, &e)).expect("create");
    let (_first, token) = attach_capture(&store, id(4));
    std::thread::sleep(Duration::from_millis(200));

    store
        .with_pty(id(4), |pty| pty.write_all(b"sentinel\n"))
        .expect("session")
        .expect("write");
    store.detach(id(4), token);
    std::thread::sleep(Duration::from_millis(400));
    let (second, _) = attach_capture(&store, id(4));

    let after = wait_for(&second, "got:sentinel", Duration::from_secs(5));
    assert!(after.contains("got:sentinel"), "got {after:?}");
    store.kill_all();
}

/// A zero size means "the client has no size yet", and the pty and the shadow must resolve it
/// the same way. They did not: the pty substituted 80x24 while the shadow clamped to 1x1, so a
/// repaint came back with one character per line. Anything that applies its own fallback to
/// this input reintroduces that.
#[test]
fn a_zero_size_resolves_to_one_default_for_everything() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("stty size; sleep 2")];
    let e = env();
    store
        .create(SessionSpec {
            id: id(6),
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &e,
            cwd: None,
            columns: 0,
            rows: 0,
            metadata: &[],
            interactive: false,
        })
        .expect("create");

    let (capture, _) = attach_capture(&store, id(6));
    let seen = wait_for(&capture, "24 80", Duration::from_secs(5));
    assert!(
        seen.contains("24 80"),
        "the pty did not get the default size: {seen:?}"
    );
    store.kill_all();
}

/// A client whose transport has failed must be dropped, not kept and retried forever.
///
/// Left installed, every subsequent chunk of output pays the transport's write deadline again,
/// and the session spends its life stalling on a peer that is never coming back — which is the
/// same "nobody is draining the pty" failure the session-owned reader exists to prevent,
/// arriving through a different door.
#[test]
fn a_client_that_cannot_be_written_to_is_dropped() {
    let store = SessionStore::new();
    // Output must keep coming AFTER the writer breaks: a single echo raced the break, and a
    // fast shell printed it into the healthy writer and then said nothing for five seconds.
    let args = [
        OsString::from("-c"),
        OsString::from("while :; do echo noisy; sleep 0.1; done"),
    ];
    let e = env();
    store.create(spec(id(7), &args, &e)).expect("create");

    // Healthy at attach, broken afterwards — which is what this test is actually about, and
    // what it only accidentally exercised before. It used to attach an ALREADY-broken writer,
    // so with `terminal-state` on it depended on whether the shell had produced output yet: an
    // empty shadow meant no repaint and the attach succeeded, a painted one meant the repaint
    // write failed. That race is now a real distinction — a writer that is dead before the
    // repaint fails the attach outright (`an_unpaintable_client_is_not_attached`), so eviction
    // has to be provoked the way it actually happens, after a working attach.
    let broken = Arc::new(std::sync::atomic::AtomicBool::new(false));
    struct Flaky(Arc<std::sync::atomic::AtomicBool>);
    impl Write for Flaky {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if self.0.load(Ordering::SeqCst) {
                return Err(std::io::ErrorKind::BrokenPipe.into());
            }
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            if self.0.load(Ordering::SeqCst) {
                return Err(std::io::ErrorKind::BrokenPipe.into());
            }
            Ok(())
        }
    }

    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Flaky(Arc::clone(&broken)))));
    store
        .attach(id(7), writer, 1, Size::cells(80, 24))
        .expect("attach");
    assert!(store.list()[0].attached);
    broken.store(true, Ordering::SeqCst);

    // The shell's own output is enough to discover the dead transport.
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.list()[0].attached && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !store.list()[0].attached,
        "a client whose writes fail must be evicted"
    );
    assert!(
        store.contains(id(7)),
        "and the session itself must survive losing its client"
    );
    store.kill_all();
}

// MARK: The size-owner policy

/// Reports the pty's actual geometry, which is what the policy is ultimately about.
fn pty_size(store: &SessionStore, session: SessionId) -> (u16, u16) {
    store
        .with_pty(session, |pty| pty.size())
        .expect("session")
        .expect("size")
}

fn attach_sized(
    store: &SessionStore,
    session: SessionId,
    columns: u16,
    rows: u16,
) -> (Capture, u64) {
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (_, token) = store
        .attach(session, writer, 1, Size::cells(columns, rows))
        .expect("attach");
    (capture, token)
}

fn sized_session(store: &SessionStore, session: SessionId) {
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store
        .create(SessionSpec {
            id: session,
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &e,
            cwd: None,
            columns: 80,
            rows: 24,
            metadata: &[],
            interactive: false,
        })
        .expect("create");
}

/// Nobody owns a new session, so the first client to bring a size takes it — otherwise a
/// session would sit at its creation geometry until somebody typed.
#[test]
fn the_first_client_with_a_size_takes_it() {
    let store = SessionStore::new();
    sized_session(&store, id(20));
    let (_client, token) = attach_sized(&store, id(20), 100, 30);
    assert_eq!(store.size_owner(id(20)), Some(token));
    assert_eq!(pty_size(&store, id(20)), (100, 30));
    store.kill_all();
}

/// A client with no size of its own cannot own one. A relay forked into a pipe rather than a
/// terminal reports 0x0, and letting that own would resize everyone else's pty to nothing.
#[test]
fn a_client_without_a_size_cannot_own_it() {
    let store = SessionStore::new();
    sized_session(&store, id(21));
    let (_client, _) = attach_sized(&store, id(21), 0, 0);
    assert_eq!(store.size_owner(id(21)), None);
    assert_eq!(
        pty_size(&store, id(21)),
        (80, 24),
        "the pty keeps its own size"
    );
    store.kill_all();
}

/// Value: protects=the pane's pixel size follows the size owner, and only the owner (#551);
/// fails_when=a client's pixels are dropped, or a non-owner's are applied; why_new=the other
/// owner tests assert cells only; seam=none; no_claim=none beyond protects
#[test]
fn the_size_owner_sets_the_pixels_and_another_client_does_not() {
    let store = SessionStore::new();
    sized_session(&store, id(36));
    let pixels = |store: &SessionStore| {
        store
            .with_pty(id(36), |pty| pty.pixels())
            .expect("session")
            .expect("pixels")
    };
    let owner_size = Size {
        columns: 100,
        rows: 30,
        x_pixels: 1000,
        y_pixels: 600,
    };
    let attach = |size: Size| {
        let capture = Capture::default();
        let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
        let (_, token) = store.attach(id(36), writer, 1, size).expect("attach");
        (capture, token)
    };
    let (_first, first) = attach(owner_size);
    assert_eq!(
        pixels(&store),
        (1000, 600),
        "the first client owns the size"
    );

    let (_second, second) = attach(Size::cells(120, 40));
    store.resize(
        id(36),
        second,
        Size {
            x_pixels: 2400,
            y_pixels: 1600,
            ..Size::cells(120, 40)
        },
    );
    assert_eq!(pixels(&store), (1000, 600), "not the owner");

    // The same grid at a new scale: a window moved to another display.
    store.resize(
        id(36),
        first,
        Size {
            x_pixels: 2000,
            y_pixels: 1200,
            ..owner_size
        },
    );
    assert_eq!(pixels(&store), (2000, 1200));
    store.kill_all();
}

/// The core of the policy: a second client's window does not move the pty.
#[test]
fn a_second_clients_resize_is_recorded_but_not_applied() {
    let store = SessionStore::new();
    sized_session(&store, id(22));
    let (_first, first) = attach_sized(&store, id(22), 100, 30);
    let (_second, second) = attach_sized(&store, id(22), 120, 40);

    assert_eq!(
        store.size_owner(id(22)),
        Some(first),
        "attaching does not take the size"
    );
    assert_eq!(pty_size(&store, id(22)), (100, 30));

    store.resize(id(22), second, Size::cells(200, 50));
    assert_eq!(
        pty_size(&store, id(22)),
        (100, 30),
        "a non-owner's resize does not apply"
    );
    assert_eq!(store.size_owner(id(22)), Some(first));
    store.kill_all();
}

/// ...and typing is what takes it, applying the size recorded while it was not the owner.
#[test]
fn typing_claims_the_size_and_applies_what_was_recorded() {
    let store = SessionStore::new();
    sized_session(&store, id(23));
    let (_first, first) = attach_sized(&store, id(23), 100, 30);
    let (_second, second) = attach_sized(&store, id(23), 120, 40);
    store.resize(id(23), second, Size::cells(200, 50));

    store.write_input(id(23), second, b"x");
    assert_eq!(store.size_owner(id(23)), Some(second));
    assert_eq!(
        pty_size(&store, id(23)),
        (200, 50),
        "the size recorded while it was not the owner takes effect at once"
    );
    assert_ne!(store.size_owner(id(23)), Some(first));
    store.kill_all();
}

/// The load-bearing exclusion. A terminal answering a query shares the input channel with the
/// user, and a pane merely being focused must not steal the size.
#[test]
fn a_terminal_answering_a_query_does_not_claim_the_size() {
    let store = SessionStore::new();
    sized_session(&store, id(24));
    let (_first, first) = attach_sized(&store, id(24), 100, 30);
    let (_second, second) = attach_sized(&store, id(24), 120, 40);

    for answer in [
        &b"\x1b[I"[..],          // focus in
        &b"\x1b[24;80R"[..],     // cursor position report
        &b"\x1b[?62;1;4c"[..],   // device attributes
        &b"\x1b[<64;10;20M"[..], // wheel scroll
    ] {
        store.write_input(id(24), second, answer);
        assert_eq!(
            store.size_owner(id(24)),
            Some(first),
            "{answer:?} must not claim the session"
        );
    }

    // But a click does.
    store.write_input(id(24), second, b"\x1b[<0;10;20M");
    assert_eq!(
        store.size_owner(id(24)),
        Some(second),
        "a click is the user acting"
    );
    store.kill_all();
}

/// Closing one laptop must not strand the terminal at the geometry of the window that just
/// went away — with one client left, it takes the size without having to ask.
#[test]
fn the_last_client_standing_takes_the_size_immediately() {
    let store = SessionStore::new();
    sized_session(&store, id(25));
    let (_first, first) = attach_sized(&store, id(25), 100, 30);
    let (_second, second) = attach_sized(&store, id(25), 120, 40);
    assert_eq!(store.size_owner(id(25)), Some(first));

    store.detach(id(25), first);
    assert_eq!(store.size_owner(id(25)), Some(second));
    assert_eq!(pty_size(&store, id(25)), (120, 40));
    store.kill_all();
}

/// With more than one client left, the owner leaving makes the size UNOWNED rather than
/// handing it to an arbitrary survivor — the next one to act takes it.
#[test]
fn the_size_is_unowned_when_the_owner_leaves_a_crowd() {
    let store = SessionStore::new();
    sized_session(&store, id(26));
    let (_first, first) = attach_sized(&store, id(26), 100, 30);
    let (_second, second) = attach_sized(&store, id(26), 120, 40);
    let (_third, third) = attach_sized(&store, id(26), 140, 45);

    store.detach(id(26), first);
    assert_eq!(store.size_owner(id(26)), None);
    assert_eq!(
        pty_size(&store, id(26)),
        (100, 30),
        "and the pty holds its last size"
    );

    store.write_input(id(26), third, b"x");
    assert_eq!(store.size_owner(id(26)), Some(third));
    assert_eq!(pty_size(&store, id(26)), (140, 45));
    assert_ne!(store.size_owner(id(26)), Some(second));
    store.kill_all();
}

/// An unowned size is claimed by a resize too, not only by typing — otherwise a lone client
/// that only ever drags its window would never move the pty.
#[test]
fn a_resize_claims_an_unowned_size() {
    let store = SessionStore::new();
    sized_session(&store, id(27));
    let (_first, first) = attach_sized(&store, id(27), 100, 30);
    let (_second, second) = attach_sized(&store, id(27), 0, 0);
    let (_third, _) = attach_sized(&store, id(27), 0, 0);
    store.detach(id(27), first);
    assert_eq!(store.size_owner(id(27)), None);

    store.resize(id(27), second, Size::cells(90, 20));
    assert_eq!(store.size_owner(id(27)), Some(second));
    assert_eq!(pty_size(&store, id(27)), (90, 20));
    store.kill_all();
}

/// The owner's own resizes keep applying, which is the ordinary single-client case.
#[test]
fn the_owner_keeps_resizing_the_pty() {
    let store = SessionStore::new();
    sized_session(&store, id(28));
    let (_client, token) = attach_sized(&store, id(28), 100, 30);
    store.resize(id(28), token, Size::cells(132, 43));
    assert_eq!(pty_size(&store, id(28)), (132, 43));
    store.kill_all();
}

/// Both windows on one session see the same output — otherwise they would each get half a
/// terminal, which is the corruption multi-client attach used to cause.
#[test]
fn every_attached_client_sees_the_same_output() {
    let store = SessionStore::new();
    let args = [
        OsString::from("-c"),
        OsString::from("sleep 0.2; echo shared; sleep 5"),
    ];
    let e = env();
    store.create(spec(id(29), &args, &e)).expect("create");
    let (first, _) = attach_capture(&store, id(29));
    let (second, _) = attach_capture(&store, id(29));

    assert!(wait_for(&first, "shared", Duration::from_secs(5)).contains("shared"));
    assert!(wait_for(&second, "shared", Duration::from_secs(5)).contains("shared"));
    store.kill_all();
}

#[test]
fn attaching_an_unknown_session_is_an_error() {
    let store = SessionStore::new();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Capture::default())));
    assert!(matches!(
        store.attach(id(9), writer, 1, Size::cells(80, 24)),
        Err(SessionError::NotFound(_))
    ));
}

#[test]
fn kill_removes_the_session_and_reaps_the_child() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    store.create(spec(id(5), &args, &e)).expect("create");
    let pid = store.with_pty(id(5), |pty| pty.child_pid()).expect("pty");

    assert!(store.kill(id(5)));
    assert!(!store.contains(id(5)));
    assert!(!store.kill(id(5)), "killing twice reports nothing to kill");

    // The child must be gone, not a zombie: signal 0 probes for existence.
    std::thread::sleep(Duration::from_millis(100));
    // SAFETY: `kill` takes no pointers, and signal 0 delivers nothing.
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1, "child should be reaped");
}

/// The reason `terminate` snapshots descendants. A child that calls `setsid()` leaves the
/// pty's foreground process group and the shell's session both, so hanging up the pty reaches
/// everything EXCEPT it — and the app quitting used to leave it running forever.
///
/// Uses a real detached grandchild rather than a simulation, and observes its pid from outside
/// the session, because the escape is a property of the OS and a stand-in would not have it.
#[test]
fn kill_reaches_a_setsid_grandchild() {
    let Some(perl) = which("perl") else {
        eprintln!("skipping: no perl to make a setsid'd grandchild with");
        return;
    };
    let pid_file = std::env::temp_dir().join(format!("wr-setsid-{}.pid", std::process::id()));
    let _ = std::fs::remove_file(&pid_file);

    let script = format!(
        "{perl} -MPOSIX=setsid -e 'setsid(); open(F, \">\", $ARGV[0]) or exit 1; \
             print F $$; close F; while (1) {{ sleep 1 }}' {} & exec cat",
        pid_file.display()
    );
    let args = [OsString::from("-c"), OsString::from(script)];
    let e = env();
    let store = SessionStore::new();
    store.create(spec(id(30), &args, &e)).expect("create");

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut grandchild = 0;
    while Instant::now() < deadline {
        if let Some(pid) = std::fs::read_to_string(&pid_file)
            .ok()
            .and_then(|raw| raw.trim().parse::<i32>().ok())
        {
            grandchild = pid;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::remove_file(&pid_file);
    assert!(grandchild > 0, "the setsid'd grandchild never started");
    assert!(alive(grandchild), "it should be running before the kill");

    assert!(store.kill(id(30)));

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && alive(grandchild) {
        std::thread::sleep(Duration::from_millis(20));
    }
    let survived = alive(grandchild);
    if survived {
        // SAFETY: `kill` takes no pointers; this is the test's own grandchild, still alive.
        unsafe { libc::kill(grandchild, libc::SIGKILL) };
    }
    assert!(!survived, "a setsid'd grandchild must not survive the kill");
}

/// Whether a pid names a running process. Test-only: the kill path itself compares start
/// times through `wr_exec::Descendant`, which this deliberately does not — a test that watched
/// for pid reuse would be testing the OS, not the daemon.
fn alive(pid: i32) -> bool {
    // SAFETY: `kill` takes no pointers, and signal 0 delivers nothing.
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}

fn which(program: &str) -> Option<String> {
    std::env::var("PATH").ok().and_then(|path| {
        path.split(':')
            .map(|dir| std::path::Path::new(dir).join(program))
            .find(|candidate| candidate.is_file())
            .and_then(|candidate| candidate.to_str().map(str::to_string))
    })
}

#[test]
fn kill_all_reports_how_many_it_ended() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 30")];
    let e = env();
    for n in 10..13 {
        store.create(spec(id(n), &args, &e)).expect("create");
    }
    assert_eq!(store.kill_all(), 3);
    assert!(store.is_empty());
}

#[test]
fn session_ids_render_as_uuids() {
    let bytes = [
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00,
        0x00,
    ];
    assert_eq!(
        SessionId(bytes).to_hyphenated(),
        "550e8400-e29b-41d4-a716-446655440000"
    );
}

#[test]
fn session_ids_must_be_exactly_sixteen_bytes() {
    assert!(SessionId::from_slice(&[0u8; 16]).is_some());
    assert!(SessionId::from_slice(&[0u8; 15]).is_none());
    assert!(SessionId::from_slice(&[0u8; 17]).is_none());
}

#[test]
fn listing_is_stable_between_calls() {
    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 5")];
    let e = env();
    for n in [7u8, 3, 9, 1] {
        store.create(spec(id(n), &args, &e)).expect("create");
    }
    let first: Vec<SessionId> = store.list().into_iter().map(|i| i.id).collect();
    let second: Vec<SessionId> = store.list().into_iter().map(|i| i.id).collect();
    assert_eq!(first, second);
    assert_eq!(first, vec![id(1), id(3), id(7), id(9)]);
    store.kill_all();
}

/// An oversized repaint must not take the session down.
///
/// `replay()` can be up to ~4 MiB and `Frame::encode` PANICS above the 1 MiB cap. `attach`
/// builds that frame while holding the attachment mutex, so before chunking, one big window
/// showing a styled TUI poisoned the mutex on unwind — and `read_session`'s own `.expect` on
/// the same lock then killed the reader thread, leaving the pty undrained and the shell
/// blocked on write for EVERY client on that session, permanently.
///
/// The shadow is painted directly rather than through the pty: the fixture has to reliably
/// exceed a megabyte, and driving a real shell to emit that much styled output is slow and
/// load-dependent. Styled on purpose: the formatter emits an SGR run per colour change, so a
/// large window running a heavily-coloured TUI is the real shape of this, and the fixture
/// asserts its own replay still exceeds the cap.
///
/// Asserting the reader is still ALIVE afterwards is the point — a test that only checked
/// `attach` returned `Ok` would pass against a version that poisoned the lock, because the
/// poisoning kills the reader rather than the attacher.
#[cfg(feature = "terminal-state")]
#[test]
fn an_oversized_repaint_does_not_wedge_the_session() {
    let store = SessionStore::new();
    let args = [
        OsString::from("-c"),
        OsString::from("sleep 0.3; echo still-draining; sleep 5"),
    ];
    let e = env();
    let mut spec = spec(id(71), &args, &e);
    spec.columns = 400;
    spec.rows = 200;
    store.create(spec).expect("create");

    // Paint the shadow past the frame cap: an SGR run per cell, so nothing coalesces.
    let (_, shadow, _) = store.parts(id(71)).expect("parts");
    {
        let mut shadow = shadow.lock().expect("shadow");
        let mut paint = Vec::new();
        for row in 0..200u32 {
            for column in 0..400u32 {
                let colour = ((row * 400 + column) % 255) + 1;
                paint.extend_from_slice(format!("\x1b[38;5;{colour}mX").as_bytes());
            }
            if row < 199 {
                paint.extend_from_slice(b"\r\n");
            }
        }
        shadow.write(&paint);
        assert!(
            shadow.replay().len() > wr_protocol::frame::MAX_PAYLOAD_SIZE,
            "fixture no longer exceeds the cap, so this proves nothing"
        );
    }

    let replay_len = shadow.lock().expect("shadow").replay().len();
    let (capture, _) = attach_capture(&store, id(71));

    // The WHOLE repaint arrived, not just its first chunk. Liveness alone is not enough: a
    // `replay.chunks(..).take(1)` would leave every other assertion here green while sending
    // 8 KiB of a megabyte screen — and that truncation is exactly the regression this pair of
    // commits has already shipped once.
    assert!(
        capture.text().len() >= replay_len,
        "client got {} bytes of a {replay_len}-byte repaint",
        capture.text().len()
    );

    // The reader is still running: output produced AFTER the repaint still arrives. This is
    // what fails when the attachment mutex has been poisoned.
    assert!(
        wait_for(&capture, "still-draining", Duration::from_secs(5)).contains("still-draining"),
        "the pty stopped draining after the repaint — the session is wedged"
    );
    store.kill_all();
}

/// A client whose transport is already dead is NOT attached, rather than attached and later
/// evicted.
///
/// A partial repaint is worse than none: an 8 KiB chunk boundary can fall inside an escape
/// sequence, so a client that got a prefix has its parser stranded mid-sequence and the next
/// live output completes it as garbage. That is the same reason the repaint chunks instead of
/// truncating, so stopping early has to fail the attach rather than register a half-painted
/// pane.
///
/// Needs a NON-EMPTY shadow, or there is no repaint to fail on and the attach legitimately
/// succeeds — which is why the eviction test above had to stop using an already-broken writer.
#[cfg(feature = "terminal-state")]
#[test]
fn an_unpaintable_client_is_not_attached() {
    struct Broken;
    impl Write for Broken {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
    }

    let store = SessionStore::new();
    let args = [OsString::from("-c"), OsString::from("sleep 5")];
    let e = env();
    store.create(spec(id(73), &args, &e)).expect("create");
    let (_, shadow, _) = store.parts(id(73)).expect("parts");
    shadow
        .lock()
        .expect("shadow")
        .write(b"something to repaint\r\n");

    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(Broken)));
    let before = store.hooks().screens.work();
    let result = store.attach(id(73), writer, 1, Size::cells(80, 24));

    assert!(
        matches!(result, Err(SessionError::RepaintFailed(_))),
        "a client that cannot take its repaint must not be attached, got {result:?}"
    );
    // The failed repaint still read, and so re-inflated, the shadow's history.
    assert_ne!(
        store.hooks().screens.work(),
        before,
        "a failed repaint did not wake the screens thread to compress again"
    );
    assert!(
        !store.list()[0].attached,
        "nothing may be left registered for a client that was never painted"
    );
    assert!(store.contains(id(73)), "the session itself survives");
    store.kill_all();
}

/// The budget SCALES with the payload — the part that was wrong, and the cheap part to pin.
///
/// A flat `WRITE_TIMEOUT` for the whole repaint is a throughput floor: a peer reading happily
/// but slower than `replay.len()` per ten seconds failed every time, and every retry repeated
/// it, so the session became permanently unattachable. These assertions fail against that.
#[test]
fn the_repaint_budget_scales_with_the_screen() {
    assert_eq!(
        repaint_budget(0),
        WRITE_TIMEOUT,
        "an empty repaint still gets the no-progress slack"
    );
    assert!(
        repaint_budget(4 * 1024 * 1024) > repaint_budget(64 * 1024),
        "a bigger screen must get longer, or the budget is a throughput floor"
    );
    // A megabyte — the size `an_oversized_repaint_does_not_wedge_the_session` reaches — must get
    // meaningfully more than the flat slack, or a slow link cannot ever finish it.
    assert!(
        repaint_budget(1024 * 1024) >= WRITE_TIMEOUT + Duration::from_secs(16),
        "a 1 MiB screen got {:?}, which a modest link cannot meet",
        repaint_budget(1024 * 1024)
    );
}

/// The number in an `Exited` frame is the one a shell would report, not the raw `waitpid`
/// status — the two differ by a byte shift, and `SessionAttachClient` hands whatever arrives
/// straight back as its own exit status.
#[test]
fn an_exit_status_becomes_the_code_a_shell_would_report() {
    assert_eq!(exit_code(7 << 8), 7, "exit 7, not the raw 1792");
    assert_eq!(exit_code(0), 0);
    assert_eq!(exit_code(255 << 8), 255, "the widest normal exit");
    assert_eq!(
        exit_code(libc::SIGKILL),
        128 + 9,
        "killed, by shell convention"
    );
    assert_eq!(exit_code(libc::SIGHUP), 128 + 1);
    assert_eq!(exit_code(0o177), 0, "stopped is not an exit");
}

/// A run's reader looks in on its supervisor without reaping it (#522), so the end it then
/// takes still reaps it under `TERMINATING` and reports the code it exited with.
#[test]
fn a_child_seen_to_have_exited_is_left_for_the_end_to_reap() {
    let mut live = std::process::Command::new("/bin/sleep")
        .arg("30")
        .spawn()
        .expect("spawn");
    assert!(
        !child_exited(live.id() as i32),
        "a live child has not exited"
    );
    let _ = live.kill();
    let _ = live.wait();

    let mut child = std::process::Command::new("/bin/sh")
        .args(["-c", "exit 7"])
        .spawn()
        .expect("spawn");
    let pid = child.id() as i32;
    assert!(
        until(Instant::now() + Duration::from_secs(5), || child_exited(
            pid
        )
        .then_some(()))
        .is_some(),
        "the exit is seen"
    );
    assert!(child_exited(pid), "and seen again: it was not reaped");
    let mut status = 0;
    assert!(child_gone(pid, &mut status));
    assert_eq!(exit_code(status), 7, "the end still gets its code");
    // `child_gone` reaped it already; this only lets go of the handle.
    let _ = child.wait();
}

/// A probed client that stops answering gives up the size, as one that detaches does, so the one
/// still answering, a Mac someone is at, gets its own window's size at once (#593). Then the
/// first answer from the one that went quiet counts it as attached again without taking the size
/// back: that needs an act, as ever.
#[cfg(feature = "terminal-state")]
#[test]
fn a_probed_client_that_stops_answering_gives_up_the_size() {
    let store = SessionStore::with_keepalive_interval(Duration::from_millis(30));
    let session = id(0xA1);
    sized_session(&store, session);
    let quiet_writer: SharedWriter = Arc::new(Mutex::new(Box::new(Capture::default())));
    let (_, quiet) = store
        .attach_client(session, quiet_writer, 1, Size::cells(80, 24), true)
        .expect("attach the probed client");
    let (_answering, answering) = attach_sized(&store, session, 100, 30);
    assert_eq!(
        store.size_owner(session),
        Some(quiet),
        "the first attach owns it"
    );

    let deadline = Instant::now() + Duration::from_secs(5);
    while store.size_owner(session) != Some(answering) {
        assert!(Instant::now() < deadline, "the quiet client kept the size");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(pty_size(&store, session), (100, 30));
    assert!(store.list()[0].attached, "the answering client is attached");

    store.write_input(session, quiet, b"\x1b[?25930;0$y");
    assert_eq!(
        store.size_owner(session),
        Some(answering),
        "an answer is no act"
    );
    store.kill_all();
}

/// A client that has stopped answering is never handed the size as the one left (#593): the Mac
/// that held it is asleep, so when the other client goes the size stays free, and the next client
/// to attach takes it at once rather than showing the sleeping Mac's geometry until it types.
#[cfg(feature = "terminal-state")]
#[test]
fn a_stale_client_left_on_its_own_is_not_handed_the_size() {
    let store = SessionStore::with_keepalive_interval(Duration::from_millis(30));
    let session = id(0xA2);
    sized_session(&store, session);
    let quiet_writer: SharedWriter = Arc::new(Mutex::new(Box::new(Capture::default())));
    store
        .attach_client(session, quiet_writer, 1, Size::cells(80, 24), true)
        .expect("attach the probed client");
    let (_other, other) = attach_sized(&store, session, 100, 30);
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.size_owner(session) != Some(other) {
        assert!(
            Instant::now() < deadline,
            "the quiet client never went stale"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    store.detach(session, other);
    assert_eq!(
        store.size_owner(session),
        None,
        "the stale client took the size"
    );
    let (_next, next) = attach_sized(&store, session, 120, 40);
    assert_eq!(
        store.size_owner(session),
        Some(next),
        "the next attach did not fill it"
    );
    assert_eq!(pty_size(&store, session), (120, 40));
    store.kill_all();
}
