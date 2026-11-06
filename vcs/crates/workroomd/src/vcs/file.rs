//! `Service::File`: directory listing, raw file reads and change notification, served by the host
//! that owns the files. Requests and replies are JSON on the same chunked envelope as `Service::Vcs`
//! (first payload byte 0 = continuation, 1 = final); a request is always one envelope.
//!
//! **Why this is not the exec service.** `Service::Vcs`'s exec runs `git` with arbitrary argv,
//! which is arbitrary code execution by construction. File access has to be its own, narrower
//! service, because a transport that has to authenticate peers will authenticate them differently:
//! shell grade for exec, repository grade for this. So listing takes NO argv from the client — the
//! command is fixed here (git) — and reads take a repository-relative path that
//! is resolved and verified on this host.
//!
//! Methods:
//!
//! - `capabilities` — this service's version and limits. Probed on THIS service and never through the
//!   VCS `capabilities` reply, whose `reads` count is compared for equality by an older client.
//! - `list` — run the fixed git listing command and return its raw result.
//! - `read` — return one regular file's bytes, base64, under one of two symlink policies.
//! - `resolve` — resolve a relative path that may hold `..` ON THIS HOST, through any symlink on
//!   the way, and return the repository-relative path it names (#327).
//! - `watch` / `unwatch` — subscribe to filesystem changes; see `watch.rs`.
//!
//! **Errors are this crate's own [`FileError`]**, not `wr_vcs_model::VcsError`: it is a type only this
//! daemon and its Swift client care about.

use crate::daemon::rpc::SharedWriter;
use crate::daemon::rpc::{self, Permit};
use crate::exec;
use crate::vcs::watch::Subscriptions;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use wr_protocol::envelope::{Envelope, Service};
use wr_protocol::reply::Reply;
use wr_vcs_model::VcsError;

/// The wire version of this service, reported by `capabilities`. Separate from `PROTOCOL_VERSION`,
/// which says whether the service exists at all.
pub const FILE_SERVICE_VERSION: u32 = 1;

/// The largest read the service performs. A request for more is REJECTED, not clamped: a clamped
/// read would hand the caller a silently short file, and the viewer's "too large" state is a
/// decision the caller has to make itself. 8 MiB is `PlainFileViewer.maxBytes`; its base64 form
/// (10.7 MiB) stays under the 16 MiB reply ceiling, which is what lets `send`'s oversize branch be
/// unreachable for this service.
pub const MAX_READ_BYTES: u64 = 8 * 1024 * 1024;

/// Reads in flight at once. Each buffers up to `MAX_READ_BYTES` and then its base64, so this bounds
/// the daemon's worst-case read memory at roughly 4 × (8 + 10.7) MiB rather than 32 ×. A `resolve`
/// takes a slot too, though it buffers nothing; like a read it holds the slot until its reply is
/// written, and a hung walk can't stretch that past `FILESYSTEM_TIMEOUT`.
const MAX_CONCURRENT_READS: usize = 4;

/// How long path resolution and file opening wait before answering that they timed out (#334/#343).
/// The same 10s as a listing, and well under `DaemonClient.fileRequest`'s 45s, so the app
/// hears this answer rather than its own timeout.
const FILESYSTEM_TIMEOUT: Duration = Duration::from_secs(10);

/// How a `resolve` answer that hit `FILESYSTEM_TIMEOUT` begins. The app matches it
/// (`DaemonFileProvider.resolveTimedOut`) and ends that click: its other candidates resolve the same
/// prefix, or open through the same link (#343), and would hang the same way.
const RESOLVE_TIMED_OUT: &str = "resolving timed out";
/// A read whose file cannot be opened and checked before the deadline returns this error.
const READ_OPEN_TIMED_OUT: &str = "opening file timed out";
/// A resolve refused at `MAX_ABANDONED_FILESYSTEM_OPERATIONS`. The app matches this text exactly
/// (`DaemonFileProvider.resolveWalksBusy`), so it keeps its #334 wording although stalled opens now
/// count towards the cap as well: a new daemon must still end an older app's click.
const RESOLVE_WALKS_BUSY: &str = "too many earlier resolves are still walking";
/// A read refused at the same cap (`DaemonFileProvider.filesystemOperationsBusy`).
const FILESYSTEM_OPERATIONS_BUSY: &str = "too many earlier filesystem operations are still pending";

/// Filesystem operations still running after their request gave up on them. A walk or file open
/// through a link onto a hung mount can block in the kernel for as long as the mount does, and Rust
/// can't stop a thread, so each one left behind is a parked thread. Once this many are counted,
/// `resolve` and `read` answer `Busy` without starting another. The check isn't an atomic admit:
/// operations already waiting when the count reaches it can still be left behind, so up to
/// `MAX_ABANDONED_FILESYSTEM_OPERATIONS - 1 + MAX_CONCURRENT_READS` (7) can be parked. While they
/// are parked, a filesystem request that would have been quick is refused too.
const MAX_ABANDONED_FILESYSTEM_OPERATIONS: usize = 4;

static ABANDONED_FILESYSTEM_OPERATIONS: AtomicUsize = AtomicUsize::new(0);

/// Matches `StatusCommandRunner`'s 10s listing timeout, so a slow tree fails the same way on both
/// paths.
const LIST_TIMEOUT: Duration = Duration::from_secs(10);

/// What a File request can fail with. Externally tagged with a string payload for every variant
/// (`{"Refused": "…"}`), so the Swift decoder has one shape to handle.
#[derive(Debug, Serialize, PartialEq)]
pub enum FileError {
    /// A request this service does not understand: bad JSON, wrong version, unknown method, a
    /// missing or invalid parameter.
    Unsupported(String),
    Io(String),
    NotFound(String),
    /// Containment refused it: a path escaping the repository root, a symlink under the `refuse`
    /// policy, or something that is not a regular file (a FIFO, a device, a directory).
    Refused(String),
    /// The file is larger than the caller's `max_bytes`.
    TooLarge(String),
    /// The listing did not fit the 4 MiB capture cap. Never returned as a cut-off list: a truncation
    /// can land mid-filename, and a tree missing files without saying so is worse than no tree.
    ListingTruncated(String),
    /// The 32-slot request budget is spent.
    LockContention(String),
    /// A per-service cap was hit (concurrent reads, subscriptions).
    Busy(String),
}

impl From<VcsError> for FileError {
    fn from(error: VcsError) -> Self {
        FileError::Io(format!("{error:?}"))
    }
}

impl From<std::io::Error> for FileError {
    fn from(error: std::io::Error) -> Self {
        match error.kind() {
            std::io::ErrorKind::NotFound => FileError::NotFound(error.to_string()),
            _ => FileError::Io(error.to_string()),
        }
    }
}

/// Required on a listing, as before #266, but only `git` deserializes: kept as a wire gate, so an
/// older app's `jj` listing is refused rather than run, and nothing varies on it.
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Backend {
    Git,
}

/// How a read treats symbolic links. Both verify the descriptor that was actually opened, so a
/// path swapped for a link between a check and the open cannot escape.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Symlinks {
    /// The file viewer: follow links, but only to a target inside the root.
    FollowWithinRoot,
    /// Diff highlighting: a link's diff is its target's PATH TEXT, not its contents, so a leaf link
    /// is refused outright (and an intermediate directory link must still stay inside the root).
    Refuse,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    method: String,
    #[serde(default)]
    backend: Option<Backend>,
    #[serde(default)]
    root: Option<String>,
    /// Accepted and ignored: the app still sends a repository's shared root, which only the
    /// removed jj listing read.
    ///
    /// ponytail: kept only so `deny_unknown_fields` does not reject the app's request. Prune once
    /// a protocol gate or a stable hand-off covers app/daemon skew (see TODOS.md).
    #[serde(default, rename = "shared_root")]
    _shared_root: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    symlinks: Option<Symlinks>,
    #[serde(default)]
    max_bytes: Option<u64>,
    #[serde(default)]
    subscription: Option<u64>,
}

fn unsupported(detail: &str) -> FileError {
    FileError::Unsupported(detail.into())
}

fn root_of(request: &Request) -> Result<PathBuf, FileError> {
    let root = request
        .root
        .as_deref()
        .ok_or_else(|| unsupported("missing root"))?;
    exec::absolute(root).map_err(|_| unsupported("invalid absolute root"))
}

fn reply(result: Result<Value, FileError>) -> Value {
    json!(Reply::new(FILE_SERVICE_VERSION, result))
}

/// Handle one envelope. Requests that do real work run on their own thread holding a `Permit`, like
/// `vcs::service::dispatch`; `watch`/`unwatch` are answered inline because they only register with the
/// connection's `Subscriptions` (and deliberately take no permit — see `watch.rs`).
pub fn dispatch(envelope: &Envelope, writer: &SharedWriter, subscriptions: &Subscriptions) {
    // Stream 0 belongs to the daemon: it is where watch events go, never where a request arrives.
    if envelope.stream == 0 {
        return;
    }
    let stream = envelope.stream;
    // A File reply over the 16 MiB ceiling becomes `FileError::TooLarge`. The service bounds its own
    // replies below it by construction (an 8 MiB read is 10.7 MiB of base64), so it is never sent;
    // it exists so that if one ever were, the client gets an error it can decode.
    let too_large = || json!(FileError::TooLarge("File reply exceeds 16 MiB".into()));
    let send = |value: Value| rpc::send_with(writer, Service::File, stream, value, too_large);
    // A request is always one envelope. The chunk marker the VCS service uses for oversized requests
    // starts with 0x02, which is not `{`; refusing it here answers instead of parsing garbage.
    if envelope.payload.first() != Some(&b'{') {
        send(reply(Err(unsupported(
            "file requests are a single JSON object",
        ))));
        return;
    }
    let request = match parse(&envelope.payload) {
        Ok(request) => request,
        Err(error) => {
            send(reply(Err(error)));
            return;
        }
    };
    match request.method.as_str() {
        "watch" => send(reply(subscribe(&request, subscriptions))),
        "unwatch" => send(reply(unsubscribe(&request, subscriptions))),
        _ => {
            let Some(permit) = Permit::acquire() else {
                send(reply(Err(FileError::LockContention(
                    "too many requests in flight".into(),
                ))));
                return;
            };
            // A read holds its slot until its reply has been WRITTEN, not merely built: the base64
            // value and its serialized copy are the memory the cap exists to bound, and they live
            // until `send` returns (which can block behind a slow reader for a long while). A
            // resolve or file open holds one just as long; a filesystem operation hung on a mount
            // can't stretch that past `FILESYSTEM_TIMEOUT` (see `resolve` and `read_file_with`). It
            // buffers nothing, so the memory rationale is a read's alone.
            let slot = if matches!(request.method.as_str(), "read" | "resolve") {
                match ReadSlot::acquire() {
                    Ok(slot) => Some(slot),
                    Err(error) => {
                        send(reply(Err(error)));
                        return;
                    }
                }
            } else {
                None
            };
            let writer = std::sync::Arc::clone(writer);
            std::thread::spawn(move || {
                let _permit = permit;
                let _slot = slot;
                rpc::send_with(
                    &writer,
                    Service::File,
                    stream,
                    reply(handle(&request)),
                    too_large,
                );
            });
        }
    }
}

fn subscribe(request: &Request, subscriptions: &Subscriptions) -> Result<Value, FileError> {
    let id = request
        .subscription
        .ok_or_else(|| unsupported("missing subscription"))?;
    let root = root_of(request)?;
    subscriptions.subscribe(id, &root)?;
    Ok(json!({"subscription": id}))
}

fn unsubscribe(request: &Request, subscriptions: &Subscriptions) -> Result<Value, FileError> {
    let id = request
        .subscription
        .ok_or_else(|| unsupported("missing subscription"))?;
    subscriptions.unsubscribe(id);
    Ok(json!({"subscription": id}))
}

/// Parse one request and check its version. The single place either happens, so `dispatch` and the
/// tests' `execute` cannot disagree about what a malformed or foreign-version request is.
fn parse(bytes: &[u8]) -> Result<Request, FileError> {
    let request = serde_json::from_slice::<Request>(bytes)
        .map_err(|error| FileError::Unsupported(error.to_string()))?;
    if request.version == FILE_SERVICE_VERSION {
        Ok(request)
    } else {
        Err(unsupported("unsupported file service version"))
    }
}

fn handle(request: &Request) -> Result<Value, FileError> {
    handle_with(request, &ABANDONED_FILESYSTEM_OPERATIONS)
}

/// `handle`, with the count of filesystem workers left behind passed in, so a test can hold a count
/// at its cap without refusing other tests' reads and resolves.
fn handle_with(request: &Request, abandoned: &'static AtomicUsize) -> Result<Value, FileError> {
    match request.method.as_str() {
        "capabilities" => Ok(json!({
            "version": FILE_SERVICE_VERSION,
            "max_read_bytes": MAX_READ_BYTES,
            "max_subscriptions": crate::vcs::watch::MAX_SUBSCRIPTIONS,
        })),
        "list" => list(request),
        "read" => read(request, abandoned),
        "resolve" => resolve(request, abandoned),
        _ => Err(unsupported("unsupported file method")),
    }
}

// MARK: Listing

/// The git listing command, FIXED here. `FileListing.command` (Swift) builds the same
/// one for the native path; `DaemonFileIntegrationTests` lists one repository through both and
/// compares, so the two cannot drift apart unnoticed.
///
/// - git: tracked plus untracked-but-not-ignored, NUL-separated so a name with a newline survives.
fn listing_command() -> (&'static str, Vec<String>) {
    (
        "git",
        [
            // `--others` refreshes the fsmonitor state, which runs a repository-configured
            // `core.fsmonitor` command (measured). `.git/config` is not trusted.
            "-c",
            "core.fsmonitor=",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ]
        .map(String::from)
        .to_vec(),
    )
}

/// The child's environment: the host's cached login profile on a remote daemon, or the app-supplied
/// inherited environment locally, with the same pins and scrubs as other git reads.
/// The pins and scrubs keep the read's repository and output stable:
/// `LC_ALL=C` so a translated git cannot change a message a caller matches on, and no `GIT_DIR` family
/// so an inherited override cannot list a different repository than the one asked about.
fn listing_environment() -> Vec<(String, String)> {
    crate::host::environment::host_read_environment()
        .into_iter()
        .collect()
}

fn list(request: &Request) -> Result<Value, FileError> {
    let root = root_of(request)?;
    // Required as before; only `git` deserializes (see `Backend`), so the listing never varies on it.
    request
        .backend
        .ok_or_else(|| unsupported("missing backend"))?;
    let (executable, args) = listing_command();
    let environment = listing_environment();
    let env: Vec<(&str, &str)> = environment
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    let captured = exec::run_exec(&root, executable, &args, LIST_TIMEOUT, None, &env)?;
    if captured.stdout_truncated {
        return Err(FileError::ListingTruncated(
            "listing exceeds the 4 MiB capture cap".into(),
        ));
    }
    let stdout = String::from_utf8_lossy(&captured.stdout);
    let stderr = String::from_utf8_lossy(&captured.stderr);
    // JSON escaping can multiply a control-heavy listing (NUL separators are six bytes each), so the
    // raw cap above does not bound the reply. Refuse rather than let `send` replace the whole reply
    // with an error the caller cannot tell from a real failure.
    if rpc::escaped_len(&stdout) + rpc::escaped_len(&stderr)
        > rpc::MAX_RESPONSE - rpc::EXEC_REPLY_RESERVE
    {
        return Err(FileError::ListingTruncated(
            "listing exceeds the reply ceiling once escaped".into(),
        ));
    }
    Ok(json!({
        "stdout": stdout,
        "stderr": stderr,
        "exit_code": captured.exit_code,
        "timed_out": captured.timed_out,
        "signaled": captured.signaled,
    }))
}

// MARK: Reading

static READS: AtomicUsize = AtomicUsize::new(0);

struct ReadSlot(&'static AtomicUsize);

impl ReadSlot {
    fn acquire() -> Result<Self, FileError> {
        Self::acquire_from(&READS, MAX_CONCURRENT_READS)
    }

    /// Take a slot from `counter` if fewer than `max` are held. Split out so a test can exercise the
    /// cap against its own counter instead of racing every other read test for the shared one.
    fn acquire_from(counter: &'static AtomicUsize, max: usize) -> Result<Self, FileError> {
        counter
            .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < max).then_some(count + 1)
            })
            .map(|_| ReadSlot(counter))
            .map_err(|_| FileError::Busy("too many reads in flight".into()))
    }
}

impl Drop for ReadSlot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn read(request: &Request, abandoned: &'static AtomicUsize) -> Result<Value, FileError> {
    let root = root_of(request)?;
    let relative = request
        .path
        .as_deref()
        .ok_or_else(|| unsupported("missing path"))?;
    let relative =
        exec::relative(relative).map_err(|_| unsupported("invalid relative file path"))?;
    let mode = request
        .symlinks
        .ok_or_else(|| unsupported("missing symlinks mode"))?;
    let max_bytes = request
        .max_bytes
        .ok_or_else(|| unsupported("missing max_bytes"))?;
    if max_bytes > MAX_READ_BYTES {
        return Err(unsupported("max_bytes exceeds the service ceiling"));
    }
    let bytes = read_file_with(
        &root,
        relative,
        mode,
        max_bytes,
        FILESYSTEM_TIMEOUT,
        abandoned,
        open_read_file,
    )?;
    Ok(json!({"size": bytes.len(), "content": crate::util::base64(&bytes)}))
}

// MARK: Resolving

/// A remote pane's ⌘-click names `link/../file.rb`, and only this host knows where `link` points
/// (#327): resolved on the Mac, the `..` lands beside the link instead of beside its target. So the
/// app sends the path with its `..` and reads whatever this answers.
///
/// `read`'s path rule (`exec::relative`) refuses `.` and `..` before any I/O, and this one keeps
/// that guarantee for every path that climbs out of the root as WRITTEN: one that does is refused
/// here, before anything is looked up. What is left leaves the root only through a symlink inside
/// it. Only the part through the last `..` is looked up, so a `..` after a link out of the root
/// can say whether that directory exists (`Refused` when it does, `NotFound` when not), and never
/// what follows. That is not a new capability: the VCS service's `stat` reports existence for any
/// absolute path.
///
/// The path walk runs on its own thread, and this answers after `FILESYSTEM_TIMEOUT` whether or not
/// it has returned (#334): a committed link can lead onto a hung network mount, and the app starts a
/// new click without waiting for the last one. Its request thread holds a `ReadSlot` and a `Permit`
/// until its reply is written, and a hung walk holds neither, so it can't keep reads out, or keep
/// the daemon from exiting idle. A walk only reads, so leaving it behind cuts nothing off
/// mid-change. `read_file_with` uses the same deadline for canonicalization, opening and descriptor
/// checks. The bounded payload read stays on the request thread so a stalled worker cannot retain
/// its 8 MiB buffer after the slot is released.
///
/// What the deadline doesn't bound is the walk's thread itself
/// (`MAX_ABANDONED_FILESYSTEM_OPERATIONS` caps how many), and a kill doesn't always end it: an NFS
/// hard mount waits killably, but a FUSE request the daemon has already read waits uninterruptibly
/// until the daemon answers (`request_wait_answer` in Linux's `fs/fuse/dev.c`). A hand-off's
/// `execve` waits for every other thread to die, so it would freeze every terminal on the host
/// behind such a walk; `crate::daemon::handoff` refuses while any walk is left behind
/// (`filesystem_operations_left_behind`). Idle exit is unaffected: it lets go of the lock and the
/// listener before the process ends.
fn resolve(request: &Request, abandoned: &'static AtomicUsize) -> Result<Value, FileError> {
    let root = root_of(request)?;
    let relative = request
        .path
        .as_deref()
        .ok_or_else(|| unsupported("missing path"))?;
    if !stays_under_root(relative) {
        return Err(unsupported("invalid relative file path"));
    }
    // The app ends the click on this, as on a timeout: its other candidates could open through the
    // same hung link.
    if let Some(error) = filesystem_capacity_error(abandoned, RESOLVE_WALKS_BUSY) {
        return Err(error);
    }
    let shown = format!("{relative} under {}", root.display());
    let relative = relative.to_owned();
    let path = with_deadline(
        FILESYSTEM_TIMEOUT,
        RESOLVE_TIMED_OUT,
        abandoned,
        move || resolve_path(&root, &relative),
    )
    .inspect_err(|error| {
        if matches!(error, FileError::Io(message) if message.starts_with(RESOLVE_TIMED_OUT)) {
            crate::note!("resolve of {shown} timed out; its walk is left behind (#334)");
        }
    })?;
    Ok(json!({"path": path}))
}

/// Filesystem workers left behind at their deadline and still running. `crate::daemon::handoff`
/// refuses while this is nonzero: see `resolve` and `read_file_with`.
pub(crate) fn filesystem_operations_left_behind() -> usize {
    ABANDONED_FILESYSTEM_OPERATIONS.load(Ordering::Acquire)
}

/// `work`'s answer if it arrives within `timeout`, run on its own thread; otherwise an `Io` error
/// starting with `timeout_message` (`RESOLVE_TIMED_OUT` or `READ_OPEN_TIMED_OUT`, which the app
/// takes as the end of that click), with the thread left to finish on its own and counted in
/// `abandoned` until it does.
///
/// The worker and this caller agree through one state word on which of them saw the deadline
/// first, so the count goes up exactly once for an operation that is left behind and down exactly
/// once when it returns, and never goes below zero.
fn with_deadline<T: Send + 'static>(
    timeout: Duration,
    timeout_message: &'static str,
    abandoned: &'static AtomicUsize,
    work: impl FnOnce() -> Result<T, FileError> + Send + 'static,
) -> Result<T, FileError> {
    const RUNNING: u8 = 0;
    const FINISHED: u8 = 1;
    const ABANDONED: u8 = 2;
    let state = std::sync::Arc::new(std::sync::atomic::AtomicU8::new(RUNNING));
    let (answer, answered) = std::sync::mpsc::sync_channel(1);
    let worker_state = std::sync::Arc::clone(&state);
    // `Builder`, not `thread::spawn`: a thread the OS refuses would panic here, on the request's
    // thread, and the app would wait out its own 45s for an answer that never comes.
    let spawned = std::thread::Builder::new().spawn(move || {
        // A panic still ends in the state change below, or a worker left behind would stay counted.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work))
            .unwrap_or_else(|_| Err(FileError::Io("the filesystem worker panicked".into())));
        let _ = answer.send(result);
        let left_behind = worker_state
            .compare_exchange(RUNNING, FINISHED, Ordering::AcqRel, Ordering::Acquire)
            .is_err();
        if left_behind {
            abandoned.fetch_sub(1, Ordering::AcqRel);
            crate::note!("a filesystem operation left behind at its deadline has returned");
        }
    });
    if let Err(error) = spawned {
        return Err(FileError::Busy(format!(
            "cannot start a filesystem worker: {error}"
        )));
    }
    match answered.recv_timeout(timeout) {
        Ok(result) => result,
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(FileError::Io(
            "the filesystem worker ended without an answer".into(),
        )),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            // Counted before it is marked, so the walk can only take back a count already there.
            abandoned.fetch_add(1, Ordering::AcqRel);
            let marked = state
                .compare_exchange(RUNNING, ABANDONED, Ordering::AcqRel, Ordering::Acquire)
                .is_ok();
            if marked {
                return Err(FileError::Io(format!(
                    "{timeout_message} after {}s",
                    timeout.as_secs()
                )));
            }
            // It finished in the meantime, so it isn't left behind, and its answer is waiting.
            abandoned.fetch_sub(1, Ordering::AcqRel);
            answered.try_recv().unwrap_or_else(|_| {
                Err(FileError::Io(
                    "the filesystem worker ended without an answer".into(),
                ))
            })
        }
    }
}

/// Whether `relative` is a relative path that, taken lexically, never climbs above the root it is
/// joined to. `.`, `..` and empty components are allowed; `..` past the root is not.
fn stays_under_root(relative: &str) -> bool {
    if relative.is_empty() || relative.starts_with('/') || relative.contains('\0') {
        return false;
    }
    let mut depth = 0usize;
    for part in relative.split('/') {
        match part {
            "" | "." => {}
            ".." => match depth.checked_sub(1) {
                Some(up) => depth = up,
                None => return false,
            },
            _ => depth += 1,
        }
    }
    true
}

/// `relative` resolved on this host, as a path under the root's real path. A path that leaves the
/// root through a link is refused, and so is the root itself, which is not a file.
///
/// Only the part up to the last `..` is resolved, through any link in it: that is the part only
/// this host can answer. What follows is kept as written, as `read` keeps it, so a link after the
/// `..` keeps its own name: `link/../current.rb` stays `current.rb` when that is a link to
/// `v2.rb`, as a click on `nested/current.rb` would. `read` then judges the rest.
fn resolve_path(root: &Path, relative: &str) -> Result<String, FileError> {
    let real_root = std::fs::canonicalize(root)?;
    let parts: Vec<&str> = relative
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect();
    let rest = parts
        .iter()
        .rposition(|part| *part == "..")
        .map_or(0, |last| last + 1);
    let mut real_path = std::fs::canonicalize(root.join(parts[..rest].join("/")))?;
    real_path.extend(&parts[rest..]);
    // `strip_prefix` compares by component, so `/a/bc` is not inside `/a/b`.
    let inside = real_path
        .strip_prefix(&real_root)
        .map_err(|_| FileError::Refused("outside the repository root".into()))?;
    if inside.as_os_str().is_empty() {
        return Err(FileError::Refused("the repository root itself".into()));
    }
    inside
        .to_str()
        .map(String::from)
        .ok_or_else(|| FileError::Refused("the resolved path is not UTF-8".into()))
}

/// The path a descriptor actually refers to, asked of the kernel rather than reconstructed from the
/// string that was opened.
fn descriptor_path(fd: RawFd) -> std::io::Result<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        let mut buffer = [0u8; libc::PATH_MAX as usize];
        // SAFETY: `F_GETPATH` writes at most PATH_MAX bytes, NUL-terminated, into the buffer.
        if unsafe { libc::fcntl(fd, libc::F_GETPATH, buffer.as_mut_ptr()) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let length = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
        Ok(PathBuf::from(std::ffi::OsStr::from_bytes(
            &buffer[..length],
        )))
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::fs::read_link(format!("/proc/self/fd/{fd}"))
    }
}

/// Read one regular file under `root`, verifying the DESCRIPTOR rather than the path.
///
/// Checking a path and then opening it leaves a window in which the path can be swapped for a link
/// that leaves the root; and neither client-side check that existed before this guarded against a
/// FIFO, which blocks a plain open forever. So: open first, non-blocking (a FIFO opens at once
/// instead of waiting for a writer), and only then ask the kernel what was opened.
///
/// - `refuse` opens with `O_NOFOLLOW`, so a leaf link fails at the open (`ELOOP`).
/// - Either way the opened file's real path must lie under the root's real path — compared by path
///   COMPONENT, so `/a/bc` is not inside `/a/b`. That is what catches an intermediate directory link
///   pointing out of the root, which `O_NOFOLLOW` does not.
/// - It must be a regular file: not a directory, FIFO, socket or device.
/// - Its size is checked before any byte is read, and the read itself is bounded, so a file that
///   grows between the check and the read still cannot exceed `max_bytes`.
///
/// The deadline, the count of workers left behind and `open` are passed in, so a test can stall the
/// open without a hung mount.
///
/// Only the open and the descriptor checks run under the deadline (#343): the lookup is what a link
/// onto a hung mount blocks, and the bounded read stays on the request thread, where its slot
/// bounds the memory it buffers. A read that blocks after the open is not bounded here.
fn read_file_with(
    root: &Path,
    relative: &str,
    mode: Symlinks,
    max_bytes: u64,
    timeout: Duration,
    abandoned: &'static AtomicUsize,
    open: impl FnOnce(&Path, &str, Symlinks, u64) -> Result<OpenedRead, FileError> + Send + 'static,
) -> Result<Vec<u8>, FileError> {
    // Refused like a resolve at the cap: the open could be left behind as well.
    if let Some(error) = filesystem_capacity_error(abandoned, FILESYSTEM_OPERATIONS_BUSY) {
        return Err(error);
    }
    let root = root.to_path_buf();
    let relative = relative.to_owned();
    let OpenedRead { mut file, size } =
        with_deadline(timeout, READ_OPEN_TIMED_OUT, abandoned, move || {
            open(&root, &relative, mode, max_bytes)
        })?;
    let mut bytes = Vec::with_capacity(size as usize);
    (&mut file).take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        return Err(FileError::TooLarge(format!("more than {max_bytes} bytes")));
    }
    Ok(bytes)
}

/// `Busy` with `message` once `abandoned` workers have reached
/// `MAX_ABANDONED_FILESYSTEM_OPERATIONS`.
fn filesystem_capacity_error(abandoned: &AtomicUsize, message: &'static str) -> Option<FileError> {
    (abandoned.load(Ordering::Acquire) >= MAX_ABANDONED_FILESYSTEM_OPERATIONS)
        .then(|| FileError::Busy(message.into()))
}

/// Open and validate the descriptor before returning it to the request thread. The deadline
/// bounds the mount operations in canonicalize, open and descriptor lookup; the size-limited byte
/// read stays on the request thread so the per-read memory budget remains tied to its slot.
struct OpenedRead {
    file: std::fs::File,
    size: u64,
}

fn open_read_file(
    root: &Path,
    relative: &str,
    mode: Symlinks,
    max_bytes: u64,
) -> Result<OpenedRead, FileError> {
    let real_root = std::fs::canonicalize(root)?;
    let mut options = std::fs::OpenOptions::new();
    // `O_NOCTTY`: a committed link can point at a tty, and opening one without it can make it the
    // daemon's controlling terminal. The descriptor check refuses it afterwards, but the open itself
    // has already happened.
    options.read(true).custom_flags(
        libc::O_NONBLOCK
            | libc::O_NOCTTY
            | match mode {
                Symlinks::Refuse => libc::O_NOFOLLOW,
                Symlinks::FollowWithinRoot => 0,
            },
    );
    let file = options.open(root.join(relative)).map_err(|error| {
        if error.raw_os_error() == Some(libc::ELOOP) && mode == Symlinks::Refuse {
            FileError::Refused("symbolic link".into())
        } else {
            error.into()
        }
    })?;
    let real_path = descriptor_path(file.as_raw_fd())?;
    if !real_path.starts_with(&real_root) {
        return Err(FileError::Refused("outside the repository root".into()));
    }
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(FileError::Refused("not a regular file".into()));
    }
    if metadata.len() > max_bytes {
        return Err(FileError::TooLarge(format!(
            "{} bytes exceeds {max_bytes}",
            metadata.len()
        )));
    }
    Ok(OpenedRead {
        file,
        size: metadata.len(),
    })
}

#[cfg(test)]
mod tests;
