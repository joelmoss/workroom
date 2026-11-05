//! `Service::Layout`: each remote workroom's pane layout, kept on its host, so any Mac that opens
//! the workroom rebuilds the same tabs and splits (#255; `docs/designs/oq8-cross-machine-reattach.md`).
//!
//! **The daemon never parses a layout.** The blob is the app's `TargetSession` JSON, and the app
//! sanitizes it on the way back in, as it does its own `session.json`: anything that can reach this
//! socket can write a layout, so a layout is untrusted input to the app. Here it is bytes.
//!
//! **Revisions, not merges.** Each key has a revision, a counter kept in its file and raised by
//! every accepted write. A `put` names the revision it read; one that names any other is refused
//! with the current one, and the app decides what to do (its whole snapshot wins, D9). The check and
//! the write happen under one lock, so two writers at one revision cannot both win.
//!
//! **On the home disk, beside the screens.** The directory is `layouts` next to `serve --screens`,
//! which a real host already keeps on a disk that outlives a reboot (#232, `boxd.sh`). A daemon
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

use crate::daemon::rpc::SharedWriter;
use wr_protocol::envelope::{Envelope, Service};
use wr_protocol::reply::Reply;

/// The wire version of this service, reported by `capabilities`. Separate from `PROTOCOL_VERSION`,
/// which says whether the service exists at all.
pub const LAYOUT_SERVICE_VERSION: u32 = 1;

/// The largest layout kept: `SessionLimits.maxFileBytes` in the app, the cap on a whole
/// `session.json`, so any layout the app could save fits (D3).
pub const MAX_BLOB: usize = 4 * 1024 * 1024;

/// How many layouts one daemon keeps.
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
    /// This daemon keeps no layouts (no `--screens`), or the request was malformed.
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

/// The directory of layouts. One per daemon.
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
        let _writing = crate::util::lock_or_recover(&self.writing);
        let path = self.path(key);
        let (current, _) = self.get(key);
        if current != expected {
            return Err(LayoutError::Stale { revision: current });
        }
        if current == 0 && !path.exists() && self.count() >= MAX_KEYS {
            return Err(LayoutError::TooLarge(format!(
                "this daemon already keeps {MAX_KEYS} layouts"
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

/// This daemon's layouts, when it keeps them: set once, by `serve`, from `--screens`.
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
    partial: &mut crate::daemon::rpc::PartialRequests,
    envelope: &Envelope,
    writer: &SharedWriter,
) {
    // Stream 0 belongs to the daemon, never to a request.
    if envelope.stream == 0 {
        return;
    }
    let send =
        |value: Value| crate::daemon::rpc::send(writer, Service::Layout, envelope.stream, value);
    let bytes = match crate::daemon::rpc::reassemble(partial, envelope) {
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
    let Some(permit) = crate::daemon::rpc::Permit::acquire() else {
        send(reply(Err(LayoutError::Failed(
            "too many requests in flight".into(),
        ))));
        return;
    };
    let writer = std::sync::Arc::clone(writer);
    let stream = envelope.stream;
    std::thread::spawn(move || {
        let _permit = permit;
        crate::daemon::rpc::send(
            &writer,
            Service::Layout,
            stream,
            reply(handle(LAYOUTS.get(), &bytes)),
        );
    });
}

fn reply(result: Result<Value, LayoutError>) -> Value {
    json!(Reply::new(
        LAYOUT_SERVICE_VERSION,
        result.map_err(|error| error.json())
    ))
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
    let layouts = layouts.ok_or_else(|| unsupported("this daemon keeps no layouts"))?;
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
mod tests;
