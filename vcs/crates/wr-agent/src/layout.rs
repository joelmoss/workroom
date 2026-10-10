//! `Service::Layout`: each remote workroom's pane layout, kept on its host, so any Mac that opens
//! the workroom rebuilds the same tabs and splits (#255; `docs/designs/oq8-cross-machine-reattach.md`).
//!
//! **The agent never parses a layout.** The blob is the app's `TargetSession` JSON, and the app
//! sanitizes it on the way back in, as it does its own `session.json`: anything that can reach this
//! socket can write a layout, so a layout is untrusted input to the app. Here it is bytes.
//!
//! **Revisions, not merges.** Each key has a revision, a counter kept in its file and raised by
//! every accepted write. A `put` names the revision it read; one that names any other is refused
//! with the current one, and the app decides what to do (its whole snapshot wins, D9). The check and
//! the write happen under one lock, so two writers at one revision cannot both win.
//!
//! **On the home disk, beside the screens.** The directory is `layouts` next to `serve --screens`,
//! which a real host already keeps on a disk that outlives a reboot (#232, `boxd.sh`). An agent
//! given no screens directory, the local Mac's included, keeps no layouts and says so: local
//! workrooms keep their layouts in `session.json` for now (premise 8).
//!
//! **Bounded.** A key's file is named by the SHA-256 of the key, so a client-supplied key never
//! names a path. A blob is at most `MAX_BLOB` (the app's own `session.json` cap), and the directory
//! holds at most `MAX_KEYS` layouts: a remote host is one workroom, so one key is the real case and
//! the cap only bounds a misbehaving client. Past either, a `put` is refused, never truncated.
//!
//! Methods, as JSON on the chunked request/reply envelope (`rpc::send`, `rpc::reassemble`):
//!
//! - `capabilities` — this service's version and limits.
//! - `get {key}` — `{revision, blob}`; revision 0 and no blob for a key never written.
//! - `put {key, expected, blob}` — `{revision}`, the new one; or a `stale` error carrying the current.

use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use serde_json::{Value, json};

use crate::protocol::envelope::{Envelope, Service};
use crate::rpc::SharedWriter;

/// The wire version of this service, reported by `capabilities`. Separate from `PROTOCOL_VERSION`,
/// which says whether the service exists at all.
pub const LAYOUT_SERVICE_VERSION: u32 = 1;

/// The largest layout kept: `SessionLimits.maxFileBytes` in the app, the cap on a whole
/// `session.json`, so any layout the app could save fits (D3).
pub const MAX_BLOB: usize = 4 * 1024 * 1024;

/// How many layouts one agent keeps.
pub const MAX_KEYS: usize = 64;

const MAGIC: &[u8; 4] = b"WRLY";
const VERSION: u8 = 1;
/// Magic, version, revision.
const HEADER: usize = 4 + 1 + 8;
const EXTENSION: &str = "layout";

/// What a `put` can fail with, as the app decodes it: externally tagged, a string payload except
/// for `stale`, which carries the revision the writer should have named.
#[derive(Debug, PartialEq, Eq)]
pub enum LayoutError {
    /// The key's revision moved since the writer read it.
    Stale { revision: u64 },
    /// The blob is over `MAX_BLOB`, or a new key would pass `MAX_KEYS`.
    TooLarge(String),
    /// This agent keeps no layouts (no `--screens`), or the request was malformed.
    Unsupported(String),
    /// The disk refused.
    Failed(String),
}

impl LayoutError {
    fn json(&self) -> Value {
        match self {
            Self::Stale { revision } => json!({"stale": {"revision": revision}}),
            Self::TooLarge(why) => json!({"tooLarge": why}),
            Self::Unsupported(why) => json!({"unsupported": why}),
            Self::Failed(why) => json!({"failed": why}),
        }
    }
}

/// The directory of layouts. One per agent.
pub struct Layouts {
    dir: PathBuf,
    /// Held across a `put`'s revision check and its write, so two writers at one revision cannot
    /// both pass the check.
    writing: Mutex<()>,
}

impl Layouts {
    /// Opens `dir`, creating it private to this user.
    pub fn open(dir: &Path) -> io::Result<Layouts> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        Ok(Layouts {
            dir: dir.to_path_buf(),
            writing: Mutex::new(()),
        })
    }

    fn path(&self, key: &str) -> PathBuf {
        let digest = ring::digest::digest(&ring::digest::SHA256, key.as_bytes());
        let name: String = digest
            .as_ref()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        self.dir.join(name).with_extension(EXTENSION)
    }

    /// The key's revision and layout; revision 0 and none for a key never written. A file that is
    /// not a whole layout (a write a crash cut short is never renamed into place, but a disk can
    /// still lose one) reads as never written, so the next `put` at revision 0 replaces it.
    pub fn get(&self, key: &str) -> (u64, Option<Vec<u8>>) {
        read(&self.path(key)).map_or((0, None), |(revision, blob)| (revision, Some(blob)))
    }

    /// Stores `blob` as the key's layout if `expected` is its current revision, and returns the
    /// new one. Temporary file, sync, rename, sync the directory: a reboot or a hand-off mid-write
    /// leaves the previous layout, never a torn one.
    pub fn put(&self, key: &str, expected: u64, blob: &[u8]) -> Result<u64, LayoutError> {
        if blob.len() > MAX_BLOB {
            return Err(LayoutError::TooLarge(format!(
                "a layout of {} bytes is over the {MAX_BLOB}-byte cap",
                blob.len()
            )));
        }
        let _writing = self.writing.lock().unwrap_or_else(|e| e.into_inner());
        let path = self.path(key);
        let (current, _) = self.get(key);
        if current != expected {
            return Err(LayoutError::Stale { revision: current });
        }
        if current == 0 && !path.exists() && self.count() >= MAX_KEYS {
            return Err(LayoutError::TooLarge(format!(
                "this agent already keeps {MAX_KEYS} layouts"
            )));
        }
        let revision = current + 1;
        let failed = |e: io::Error| LayoutError::Failed(e.to_string());
        let temporary = path.with_extension("layout.tmp");
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(failed)?;
        let mut bytes = Vec::with_capacity(HEADER + blob.len());
        bytes.extend_from_slice(MAGIC);
        bytes.push(VERSION);
        bytes.extend_from_slice(&revision.to_be_bytes());
        bytes.extend_from_slice(blob);
        file.write_all(&bytes).map_err(failed)?;
        file.sync_all().map_err(failed)?;
        fs::rename(&temporary, &path).map_err(failed)?;
        File::open(&self.dir)
            .and_then(|dir| dir.sync_all())
            .map_err(failed)?;
        Ok(revision)
    }

    /// How many layouts are kept.
    fn count(&self) -> usize {
        fs::read_dir(&self.dir).map_or(0, |entries| {
            entries
                .filter_map(Result::ok)
                .filter(|entry| entry.path().extension().is_some_and(|e| e == EXTENSION))
                .count()
        })
    }
}

/// A layout file's revision and blob, or none if it is not a whole one. Reads at most one byte
/// past the largest valid file, so a file that is not one costs no more.
fn read(path: &Path) -> Option<(u64, Vec<u8>)> {
    let mut bytes = Vec::new();
    File::open(path)
        .ok()?
        .take((HEADER + MAX_BLOB + 1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() < HEADER || bytes.len() > HEADER + MAX_BLOB || &bytes[..4] != MAGIC {
        return None;
    }
    if bytes[4] != VERSION {
        return None;
    }
    let revision = u64::from_be_bytes(bytes[5..HEADER].try_into().expect("8 bytes"));
    // A revision of 0 is never written; a file claiming it is not one of ours.
    (revision > 0).then(|| (revision, bytes[HEADER..].to_vec()))
}

/// This agent's layouts, when it keeps them: set once, by `serve`, from `--screens`.
static LAYOUTS: OnceLock<Layouts> = OnceLock::new();

/// Keeps `layouts` for the life of this program. A second call is ignored.
pub fn keep(layouts: Layouts) {
    let _ = LAYOUTS.set(layouts);
}

/// Where a host's layouts go: `layouts` beside its screens directory.
pub fn dir_beside(screens: &Path) -> PathBuf {
    screens
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("layouts")
}

pub fn dispatch(
    partial: &mut crate::rpc::PartialRequests,
    envelope: &Envelope,
    writer: &SharedWriter,
) {
    // Stream 0 belongs to the agent, never to a request.
    if envelope.stream == 0 {
        return;
    }
    let send = |value: Value| crate::rpc::send(writer, Service::Layout, envelope.stream, value);
    let bytes = match crate::rpc::reassemble(partial, envelope) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => return,
        Err(error) => {
            send(reply(Err(LayoutError::TooLarge(error.to_string()))));
            return;
        }
    };
    // On its own thread, as a File request is: a put syncs a file and its directory, and the
    // connection's other services must not wait behind that. The permit is held until the reply is
    // written, so a hand-off drains layout writes before it replaces the program.
    let Some(permit) = crate::rpc::Permit::acquire() else {
        send(reply(Err(LayoutError::Failed(
            "too many requests in flight".into(),
        ))));
        return;
    };
    let writer = std::sync::Arc::clone(writer);
    let stream = envelope.stream;
    std::thread::spawn(move || {
        let _permit = permit;
        crate::rpc::send(
            &writer,
            Service::Layout,
            stream,
            reply(handle(LAYOUTS.get(), &bytes)),
        );
    });
}

fn reply(result: Result<Value, LayoutError>) -> Value {
    match result {
        Ok(result) => json!({"version": LAYOUT_SERVICE_VERSION, "result": result}),
        Err(error) => json!({"version": LAYOUT_SERVICE_VERSION, "error": error.json()}),
    }
}

/// One request against `layouts`, separated from the transport so tests drive it directly.
fn handle(layouts: Option<&Layouts>, bytes: &[u8]) -> Result<Value, LayoutError> {
    let unsupported = |why: &str| LayoutError::Unsupported(why.to_string());
    let request: Value =
        serde_json::from_slice(bytes).map_err(|_| unsupported("layout requests are JSON"))?;
    let method = request.get("method").and_then(Value::as_str);
    if method == Some("capabilities") {
        return Ok(json!({
            "version": LAYOUT_SERVICE_VERSION,
            "available": layouts.is_some(),
            "maxBlobBytes": MAX_BLOB,
            "maxKeys": MAX_KEYS,
        }));
    }
    let layouts = layouts.ok_or_else(|| unsupported("this agent keeps no layouts"))?;
    let key = request
        .get("key")
        .and_then(Value::as_str)
        .filter(|key| !key.is_empty())
        .ok_or_else(|| unsupported("a layout request names its key"))?;
    match method {
        Some("get") => {
            let (revision, blob) = layouts.get(key);
            let blob = blob.map(|blob| String::from_utf8_lossy(&blob).into_owned());
            Ok(json!({"revision": revision, "blob": blob}))
        }
        Some("put") => {
            let expected = request
                .get("expected")
                .and_then(Value::as_u64)
                .ok_or_else(|| unsupported("a put names the revision it read"))?;
            let blob = request
                .get("blob")
                .and_then(Value::as_str)
                .ok_or_else(|| unsupported("a put carries its layout as a string"))?;
            let revision = layouts.put(key, expected, blob.as_bytes())?;
            Ok(json!({"revision": revision}))
        }
        _ => Err(unsupported(
            "layout requests are {\"method\": \"capabilities\"|\"get\"|\"put\"}",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wr-layouts-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn request(value: Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    /// A key never written is revision 0 with no layout; a put at 0 makes it 1, a put naming 1
    /// makes it 2, and a get returns the latest.
    #[test]
    fn a_put_at_the_current_revision_is_kept_and_raises_it() {
        let dir = scratch("cas");
        let layouts = Layouts::open(&dir).unwrap();
        assert_eq!(layouts.get("wr-1"), (0, None));
        assert_eq!(layouts.put("wr-1", 0, b"{\"tabs\":[]}"), Ok(1));
        assert_eq!(layouts.put("wr-1", 1, b"{\"tabs\":[1]}"), Ok(2));
        assert_eq!(layouts.get("wr-1"), (2, Some(b"{\"tabs\":[1]}".to_vec())));
        let _ = fs::remove_dir_all(&dir);
    }

    /// A put naming a revision that has moved is refused with the current one, and changes nothing.
    #[test]
    fn a_stale_put_is_refused_with_the_current_revision() {
        let dir = scratch("stale");
        let layouts = Layouts::open(&dir).unwrap();
        layouts.put("wr-1", 0, b"first").unwrap();
        assert_eq!(
            layouts.put("wr-1", 0, b"second"),
            Err(LayoutError::Stale { revision: 1 })
        );
        assert_eq!(layouts.get("wr-1"), (1, Some(b"first".to_vec())));
        let _ = fs::remove_dir_all(&dir);
    }

    /// Two writers at one revision: exactly one wins (R3-5).
    #[test]
    fn two_puts_at_one_revision_have_exactly_one_winner() {
        let dir = scratch("race");
        let layouts = std::sync::Arc::new(Layouts::open(&dir).unwrap());
        const WRITERS: usize = 8;
        for round in 0..20u64 {
            // Released together, so every writer reads the revision before any has renamed.
            let start = std::sync::Arc::new(std::sync::Barrier::new(WRITERS));
            let handles: Vec<_> = (0..WRITERS)
                .map(|n| {
                    let layouts = std::sync::Arc::clone(&layouts);
                    let start = std::sync::Arc::clone(&start);
                    std::thread::spawn(move || {
                        start.wait();
                        layouts.put("wr-1", round, format!("writer {n}").as_bytes())
                    })
                })
                .collect();
            let results: Vec<_> = handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .collect();
            let won = results.iter().filter(|result| result.is_ok()).count();
            let stale = results
                .iter()
                .filter(|result| matches!(result, Err(LayoutError::Stale { .. })))
                .count();
            // Every loser is told it was stale, never a disk error from a shared temporary file.
            assert_eq!((won, stale), (1, WRITERS - 1), "round {round}: {results:?}");
        }
        let _ = fs::remove_dir_all(&dir);
    }

    /// A file cut short, or not a layout at all, reads as never written rather than as garbage, and
    /// the next put at revision 0 replaces it (R3-5).
    #[test]
    fn a_truncated_layout_reads_as_never_written() {
        let dir = scratch("torn");
        let layouts = Layouts::open(&dir).unwrap();
        layouts.put("wr-1", 0, b"whole layout").unwrap();
        let path = layouts.path("wr-1");
        let bytes = fs::read(&path).unwrap();
        fs::write(&path, &bytes[..HEADER - 1]).unwrap();
        assert_eq!(layouts.get("wr-1"), (0, None));
        fs::write(&path, b"not a layout at all").unwrap();
        assert_eq!(layouts.get("wr-1"), (0, None));
        assert_eq!(layouts.put("wr-1", 0, b"again"), Ok(1));
        let _ = fs::remove_dir_all(&dir);
    }

    /// The key names no path: its file is the SHA-256 of the key, whatever the key holds.
    #[test]
    fn a_key_is_hashed_into_its_file_name() {
        let dir = scratch("names");
        let layouts = Layouts::open(&dir).unwrap();
        layouts.put("../../etc/passwd", 0, b"x").unwrap();
        let names: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names.len(), 1);
        assert_eq!(names[0].len(), 64 + 1 + EXTENSION.len());
        assert!(names[0].chars().take(64).all(|c| c.is_ascii_hexdigit()));
        let _ = fs::remove_dir_all(&dir);
    }

    /// A blob over the cap, and a new key past the key cap, are refused rather than truncated or
    /// evicted; an existing key can still be written at the key cap.
    #[test]
    fn the_blob_and_key_caps_refuse() {
        let dir = scratch("caps");
        let layouts = Layouts::open(&dir).unwrap();
        assert!(matches!(
            layouts.put("big", 0, &vec![b'x'; MAX_BLOB + 1]),
            Err(LayoutError::TooLarge(_))
        ));
        assert_eq!(layouts.put("big", 0, &vec![b'x'; MAX_BLOB]), Ok(1));
        for n in 1..MAX_KEYS {
            layouts.put(&format!("k{n}"), 0, b"x").unwrap();
        }
        assert!(matches!(
            layouts.put("one-too-many", 0, b"x"),
            Err(LayoutError::TooLarge(_))
        ));
        assert_eq!(layouts.put("k1", 1, b"y"), Ok(2));
        let _ = fs::remove_dir_all(&dir);
    }

    /// The wire: capabilities, get, put and a stale put, as the app sees them.
    #[test]
    fn requests_and_replies() {
        let dir = scratch("wire");
        let layouts = Layouts::open(&dir).unwrap();
        let caps = handle(Some(&layouts), &request(json!({"method": "capabilities"}))).unwrap();
        assert_eq!(caps["available"], true);
        assert_eq!(caps["maxBlobBytes"], MAX_BLOB);
        assert_eq!(
            handle(
                Some(&layouts),
                &request(json!({"method": "get", "key": "wr"}))
            )
            .unwrap(),
            json!({"revision": 0, "blob": null})
        );
        assert_eq!(
            handle(
                Some(&layouts),
                &request(
                    json!({"method": "put", "key": "wr", "expected": 0, "blob": "{\"tabs\":[]}"})
                )
            )
            .unwrap(),
            json!({"revision": 1})
        );
        assert_eq!(
            handle(
                Some(&layouts),
                &request(json!({"method": "get", "key": "wr"}))
            )
            .unwrap(),
            json!({"revision": 1, "blob": "{\"tabs\":[]}"})
        );
        assert_eq!(
            reply(handle(
                Some(&layouts),
                &request(json!({"method": "put", "key": "wr", "expected": 0, "blob": "x"}))
            )),
            json!({"version": 1, "error": {"stale": {"revision": 1}}})
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// An agent with no screens directory keeps no layouts: capabilities says so, and get and put
    /// are refused as unsupported, which the app treats as an agent without the service.
    #[test]
    fn an_agent_without_a_layouts_directory_says_so() {
        let caps = handle(None, &request(json!({"method": "capabilities"}))).unwrap();
        assert_eq!(caps["available"], false);
        assert!(matches!(
            handle(None, &request(json!({"method": "get", "key": "wr"}))),
            Err(LayoutError::Unsupported(_))
        ));
    }

    /// Anything can reach the socket, so a malformed request is refused as unsupported, and none
    /// of them writes a layout.
    #[test]
    fn malformed_requests_are_refused_and_write_nothing() {
        let dir = scratch("malformed");
        let layouts = Layouts::open(&dir).unwrap();
        for bad in [
            json!({"method": "get"}),
            json!({"method": "get", "key": ""}),
            json!({"method": "put", "key": "k", "blob": "x"}),
            json!({"method": "put", "key": "k", "expected": 0, "blob": 5}),
            json!({"method": "nope", "key": "k"}),
        ] {
            assert!(
                matches!(
                    handle(Some(&layouts), &request(bad.clone())),
                    Err(LayoutError::Unsupported(_))
                ),
                "{bad}"
            );
        }
        assert!(matches!(
            handle(Some(&layouts), b"not json"),
            Err(LayoutError::Unsupported(_))
        ));
        assert_eq!(layouts.get("k"), (0, None));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn layouts_sit_beside_the_screens() {
        assert_eq!(
            dir_beside(Path::new("/home/workroom/.local/state/workroom/screens")),
            PathBuf::from("/home/workroom/.local/state/workroom/layouts")
        );
    }
}
