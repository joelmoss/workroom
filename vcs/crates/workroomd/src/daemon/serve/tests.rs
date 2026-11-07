use super::*;
use crate::terminal::session::{SessionId, SessionSpec};
use std::ffi::{OsStr, OsString};

/// Every test that runs `Daemon::run` takes this. Each run sleeps on the one process-wide wake
/// pipe (`IDLE_WAKE`) and drains it when it wakes, so two at once can take each other's wake: a
/// run that a client or session keeps busy then sleeps with no deadline and never idles out. A
/// real daemon is one `Daemon::run` per process, where nothing else drains its pipe.
static DAEMON_RUN_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn daemon_run_lock() -> std::sync::MutexGuard<'static, ()> {
    DAEMON_RUN_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

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
    let _run = daemon_run_lock();
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
    let _run = daemon_run_lock();
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
    let _run = daemon_run_lock();
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
