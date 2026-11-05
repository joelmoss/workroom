//! Ids a client asked to kill, refused a new session for a while, and their file.

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use super::{SessionId, SessionStore};
use crate::util::lock_or_recover;

/// How long an id a client asked to kill is refused a new session (`SessionStore::refuse`): long
/// enough for an attach that set out before the kill to arrive behind it. Over ssh that is a
/// connect bounded at 10s (`ContainerHostDriver`'s `ConnectTimeout`), authentication and the
/// daemon's start, so a minute has room to spare. The refusals outlive this program in a file beside
/// its socket (`SessionStore::keep_refusals`), so a hand-off, an idle exit or a crash does not let
/// the next one create a session killed just before it (#310).
pub const REFUSED_ID_WINDOW: Duration = Duration::from_secs(60);

/// Where a socket's refusals are kept, beside it in the daemon's own directory.
pub fn refusals_path(socket: &Path) -> PathBuf {
    socket.with_extension("refused")
}

pub(super) const REFUSALS_MAGIC: [u8; 4] = *b"WRRF";

/// One refusal in the file: the session's 16-byte id, then when it ends.
const REFUSAL_LEN: usize = 16 + 8;

/// The time since the epoch, for a refusal's end as another process reads it. Zero on a clock
/// before the epoch, which can only lengthen a refusal, never shorten one.
pub(super) fn wall_now() -> Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
}

/// Magic, then per refusal its id and when it ends, as milliseconds since the epoch: an `Instant`
/// means nothing to another process. Through a temporary file and a rename, so a program that
/// dies mid-write leaves the previous file whole rather than one that loses every refusal.
pub(super) fn write_refusals(
    path: &Path,
    refused: &HashMap<SessionId, Instant>,
    now: Instant,
) -> std::io::Result<()> {
    let wall = wall_now();
    let mut out = REFUSALS_MAGIC.to_vec();
    for (id, until) in refused {
        let ends = wall + until.saturating_duration_since(now);
        out.extend_from_slice(&id.0);
        out.extend_from_slice(&(ends.as_millis() as u64).to_be_bytes());
    }
    // Created afresh, as the hand-off table is: an existing file or link at this path is never
    // written through.
    let temporary = path.with_extension("refused-new");
    let _ = std::fs::remove_file(&temporary);
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .and_then(|mut file| file.write_all(&out))?;
    std::fs::rename(&temporary, path)
}

/// The refusals in `path` that have not ended, each ending no later than a window from now: a
/// clock set back must not stretch one.
fn read_refusals(path: &Path) -> std::io::Result<Vec<(SessionId, Instant)>> {
    let bytes = std::fs::read(path)?;
    let invalid = || std::io::Error::new(std::io::ErrorKind::InvalidData, "not a refusals file");
    let (entries, rest) = bytes
        .strip_prefix(&REFUSALS_MAGIC)
        .ok_or_else(invalid)?
        .as_chunks::<REFUSAL_LEN>();
    if !rest.is_empty() {
        return Err(invalid());
    }
    let wall = wall_now();
    let now = Instant::now();
    Ok(entries
        .iter()
        .filter_map(|entry| {
            let id = SessionId(entry[..16].try_into().expect("16 bytes"));
            let ends =
                Duration::from_millis(u64::from_be_bytes(entry[16..].try_into().expect("8 bytes")));
            let left = ends.checked_sub(wall).filter(|left| !left.is_zero())?;
            Some((id, now + left.min(REFUSED_ID_WINDOW)))
        })
        .collect())
}

impl SessionStore {
    /// Refuses `id` a new session for `REFUSED_ID_WINDOW`. A closed pane's attach can still be on
    /// its way when its kill arrives, and created after it the shell would run on with no pane.
    ///
    /// Called before the kill looks for the session, and `create_then` checks under the map's
    /// lock, so either a create sees the refusal or the kill sees the session it created.
    ///
    /// Written to the refusals file under the refusals' own lock, so two kills cannot write their copies
    /// out of order and lose one; a file this small costs a kill nothing it would notice.
    pub fn refuse(&self, id: SessionId) {
        let now = Instant::now();
        let mut refused = lock_or_recover(&self.refused);
        // ponytail: a scan per kill, which kills at the rate panes close never notice; a flood of
        // kills would want pruning on a timer or past a size.
        refused.retain(|_, until| *until > now);
        refused.insert(id, now + REFUSED_ID_WINDOW);
        if let Some(path) = self.refusals.get()
            && let Err(e) = write_refusals(path, &refused, now)
        {
            crate::note!("could not keep refusals in {}: {e}", path.display());
        }
    }

    pub(super) fn is_refused(&self, id: SessionId) -> bool {
        lock_or_recover(&self.refused)
            .get(&id)
            .is_some_and(|until| *until > Instant::now())
    }

    /// Keeps refusals in `path` from now on, starting from the ones it already holds: those of the
    /// program that served this socket before, whether it handed off, idled out or crashed. Once
    /// per store. A file that cannot be read costs its refusals, never the daemon.
    pub fn keep_refusals(&self, path: PathBuf) {
        match read_refusals(&path) {
            Ok(kept) => {
                lock_or_recover(&self.refused).extend(kept);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => crate::note!("not taking refusals from {}: {e}", path.display()),
        }
        let _ = self.refusals.set(path);
    }
}
