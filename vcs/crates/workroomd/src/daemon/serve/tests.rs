use super::*;
use wr_protocol::terminal::decode_descriptor_list;

/// A container's daemon is its entrypoint, so nothing makes the socket's folder first (#308):
/// the lock beside the socket is the first thing written there.
#[test]
fn the_lock_makes_a_missing_socket_folder_private() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("workroomd-mkdir-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let socket = root.join("a/b/workroomd.sock");

    let _lock = acquire_instance_lock(&socket).expect("the lock makes the folder");

    let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&root.join("a/b")), 0o700);
    assert_eq!(mode(&root.join("a")), 0o700);
    let _ = std::fs::remove_dir_all(&root);
}

/// A folder someone else made keeps the mode they gave it.
#[test]
fn the_lock_leaves_an_existing_socket_folder_alone() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("workroomd-keep-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o750)).unwrap();

    let _lock = acquire_instance_lock(&dir.join("workroomd.sock")).expect("lock");

    let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o750);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn instance_lock_is_exclusive() {
    let dir = std::env::temp_dir().join(format!("workroomd-lock-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("workroomd.sock");

    let first = acquire_instance_lock(&socket).expect("first lock");
    assert!(
        matches!(
            acquire_instance_lock(&socket),
            Err(ServeError::AlreadyRunning(_))
        ),
        "a second daemon must not be able to take the lock"
    );
    drop(first);
    // Released on drop, so a restart after a clean exit works. Retried briefly: a process
    // another test forks at that moment holds the lock until it execs (see #224).
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
    while acquire_instance_lock(&socket).is_err() {
        assert!(std::time::Instant::now() < deadline, "lock after release");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let _ = std::fs::remove_dir_all(&dir);
}

fn aged(path: &Path) {
    let days = std::time::SystemTime::now() - Duration::from_secs(10 * 24 * 3600);
    std::fs::File::options()
        .append(true)
        .open(path)
        .unwrap()
        .set_times(
            std::fs::FileTimes::new()
                .set_accessed(days)
                .set_modified(days),
        )
        .unwrap();
}

fn modified_ago(path: &Path) -> Duration {
    let modified = std::fs::metadata(path).unwrap().modified().unwrap();
    std::time::SystemTime::now()
        .duration_since(modified)
        .unwrap_or_default()
}

/// Runs an idle daemon for 400 ms with `lock` and a log kept fresh `every`, from files ten days
/// old, and returns how long ago each file was last modified. With `age_again`, both files are
/// set ten days back once more 150 ms in, after the first touch, so only a later one freshens them.
fn serve_kept_fresh(
    name: &str,
    every: Duration,
    age_again: bool,
    take_lock: impl FnOnce(&Path) -> InstanceLock,
) -> (Duration, Duration) {
    let dir = std::env::temp_dir().join(format!("wr-fresh-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("workroomd");
    let lock = take_lock(&socket);
    let log_path = crate::daemon::log::log_path(&socket);
    let log = std::fs::File::create(&log_path).unwrap();
    aged(&socket.with_extension("lock"));
    aged(&log_path);

    let mut daemon = Daemon::new();
    daemon.keep_fresh(lock.fd(), log.as_raw_fd(), every);
    let listener = bind(&socket).unwrap();
    let ager = age_again.then(|| {
        let files = [socket.with_extension("lock"), log_path.clone()];
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            files.iter().for_each(|file| aged(file));
        })
    });
    daemon
        .run(listener, &socket, Duration::from_millis(400))
        .unwrap();
    if let Some(ager) = ager {
        ager.join().unwrap();
    }

    let ages = (
        modified_ago(&socket.with_extension("lock")),
        modified_ago(&log_path),
    );
    let _ = std::fs::remove_dir_all(&dir);
    ages
}

/// A daemon with a client is not idle and sleeps with no deadline; the client leaving is what
/// has it look again (`wake_idle`), so it idles out `idle_timeout` after that and not never.
#[test]
fn the_last_client_leaving_wakes_the_idle_check() {
    let dir = std::env::temp_dir().join(format!("wr-idlewake-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("workroomd");
    let listener = bind(&socket).unwrap();
    let client = UnixStream::connect(&socket).unwrap();
    let daemon = Daemon::new();
    let served = {
        let socket = socket.clone();
        std::thread::spawn(move || daemon.run(listener, &socket, Duration::from_millis(200)))
    };
    std::thread::sleep(Duration::from_millis(500));
    assert!(!served.is_finished(), "idled out with a client connected");

    drop(client);
    let deadline = Instant::now() + Duration::from_secs(3);
    while !served.is_finished() {
        assert!(
            Instant::now() < deadline,
            "the client leaving did not wake the idle check"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    served.join().unwrap().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A daemon in /tmp looks at least once a second, so a Mac waking from days asleep freshens its
/// lock and log before `tmp_cleaner` can take them; any other daemon sleeps until something
/// happens or its next deadline.
/// Value: protects=the /tmp lock is touched within a second of a wake; fails_when=a /tmp daemon sleeps on an hour-long freshen timeout; why_new=no test looked at the timeout; seam=none; no_claim=poll's clock across a real sleep (can't be slept in a test)
#[test]
fn a_tmp_daemon_looks_every_second_and_others_sleep_until_due() {
    let hour = Some(Duration::from_secs(3600));
    assert_eq!(poll_timeout(hour, true, true), 1000, "a /tmp daemon");
    assert_eq!(poll_timeout(hour, true, false), 3_600_000, "elsewhere");
    assert_eq!(
        poll_timeout(None, true, false),
        -1,
        "nothing due, nothing kept"
    );
    assert_eq!(poll_timeout(None, false, false), 1000, "no wake pipe");
    assert_eq!(
        poll_timeout(Some(Duration::from_millis(300)), true, true),
        300,
        "a sooner deadline still wins"
    );
}

/// The commonest way a daemon's last session goes: its shell exits on its own, with no client
/// and no kill. That too must wake the idle check, or the daemon never idles out.
/// Value: protects=a daemon idles out after its last session ends on its own; fails_when=remove_if_held stops calling wake_idle; why_new=the other idle test ends a client, not a session; seam=none; no_claim=kill and the rpc paths (their own wake_idle calls)
#[test]
fn a_session_ending_on_its_own_wakes_the_idle_check() {
    let dir = std::env::temp_dir().join(format!("wr-idleend-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("workroomd");
    let listener = bind(&socket).unwrap();
    let daemon = Daemon::new();
    let args = [OsString::from("-c"), OsString::from("sleep 1")];
    daemon
        .sessions
        .create(SessionSpec {
            id: SessionId([0x5e; 16]),
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
        .expect("a session that ends");
    let served = {
        let socket = socket.clone();
        std::thread::spawn(move || daemon.run(listener, &socket, Duration::from_millis(200)))
    };
    std::thread::sleep(Duration::from_millis(500));
    assert!(!served.is_finished(), "idled out with a session running");

    let deadline = Instant::now() + Duration::from_secs(5);
    while !served.is_finished() {
        assert!(
            Instant::now() < deadline,
            "the session ending did not wake the idle check"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    served.join().unwrap().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

/// macOS's `tmp_cleaner` deletes /tmp files untouched for three days (#528). A daemon's lock is
/// never written after it is taken, and a quiet one's log can sit for days: the serve loop
/// touches both through the descriptors it holds, every interval, logged lines or not.
#[test]
fn a_serving_daemon_keeps_its_lock_and_log_fresh() {
    let (lock, log) = serve_kept_fresh("taken", Duration::from_millis(50), true, |socket| {
        acquire_instance_lock(socket).expect("lock")
    });
    assert!(
        lock < Duration::from_secs(60),
        "lock last modified {lock:?} ago"
    );
    assert!(
        log < Duration::from_secs(60),
        "log last modified {log:?} ago"
    );
}

/// A daemon that took over by hand-off holds the lock the program before it took, adopted from
/// the hand-off table, and keeps that one fresh too, from the moment it serves: an inherited lock
/// can already be days old, and must not wait out an interval before its first touch.
#[test]
fn a_daemon_that_took_over_by_hand_off_keeps_the_lock_it_inherited_fresh() {
    let (lock, _) = serve_kept_fresh("adopted", FRESHEN_EVERY, false, |socket| {
        let taken = acquire_instance_lock(socket).expect("lock");
        // SAFETY: a fresh duplicate of the open lock file, owned by nothing else, as a
        // hand-off table's lock is; the original is closed, as the program before exits.
        let inherited = unsafe { InstanceLock::adopt(libc::dup(taken.fd())) };
        drop(taken);
        inherited
    });
    assert!(
        lock < Duration::from_secs(60),
        "lock last modified {lock:?} ago"
    );
}

/// The descriptor list must match what `SessionDescriptor.decodeList` expects, byte for byte,
/// or the app silently sees no sessions on the Rust backend.
#[test]
fn descriptor_list_round_trips_through_our_own_decoder() {
    use crate::terminal::session::SessionInfo;
    let sessions = vec![
        SessionInfo {
            id: SessionId([3u8; 16]),
            pid: 4242,
            attached: true,
            foreground: Some("nvim".into()),
            cwd: Some("/work/room".into()),
            claude_profile: None,
            metadata: Vec::new(),
        },
        SessionInfo {
            id: SessionId([9u8; 16]),
            pid: 77,
            attached: false,
            foreground: None,
            cwd: None,
            claude_profile: None,
            metadata: Vec::new(),
        },
    ];
    let decoded = decode_descriptor_list(&encode_descriptor_list(&sessions));
    assert_eq!(decoded.len(), 2);
    assert_eq!(decoded[0].0, SessionId([3u8; 16]).to_hyphenated());
    assert!(decoded[0].1);
    assert_eq!(decoded[0].2, "nvim");
    assert!(!decoded[1].1);
    assert_eq!(decoded[1].2, "-");
}

/// The Claude profile entry is sent for a confirmed `claude`, empty when it has none, and not at
/// all otherwise, so the app shows no account rather than guessing one (#480).
#[test]
fn descriptor_list_carries_the_claude_profile_of_a_claude_only() {
    use crate::terminal::session::SessionInfo;
    let entry = |key: &str, value: &str| {
        let mut out = Vec::new();
        out.extend_from_slice(&(key.len() as u32).to_be_bytes());
        out.extend_from_slice(key.as_bytes());
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
        out
    };
    let contains = |haystack: &[u8], needle: &[u8]| {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    };
    let session = |claude_profile: Option<&str>| SessionInfo {
        id: SessionId([5u8; 16]),
        pid: 9,
        attached: false,
        foreground: Some("claude".into()),
        cwd: None,
        claude_profile: claude_profile.map(str::to_string),
        metadata: Vec::new(),
    };

    let set = encode_descriptor_list(&[session(Some("/p/sessions/2-u_example.com"))]);
    assert!(contains(
        &set,
        &entry("claude_profile", "/p/sessions/2-u_example.com")
    ));
    let unset = encode_descriptor_list(&[session(Some(""))]);
    assert!(contains(&unset, &entry("claude_profile", "")));
    // And the entry count covers it, so the app's decoder reads past it to the end.
    let decoded = decode_descriptor_list(&unset);
    assert_eq!(decoded.len(), 1);
    assert_eq!(decoded[0].2, "claude");
    let unknown = encode_descriptor_list(&[session(None)]);
    assert!(!contains(&unknown, b"claude_profile"));
    assert_eq!(decode_descriptor_list(&unknown)[0].2, "claude");
}

/// The header the Swift decoder reads first, pinned explicitly: a count, then a 16-byte id.
/// `SessionDescriptor.minimumEncodedSize` is 37, and `decodeList` rejects a count larger than
/// `payload.count / 37` — so an encoder that disagreed here would be rejected wholesale rather
/// than producing a visible error.
#[test]
fn descriptor_list_layout_matches_the_swift_decoder() {
    use crate::terminal::session::SessionInfo;
    let bytes = encode_descriptor_list(&[SessionInfo {
        id: SessionId([1u8; 16]),
        pid: 1,
        attached: true,
        foreground: None,
        cwd: None,
        claude_profile: None,
        metadata: Vec::new(),
    }]);
    assert_eq!(&bytes[..4], &[0, 0, 0, 1], "count is a big-endian u32");
    assert_eq!(&bytes[4..20], &[1u8; 16], "then the 16-byte identifier");
    // 4 (count) + 16 + 4 (pid) + 8 (tty) + 4 (empty cwd) + 1 (attached) + 4 (no metadata)
    assert_eq!(bytes.len(), 41);
    assert!(
        1 <= bytes.len() / 37,
        "a single descriptor must satisfy Swift's minimumEncodedSize guard"
    );
}

/// A `Sessions` reply is one frame, and `Frame::encode` panics rather than truncating past the
/// cap. Reply with a failure instead — which the app already renders — rather than killing the
/// connection thread and leaving the client waiting for a frame that will never come.
#[test]
fn an_oversized_session_list_is_refused_rather_than_panicking() {
    // What `dispatch` sends: the reply frame inside an envelope. Encoding the frame alone
    // passed at exactly `MAX_PAYLOAD_SIZE`, which then panicked `Envelope::encode` (#246).
    let sent = |payload: Vec<u8>| {
        let frame = list_reply(payload);
        let _ = Envelope::new(Service::Control, 0, frame.encode()).encode();
        frame.kind
    };

    // The biggest list that fits is the smaller of the frame cap and what the envelope leaves
    // after the frame's five-byte header, whichever way round the two caps are.
    let fits = MAX_PAYLOAD_SIZE.min(MAX_ENVELOPE_PAYLOAD - HEADER_SIZE);

    assert_eq!(sent(encode_descriptor_list(&[])), FrameKind::Sessions);
    assert_eq!(sent(vec![0u8; fits]), FrameKind::Sessions);
    // And the refusal must itself be sendable, which is the whole point.
    assert_eq!(sent(vec![0u8; fits + 1]), FrameKind::Failure);
    // Exactly `MAX_PAYLOAD_SIZE` is what panicked before the fix (#246).
    assert_eq!(
        sent(vec![0u8; MAX_PAYLOAD_SIZE]) == FrameKind::Failure,
        MAX_PAYLOAD_SIZE > fits
    );
    assert_eq!(sent(vec![0u8; MAX_PAYLOAD_SIZE + 1]), FrameKind::Failure);
}

fn env(entries: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    entries
        .iter()
        .map(|(key, value)| (OsString::from(key), OsString::from(value)))
        .collect()
}

/// The app's metadata variables become the session's metadata, under the keys the app reads
/// them back by (`SessionMetadataKey`); everything else in the client's environment, the app's
/// unread `project` included, is not metadata (#255).
#[test]
fn a_sessions_metadata_comes_from_the_apps_variables() {
    let metadata = session_metadata(&env(&[
        ("PATH", "/bin"),
        ("WORKROOM_SESSION_ID", "ignored"),
        ("WORKROOM_SESSION_PROJECT", "/Users/me/dev/app"),
        (
            "WORKROOM_SESSION_WORKROOM",
            "wr|/Users/me/dev/app|cyan-brush",
        ),
        ("WORKROOM_SESSION_TITLE", "Terminal 2"),
        ("WORKROOM_SESSION_TAB", "dead"),
    ]));
    assert_eq!(
        metadata,
        vec![
            (
                "workroom".to_string(),
                "wr|/Users/me/dev/app|cyan-brush".to_string()
            ),
            ("title".to_string(), "Terminal 2".to_string()),
        ]
    );
    assert!(session_metadata(&env(&[("WORKROOM_SESSION_WORKROOM", "")])).is_empty());
}

/// A local workroom id holds the whole project path, so it can be long and must still be kept;
/// one past the bound drops the metadata whole rather than keep a cut id (D8).
#[test]
fn a_long_workroom_id_is_kept_and_one_past_the_bound_drops_the_metadata() {
    let long = format!("wr|/{}|cyan", "p".repeat(1100));
    let kept = session_metadata(&env(&[
        ("WORKROOM_SESSION_WORKROOM", &long),
        ("WORKROOM_SESSION_TITLE", "Terminal 1"),
    ]));
    assert_eq!(kept[0], ("workroom".to_string(), long));

    let over = "w".repeat(MAX_WORKROOM_BYTES + 1);
    assert!(
        session_metadata(&env(&[
            ("WORKROOM_SESSION_WORKROOM", &over),
            ("WORKROOM_SESSION_TITLE", "Terminal 1"),
        ]))
        .is_empty()
    );
}

/// A title is cut to `MAX_TITLE_BYTES` at a character boundary, never mid-character.
#[test]
fn a_long_title_is_cut_at_a_character_boundary() {
    // Three bytes each, so 256 falls inside one.
    let title = "€".repeat(10 * 1024);
    let metadata = session_metadata(&env(&[("WORKROOM_SESSION_TITLE", &title)]));
    let (key, cut) = &metadata[0];
    assert_eq!(key, "title");
    assert!(cut.len() <= MAX_TITLE_BYTES && cut.len() > MAX_TITLE_BYTES - 3);
    assert!(cut.chars().all(|c| c == '€'));
}

/// With every field at its bound, hundreds of sessions still fit one list reply, so no title or
/// workroom id can turn the whole list into a `Failure` (D8).
#[test]
fn many_sessions_at_the_metadata_bounds_still_list() {
    use crate::terminal::session::SessionInfo;
    let metadata = vec![
        ("workroom".to_string(), "w".repeat(MAX_WORKROOM_BYTES)),
        ("title".to_string(), "t".repeat(MAX_TITLE_BYTES)),
        ("created".to_string(), u64::MAX.to_string()),
    ];
    let sessions: Vec<SessionInfo> = (0..250u8)
        .map(|n| SessionInfo {
            id: SessionId([n; 16]),
            pid: 1,
            attached: false,
            foreground: Some("nvim".into()),
            cwd: Some("c".repeat(1024)),
            claude_profile: None,
            metadata: metadata.clone(),
        })
        .collect();
    assert_eq!(
        list_reply(encode_descriptor_list(&sessions)).kind,
        FrameKind::Sessions
    );
}

#[test]
fn a_truncated_descriptor_list_decodes_to_what_survived() {
    use crate::terminal::session::SessionInfo;
    let full = encode_descriptor_list(&[SessionInfo {
        id: SessionId([5u8; 16]),
        pid: 1,
        attached: true,
        foreground: None,
        cwd: None,
        claude_profile: None,
        metadata: Vec::new(),
    }]);
    // Cut mid-descriptor: no panic, no phantom entry.
    assert!(decode_descriptor_list(&full[..20]).is_empty());
}
