use super::*;
#[cfg(feature = "terminal-state")]
use std::ffi::{OsStr, OsString};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wr-screens-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

const ID: SessionId = SessionId([7u8; 16]);

#[test]
fn a_record_round_trips() {
    let bytes = encode(120, 40, b"\x1b[1mhello\x1b[m");
    assert_eq!(decode(&bytes), Some((120, 40, &b"\x1b[1mhello\x1b[m"[..])));
}

/// A newer daemon reads what an older one wrote without running it. Version 1, written out by
/// hand, must keep decoding for as long as version 1 is the format.
#[test]
fn a_version_one_record_still_reads() {
    let written_by_an_older_daemon = b"WRSCREEN\x01\x00\x50\x00\x18\x00\x00\x00\x02hi";
    assert_eq!(
        decode(written_by_an_older_daemon),
        Some((80, 24, &b"hi"[..]))
    );
}

#[test]
fn anything_but_a_whole_record_is_no_record() {
    let whole = encode(80, 24, b"screen");
    assert!(decode(&whole[..whole.len() - 1]).is_none(), "truncated");
    assert!(
        decode(&[whole.as_slice(), b"!"].concat()).is_none(),
        "trailing bytes"
    );
    assert!(decode(&whole[..HEADER - 1]).is_none(), "short header");
    let mut other = whole.clone();
    other[8] = 2;
    assert!(decode(&other).is_none(), "unknown version");
    let mut other = whole.clone();
    other[0] = b'X';
    assert!(decode(&other).is_none(), "not a record");
    assert!(decode(&encode(0, 24, b"screen")).is_none(), "no width");
}

/// A file too big to be a record is not read whole to find that out.
#[test]
fn a_record_over_the_bound_is_not_loaded() {
    let dir = scratch("oversized");
    let screens = Screens::open(&dir).expect("open");
    fs::write(
        screens.path(ID),
        encode(80, 24, &vec![b'x'; MAX_RECORD + 1]),
    )
    .expect("write");
    assert!(screens.load(ID).is_none());
    let _ = fs::remove_dir_all(&dir);
}

/// A new session under an id with a record replaces it at once, so a shell that exits before
/// its first write leaves nothing of the old one to show. A create that loses to a live session
/// under the same id leaves that session's record alone.
#[test]
fn a_new_session_supersedes_its_ids_record() {
    let dir = scratch("supersede");
    let sessions = SessionStore::new();
    sessions
        .hooks()
        .screens
        .keep(Screens::open(&dir).expect("open"));
    let screens = sessions.hooks().screens.get().expect("screens");
    screens
        .save(ID, 80, 24, b"an earlier session")
        .expect("save");

    let args = [
        std::ffi::OsString::from("-c"),
        std::ffi::OsString::from("sleep 5"),
    ];
    let spec = || crate::terminal::session::SessionSpec {
        id: ID,
        program: std::ffi::OsStr::new("/bin/sh"),
        argv0: None,
        args: &args,
        env: &[],
        cwd: None,
        columns: 80,
        rows: 24,
        metadata: &[],
        interactive: false,
    };
    sessions.create(spec()).expect("create");
    assert!(
        screens.load(ID).is_none(),
        "the old record outlived its id's reuse"
    );

    screens.save(ID, 80, 24, b"the live session").expect("save");
    assert!(
        sessions.create(spec()).is_err(),
        "a second session took the id"
    );
    assert!(
        screens.load(ID).is_some(),
        "a create that lost removed the live record"
    );
    sessions.kill_all();
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_record_is_private_to_its_user() {
    let dir = scratch("private");
    let screens = Screens::open(&dir).expect("open");
    screens.save(ID, 80, 24, b"secret").expect("save");
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&dir), 0o700);
    assert_eq!(mode(&screens.path(ID)), 0o600);
    assert_eq!(screens.load(ID), Some((80, 24, b"secret".to_vec())));
    let _ = fs::remove_dir_all(&dir);
}

/// A reboot during a write leaves the temporary file and the previous record. The record is
/// what reads back, and `open` clears the leftover.
#[test]
fn a_write_a_reboot_interrupted_leaves_the_previous_record() {
    let dir = scratch("torn");
    let screens = Screens::open(&dir).expect("open");
    screens.save(ID, 80, 24, b"previous").expect("save");
    let temporary = screens.path(ID).with_extension("vt.tmp");
    fs::write(&temporary, &encode(80, 24, b"next")[..HEADER + 2]).expect("torn write");

    let screens = Screens::open(&dir).expect("reopen");
    assert!(!temporary.exists(), "the torn write was left behind");
    assert_eq!(screens.load(ID), Some((80, 24, b"previous".to_vec())));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_screen_over_the_bound_leaves_no_record() {
    let dir = scratch("bound");
    let screens = Screens::open(&dir).expect("open");
    screens.save(ID, 80, 24, b"small").expect("save");
    screens
        .save(ID, 80, 24, &vec![b'x'; MAX_RECORD + 1])
        .expect("save");
    assert!(!screens.path(ID).exists(), "a stale record was kept");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn open_keeps_only_the_newest_records() {
    let dir = scratch("prune");
    let screens = Screens::open(&dir).expect("open");
    let base = std::time::SystemTime::now() - Duration::from_secs(3600);
    let ids: Vec<SessionId> = (0..MAX_RECORDS as u8 + 2)
        .map(|n| SessionId([n; 16]))
        .collect();
    for (age, id) in ids.iter().enumerate() {
        screens.save(*id, 80, 24, b"screen").expect("save");
        File::options()
            .write(true)
            .open(screens.path(*id))
            .and_then(|f| f.set_modified(base + Duration::from_secs(age as u64)))
            .expect("age");
    }
    let screens = Screens::open(&dir).expect("reopen");
    assert_eq!(screens.records().len(), MAX_RECORDS);
    assert!(screens.load(ids[0]).is_none() && screens.load(ids[1]).is_none());
    assert!(screens.load(ids[2]).is_some());
    let _ = fs::remove_dir_all(&dir);
}

/// The pane's user closing it is the app killing the session by id.
#[test]
fn killing_a_session_removes_its_record() {
    let dir = scratch("kill");
    let sessions = SessionStore::new();
    sessions
        .hooks()
        .screens
        .keep(Screens::open(&dir).expect("open"));
    let screens = sessions.hooks().screens.get().expect("screens");
    screens.save(ID, 80, 24, b"one").expect("save");
    screens
        .save(SessionId([8u8; 16]), 80, 24, b"two")
        .expect("save");

    sessions.kill(ID);
    assert!(screens.load(ID).is_none());
    sessions.kill_all();
    assert!(screens.records().is_empty());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn the_notice_fits_the_pane() {
    let notice = String::from_utf8(notice(20, 5)).unwrap();
    assert!(
        notice.contains("\x1b[5;1H"),
        "not on the bottom row: {notice:?}"
    );
    assert!(notice.contains(&NOTICE[..20]) && !notice.contains(&NOTICE[..21]));
}

#[cfg(feature = "terminal-state")]
#[test]
fn a_record_is_repainted_at_the_panes_size_with_the_notice() {
    let dir = scratch("render");
    let screens = Screens::open(&dir).expect("open");
    let mut shadow = Shadow::new(40, 10);
    shadow.write(b"\x1b[?1049h\x1b[HFULL-SCREEN-PROGRAM");
    screens.save(ID, 40, 10, &shadow.record()).expect("save");

    let painted = screens.render(ID, 100, 30).expect("render");
    let mut client = Shadow::new(100, 30);
    client.write(&painted);
    let text = client.visible_text();
    assert!(text.contains("FULL-SCREEN-PROGRAM"), "{text:?}");
    assert!(text.contains(NOTICE), "{text:?}");
    assert!(screens.render(SessionId([9u8; 16]), 100, 30).is_none());
    let _ = fs::remove_dir_all(&dir);
}

/// A zero size means "the client has none yet" — `run_attach` reports that before it knows its
/// own terminal's geometry — and `render` must not resize the shadow down to it. The record's
/// own size is what gets used instead.
#[cfg(feature = "terminal-state")]
#[test]
fn render_with_no_client_size_keeps_the_records_own() {
    let dir = scratch("norequestedsize");
    let screens = Screens::open(&dir).expect("open");
    let mut shadow = Shadow::new(40, 10);
    shadow.write(b"RECORDED-AT-40x10");
    screens.save(ID, 40, 10, &shadow.record()).expect("save");

    let painted = screens.render(ID, 0, 0).expect("render");
    let mut client = Shadow::new(40, 10);
    client.write(&painted);
    assert!(client.visible_text().contains("RECORDED-AT-40x10"));
    let _ = fs::remove_dir_all(&dir);
}

/// The module doc: "A record goes when its session ends while the daemon runs." That is
/// `flush`'s cleanup half, not `SessionStore::kill` — the shell exits on its own, nobody closes
/// the pane, and the NEXT tick is what notices the id is no longer live and drops its record.
#[test]
fn a_session_that_ends_while_the_daemon_runs_loses_its_record_on_the_next_tick() {
    let dir = scratch("endedwhilerunning");
    let screens = Screens::open(&dir).expect("open");
    let sessions = SessionStore::new();
    sessions.hooks().screens.keep(screens);
    let live = sessions.hooks().screens.get().expect("screens");
    live.save(ID, 80, 24, b"was-on-screen").expect("save");

    // `written` simulates an earlier tick having written this id's record; `sessions` holds no
    // session for it, exactly as if the shell had already exited on its own.
    let mut written: HashSet<SessionId> = [ID].into_iter().collect();
    let mut failing = HashSet::new();
    flush(&sessions, &mut written, &mut failing);

    assert!(
        live.load(ID).is_none(),
        "a session that ended kept its record"
    );
    assert!(!written.contains(&ID));
    let _ = fs::remove_dir_all(&dir);
}

/// A session that ended with its host reports busy only while it runs: its record is written
/// from the live shadow and rendered long after the program is gone, so a restored pane must
/// never be told it is busy (#359): its repaint says idle (a REMOVE) at most. Driven through the
/// real writer, `flush`.
/// Value: protects=a restored pane's repaint carries no busy report for a session that reported busy; fails_when=changed_screens() takes replay() instead of record(), pinning the restored pane's spinner on; why_new=no test took a record from a live session through flush and render; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn a_restored_pane_is_never_told_the_session_was_busy() {
    let dir = scratch("restorenotbusy");
    let screens = Screens::open(&dir).expect("open");
    let sessions = SessionStore::new();
    sessions.hooks().screens.keep(screens);
    let args = vec![
        OsString::from("-c"),
        OsString::from("printf 'WORKING\\033]9;4;3\\033\\\\'; sleep 5"),
    ];
    sessions
        .create(crate::terminal::session::SessionSpec {
            id: ID,
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &[],
            cwd: None,
            columns: 80,
            rows: 24,
            metadata: &[],
            interactive: false,
        })
        .expect("create");
    let busy = b"\x1b]9;4;3";
    let has = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !has(&sessions.replay_bytes(ID), busy) && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        has(&sessions.replay_bytes(ID), busy),
        "fixture: the session never became busy"
    );
    flush(&sessions, &mut HashSet::new(), &mut HashSet::new());
    let live = sessions.hooks().screens.get().expect("screens");

    let painted = live.render(ID, 80, 24).expect("render");
    assert!(
        has(&painted, b"WORKING"),
        "fixture: the record has no screen; got {painted:?}"
    );
    assert!(
        !has(&painted, busy),
        "a restored pane was told the session was busy: {painted:?}"
    );
    sessions.kill_all();
    let _ = fs::remove_dir_all(&dir);
}

/// `flush`'s error arm: a write that fails is retried on the very next tick (via
/// `sessions.mark_changed`) rather than only after more output, and the session leaves
/// `failing` once a write finally lands.
#[cfg(feature = "terminal-state")]
#[test]
fn a_failing_write_is_retried_and_clears_once_it_succeeds() {
    // Root writes through a read-only directory, so there is no failure to retry.
    // SAFETY: `geteuid` takes no arguments and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("skipping: running as root");
        return;
    }
    let dir = scratch("writefails");
    let screens = Screens::open(&dir).expect("open");
    // No write permission left on the directory, so `save`'s temporary file cannot be created.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).expect("chmod");
    let sessions = SessionStore::new();
    sessions.hooks().screens.keep(screens);

    let args = vec![
        OsString::from("-c"),
        OsString::from("echo screen-content; sleep 5"),
    ];
    sessions
        .create(crate::terminal::session::SessionSpec {
            id: ID,
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &[],
            cwd: None,
            columns: 80,
            rows: 24,
            metadata: &[],
            interactive: false,
        })
        .expect("create");
    std::thread::sleep(Duration::from_millis(400));

    let mut written = HashSet::new();
    let mut failing = HashSet::new();
    // `tick` is the loop's pass: it must report a pending retry, or the thread sleeps on it.
    assert!(
        tick(&sessions, &mut written, &mut failing),
        "a failing write left no pass owed"
    );
    assert!(failing.contains(&ID), "a failed write was not tracked");
    assert!(!written.contains(&ID));
    assert!(
        sessions
            .hooks()
            .screens
            .get()
            .expect("screens")
            .load(ID)
            .is_none(),
        "a failed write still left a record"
    );

    // Fixed now: `mark_changed` in the error arm means the next tick tries again with no new
    // output needed.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).expect("chmod back");
    assert!(
        !tick(&sessions, &mut written, &mut failing),
        "a recovered write still owes a pass"
    );
    assert!(written.contains(&ID), "the recovered write was not retried");
    assert!(!failing.contains(&ID), "failing was not cleared on success");

    sessions.kill_all();
    let _ = fs::remove_dir_all(&dir);
}

/// Every daemon's tick compresses every shadow's history (#463), whether or not it keeps
/// records: the local Mac's daemon keeps none and holds the most panes.
///
/// Value: protects=tick compresses every shadow, with records and without; fails_when=tick
/// stops calling compress_shadows, or compression runs only beside records; why_new=no shadow
/// was ever compressed; seam=none
#[cfg(feature = "terminal-state")]
#[test]
fn a_tick_compresses_every_shadow_with_records_or_without() {
    for keep in [false, true] {
        let dir = scratch(&format!("compress-{keep}"));
        let sessions = SessionStore::new();
        if keep {
            sessions
                .hooks()
                .screens
                .keep(Screens::open(&dir).expect("open"));
        }
        let args = [OsString::from("-c"), OsString::from("sleep 10")];
        sessions
            .create(crate::terminal::session::SessionSpec {
                id: ID,
                program: OsStr::new("/bin/sh"),
                argv0: None,
                args: &args,
                env: &[],
                cwd: None,
                columns: 80,
                rows: 24,
                metadata: &[],
                interactive: false,
            })
            .expect("create");
        let shadow = sessions.shadow(ID).expect("shadow");
        {
            let mut shadow = shadow.lock().expect("shadow");
            for n in 0..20_000 {
                shadow.write(format!("line {n} {}\r\n", "z".repeat(60)).as_bytes());
            }
        }
        let memory = || shadow.lock().expect("shadow").memory().expect("memory");
        let full = memory().primary_resident_bytes;
        tick(&sessions, &mut HashSet::new(), &mut HashSet::new());
        let after = memory();
        sessions.kill_all();
        let _ = fs::remove_dir_all(&dir);
        assert!(
            after.primary_compressed_pages > 0 && after.primary_resident_bytes * 2 < full,
            "records {keep}: {} bytes resident after a tick, {full} before",
            after.primary_resident_bytes
        );
    }
}
