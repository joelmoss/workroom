use super::*;

const HOST: &str = "f00dcafe";

/// A new directory of this test's own under the system temp dir, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        for attempt in 0u32.. {
            let dir = std::env::temp_dir().join(format!(
                "workroom-staging-{name}-{}-{attempt}",
                std::process::id()
            ));
            if std::fs::create_dir(&dir).is_ok() {
                return Scratch(dir.canonicalize().unwrap());
            }
        }
        unreachable!()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A pid no process has: a child's, once it has been reaped.
fn dead_pid() -> u32 {
    let mut child = std::process::Command::new("true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

fn staging_name(prefix: &str, host: &str, pid: u32) -> String {
    format!("{prefix}{host}-{pid}-abc")
}

/// A staging folder with something in it, as a clone leaves one.
fn make_staging(path: &Path) {
    std::fs::create_dir_all(path.join(".git")).unwrap();
}

fn touch(path: &Path) {
    std::fs::write(path, b"").unwrap();
}

/// Holds `path`'s lock through an open file description of its own, as another process would,
/// until the returned file is dropped.
fn hold_lock(path: &Path) -> File {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap();
    flock_exclusive(&file).unwrap();
    file
}

/// Go's `TestStaleStaging_LockRules`: a lock, when there is one, decides; held keeps whatever the
/// pid, free sweeps whatever the pid; with none the pid decides; an orphan lock goes only once
/// free.
#[test]
fn a_staging_lock_decides_whether_its_clone_is_alive_else_its_pid_does() {
    let me = std::process::id();
    for (name, pid, folder, lock, held, want_stale) in [
        ("held lock, dead pid", dead_pid(), true, true, true, false),
        ("free lock, live pid", me, true, true, false, true),
        ("no lock, dead pid", dead_pid(), true, false, false, true),
        ("no lock, live pid", me, true, false, false, false),
        ("orphan lock, free", dead_pid(), false, true, false, true),
        ("orphan lock, held", dead_pid(), false, true, true, false),
    ] {
        let dir = Scratch::new("rules");
        let stage = dir.0.join(staging_name(".clone-", HOST, pid));
        if folder {
            make_staging(&stage);
        }
        let mut _holder = None;
        if lock {
            touch(&lock_path(&stage));
            if held {
                _holder = Some(hold_lock(&lock_path(&stage)));
            }
        }
        let stale = stale_staging(&dir.0, b".clone-", HOST);
        assert_eq!(stale.len() == 1, want_stale, "{name}");
        if let Some(found) = stale.first() {
            assert_eq!(found.dir, folder.then(|| stage.clone()), "{name}");
            assert_eq!(found.lock, lock.then(|| lock_path(&stage)), "{name}");
        }
    }
}

/// What has the shape of staging but no proof it is a dead clone of this machine's is never
/// swept: another machine's, one without an owner, one whose pid isn't a pid, a symlink, a file,
/// a lock file that is a FIFO or a folder, and everything when the machine has no id.
#[test]
fn staging_that_cant_be_proved_dead_and_this_machines_is_kept() {
    let dir = Scratch::new("foreign");
    let dead = dead_pid();
    let target = Scratch::new("target");
    make_staging(&target.0);
    let other = dir.0.join(staging_name(".clone-", "0badf00d", dead));
    make_staging(&other);
    make_staging(&dir.0.join(".clone-unowned"));
    make_staging(&dir.0.join(format!(".clone-{HOST}-x{dead}-abc")));
    make_staging(&dir.0.join(format!(".clone-{HOST}-0-abc")));
    make_staging(&dir.0.join(format!(".clone-{HOST}-99999999999-abc")));
    make_staging(&dir.0.join(format!(".clone-{HOST}-{dead}")));
    std::os::unix::fs::symlink(
        &target.0,
        dir.0.join(staging_name(".clone-", HOST, dead_pid())),
    )
    .unwrap();
    touch(&dir.0.join(staging_name(".clone-", HOST, dead_pid())));
    let fifo_stage = dir.0.join(staging_name(".clone-", HOST, dead_pid()));
    make_staging(&fifo_stage);
    let fifo = std::ffi::CString::new(lock_path(&fifo_stage).as_os_str().as_bytes()).unwrap();
    // SAFETY: a valid path; makes a FIFO where the lock file would be.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    let folder_lock = dir
        .0
        .join(staging_name(".clone-", HOST, dead_pid()) + ".lock");
    std::fs::create_dir(&folder_lock).unwrap();

    let started = std::time::Instant::now();
    assert!(stale_staging(&dir.0, b".clone-", HOST).is_empty());
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the FIFO blocked the probe"
    );
    // Swept by nothing without a machine id, however dead.
    let dead_one = dir.0.join(staging_name(".clone-", HOST, dead));
    make_staging(&dead_one);
    assert_eq!(stale_staging(&dir.0, b".clone-", HOST).len(), 1);
    assert!(stale_staging(&dir.0, b".clone-", "").is_empty());
    assert!(target.0.join(".git").exists(), "a symlink was followed");
}

/// Set in the one process [`a_lock_a_child_inherited_keeps_its_staging_after_the_maker_lets_go`]
/// runs its lock in.
const INHERIT_PROBE: &str = "WORKROOM_TEST_STAGING_INHERIT_PROBE";

/// Go's `TestRunClone_GitInheritsTheLock` without git: a lock held by a live process, here a
/// child that inherited it, keeps the staging though the run that made it let go.
///
/// The lock is made in a process of its own, this test binary run for this test alone. A flock
/// belongs to the open file description, and a spawn on any other test's thread copies every
/// descriptor this process has into its child, close-on-exec ones too, until that child execs:
/// one still on its way to exec held the lock after the sleep was gone, so "free once the child
/// is gone" failed in parallel runs and passed alone (measured: 302 in 500 beside a thread
/// forking in a loop, none alone).
#[test]
fn a_lock_a_child_inherited_keeps_its_staging_after_the_maker_lets_go() {
    if std::env::var_os(INHERIT_PROBE).is_some() {
        a_lock_a_child_inherited_in_this_process();
        return;
    }
    // The libtest name from this module's own path, so a move can't leave `--exact` naming a test
    // that no longer exists, which would run nothing and pass.
    let name = format!(
        "{}::a_lock_a_child_inherited_keeps_its_staging_after_the_maker_lets_go",
        module_path!()
            .split_once("::")
            .expect("a crate-qualified path")
            .1
    );
    let output = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args(["--exact", name.as_str(), "--test-threads=1"])
        .env(INHERIT_PROBE, "1")
        .output()
        .expect("run the test in a process of its own");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success() && stdout.contains("test result: ok. 1 passed"),
        "`--exact {name}` on its own: {}\n{stdout}{}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
}

fn a_lock_a_child_inherited_in_this_process() {
    let dir = Scratch::new("inherit");
    let stage = dir.0.join(staging_name(".clone-", HOST, dead_pid()));
    let lock = create_lock(&lock_path(&stage)).unwrap_or_else(|_| panic!("lock"));
    make_staging(&stage);
    let fd = lock.as_raw_fd();
    let mut command = std::process::Command::new("sleep");
    command.arg("30");
    // SAFETY: only fcntl between fork and exec.
    unsafe {
        std::os::unix::process::CommandExt::pre_exec(&mut command, move || {
            libc::fcntl(fd, libc::F_SETFD, 0);
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
    drop(lock);
    let kept = stale_staging(&dir.0, b".clone-", HOST);
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(kept.is_empty(), "swept while a child held the lock");
    let swept = stale_staging(&dir.0, b".clone-", HOST);
    assert_eq!(swept.len(), 1, "free once the child is gone");
}

/// A fresh lock is this run's, locked, and a second take of the same name is refused.
#[test]
fn a_new_lock_is_locked_and_its_name_is_taken() {
    let dir = Scratch::new("create");
    let path = dir.0.join("stage.lock");
    let lock = create_lock(&path).unwrap_or_else(|_| panic!("lock"));
    assert!(matches!(create_lock(&path), Err(LockError::Exists)));
    assert_eq!(probe_lock(&path).1, LockState::Held);
    release_lock(Some(lock), &dir.0.join("stage"));
    assert!(!path.exists(), "the lock file goes with the release");
    assert_eq!(probe_lock(&path).1, LockState::Missing);
}

/// The sweep says what it removes before it removes it, removes a dead clone's folder and lock,
/// and leaves the rest of the folder alone.
#[test]
fn the_sweep_names_and_removes_only_the_dead() {
    let dir = Scratch::new("sweep");
    let dead = dir.0.join(staging_name(".clone-", HOST, dead_pid()));
    make_staging(&dead);
    touch(&lock_path(&dead));
    let live = dir
        .0
        .join(staging_name(".clone-", HOST, std::process::id()));
    make_staging(&live);
    touch(&dir.0.join("README"));
    let signals = crate::script::Signals::watch();
    let mut progress = Vec::new();
    remove_stale(
        &signals,
        &mut progress,
        stale_staging(&dir.0, b".clone-", HOST),
    )
    .unwrap_or_else(|error| panic!("{}", error.message));
    assert_eq!(
        String::from_utf8(progress).unwrap(),
        format!(
            "Removing staging a crashed clone left: {}\n",
            dead.file_name().unwrap().to_string_lossy()
        )
    );
    assert!(!dead.exists() && !lock_path(&dead).exists());
    assert!(live.join(".git").exists() && dir.0.join("README").exists());
}

#[test]
fn staging_in_the_way_names_only_staging_shapes() {
    let dir = Scratch::new("in-the-way");
    make_staging(&dir.0.join(".clone-b"));
    touch(&dir.0.join(".clone-a.lock"));
    touch(&dir.0.join(".DS_Store"));
    assert_eq!(
        staging_in_the_way(&dir.0, &[]),
        [".clone-a.lock", ".clone-b"]
    );
    touch(&dir.0.join(".clone-notes"));
    assert!(staging_in_the_way(&dir.0, &[]).is_empty());
}

#[test]
fn machine_ids_are_read_as_go_reads_them() {
    assert_eq!(
        parse_ioplatform_uuid(
            "+-o J316sAP  <class IOPlatformExpertDevice>\n    \"IOPlatformSerialNumber\" = \"X\"\n    \
             \"IOPlatformUUID\" = \"0A1B-2C3D\"\n"
        ),
        "0A1B-2C3D"
    );
    assert_eq!(parse_ioplatform_uuid("\"IOPlatformUUIDx\" = \"y\"\n"), "");
    assert_eq!(parse_machine_id_file("abc123\n"), "abc123");
    assert_eq!(parse_machine_id_file("uninitialized\n"), "");
    assert_eq!(parse_machine_id_file("  \n"), "");
    // FNV-32a's published vectors.
    assert_eq!(fnv_hex(""), "811c9dc5");
    assert_eq!(fnv_hex("a"), "e40c292c");
    assert_eq!(fnv_hex("foobar"), "bf9cf968");
}

#[test]
fn the_machine_host_is_stable_and_names_this_runs_staging() {
    assert_eq!(machine_host(), machine_host());
    let owner = staging_owner();
    assert!(
        owner.ends_with(&format!("-{}-", std::process::id())),
        "{owner}"
    );
    if let Some(host) = machine_host() {
        assert!(owner.starts_with(host) && host.len() == 8, "{owner}");
    }
}
