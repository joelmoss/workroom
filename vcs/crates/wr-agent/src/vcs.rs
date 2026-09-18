//! Versioned VCS requests over Service::Vcs. Capability negotiation is separate from the terminal
//! greeting. Each nonzero stream is one request. Reply JSON is chunked; the first payload byte is
//! 0 for continuation, 1 for final. Maximum assembled reply is 16MiB. Requests are never replayed.
use crate::protocol::envelope::{Envelope, Service, MAX_ENVELOPE_PAYLOAD};
use crate::session::SharedWriter;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use wr_vcs_model::{self as model, VcsError};

const MAX_RESPONSE: usize = 16 * 1024 * 1024;
const MAX_HISTORY_LIMIT: usize = 10000;
static ACTIVE: AtomicUsize = AtomicUsize::new(0);

/// Whether any dispatched VCS request — including a JJ snapshot that owns the working-copy lock
/// and rewrites `@` in-process — is still running. Consulted by `serve`'s idle-exit check: a hard
/// process exit while this is nonzero would abort a repo-level transaction mid-flight, not just
/// drop a socket.
pub fn is_busy() -> bool {
    ACTIVE.load(Ordering::Acquire) > 0
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    version: u32,
    #[serde(default)]
    root: Option<String>,
    #[serde(default)]
    shared_root: Option<String>,
    #[serde(default)]
    backend: Option<Backend>,
    method: String,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    revision: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    base: Option<String>,
}

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Backend {
    Git,
    Jj,
}

fn io(error: impl std::fmt::Display) -> VcsError {
    VcsError::Io(error.to_string())
}
fn required(value: &Option<String>) -> model::Result<&str> {
    value
        .as_deref()
        .ok_or_else(|| io("missing request parameter"))
}
fn absolute(value: &str) -> model::Result<PathBuf> {
    if !value.starts_with('/')
        || value.contains('\0')
        || value.split('/').any(|s| s == "." || s == "..")
    {
        return Err(io("invalid absolute repository path"));
    }
    Ok(PathBuf::from(value))
}
fn relative(value: &str) -> model::Result<&str> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains('\0')
        || value.split('/').any(|s| s == "." || s == "..")
    {
        return Err(io("invalid relative file path"));
    }
    Ok(value)
}

/// This lock belongs to actual native work, not to a socket or the caller waiting for its reply.
/// Native app writers take the same cross-process barrier before starting a JJ operation.
struct SnapshotLock(std::fs::File);
impl SnapshotLock {
    fn acquire(root: &Path, shared: Option<&str>) -> model::Result<Self> {
        let shared = absolute(shared.ok_or_else(|| {
            VcsError::UnsupportedRepo("registration required for JJ snapshot".into())
        })?)?;
        fn repository(root: &Path) -> model::Result<PathBuf> {
            let path = root.join(".jj/repo");
            if path.is_dir() {
                path.canonicalize().map_err(io)
            } else {
                let target = std::fs::read_to_string(&path).map_err(io)?;
                root.join(".jj")
                    .join(target.trim())
                    .canonicalize()
                    .map_err(io)
            }
        }
        if repository(root)? != repository(&shared)? {
            return Err(io("working and shared JJ repository differ"));
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(shared.join(".jj/workroom-vcs.lock"))
            .map_err(io)?;
        let started = std::time::Instant::now();
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(Self(file));
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::WouldBlock {
                return Err(io(error));
            }
            if started.elapsed() > std::time::Duration::from_secs(30) {
                return Err(VcsError::LockContention);
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
}
// Close, never LOCK_UN: a snapshotting CLI child may share the locked file description.

fn jj(root: &Path, args: &[&str]) -> model::Result<String> {
    String::from_utf8(wr_vcs_git::diff::run(root, "jj", args)?).map_err(io)
}
fn parent(root: &Path, rev: &str) -> model::Result<String> {
    let text = jj(
        root,
        &[
            "log",
            "--ignore-working-copy",
            "--no-graph",
            "--color",
            "never",
            "-r",
            rev,
            "-T",
            "parents.map(|c| c.commit_id()).join(\" \")",
        ],
    )?;
    text.split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| VcsError::NotFound("parent".into()))
}
fn content(root: &Path, rev: &str, path: &str) -> model::Result<Value> {
    // Preserve the existing best-effort highlighting semantics. Transport/service failures are
    // handled outside this operation and cannot become nil content.
    let value = jj(
        root,
        &[
            "file",
            "show",
            "--ignore-working-copy",
            "-r",
            rev,
            "--",
            path,
        ],
    )
    .ok()
    .filter(|s| !s.is_empty() && s.len() <= 2 * 1024 * 1024 && !s.contains('\0'));
    Ok(json!(value))
}

pub fn execute(bytes: &[u8]) -> Value {
    let result = serde_json::from_slice::<Request>(bytes)
        .map_err(io)
        .and_then(read);
    match result {
        Ok(result) => json!({"version": 1, "result": result}),
        Err(error) => json!({"version": 1, "error": error}),
    }
}

fn read(request: Request) -> model::Result<Value> {
    if request.version != 1 {
        return Err(VcsError::BackendVersion(
            "unsupported VCS service version".into(),
        ));
    }
    if request.method == "capabilities" {
        return Ok(json!({"version": 1, "reads": 9}));
    }
    if request.limit.is_some_and(|limit| limit > MAX_HISTORY_LIMIT) {
        return Err(VcsError::PartialData(format!(
            "history request exceeds {MAX_HISTORY_LIMIT} commits"
        )));
    }
    let root = absolute(required(&request.root)?)?;
    let backend = request.backend.ok_or_else(|| io("missing backend"))?;
    let path = request.path.as_deref().map(relative).transpose()?;
    let rev = request.revision.as_deref();
    let param = |value: Option<&str>| {
        value
            .map(str::to_owned)
            .ok_or_else(|| io("missing request parameter"))
    };
    let working = match request.base.as_deref() {
        None | Some("working_copy") => true,
        Some("parent") => false,
        _ => return Err(io("invalid working base")),
    };
    let _lock = if backend == Backend::Jj
        && (request.method == "working_status"
            || (request.method == "working_file_diff" && working))
    {
        Some(SnapshotLock::acquire(
            &root,
            request.shared_root.as_deref(),
        )?)
    } else {
        None
    };
    let value = match (backend, request.method.as_str()) {
        (Backend::Git, "log") => serde_json::to_value(wr_vcs_git::log_page(
            &root,
            request.limit.unwrap_or(100).min(MAX_HISTORY_LIMIT),
        )?),
        (Backend::Jj, "log") => serde_json::to_value(wr_vcs_core::log_page(
            &root,
            request.limit.unwrap_or(100).min(MAX_HISTORY_LIMIT),
        )?),
        (Backend::Git, "changeset") => {
            serde_json::to_value(wr_vcs_git::changeset(&root, &param(rev)?)?)
        }
        (Backend::Jj, "changeset") => {
            serde_json::to_value(wr_vcs_core::changeset(&root, &param(rev)?)?)
        }
        (Backend::Git, "current_ref") => serde_json::to_value(wr_vcs_git::current_ref(&root)?),
        (Backend::Jj, "current_ref") => serde_json::to_value(wr_vcs_core::current_ref(&root)?),
        (Backend::Git, "working_status") => {
            serde_json::to_value(wr_vcs_git::diff::working_status(&root)?)
        }
        (Backend::Jj, "working_status") => {
            serde_json::to_value(wr_vcs_core::working_status(&root)?)
        }
        (Backend::Git, "file_diff") => {
            let change = wr_vcs_git::changeset(&root, &param(rev)?)?;
            serde_json::to_value(wr_vcs_git::diff::committed_patch(
                &root,
                &change.commit,
                &param(path)?,
            )?)
        }
        (Backend::Git, "working_file_diff") if working => {
            serde_json::to_value(wr_vcs_git::diff::working_patch(&root, &param(path)?)?)
        }
        (Backend::Git, "file_content") => serde_json::to_value(wr_vcs_git::file_content(
            &root,
            &param(rev)?,
            &param(path)?,
            false,
        )?),
        (Backend::Git, "commit_parent_file_content") => serde_json::to_value(
            wr_vcs_git::file_content(&root, &param(rev)?, &param(path)?, true)?,
        ),
        (Backend::Git, "working_base_file_content") if working => serde_json::to_value(
            wr_vcs_git::file_content(&root, "HEAD", &param(path)?, false)?,
        ),
        (Backend::Jj, "file_diff" | "working_file_diff") => {
            let revision = if request.method == "file_diff" {
                param(rev)?
            } else if working {
                "@".into()
            } else {
                "@-".into()
            };
            let from = parent(&root, &revision)?;
            let path = param(path)?;
            let mut args = vec![
                "diff", "--git", "--color", "never", "--from", &from, "--to", &revision,
            ];
            if request.method == "file_diff" || !working {
                args.push("--ignore-working-copy");
            }
            args.extend(["--", &path]);
            let bytes = if let Some(lock) = &_lock {
                wr_vcs_git::diff::run_with_barrier(&root, "jj", &args, lock.0.as_raw_fd())?
            } else {
                wr_vcs_git::diff::run(&root, "jj", &args)?
            };
            serde_json::to_value(String::from_utf8(bytes).map_err(io)?)
        }
        (Backend::Jj, "file_content") => return content(&root, &param(rev)?, &param(path)?),
        (Backend::Jj, "commit_parent_file_content") => {
            return content(&root, &parent(&root, &param(rev)?)?, &param(path)?)
        }
        (Backend::Jj, "working_base_file_content") => {
            return content(&root, if working { "@-" } else { "@--" }, &param(path)?)
        }
        _ => return Err(VcsError::UnsupportedRepo("unsupported VCS read".into())),
    };
    value.map_err(io)
}

fn send(writer: &SharedWriter, stream: u32, value: Value) {
    let mut bytes = serde_json::to_vec(&value).expect("JSON value serializes");
    if bytes.len() > MAX_RESPONSE {
        bytes = serde_json::to_vec(&json!({"version": 1, "error": VcsError::PartialData("VCS reply exceeds 16 MiB".into())})).unwrap();
    }
    let chunks = bytes.chunks(MAX_ENVELOPE_PAYLOAD - 1);
    let count = chunks.len();
    for (index, chunk) in chunks.enumerate() {
        let mut payload = vec![u8::from(index + 1 == count)];
        payload.extend_from_slice(chunk);
        let Ok(mut writer) = writer.lock() else {
            return;
        };
        if writer
            .write_all(&Envelope::new(Service::Vcs, stream, payload).encode())
            .and_then(|()| writer.flush())
            .is_err()
        {
            return;
        }
    }
}

pub fn dispatch(envelope: &Envelope, writer: &SharedWriter) {
    if envelope.stream == 0 {
        return;
    }
    if ACTIVE
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < 32).then_some(count + 1)
        })
        .is_err()
    {
        send(
            writer,
            envelope.stream,
            json!({"version": 1, "error": VcsError::LockContention}),
        );
        return;
    }
    let writer = Arc::clone(writer);
    let bytes = envelope.payload.clone();
    let stream = envelope.stream;
    std::thread::spawn(move || {
        struct Permit;
        impl Drop for Permit {
            fn drop(&mut self) {
                ACTIVE.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _permit = Permit;
        send(&writer, stream, execute(&bytes));
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::envelope::{EnvelopeDecoder, Hello};
    use crate::protocol::frame::{Frame, FrameKind};
    use std::io::Read;
    use std::os::unix::net::UnixStream;

    #[test]
    fn version_and_path_errors_are_explicit() {
        assert!(execute(br#"{"version":99,"method":"capabilities"}"#)
            .get("error")
            .is_some());
        assert_eq!(
            execute(br#"{"version":1,"method":"capabilities"}"#)["result"]["reads"],
            9
        );
        for root in ["relative", "/tmp/../other", "/tmp/./other", "/tmp/\0other"] {
            let request = json!({"version":1,"method":"log","backend":"git","root":root});
            assert!(execute(&serde_json::to_vec(&request).unwrap())
                .get("error")
                .is_some());
        }
        let request = json!({"version":1,"method":"working_status","backend":"jj","root":"/definitely-absent"});
        assert!(
            execute(&serde_json::to_vec(&request).unwrap())["error"]["UnsupportedRepo"]
                .as_str()
                .unwrap()
                .contains("registration required")
        );
    }

    #[test]
    fn a_blocked_snapshot_does_not_block_control_or_disconnect() {
        let root = std::env::temp_dir().join(format!("wr-vcs-lock-test-{}", std::process::id()));
        std::fs::create_dir_all(root.join(".jj/repo")).unwrap();
        let held = SnapshotLock::acquire(&root, root.to_str()).unwrap();
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();
        let worker = std::thread::spawn(move || {
            crate::serve::handle_connection(server, crate::session::SessionStore::new())
        });
        client.write_all(&Hello::current("test").encode()).unwrap();
        let mut hello = Vec::new();
        while Hello::decode(&hello).unwrap().is_none() {
            let mut byte = [0];
            client.read_exact(&mut byte).unwrap();
            hello.push(byte[0]);
        }
        let request = json!({"version":1,"method":"working_status","backend":"jj","root":root,"shared_root":root});
        client
            .write_all(
                &Envelope::new(Service::Vcs, 7, serde_json::to_vec(&request).unwrap()).encode(),
            )
            .unwrap();
        client
            .write_all(
                &Envelope::new(
                    Service::Control,
                    0,
                    Frame::control(FrameKind::List).encode(),
                )
                .encode(),
            )
            .unwrap();
        let mut decoder = EnvelopeDecoder::new();
        loop {
            let mut bytes = [0; 4096];
            let count = client.read(&mut bytes).unwrap();
            assert!(count > 0);
            decoder.push(&bytes[..count]);
            if let Some(reply) = decoder.next_envelope().unwrap() {
                assert_eq!(reply.service, Service::Control);
                break;
            }
        }
        drop(client);
        worker.join().unwrap().unwrap();
        drop(held);
        // Worker may be finishing the deliberately invalid repository read; keep its fixture
        // until the global permit count falls (the other tests in this module do no dispatch).
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while ACTIVE.load(Ordering::Acquire) != 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
