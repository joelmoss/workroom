//! Test helpers for running a file the test itself just wrote.
//!
//! Linux refuses to exec a file some process still has open for writing (`ETXTBSY`, "Text file
//! busy"). A test that writes an executable and runs it races every other test thread that forks
//! in between: the child inherits the write descriptor until it execs, and the exec of ours fails
//! for that window. [`write_executable`] closes its own handle first, and [`spawn`] retries the exec while it is busy, so a test never sees the other thread's fork.

use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

/// How long a busy executable is retried before the error is returned.
const BUSY_FOR: Duration = Duration::from_secs(10);

/// `bytes` at `path`, executable: synced and closed before the mode is set, so this thread holds
/// no write descriptor to it by the time it is run.
pub(crate) fn write_executable(path: &Path, bytes: impl AsRef<[u8]>) {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o755)
        .open(path)
        .expect("create the executable");
    file.write_all(bytes.as_ref())
        .expect("write the executable");
    file.sync_all().expect("sync the executable");
    drop(file);
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
}

/// `attempt` until it is no longer refused as a busy executable, for up to [`BUSY_FOR`].
fn retrying_busy<T>(mut attempt: impl FnMut() -> io::Result<T>) -> io::Result<T> {
    let deadline = Instant::now() + BUSY_FOR;
    let mut wait = Duration::from_millis(2);
    loop {
        match attempt() {
            Err(e)
                if e.kind() == io::ErrorKind::ExecutableFileBusy && Instant::now() < deadline =>
            {
                std::thread::sleep(wait);
                wait = (wait * 2).min(Duration::from_millis(50));
            }
            other => return other,
        }
    }
}

/// `command` started, tried again while its executable is busy.
pub(crate) fn spawn(command: &mut Command) -> io::Result<Child> {
    retrying_busy(|| command.spawn())
}
