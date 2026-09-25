//! Each session's screen, kept on disk, so a pane that reattaches after its host stopped and
//! rebooted is shown what was on it (#232).
//!
//! **VT bytes, not a snapshot.** The snapshot format carries no compatibility guarantee between
//! agent revisions, and a reboot is exactly when a newer agent may be the one reading (design doc,
//! Distribution Plan: "The snapshot format is not a wire contract"). VT does not change between
//! revisions, so a record is `replay()`'s output behind a small versioned header, and the hand-off
//! already carries screens the same way (`FrozenSession::screen`).
//!
//! **A record is not a session.** After a reboot the shell is gone and only the screen is left. An
//! attach that asks only for what exists (`CREATE=0`, a restored pane) and names an id the agent
//! does not hold is shown that screen, with a notice on its bottom row, and nothing else happens on
//! that connection: there is no pty, so input and resizes go nowhere. The pane stays that way until
//! its user closes it. An attach that may create gets a new session, as it always has.
//!
//! **Write policy.** One thread, every `INTERVAL`, writes the record of each session whose screen
//! changed since its last one. A write goes to a temporary file, is synced, and is renamed into
//! place, so a reboot mid-write leaves the previous record or none, never a torn one. A record has
//! the shadow's scrollback, which libghostty bounds (10 KB by default), and one larger than
//! `MAX_RECORD` is not kept at all. A record goes when its session ends while the agent runs, and
//! when a client kills it (`SessionStore::kill`).
//!
//! **Opt-in, and never beside the socket.** `serve --screens <dir>` turns this on. The directory
//! must survive a reboot, and a real host's socket directory is on tmpfs. The local Mac does not
//! pass it: restoring local screens after a Mac restart is a separate decision.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::session::{SessionId, SessionStore};
use crate::shadow::Shadow;

const MAGIC: &[u8; 8] = b"WRSCREEN";
const VERSION: u8 = 1;
/// Magic, version, columns, rows, length.
const HEADER: usize = 8 + 1 + 2 + 2 + 4;

/// How often changed screens are written. A stop that kills the agent outright loses at most this
/// much of the screen, and a busy session is rewritten this often.
// ponytail: a fixed tick; flush on SIGTERM too if providers turn out to stop boxes gracefully.
const INTERVAL: Duration = Duration::from_secs(2);

/// The largest record kept. One over it is removed rather than left stale.
const MAX_RECORD: usize = 4 << 20;

/// How many records `open` keeps, newest first. A pane closed while its host was down cannot kill
/// its record: the app has no way to end a remote session yet (Phase 4).
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
        if fs::remove_file(self.path(id)).is_ok() {
            let _ = self.sync();
        }
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
            shadow.resize(columns, rows);
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

/// Keeps every session's record current for the life of the agent. Does nothing unless the store
/// has records (`SessionStore::keep_screens`).
///
/// Writes at once, then every `INTERVAL`: the sessions a hand-off carried in get their records
/// straight away, not a tick after `open` may have pruned them.
pub fn spawn(sessions: SessionStore) {
    let spawned = std::thread::Builder::new()
        .name("screens".into())
        .spawn(move || {
            // The sessions a hand-off carried in, whose records the program before wrote: one
            // that ends before this program's first write for it still loses its record.
            let mut written: HashSet<SessionId> = sessions.ids().into_iter().collect();
            let mut failing = HashSet::new();
            loop {
                flush(&sessions, &mut written, &mut failing);
                std::thread::sleep(INTERVAL);
            }
        });
    if let Err(e) = spawned {
        eprintln!("wr-agent: not keeping screens: no thread to write them: {e}");
    }
}

/// One tick: writes the screens that changed, and removes the records of sessions that ended.
///
/// `written` is every session this agent wrote a record for. A record it did not write belongs to
/// a session that ended with the host, and stays until a client kills it.
fn flush(
    sessions: &SessionStore,
    written: &mut HashSet<SessionId>,
    failing: &mut HashSet<SessionId>,
) {
    let Some(screens) = sessions.screens() else {
        return;
    };
    let mut saved = Vec::new();
    for (id, columns, rows, screen) in sessions.changed_screens() {
        if screen.is_empty() {
            continue;
        }
        match screens.save(id, columns, rows, &screen) {
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
                        "wr-agent: could not keep the screen of {}: {e}",
                        id.to_hyphenated()
                    );
                }
            }
        }
    }
    if !saved.is_empty() {
        if let Err(e) = screens.sync() {
            // Their renames are not durable yet, and taking their screens cleared their changed
            // flags: an idle session would never be written, or synced, again.
            for id in saved {
                sessions.mark_changed(id);
            }
            eprintln!("wr-agent: could not sync the screens directory: {e}");
        }
    }
    // After the writes, so a session killed while its screen was being written loses the record
    // that write put back. A session that ends while the agent runs leaves nothing to restore.
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
mod tests {
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

    /// A newer agent reads what an older one wrote without running it. Version 1, written out by
    /// hand, must keep decoding for as long as version 1 is the format.
    #[test]
    fn a_version_one_record_still_reads() {
        let written_by_an_older_agent = b"WRSCREEN\x01\x00\x50\x00\x18\x00\x00\x00\x02hi";
        assert_eq!(
            decode(written_by_an_older_agent),
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
        sessions.keep_screens(Screens::open(&dir).expect("open"));
        let screens = sessions.screens().expect("screens");
        screens
            .save(ID, 80, 24, b"an earlier session")
            .expect("save");

        let args = [
            std::ffi::OsString::from("-c"),
            std::ffi::OsString::from("sleep 5"),
        ];
        let spec = || crate::session::SessionSpec {
            id: ID,
            program: std::ffi::OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &[],
            cwd: None,
            columns: 80,
            rows: 24,
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
        sessions.keep_screens(Screens::open(&dir).expect("open"));
        let screens = sessions.screens().expect("screens");
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

    /// The module doc: "A record goes when its session ends while the agent runs." That is
    /// `flush`'s cleanup half, not `SessionStore::kill` — the shell exits on its own, nobody closes
    /// the pane, and the NEXT tick is what notices the id is no longer live and drops its record.
    #[test]
    fn a_session_that_ends_while_the_agent_runs_loses_its_record_on_the_next_tick() {
        let dir = scratch("endedwhilerunning");
        let screens = Screens::open(&dir).expect("open");
        let sessions = SessionStore::new();
        sessions.keep_screens(screens);
        let live = sessions.screens().expect("screens");
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

    /// `flush`'s error arm: a write that fails is retried on the very next tick (via
    /// `sessions.mark_changed`) rather than only after more output, and the session leaves
    /// `failing` once a write finally lands.
    #[cfg(feature = "terminal-state")]
    #[test]
    fn a_failing_write_is_retried_and_clears_once_it_succeeds() {
        // Root writes through a read-only directory, so there is no failure to retry.
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipping: running as root");
            return;
        }
        let dir = scratch("writefails");
        let screens = Screens::open(&dir).expect("open");
        // No write permission left on the directory, so `save`'s temporary file cannot be created.
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).expect("chmod");
        let sessions = SessionStore::new();
        sessions.keep_screens(screens);

        let args = vec![
            OsString::from("-c"),
            OsString::from("echo screen-content; sleep 5"),
        ];
        sessions
            .create(crate::session::SessionSpec {
                id: ID,
                program: OsStr::new("/bin/sh"),
                argv0: None,
                args: &args,
                env: &[],
                cwd: None,
                columns: 80,
                rows: 24,
            })
            .expect("create");
        std::thread::sleep(Duration::from_millis(400));

        let mut written = HashSet::new();
        let mut failing = HashSet::new();
        flush(&sessions, &mut written, &mut failing);
        assert!(failing.contains(&ID), "a failed write was not tracked");
        assert!(!written.contains(&ID));
        assert!(
            sessions.screens().expect("screens").load(ID).is_none(),
            "a failed write still left a record"
        );

        // Fixed now: `mark_changed` in the error arm means the next tick tries again with no new
        // output needed.
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).expect("chmod back");
        flush(&sessions, &mut written, &mut failing);
        assert!(written.contains(&ID), "the recovered write was not retried");
        assert!(!failing.contains(&ID), "failing was not cleared on success");

        sessions.kill_all();
        let _ = fs::remove_dir_all(&dir);
    }
}
