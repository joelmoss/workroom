use super::*;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::symlink;
use std::process::Command;

/// A read as `read` makes it, with the daemon's own deadline, count and open.
fn read_file(
    root: &Path,
    relative: &str,
    mode: Symlinks,
    max_bytes: u64,
) -> Result<Vec<u8>, FileError> {
    read_file_with(
        root,
        relative,
        mode,
        max_bytes,
        FILESYSTEM_TIMEOUT,
        &ABANDONED_FILESYSTEM_OPERATIONS,
        open_read_file,
    )
}

/// Everything that is a plain request/reply, without a socket.
fn execute(bytes: &[u8]) -> Value {
    reply(parse(bytes).and_then(|request| handle(&request)))
}

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("wr-file-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    // The tests compare real paths, and /tmp is a symlink on macOS.
    std::fs::canonicalize(&root).unwrap()
}

fn git(root: &Path, args: &[&str]) {
    assert!(
        Command::new("git")
            .args(args)
            .current_dir(root)
            .status()
            .unwrap()
            .success()
    );
}

#[test]
fn a_regular_file_reads_under_both_policies() {
    let root = scratch("regular");
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/a.txt"), b"hello").unwrap();
    for mode in [Symlinks::FollowWithinRoot, Symlinks::Refuse] {
        assert_eq!(read_file(&root, "src/a.txt", mode, 100).unwrap(), b"hello");
    }
    std::fs::write(root.join("empty"), b"").unwrap();
    assert!(
        read_file(&root, "empty", Symlinks::Refuse, 100)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn a_link_inside_the_root_is_followed_by_the_viewer_and_refused_for_diffs() {
    let root = scratch("inside");
    std::fs::write(root.join("real.txt"), b"data").unwrap();
    symlink("real.txt", root.join("alias.txt")).unwrap();
    assert_eq!(
        read_file(&root, "alias.txt", Symlinks::FollowWithinRoot, 100).unwrap(),
        b"data"
    );
    assert_eq!(
        read_file(&root, "alias.txt", Symlinks::Refuse, 100),
        Err(FileError::Refused("symbolic link".into()))
    );
}

#[test]
fn a_link_out_of_the_root_is_refused_under_both_policies() {
    let root = scratch("escape");
    let outside = scratch("escape-outside");
    std::fs::write(outside.join("secret"), b"top secret").unwrap();
    symlink(outside.join("secret"), root.join("notes")).unwrap();
    for mode in [Symlinks::FollowWithinRoot, Symlinks::Refuse] {
        assert!(
            matches!(
                read_file(&root, "notes", mode, 100),
                Err(FileError::Refused(_))
            ),
            "{mode:?}"
        );
    }
}

#[test]
fn a_directory_link_out_of_the_root_is_refused_even_when_the_leaf_is_a_plain_file() {
    let root = scratch("dirlink");
    let outside = scratch("dirlink-outside");
    std::fs::write(outside.join("secret"), b"top secret").unwrap();
    symlink(&outside, root.join("linked")).unwrap();
    // The leaf `secret` is a regular file, so `O_NOFOLLOW` alone would let this through.
    for mode in [Symlinks::FollowWithinRoot, Symlinks::Refuse] {
        assert!(
            matches!(
                read_file(&root, "linked/secret", mode, 100),
                Err(FileError::Refused(_))
            ),
            "{mode:?}"
        );
    }
}

#[test]
fn a_sibling_directory_sharing_the_roots_name_prefix_is_outside_it() {
    let parent = scratch("prefix");
    let root = parent.join("repo");
    let sibling = parent.join("repo-other");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&sibling).unwrap();
    std::fs::write(sibling.join("x"), b"x").unwrap();
    symlink(sibling.join("x"), root.join("x")).unwrap();
    assert!(matches!(
        read_file(&root, "x", Symlinks::FollowWithinRoot, 100),
        Err(FileError::Refused(_))
    ));
}

#[test]
fn a_fifo_is_refused_without_blocking() {
    let root = scratch("fifo");
    let path = std::ffi::CString::new(root.join("pipe").as_os_str().as_bytes()).unwrap();
    // SAFETY: `path` is a NUL-terminated string that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let started = std::time::Instant::now();
    assert_eq!(
        read_file(&root, "pipe", Symlinks::FollowWithinRoot, 100),
        Err(FileError::Refused("not a regular file".into()))
    );
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn a_directory_is_not_a_readable_file() {
    let root = scratch("directory");
    std::fs::create_dir_all(root.join("sub")).unwrap();
    assert_eq!(
        read_file(&root, "sub", Symlinks::Refuse, 100),
        Err(FileError::Refused("not a regular file".into()))
    );
}

#[test]
fn a_missing_file_is_not_found() {
    let root = scratch("missing");
    assert!(matches!(
        read_file(&root, "nope", Symlinks::Refuse, 100),
        Err(FileError::NotFound(_))
    ));
}

#[test]
fn a_file_over_max_bytes_is_too_large_and_one_at_the_limit_is_not() {
    let root = scratch("large");
    std::fs::write(root.join("f"), vec![b'x'; 11]).unwrap();
    assert!(matches!(
        read_file(&root, "f", Symlinks::Refuse, 10),
        Err(FileError::TooLarge(_))
    ));
    assert_eq!(
        read_file(&root, "f", Symlinks::Refuse, 11).unwrap().len(),
        11
    );
}

#[test]
fn a_read_ceiling_above_the_services_is_rejected_not_clamped() {
    let root = scratch("ceiling");
    std::fs::write(root.join("f"), b"x").unwrap();
    let request = json!({
        "version": 1, "method": "read", "root": root, "path": "f",
        "symlinks": "refuse", "max_bytes": MAX_READ_BYTES + 1,
    });
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert!(
        reply["error"]["Unsupported"]
            .as_str()
            .unwrap()
            .contains("ceiling")
    );
}

#[test]
fn read_replies_carry_the_size_and_base64_content() {
    let root = scratch("reply");
    std::fs::write(root.join("f"), b"foobar").unwrap();
    let request = json!({
        "version": 1, "method": "read", "root": root, "path": "f",
        "symlinks": "follow_within_root", "max_bytes": 100,
    });
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert_eq!(reply["result"]["size"], 6);
    assert_eq!(reply["result"]["content"], "Zm9vYmFy");
}

#[test]
fn concurrent_reads_are_capped_and_a_finished_read_frees_its_slot() {
    static LOCAL: AtomicUsize = AtomicUsize::new(0);
    let held: Vec<_> = (0..MAX_CONCURRENT_READS)
        .map(|_| ReadSlot::acquire_from(&LOCAL, MAX_CONCURRENT_READS).unwrap())
        .collect();
    assert!(matches!(
        ReadSlot::acquire_from(&LOCAL, MAX_CONCURRENT_READS),
        Err(FileError::Busy(_))
    ));
    drop(held);
    assert!(ReadSlot::acquire_from(&LOCAL, MAX_CONCURRENT_READS).is_ok());
}

#[test]
fn a_relative_path_that_climbs_is_rejected_before_any_io() {
    let root = scratch("climb");
    for path in ["../x", "a/../../x", "/etc/passwd", "", "a\0b"] {
        let request = json!({
            "version": 1, "method": "read", "root": root, "path": path,
            "symlinks": "refuse", "max_bytes": 10,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(reply["error"]["Unsupported"].is_string(), "{path:?}");
    }
}

/// Every test that resolves, or moves `ABANDONED_FILESYSTEM_OPERATIONS`, takes this: `resolve`
/// reads the count, so one test holding it at the cap would refuse the others' resolves.
static WALKS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn walks_lock() -> std::sync::MutexGuard<'static, ()> {
    WALKS_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn resolve_request(root: &Path, path: &str) -> Value {
    let _walks = walks_lock();
    let request = json!({"version": 1, "method": "resolve", "root": root, "path": path});
    execute(&serde_json::to_vec(&request).unwrap())
}

// Value: protects=a walk that hangs (a link onto a dead mount, #334) is answered at its
// deadline, with the text the app stops a click on, and the walk stays counted until it
// returns; fails_when=`with_deadline` waits for the walk, or miscounts one left
// behind; why_new=no other test makes a walk outlive its request; seam=none (the closure is
// the walk itself, as `resolve` passes it)
#[test]
fn a_walk_past_its_deadline_is_answered_then_and_counted_until_it_returns() {
    let _walks = walks_lock();
    let before = ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire);
    let (release, released) = std::sync::mpsc::channel::<()>();
    let started = std::time::Instant::now();
    // The walk waits for the release, but not forever: if `with_deadline` waited for it, the
    // test would fail on its elapsed time instead of hanging.
    let result = with_deadline(
        Duration::from_millis(100),
        RESOLVE_TIMED_OUT,
        &ABANDONED_FILESYSTEM_OPERATIONS,
        move || {
            let _ = released.recv_timeout(Duration::from_secs(5));
            Ok("late")
        },
    );
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "it waited for the walk"
    );
    // The literal, not `RESOLVE_TIMED_OUT`: the app matches this text
    // (`DaemonFileProvider.resolveTimedOut`), so changing it has to fail here.
    assert!(
        matches!(&result, Err(FileError::Io(message)) if message.starts_with("resolving timed out")),
        "{result:?}"
    );
    assert_eq!(
        ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire),
        before + 1
    );
    assert_eq!(filesystem_operations_left_behind(), before + 1);
    release.send(()).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire) != before
        && std::time::Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire),
        before,
        "a returned walk is still counted"
    );
    assert_eq!(
        with_deadline(
            Duration::from_secs(5),
            RESOLVE_TIMED_OUT,
            &ABANDONED_FILESYSTEM_OPERATIONS,
            || Ok(7)
        )
        .unwrap(),
        7
    );
    assert_eq!(
        ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire),
        before
    );
}

// Value: protects=a walk that panics is answered as an `Io` error naming the panic, rather than
// as a vanished thread or a hung request; fails_when=`with_deadline` stops catching the walk's
// panic (the answer becomes "ended without an answer"); why_new=no other test makes a walk
// panic; seam=none (the closure is the walk itself)
#[test]
fn a_walk_that_panics_is_answered_as_an_io_error() {
    let _walks = walks_lock();
    let before = ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire);
    let result: Result<u8, FileError> = with_deadline(
        Duration::from_secs(5),
        RESOLVE_TIMED_OUT,
        &ABANDONED_FILESYSTEM_OPERATIONS,
        || panic!("walk exploded"),
    );
    assert!(
        matches!(&result, Err(FileError::Io(message)) if message.contains("panicked")),
        "{result:?}"
    );
    assert_eq!(
        ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire),
        before
    );
}

// Value: protects=a walk that panics AFTER it was left behind still comes off the count, so one
// bad walk can't hold a hand-off off, or the resolve cap shut, until the daemon restarts;
// fails_when=the panic skips the state change that takes the count back; why_new=the
// returned-walk test only covers a walk that ends normally; seam=none
#[test]
fn a_walk_that_panics_after_its_deadline_is_still_taken_off_the_count() {
    let _walks = walks_lock();
    let before = ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire);
    let (release, released) = std::sync::mpsc::channel::<()>();
    let result: Result<u8, FileError> = with_deadline(
        Duration::from_millis(100),
        RESOLVE_TIMED_OUT,
        &ABANDONED_FILESYSTEM_OPERATIONS,
        move || {
            let _ = released.recv_timeout(Duration::from_secs(5));
            panic!("walk exploded late")
        },
    );
    assert!(
        matches!(&result, Err(FileError::Io(message)) if message.starts_with(RESOLVE_TIMED_OUT)),
        "{result:?}"
    );
    assert_eq!(filesystem_operations_left_behind(), before + 1);
    release.send(()).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire) != before
        && std::time::Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire),
        before,
        "a panicked walk is still counted"
    );
}

// Value: protects=a read whose open stalls on a mount answers at its deadline, so the request
// thread, and the permit and read slot `dispatch` holds for it, is freed; the open left behind
// stays counted until it returns (#343); fails_when=`read_file_with` runs the open on the
// request thread, or does not count the stalled one; seam=the open is passed in and blocks on a
// channel, so no hung mount is needed, and the count is the test's own
#[test]
fn a_read_whose_open_stalls_answers_at_its_deadline() {
    static COUNT: AtomicUsize = AtomicUsize::new(0);
    let root = scratch("read-open-stall");
    let (release, released) = std::sync::mpsc::channel::<()>();
    let (answer, answered) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = read_file_with(
            &root,
            "f",
            Symlinks::FollowWithinRoot,
            10,
            Duration::from_millis(100),
            &COUNT,
            move |_: &Path, _: &str, _: Symlinks, _: u64| {
                let _ = released.recv_timeout(Duration::from_secs(10));
                Err(FileError::Io("the stalled open returned".into()))
            },
        );
        let _ = answer.send(result);
    });
    let result = answered
        .recv_timeout(Duration::from_secs(3))
        .expect("the read waited for its stalled open");
    assert!(
        matches!(&result, Err(FileError::Io(message)) if message.starts_with(READ_OPEN_TIMED_OUT)),
        "{result:?}"
    );
    assert_eq!(
        COUNT.load(Ordering::Acquire),
        1,
        "the stalled open is not counted"
    );
    release.send(()).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while COUNT.load(Ordering::Acquire) != 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        COUNT.load(Ordering::Acquire),
        0,
        "a returned open is still counted"
    );
}

// Value: protects=at the cap of workers left behind, a resolve and a read are both refused
// before they start another worker, through the routing a request takes, and both go through
// again once one returns; fails_when=either method skips the cap, or the cap is not lifted;
// seam=the count is passed in, so the shared one other tests read is never moved
#[test]
fn at_the_worker_cap_resolves_and_reads_are_refused_until_one_returns() {
    static COUNT: AtomicUsize = AtomicUsize::new(0);
    let root = scratch("worker-cap");
    std::fs::create_dir_all(root.join("sub")).unwrap();
    std::fs::write(root.join("f"), b"hi").unwrap();
    let ask = |request: &Value| {
        reply(
            parse(&serde_json::to_vec(request).unwrap())
                .and_then(|request| handle_with(&request, &COUNT)),
        )
    };
    let resolve = json!({"version": 1, "method": "resolve", "root": root, "path": "sub/../f"});
    let read = json!({
        "version": 1, "method": "read", "root": root, "path": "f",
        "symlinks": "follow_within_root", "max_bytes": 10,
    });

    COUNT.store(MAX_ABANDONED_FILESYSTEM_OPERATIONS, Ordering::Release);
    // The literal texts, not the constants: the app matches them (`DaemonFileProvider`).
    assert_eq!(
        ask(&resolve)["error"]["Busy"],
        "too many earlier resolves are still walking"
    );
    assert_eq!(
        ask(&read)["error"]["Busy"],
        "too many earlier filesystem operations are still pending"
    );

    COUNT.store(MAX_ABANDONED_FILESYSTEM_OPERATIONS - 1, Ordering::Release);
    assert_eq!(ask(&resolve)["result"]["path"], "f");
    assert_eq!(ask(&read)["result"]["size"], 2);
}

/// #327: `link/..` is the link TARGET's parent, which only the host can know.
#[test]
fn resolve_follows_a_link_before_its_parent_traversal() {
    let root = scratch("resolve-link");
    std::fs::create_dir_all(root.join("nested/dir")).unwrap();
    std::fs::write(root.join("nested/file.rb"), b"x").unwrap();
    std::fs::write(root.join("file.rb"), b"decoy").unwrap();
    symlink("nested/dir", root.join("link")).unwrap();
    assert_eq!(
        resolve_request(&root, "link/../file.rb")["result"]["path"],
        "nested/file.rb"
    );
    assert_eq!(
        resolve_request(&root, "./nested/./dir/../file.rb")["result"]["path"],
        "nested/file.rb"
    );
}

#[test]
fn resolve_refuses_a_path_that_climbs_the_root_before_any_io() {
    // The root does not exist, so any lookup would answer `NotFound`: `Unsupported` means
    // the path was refused before one.
    let root = std::env::temp_dir().join("wr-file-test-resolve-no-such-root");
    for path in [
        "..",
        "../x",
        "a/../../x",
        "./../x",
        "/etc/passwd",
        "",
        "a\0b",
    ] {
        let reply = resolve_request(&root, path);
        assert!(
            reply["error"]["Unsupported"].is_string(),
            "{path:?}: {reply}"
        );
    }
}

#[test]
fn resolve_refuses_a_link_out_of_the_root_and_the_root_itself() {
    let root = scratch("resolve-escape");
    let outside = scratch("resolve-escape-outside");
    std::fs::create_dir_all(outside.join("dir")).unwrap();
    std::fs::write(outside.join("secret"), b"top secret").unwrap();
    symlink(outside.join("dir"), root.join("out")).unwrap();
    std::fs::create_dir_all(root.join("sub")).unwrap();
    for path in ["out/../secret", "sub/.."] {
        let reply = resolve_request(&root, path);
        assert!(reply["error"]["Refused"].is_string(), "{path:?}: {reply}");
    }
}

// Value: protects=resolving works when the root the app names is itself a link (a symlinked
// home or a macOS /tmp), answering the path under the REAL root; fails_when=`resolve_path`
// compares against the root as given instead of its real path, refusing every click as
// outside the root; why_new=`scratch` canonicalizes every root, so no test names a link;
// seam=none
#[test]
fn resolve_works_when_the_root_is_itself_a_link() {
    let real = scratch("resolve-real-root");
    std::fs::create_dir_all(real.join("nested/dir")).unwrap();
    std::fs::write(real.join("nested/file.rb"), b"x").unwrap();
    symlink("nested/dir", real.join("link")).unwrap();
    let alias = real.with_file_name(format!(
        "{}-alias",
        real.file_name().unwrap().to_string_lossy()
    ));
    let _ = std::fs::remove_file(&alias);
    symlink(&real, &alias).unwrap();
    let reply = resolve_request(&alias, "link/../file.rb");
    std::fs::remove_file(&alias).unwrap();
    assert_eq!(reply["result"]["path"], "nested/file.rb", "{reply}");
}

/// What comes before the last `..` must exist, since only the host can say where it leads.
/// What comes after it is `read`'s to judge, as it is for a path with no `..`.
#[test]
fn resolve_reports_a_missing_directory_before_the_parent_traversal_as_not_found() {
    let root = scratch("resolve-missing");
    std::fs::create_dir_all(root.join("sub")).unwrap();
    let reply = resolve_request(&root, "nope/../x");
    assert!(reply["error"]["NotFound"].is_string(), "{reply}");
    assert_eq!(
        resolve_request(&root, "sub/../nope")["result"]["path"],
        "nope"
    );
}

// Value: protects=a link AFTER the last `..` keeps its own name, as a plain click on it would
// (links before it come back as their target); fails_when=`resolve_path` canonicalizes the
// whole path and answers the link's target; why_new=the other cases have no link after the
// `..`; seam=none
#[test]
fn resolve_keeps_what_follows_the_last_parent_traversal_as_written() {
    let root = scratch("resolve-leaf-link");
    std::fs::create_dir_all(root.join("nested/dir")).unwrap();
    std::fs::create_dir_all(root.join("real")).unwrap();
    std::fs::write(root.join("nested/v2.rb"), b"x").unwrap();
    symlink("v2.rb", root.join("nested/current.rb")).unwrap();
    symlink("nested/dir", root.join("link")).unwrap();
    symlink("real", root.join("linkdir")).unwrap();
    assert_eq!(
        resolve_request(&root, "link/../current.rb")["result"]["path"],
        "nested/current.rb"
    );
    assert!(
        resolve_request(&root, "a/../linkdir/x.rb")["error"]["NotFound"].is_string(),
        "`a` is missing, so there is nothing to resolve the `..` against"
    );
    std::fs::create_dir_all(root.join("a")).unwrap();
    assert_eq!(
        resolve_request(&root, "a/../linkdir/x.rb")["result"]["path"],
        "linkdir/x.rb"
    );
}

// Value: protects=a `resolve` request counts against the same MAX_CONCURRENT_READS cap as a
// `read`, because it canonicalizes through links that can sit on a hung network mount;
// fails_when=`dispatch` stops taking a `ReadSlot` for "resolve", so a resolve is no longer
// refused `Busy` while every slot is held; why_new=the other cap test drives `acquire_from` on
// its own counter and `execute` skips `dispatch`, so nothing pins which methods take a slot;
// seam=none (no other lib test reaches the global `READS`; only this one calls `dispatch`)
#[test]
fn a_resolve_is_refused_busy_while_every_read_slot_is_held() {
    // A resolve admitted here would read `ABANDONED_FILESYSTEM_OPERATIONS`, and the cap test's
    // `Busy` must not stand in for this one's.
    let _walks = walks_lock();
    #[derive(Clone, Default)]
    struct Capture(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);
    impl std::io::Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let capture = Capture::default();
    let writer: SharedWriter =
        std::sync::Arc::new(std::sync::Mutex::new(Box::new(capture.clone())));
    let subscriptions =
        Subscriptions::new(std::sync::Arc::clone(&writer), std::sync::Arc::new(|| {}));
    let _held: Vec<_> = (0..MAX_CONCURRENT_READS)
        .map(|_| ReadSlot::acquire().unwrap())
        .collect();
    // The root does not exist: were the resolve admitted it would answer `NotFound`, never `Busy`.
    let root = std::env::temp_dir().join("wr-file-test-resolve-busy-no-such-root");
    let request = json!({"version": 1, "method": "resolve", "root": root, "path": "f"});
    let envelope = Envelope::new(Service::File, 1, serde_json::to_vec(&request).unwrap());
    dispatch(&envelope, &writer, &subscriptions);
    let mut decoder = wr_protocol::envelope::EnvelopeDecoder::new();
    decoder.push(&capture.0.lock().unwrap());
    let reply = decoder
        .next_envelope()
        .unwrap()
        .expect("the refusal is written before dispatch returns");
    let reply: Value = serde_json::from_slice(&reply.payload[1..]).unwrap();
    assert!(reply["error"]["Busy"].is_string(), "{reply}");
}

#[test]
fn unknown_fields_methods_and_versions_are_typed_errors() {
    for request in [
        json!({"version": 1, "method": "nope"}),
        json!({"version": 2, "method": "capabilities"}),
        json!({"version": 1, "method": "capabilities", "argv": ["x"]}),
    ] {
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(reply["error"]["Unsupported"].is_string(), "{request}");
    }
    let reply = execute(br#"{"version":1,"method":"capabilities"}"#);
    assert_eq!(reply["result"]["version"], FILE_SERVICE_VERSION);
}

#[test]
fn git_listing_matches_git_ls_files_including_untracked_and_awkward_names() {
    let root = scratch("list");
    git(&root, &["init", "-q", "-b", "main"]);
    std::fs::write(root.join(".gitignore"), "ignored.txt\n").unwrap();
    std::fs::write(root.join("tracked.txt"), b"a").unwrap();
    std::fs::write(root.join("ignored.txt"), b"b").unwrap();
    std::fs::write(root.join("untracked.txt"), b"c").unwrap();
    std::fs::write(root.join("with\nnewline.txt"), b"d").unwrap();
    git(&root, &["add", ".gitignore", "tracked.txt"]);
    let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    let result = &reply["result"];
    assert_eq!(result["exit_code"], 0, "{reply}");
    let names: Vec<&str> = result["stdout"]
        .as_str()
        .unwrap()
        .split('\0')
        .filter(|name| !name.is_empty())
        .collect();
    assert!(names.contains(&"tracked.txt"));
    assert!(names.contains(&"untracked.txt"));
    assert!(names.contains(&"with\nnewline.txt"));
    assert!(!names.contains(&"ignored.txt"), "{names:?}");
}

/// The app still sends `shared_root` on every listing (a jj-era field the daemon ignores);
/// `Request` is `deny_unknown_fields`, so losing the ignored field would reject every listing.
#[test]
fn a_listing_naming_a_shared_root_still_runs() {
    let root = scratch("shared-root-list");
    git(&root, &["init", "-q", "-b", "main"]);
    let request = json!({
        "version": 1, "method": "list", "backend": "git", "root": root, "shared_root": root,
    });
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert_eq!(reply["result"]["exit_code"], 0, "{reply}");
}

#[test]
fn a_repository_fsmonitor_never_runs_during_a_listing() {
    let root = scratch("fsmonitor");
    git(&root, &["init", "-q", "-b", "main"]);
    std::fs::write(root.join("tracked.txt"), b"a").unwrap();
    git(&root, &["add", "tracked.txt"]);
    let marker = root.join("ran");
    let hook = root.join(".git/fsmonitor.sh");
    std::fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
    std::fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    git(&root, &["config", "core.fsmonitor", hook.to_str().unwrap()]);
    std::fs::write(root.join("untracked.txt"), b"c").unwrap();
    let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert_eq!(reply["result"]["exit_code"], 0, "{reply}");
    assert!(
        !marker.exists(),
        "a .git/config fsmonitor ran during a listing"
    );
}

#[test]
fn listing_outside_a_repository_reports_the_tools_own_failure() {
    let root = scratch("not-a-repo");
    let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert_ne!(reply["result"]["exit_code"], 0, "{reply}");
}
