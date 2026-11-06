//! Each session's screen, kept on disk, so a pane that reattaches after its host stopped and
//! rebooted is shown what was on it (#232).
//!
//! **VT bytes, not a snapshot.** The snapshot format carries no compatibility guarantee between
//! daemon revisions, and a reboot is exactly when a newer daemon may be the one reading (design doc,
//! Distribution Plan: "The snapshot format is not a wire contract"). VT does not change between
//! revisions, so a record is `record()`'s output (`replay()` without the progress report and the
//! parser continuation) behind a small versioned header, and the hand-off already carries screens
//! the same way (`FrozenSession::screen`). A restored repaint says idle (OSC 9;4 REMOVE), never
//! busy: the program that was busy is gone (#359).
//!
//! **A record is not a session.** After a reboot the shell is gone and only the screen is left. An
//! attach that asks only for what exists (`CREATE=0`, a restored pane) and names an id the daemon
//! does not hold is shown that screen, with a notice on its bottom row, and nothing else happens on
//! that connection: there is no pty, so input and resizes go nowhere. The pane stays that way until
//! its user closes it. An attach that may create gets a new session, as it always has.
//!
//! **Write policy.** One thread, every `INTERVAL`, writes the record of each session whose screen
//! changed since its last one. A write goes to a temporary file, is synced, and is renamed into
//! place, so a reboot mid-write leaves the previous record or none, never a torn one. A record has
//! the newest scrollback that fits `vt::RECORD_MAX_BYTES`, so only a screen larger than
//! `MAX_RECORD` on its own is not kept at all. A record goes when its session ends while the daemon
//! runs, and when a client kills it (`SessionStore::kill`).
//!
//! **The same thread compresses every shadow (#463)**, on every daemon, with records or without:
//! each shadow straight after its record is taken (`SessionStore::changed_screens`), then every
//! shadow after the writes, for what output and attaches inflated since the last tick.
//!
//! **Opt-in, and never beside the socket.** `serve --screens <dir>` turns this on. The directory
//! must survive a reboot, and a real host's socket directory is on tmpfs. The local Mac does not
//! pass it: restoring local screens after a Mac restart is a separate decision.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use crate::terminal::session::{SessionId, SessionStore};
use crate::terminal::shadow::Shadow;
use crate::util::Wake;

/// The screens thread's side of a session store, which the store reaches through its hooks
/// (`session::Hooks`): where each session's screen is kept for after a reboot, when the daemon
/// was asked to keep them (`serve --screens`), and what the thread sleeps on.
#[derive(Default)]
pub struct KeptScreens {
    screens: OnceLock<Screens>,
    /// Raised when a screen may have changed or a session has gone (output, a resize,
    /// `mark_changed`, the reader's end): what the screens thread sleeps on instead of ticking
    /// every two seconds of an idle daemon.
    work: Wake,
}

impl KeptScreens {
    /// Keeps each session's screen in `screens` from now on (`spawn` does the writing). Once per
    /// store.
    pub fn keep(&self, screens: Screens) {
        let _ = self.screens.set(screens);
    }

    pub fn get(&self) -> Option<&Screens> {
        self.screens.get()
    }

    /// How often a screen may have changed or a session gone so far. Read before a pass over the
    /// sessions, so `wait_for_work` cannot miss a change made during it.
    pub(crate) fn work(&self) -> u64 {
        self.work.seen()
    }

    /// Blocks until a screen may have changed or a session has gone after `work` returned `seen`.
    pub(crate) fn wait_for_work(&self, seen: u64) {
        self.work.wait_past(seen);
    }

    pub(crate) fn raise(&self) {
        self.work.raise();
    }
}

const MAGIC: &[u8; 8] = b"WRSCREEN";
const VERSION: u8 = 1;
/// Magic, version, columns, rows, length.
const HEADER: usize = 8 + 1 + 2 + 2 + 4;

/// How often changed screens are written. A stop that kills the daemon outright loses at most this
/// much of the screen, and a busy session is rewritten this often.
// ponytail: a fixed tick; flush on SIGTERM too if providers turn out to stop boxes gracefully.
const INTERVAL: Duration = Duration::from_secs(2);

/// The largest record kept, and read. One over it is removed rather than left stale.
pub(crate) const MAX_RECORD: usize = 4 << 20;

/// How many records `open` keeps, newest first. A pane closed while its host was down cannot end
/// its record: the kill that would have removed it never reached the host (#283).
const MAX_RECORDS: usize = 64;

const NOTICE: &str = "This terminal ended when its host restarted. Close it to start again.";

/// The directory of records.
pub struct Screens {
    dir: PathBuf,
}

impl Screens {
    /// Opens `dir`, creating it private to this user, and drops what a reboot left half-written
    /// and records beyond `MAX_RECORDS`.
    pub fn open(dir: &Path) -> io::Result<Screens> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        // A record is whatever was on the user's screen, so the directory is theirs alone even if
        // something else created it first.
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        let screens = Screens {
            dir: dir.to_path_buf(),
        };
        screens.prune();
        Ok(screens)
    }

    fn path(&self, id: SessionId) -> PathBuf {
        self.dir.join(format!("{}.vt", id.to_hyphenated()))
    }

    /// Replaces a session's record: temporary file, sync, rename. The rename survives a reboot
    /// only once the directory is synced too, which `sync` does once for a tick's writes.
    pub fn save(&self, id: SessionId, columns: u16, rows: u16, screen: &[u8]) -> io::Result<()> {
        let path = self.path(id);
        if screen.len() > MAX_RECORD {
            // The previous record would be shown as this session's last screen, and it is not.
            return match fs::remove_file(&path) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
        }
        let temporary = path.with_extension("vt.tmp");
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&encode(columns, rows, screen))?;
        file.sync_all()?;
        fs::rename(&temporary, &path)
    }

    /// Makes the renames of earlier `save`s, and removals, durable.
    pub fn sync(&self) -> io::Result<()> {
        File::open(&self.dir)?.sync_all()
    }

    /// A session's record as `(columns, rows, screen)`, or none if there is no valid one. Reads at
    /// most one byte past the largest valid record, so a file that is not one costs no more.
    pub fn load(&self, id: SessionId) -> Option<(u16, u16, Vec<u8>)> {
        let mut bytes = Vec::new();
        File::open(self.path(id))
            .ok()?
            .take((HEADER + MAX_RECORD + 1) as u64)
            .read_to_end(&mut bytes)
            .ok()?;
        let (columns, rows, screen) = decode(&bytes)?;
        Some((columns, rows, screen.to_vec()))
    }

    /// Removes a session's record, durably: a record that came back after a power cut would show
    /// a pane its user closed as one that ended with its host.
    pub fn remove(&self, id: SessionId) {
        if self.remove_unsynced(id) {
            let _ = self.sync();
        }
    }

    /// Removes a session's record without syncing the directory, for a caller holding a lock
    /// other work waits on, which then `sync`s after releasing it. True if there was one.
    pub fn remove_unsynced(&self, id: SessionId) -> bool {
        fs::remove_file(self.path(id)).is_ok()
    }

    pub fn remove_all(&self) {
        for (_, path) in self.records() {
            let _ = fs::remove_file(path);
        }
        let _ = self.sync();
    }

    /// What a restored pane is shown for a session that ended with its host: the record, repainted
    /// at the client's size, then the notice. None when there is no record, or this build has no
    /// terminal state to repaint it with.
    pub fn render(&self, id: SessionId, columns: u16, rows: u16) -> Option<Vec<u8>> {
        let (record_columns, record_rows, screen) = self.load(id)?;
        // Through a shadow, as a hand-off adopts a screen (`SessionStore::adopt`), so a pane of a
        // different size gets the record reflowed rather than wrapped at the old width.
        let mut shadow = Shadow::new(record_columns, record_rows);
        shadow.write(&screen);
        let (columns, rows) = if columns > 0 && rows > 0 {
            shadow.resize(crate::terminal::pty::Size::cells(columns, rows));
            (columns, rows)
        } else {
            (record_columns, record_rows)
        };
        let mut out = shadow.replay();
        if out.is_empty() {
            return None;
        }
        out.extend_from_slice(&notice(columns, rows));
        Some(out)
    }

    /// Every record in the directory, with its modification time.
    fn records(&self) -> Vec<(Option<std::time::SystemTime>, PathBuf)> {
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|e| e == "vt"))
            .map(|path| (fs::metadata(&path).and_then(|m| m.modified()).ok(), path))
            .collect()
    }

    fn prune(&self) {
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for path in entries.flatten().map(|entry| entry.path()) {
                // A write a reboot interrupted. It was never renamed into place, so it was never a
                // record.
                if path.extension().is_some_and(|e| e == "tmp") {
                    let _ = fs::remove_file(path);
                }
            }
        }
        // A record whose time cannot be read counts as oldest, so it goes first.
        let mut records = self.records();
        records.sort_by_key(|record| {
            std::cmp::Reverse(record.0.unwrap_or(std::time::SystemTime::UNIX_EPOCH))
        });
        for (_, path) in records.into_iter().skip(MAX_RECORDS) {
            let _ = fs::remove_file(path);
        }
    }
}

/// Moves the frozen screen's cursor out of the way and says what the pane is.
///
/// Mouse reporting goes off so the screen can be selected and copied, and origin mode off so the
/// notice lands on the pane's bottom row whatever scrolling region the program left. The notice
/// goes over that row rather than after the cursor: a newline at the bottom would scroll a
/// full-screen program's screen.
fn notice(columns: u16, rows: u16) -> Vec<u8> {
    let text: String = NOTICE.chars().take(columns as usize).collect();
    format!("\x1b[?1000;1002;1003;1006;6l\x1b[?25l\x1b[m\x1b[{rows};1H\x1b[2K\x1b[7m{text}\x1b[m")
        .into_bytes()
}

fn encode(columns: u16, rows: u16, screen: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER + screen.len());
    out.extend_from_slice(MAGIC);
    out.push(VERSION);
    out.extend_from_slice(&columns.to_be_bytes());
    out.extend_from_slice(&rows.to_be_bytes());
    out.extend_from_slice(&(screen.len() as u32).to_be_bytes());
    out.extend_from_slice(screen);
    out
}

/// A record's parts, or none for anything else: another format, another version, or a file whose
/// length disagrees with its header.
fn decode(bytes: &[u8]) -> Option<(u16, u16, &[u8])> {
    let (header, screen) = bytes.split_at_checked(HEADER)?;
    if &header[..8] != MAGIC || header[8] != VERSION {
        return None;
    }
    let columns = u16::from_be_bytes([header[9], header[10]]);
    let rows = u16::from_be_bytes([header[11], header[12]]);
    let length = u32::from_be_bytes([header[13], header[14], header[15], header[16]]) as usize;
    (length == screen.len() && length <= MAX_RECORD && columns > 0 && rows > 0)
        .then_some((columns, rows, screen))
}

/// Keeps every session's record current, when the store has records (`KeptScreens::keep`), and
/// every shadow's history compressed, for the life of the daemon. Called once by every daemon,
/// after `keep` if it keeps any.
///
/// Writes at once, then every `INTERVAL`: the sessions a hand-off carried in get their records
/// straight away, not a tick after `open` may have pruned them.
pub fn spawn(sessions: SessionStore) {
    if !Shadow::new(1, 1).compression_supported() {
        eprintln!(
            "workroomd: history compression is not supported on this target; each session's \
             history stays uncompressed, up to 50 MB"
        );
    }
    let spawned = std::thread::Builder::new()
        .name("screens".into())
        .spawn(move || {
            // The sessions a hand-off carried in, whose records the program before wrote: one
            // that ends before this program's first write for it still loses its record. Read
            // only when there are records.
            let mut written: HashSet<SessionId> = sessions.ids().into_iter().collect();
            let mut failing = HashSet::new();
            loop {
                // Read before the pass looks, so a change made during it still wakes the thread.
                let seen = sessions.hooks().screens.work();
                let pending = tick(&sessions, &mut written, &mut failing);
                // With nothing to come back for, sleep until a screen may have changed or a
                // session has gone, rather than tick every INTERVAL of an idle daemon (half of
                // its remaining wakeups, 2026-10-23). The INTERVAL after the wake batches a busy
                // session's output as the fixed tick did.
                if !pending {
                    sessions.hooks().screens.wait_for_work(seen);
                }
                std::thread::sleep(INTERVAL);
            }
        });
    if let Err(e) = spawned {
        eprintln!(
            "workroomd: neither keeping screens nor compressing history: no thread for them: {e}"
        );
    }
}

/// One tick: the records, then the compression, which then also undoes what the records' reads
/// re-inflated, then the unprobed requests whose grace has passed (#481). Whether another tick
/// is owed without new output: a record to retry, or a request still waiting out its grace.
fn tick(
    sessions: &SessionStore,
    written: &mut HashSet<SessionId>,
    failing: &mut HashSet<SessionId>,
) -> bool {
    flush(sessions, written, failing);
    sessions.compress_shadows();
    let unprobed = sessions.promote_unprobed(std::time::Instant::now());
    unprobed || !failing.is_empty()
}

/// One tick: writes the screens that changed, and removes the records of sessions that ended.
///
/// `written` is every session this daemon wrote a record for. A record it did not write belongs to
/// a session that ended with the host, and stays until a client kills it.
fn flush(
    sessions: &SessionStore,
    written: &mut HashSet<SessionId>,
    failing: &mut HashSet<SessionId>,
) {
    let Some(screens) = sessions.hooks().screens.get() else {
        return;
    };
    let mut saved = Vec::new();
    for taken in sessions.changed_screens() {
        let id = taken.id;
        if taken.record.is_empty() {
            continue;
        }
        match screens.save(id, taken.columns, taken.rows, &taken.record) {
            // The id was reused, or its session ended, after its screen was taken: the record just
            // written is of a session that no longer holds it. This thread is the only writer, so
            // checking after the write is enough.
            Ok(()) if !sessions.still_holds(id, taken.session) => {
                screens.remove(id);
                failing.remove(&id);
            }
            Ok(()) => {
                written.insert(id);
                failing.remove(&id);
                saved.push(id);
            }
            Err(e) => {
                // Tried again next tick, not only after more output: a program waiting for input
                // may never write another byte.
                sessions.mark_changed(id);
                if failing.insert(id) {
                    eprintln!(
                        "workroomd: could not keep the screen of {}: {e}",
                        id.to_hyphenated()
                    );
                }
            }
        }
    }
    if !saved.is_empty()
        && let Err(e) = screens.sync()
    {
        // Their renames are not durable yet, and taking their screens cleared their changed
        // flags: an idle session would never be written, or synced, again.
        for id in saved {
            sessions.mark_changed(id);
        }
        eprintln!("workroomd: could not sync the screens directory: {e}");
    }
    // After the writes, so a session killed while its screen was being written loses the record
    // that write put back. A session that ends while the daemon runs leaves nothing to restore.
    let live: HashSet<SessionId> = sessions.ids().into_iter().collect();
    written.retain(|id| {
        let keep = live.contains(id);
        if !keep {
            screens.remove(*id);
        }
        keep
    });
    failing.retain(|id| live.contains(id));
}

#[cfg(test)]
mod tests;
