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
//! agent and its Swift client care about.

use crate::protocol::envelope::{Envelope, Service};
use crate::session::SharedWriter;
use crate::vcs::{self, Permit};
use crate::watch::Subscriptions;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
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
/// the agent's worst-case read memory at roughly 4 × (8 + 10.7) MiB rather than 32 ×. A `resolve`
/// takes a slot too, though it buffers nothing; like a read it holds the slot until its reply is
/// written, and a hung walk can't stretch that past `RESOLVE_TIMEOUT`.
const MAX_CONCURRENT_READS: usize = 4;

/// How long a `resolve` waits for its walk before answering that it timed out (#334). The same
/// 10s as a listing, and well under `AgentVCSConnection.fileRequest`'s 45s, so the app hears this
/// answer rather than its own timeout.
const RESOLVE_TIMEOUT: Duration = Duration::from_secs(10);

/// How a `resolve` answer that hit `RESOLVE_TIMEOUT` begins. The app matches it
/// (`AgentFileProvider.resolveTimedOut`) and ends that click: its other candidates resolve the same
/// prefix, or read through the same link with no deadline (#343), and would hang the same way.
const RESOLVE_TIMED_OUT: &str = "resolving timed out";

/// Walks still running after their `resolve` gave up on them. A walk through a link onto a hung
/// mount can block in the kernel for as long as the mount does, and Rust can't stop a thread, so
/// each one left behind is a parked thread. Once this many are counted, `resolve` answers `Busy`
/// without starting another. The check isn't an atomic admit: walks already waiting when the count
/// reaches it can still be left behind, so up to `MAX_ABANDONED_WALKS - 1 + MAX_CONCURRENT_READS`
/// (7) can be parked, and then resolves stay refused until enough return to bring the count back
/// under this. The cost: while they are parked, a resolve that would have been quick is refused
/// too. Reads are unaffected, since an abandoned walk holds no read slot and no permit.
const MAX_ABANDONED_WALKS: usize = 4;

static ABANDONED_WALKS: AtomicUsize = AtomicUsize::new(0);

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
    /// a protocol gate or a stable hand-off covers app/agent skew (see TODOS.md).
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
    vcs::absolute(root).map_err(|_| unsupported("invalid absolute root"))
}

fn reply(result: Result<Value, FileError>) -> Value {
    match result {
        Ok(result) => json!({"version": FILE_SERVICE_VERSION, "result": result}),
        Err(error) => json!({"version": FILE_SERVICE_VERSION, "error": error}),
    }
}

/// Handle one envelope. Requests that do real work run on their own thread holding a `Permit`, like
/// `vcs::dispatch`; `watch`/`unwatch` are answered inline because they only register with the
/// connection's `Subscriptions` (and deliberately take no permit — see `watch.rs`).
pub fn dispatch(envelope: &Envelope, writer: &SharedWriter, subscriptions: &Subscriptions) {
    // Stream 0 belongs to the agent: it is where watch events go, never where a request arrives.
    if envelope.stream == 0 {
        return;
    }
    let stream = envelope.stream;
    let send = |value: Value| vcs::send(writer, Service::File, stream, value);
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
            // A read holds its slot until its reply has been WRITTEN, not merely built: the
            // base64 value and its serialized copy are the memory the cap exists to bound, and they
            // live until `send` returns (which can block behind a slow reader for a long while).
            // A resolve holds one just as long; a walk hung on a mount can't stretch that past
            // `RESOLVE_TIMEOUT` (see `resolve`). It buffers nothing, so the memory rationale is a
            // read's alone.
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
                vcs::send(&writer, Service::File, stream, reply(handle(&request)));
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
    match request.method.as_str() {
        "capabilities" => Ok(json!({
            "version": FILE_SERVICE_VERSION,
            "max_read_bytes": MAX_READ_BYTES,
            "max_subscriptions": crate::watch::MAX_SUBSCRIPTIONS,
        })),
        "list" => list(request),
        "read" => read(request),
        "resolve" => resolve(request),
        _ => Err(unsupported("unsupported file method")),
    }
}

// MARK: Listing

/// The git listing command, FIXED here. `FileListing.command` (Swift) builds the same
/// one for the native path; `AgentFileIntegrationTests` lists one repository through both and
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

/// The child's environment: this agent's own, with the same pins and scrubs
/// `StatusCommandRunner.childEnvironment` applies on the native path.
///
/// "This agent's own" is the point of the file service on a remote host, where the app's environment
/// does not exist. Locally it is a snapshot of whichever app launch first spawned the agent — stale
/// for identity, which a LISTING does not use, and current enough for `PATH`, `HOME` and the global
/// ignore file, which it does. The pins and scrubs are what keep the two paths' output identical:
/// `LC_ALL=C` so a translated git cannot change a message a caller matches on, and no `GIT_DIR` family
/// so an inherited override cannot list a different repository than the one asked about.
fn listing_environment() -> Vec<(String, String)> {
    scrubbed_environment(std::env::vars_os())
}

/// `listing_environment` over an explicit variable set, so the scrub and the pins can be tested
/// without mutating this process's own environment — which other tests' child processes inherit.
pub(crate) fn scrubbed_environment(
    vars: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
) -> Vec<(String, String)> {
    const SCRUBBED: [&str; 7] = [
        "GIT_EXTERNAL_DIFF",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ];
    let mut env: BTreeMap<String, String> = vars
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    env.retain(|key, _| !SCRUBBED.contains(&key.as_str()));
    for (key, value) in [
        ("GIT_OPTIONAL_LOCKS", "0"),
        ("GIT_TERMINAL_PROMPT", "0"),
        ("LC_ALL", "C"),
    ] {
        env.insert(key.into(), value.into());
    }
    env.into_iter().collect()
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
    let captured = vcs::run_exec_with(&root, executable, &args, LIST_TIMEOUT, None, &env)?;
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
    if vcs::escaped_len(&stdout) + vcs::escaped_len(&stderr)
        > vcs::MAX_RESPONSE - vcs::EXEC_REPLY_RESERVE
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

fn read(request: &Request) -> Result<Value, FileError> {
    let root = root_of(request)?;
    let relative = request
        .path
        .as_deref()
        .ok_or_else(|| unsupported("missing path"))?;
    let relative =
        vcs::relative(relative).map_err(|_| unsupported("invalid relative file path"))?;
    let mode = request
        .symlinks
        .ok_or_else(|| unsupported("missing symlinks mode"))?;
    let max_bytes = request
        .max_bytes
        .ok_or_else(|| unsupported("missing max_bytes"))?;
    if max_bytes > MAX_READ_BYTES {
        return Err(unsupported("max_bytes exceeds the service ceiling"));
    }
    let bytes = read_file(&root, relative, mode, max_bytes)?;
    Ok(json!({"size": bytes.len(), "content": base64(&bytes)}))
}

// MARK: Resolving

/// A remote pane's ⌘-click names `link/../file.rb`, and only this host knows where `link` points
/// (#327): resolved on the Mac, the `..` lands beside the link instead of beside its target. So the
/// app sends the path with its `..` and reads whatever this answers.
///
/// `read`'s path rule (`vcs::relative`) refuses `.` and `..` before any I/O, and this one keeps
/// that guarantee for every path that climbs out of the root as WRITTEN: one that does is refused
/// here, before anything is looked up. What is left leaves the root only through a symlink inside
/// it. Only the part through the last `..` is looked up, so a `..` after a link out of the root
/// can say whether that directory exists (`Refused` when it does, `NotFound` when not), and never
/// what follows. That is not a new capability: the VCS service's `stat` reports existence for any
/// absolute path.
///
/// The walk runs on its own thread, and this answers after `RESOLVE_TIMEOUT` whether or not it has
/// returned (#334): a committed link can lead onto a hung network mount, and the app starts a new
/// click without waiting for the last one. Its request thread holds a `ReadSlot` and a `Permit`
/// until its reply is written, and a hung walk holds neither, so it can't keep reads out, or keep
/// the agent from exiting idle. A walk only reads, so leaving it behind cuts nothing off
/// mid-change.
///
/// What the deadline doesn't bound is the walk's thread itself (`MAX_ABANDONED_WALKS` caps how
/// many), and a kill doesn't always end it: an NFS hard mount waits killably, but a FUSE request
/// the daemon has already read waits uninterruptibly until the daemon answers (`request_wait_answer`
/// in Linux's `fs/fuse/dev.c`). A hand-off's `execve` waits for every other thread to die, so it
/// would freeze every terminal on the host behind such a walk; `crate::handoff` refuses while any
/// walk is left behind (`walks_left_behind`). Idle exit is unaffected: it lets go of the lock and
/// the listener before the process ends.
fn resolve(request: &Request) -> Result<Value, FileError> {
    let root = root_of(request)?;
    let relative = request
        .path
        .as_deref()
        .ok_or_else(|| unsupported("missing path"))?;
    if !stays_under_root(relative) {
        return Err(unsupported("invalid relative file path"));
    }
    if ABANDONED_WALKS.load(Ordering::Acquire) >= MAX_ABANDONED_WALKS {
        return Err(FileError::Busy(
            "too many earlier resolves are still walking".into(),
        ));
    }
    let shown = format!("{relative} under {}", root.display());
    let relative = relative.to_owned();
    let path = with_deadline(RESOLVE_TIMEOUT, move || resolve_path(&root, &relative)).inspect_err(
        |error| {
            if matches!(error, FileError::Io(message) if message.starts_with(RESOLVE_TIMED_OUT)) {
                crate::note!("resolve of {shown} timed out; its walk is left behind (#334)");
            }
        },
    )?;
    Ok(json!({"path": path}))
}

/// Walks left behind at their deadline and still running. `crate::handoff` refuses while this is
/// nonzero: see `resolve`.
pub(crate) fn walks_left_behind() -> usize {
    ABANDONED_WALKS.load(Ordering::Acquire)
}

/// `work`'s answer if it arrives within `timeout`, run on its own thread; otherwise an `Io` timeout
/// (which the app takes as the end of that click, `AgentFileProvider.resolveTimedOut`, not as an
/// agent too old to resolve), with the thread left to finish on its own and counted in
/// `ABANDONED_WALKS` until it does.
///
/// The thread and this caller agree through one state word on which of them saw the deadline
/// first, so the count goes up exactly once for a walk that is left behind and down exactly once
/// when it returns, and never goes below zero.
fn with_deadline<T: Send + 'static>(
    timeout: Duration,
    work: impl FnOnce() -> Result<T, FileError> + Send + 'static,
) -> Result<T, FileError> {
    const RUNNING: u8 = 0;
    const FINISHED: u8 = 1;
    const ABANDONED: u8 = 2;
    let state = std::sync::Arc::new(std::sync::atomic::AtomicU8::new(RUNNING));
    let (answer, answered) = std::sync::mpsc::sync_channel(1);
    let walker_state = std::sync::Arc::clone(&state);
    // `Builder`, not `thread::spawn`: a thread the OS refuses would panic here, on the request's
    // thread, and the app would wait out its own 45s for an answer that never comes.
    let spawned = std::thread::Builder::new().spawn(move || {
        // A panic still ends in the state change below, or a walk left behind would stay counted.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work))
            .unwrap_or_else(|_| Err(FileError::Io("the walk panicked".into())));
        let _ = answer.send(result);
        let left_behind = walker_state
            .compare_exchange(RUNNING, FINISHED, Ordering::AcqRel, Ordering::Acquire)
            .is_err();
        if left_behind {
            ABANDONED_WALKS.fetch_sub(1, Ordering::AcqRel);
            crate::note!("a resolve walk left behind at its deadline has returned");
        }
    });
    if let Err(error) = spawned {
        return Err(FileError::Busy(format!("cannot start a walk: {error}")));
    }
    match answered.recv_timeout(timeout) {
        Ok(result) => result,
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            Err(FileError::Io("the walk ended without an answer".into()))
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            // Counted before it is marked, so the walk can only take back a count already there.
            ABANDONED_WALKS.fetch_add(1, Ordering::AcqRel);
            let marked = state
                .compare_exchange(RUNNING, ABANDONED, Ordering::AcqRel, Ordering::Acquire)
                .is_ok();
            if marked {
                return Err(FileError::Io(format!(
                    "{RESOLVE_TIMED_OUT} after {}s",
                    timeout.as_secs()
                )));
            }
            // It finished in the meantime, so it isn't left behind, and its answer is waiting.
            ABANDONED_WALKS.fetch_sub(1, Ordering::AcqRel);
            answered
                .try_recv()
                .unwrap_or_else(|_| Err(FileError::Io("the walk ended without an answer".into())))
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
pub(crate) fn read_file(
    root: &Path,
    relative: &str,
    mode: Symlinks,
    max_bytes: u64,
) -> Result<Vec<u8>, FileError> {
    let real_root = std::fs::canonicalize(root)?;
    let mut options = std::fs::OpenOptions::new();
    // `O_NOCTTY`: a committed link can point at a tty, and opening one without it can make it the
    // agent's controlling terminal. The descriptor check refuses it afterwards, but the open itself has
    // already happened.
    options.read(true).custom_flags(
        libc::O_NONBLOCK
            | libc::O_NOCTTY
            | match mode {
                Symlinks::Refuse => libc::O_NOFOLLOW,
                Symlinks::FollowWithinRoot => 0,
            },
    );
    let mut file = options.open(root.join(relative)).map_err(|error| {
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
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    (&mut file).take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        return Err(FileError::TooLarge(format!("more than {max_bytes} bytes")));
    }
    Ok(bytes)
}

/// Standard base64 with padding. Hand-rolled because it is fifteen lines and the crate has no other
/// use for a base64 dependency; `Data(base64Encoded:)` is its decoder on the Swift side.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::symlink;
    use std::process::Command;

    /// Everything that is a plain request/reply, without a socket.
    fn execute(bytes: &[u8]) -> Value {
        reply(parse(bytes).and_then(|request| handle(&request)))
    }

    fn scratch(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("wr-file-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        // The tests compare real paths, and /tmp is a symlink on macOS.
        std::fs::canonicalize(&root).unwrap()
    }

    fn git(root: &Path, args: &[&str]) {
        assert!(Command::new("git")
            .args(args)
            .current_dir(root)
            .status()
            .unwrap()
            .success());
    }

    #[test]
    fn base64_matches_the_rfc_4648_vectors() {
        for (plain, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(plain.as_bytes()), encoded);
        }
        assert_eq!(base64(&[0xff, 0xfe, 0x00]), "//4A");
    }

    #[test]
    fn a_regular_file_reads_under_both_policies() {
        let root = scratch("regular");
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/a.txt"), b"hello").unwrap();
        for mode in [Symlinks::FollowWithinRoot, Symlinks::Refuse] {
            assert_eq!(read_file(&root, "src/a.txt", mode, 100).unwrap(), b"hello");
        }
        std::fs::write(root.join("empty"), b"").unwrap();
        assert!(read_file(&root, "empty", Symlinks::Refuse, 100)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn a_link_inside_the_root_is_followed_by_the_viewer_and_refused_for_diffs() {
        let root = scratch("inside");
        std::fs::write(root.join("real.txt"), b"data").unwrap();
        symlink("real.txt", root.join("alias.txt")).unwrap();
        assert_eq!(
            read_file(&root, "alias.txt", Symlinks::FollowWithinRoot, 100).unwrap(),
            b"data"
        );
        assert_eq!(
            read_file(&root, "alias.txt", Symlinks::Refuse, 100),
            Err(FileError::Refused("symbolic link".into()))
        );
    }

    #[test]
    fn a_link_out_of_the_root_is_refused_under_both_policies() {
        let root = scratch("escape");
        let outside = scratch("escape-outside");
        std::fs::write(outside.join("secret"), b"top secret").unwrap();
        symlink(outside.join("secret"), root.join("notes")).unwrap();
        for mode in [Symlinks::FollowWithinRoot, Symlinks::Refuse] {
            assert!(
                matches!(
                    read_file(&root, "notes", mode, 100),
                    Err(FileError::Refused(_))
                ),
                "{mode:?}"
            );
        }
    }

    #[test]
    fn a_directory_link_out_of_the_root_is_refused_even_when_the_leaf_is_a_plain_file() {
        let root = scratch("dirlink");
        let outside = scratch("dirlink-outside");
        std::fs::write(outside.join("secret"), b"top secret").unwrap();
        symlink(&outside, root.join("linked")).unwrap();
        // The leaf `secret` is a regular file, so `O_NOFOLLOW` alone would let this through.
        for mode in [Symlinks::FollowWithinRoot, Symlinks::Refuse] {
            assert!(
                matches!(
                    read_file(&root, "linked/secret", mode, 100),
                    Err(FileError::Refused(_))
                ),
                "{mode:?}"
            );
        }
    }

    #[test]
    fn a_sibling_directory_sharing_the_roots_name_prefix_is_outside_it() {
        let parent = scratch("prefix");
        let root = parent.join("repo");
        let sibling = parent.join("repo-other");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&sibling).unwrap();
        std::fs::write(sibling.join("x"), b"x").unwrap();
        symlink(sibling.join("x"), root.join("x")).unwrap();
        assert!(matches!(
            read_file(&root, "x", Symlinks::FollowWithinRoot, 100),
            Err(FileError::Refused(_))
        ));
    }

    #[test]
    fn a_fifo_is_refused_without_blocking() {
        let root = scratch("fifo");
        let path = std::ffi::CString::new(root.join("pipe").as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        let started = std::time::Instant::now();
        assert_eq!(
            read_file(&root, "pipe", Symlinks::FollowWithinRoot, 100),
            Err(FileError::Refused("not a regular file".into()))
        );
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn a_directory_is_not_a_readable_file() {
        let root = scratch("directory");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        assert_eq!(
            read_file(&root, "sub", Symlinks::Refuse, 100),
            Err(FileError::Refused("not a regular file".into()))
        );
    }

    #[test]
    fn a_missing_file_is_not_found() {
        let root = scratch("missing");
        assert!(matches!(
            read_file(&root, "nope", Symlinks::Refuse, 100),
            Err(FileError::NotFound(_))
        ));
    }

    #[test]
    fn a_file_over_max_bytes_is_too_large_and_one_at_the_limit_is_not() {
        let root = scratch("large");
        std::fs::write(root.join("f"), vec![b'x'; 11]).unwrap();
        assert!(matches!(
            read_file(&root, "f", Symlinks::Refuse, 10),
            Err(FileError::TooLarge(_))
        ));
        assert_eq!(
            read_file(&root, "f", Symlinks::Refuse, 11).unwrap().len(),
            11
        );
    }

    #[test]
    fn a_read_ceiling_above_the_services_is_rejected_not_clamped() {
        let root = scratch("ceiling");
        std::fs::write(root.join("f"), b"x").unwrap();
        let request = json!({
            "version": 1, "method": "read", "root": root, "path": "f",
            "symlinks": "refuse", "max_bytes": MAX_READ_BYTES + 1,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(reply["error"]["Unsupported"]
            .as_str()
            .unwrap()
            .contains("ceiling"));
    }

    #[test]
    fn read_replies_carry_the_size_and_base64_content() {
        let root = scratch("reply");
        std::fs::write(root.join("f"), b"foobar").unwrap();
        let request = json!({
            "version": 1, "method": "read", "root": root, "path": "f",
            "symlinks": "follow_within_root", "max_bytes": 100,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert_eq!(reply["result"]["size"], 6);
        assert_eq!(reply["result"]["content"], "Zm9vYmFy");
    }

    #[test]
    fn concurrent_reads_are_capped_and_a_finished_read_frees_its_slot() {
        static LOCAL: AtomicUsize = AtomicUsize::new(0);
        let held: Vec<_> = (0..MAX_CONCURRENT_READS)
            .map(|_| ReadSlot::acquire_from(&LOCAL, MAX_CONCURRENT_READS).unwrap())
            .collect();
        assert!(matches!(
            ReadSlot::acquire_from(&LOCAL, MAX_CONCURRENT_READS),
            Err(FileError::Busy(_))
        ));
        drop(held);
        assert!(ReadSlot::acquire_from(&LOCAL, MAX_CONCURRENT_READS).is_ok());
    }

    #[test]
    fn a_relative_path_that_climbs_is_rejected_before_any_io() {
        let root = scratch("climb");
        for path in ["../x", "a/../../x", "/etc/passwd", "", "a\0b"] {
            let request = json!({
                "version": 1, "method": "read", "root": root, "path": path,
                "symlinks": "refuse", "max_bytes": 10,
            });
            let reply = execute(&serde_json::to_vec(&request).unwrap());
            assert!(reply["error"]["Unsupported"].is_string(), "{path:?}");
        }
    }

    /// Every test that resolves, or moves `ABANDONED_WALKS`, takes this: `resolve` reads the count,
    /// so one test holding it at the cap would refuse the others' resolves.
    static WALKS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn walks_lock() -> std::sync::MutexGuard<'static, ()> {
        WALKS_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn resolve_request(root: &Path, path: &str) -> Value {
        let _walks = walks_lock();
        let request = json!({"version": 1, "method": "resolve", "root": root, "path": path});
        execute(&serde_json::to_vec(&request).unwrap())
    }

    // Value: protects=a walk that hangs (a link onto a dead mount, #334) is answered at its
    // deadline, with the text the app stops a click on, and the walk stays counted until it
    // returns; fails_when=`with_deadline` waits for the walk, or miscounts one left
    // behind; why_new=no other test makes a walk outlive its request; seam=none (the closure is
    // the walk itself, as `resolve` passes it)
    #[test]
    fn a_walk_past_its_deadline_is_answered_then_and_counted_until_it_returns() {
        let _walks = walks_lock();
        let before = ABANDONED_WALKS.load(Ordering::Acquire);
        let (release, released) = std::sync::mpsc::channel::<()>();
        let started = std::time::Instant::now();
        // The walk waits for the release, but not forever: if `with_deadline` waited for it, the
        // test would fail on its elapsed time instead of hanging.
        let result = with_deadline(Duration::from_millis(100), move || {
            let _ = released.recv_timeout(Duration::from_secs(5));
            Ok("late")
        });
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "it waited for the walk"
        );
        // The literal, not `RESOLVE_TIMED_OUT`: the app matches this text
        // (`AgentFileProvider.resolveTimedOut`), so changing it has to fail here.
        assert!(
            matches!(&result, Err(FileError::Io(message)) if message.starts_with("resolving timed out")),
            "{result:?}"
        );
        assert_eq!(ABANDONED_WALKS.load(Ordering::Acquire), before + 1);
        assert_eq!(walks_left_behind(), before + 1);
        release.send(()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while ABANDONED_WALKS.load(Ordering::Acquire) != before
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            ABANDONED_WALKS.load(Ordering::Acquire),
            before,
            "a returned walk is still counted"
        );
        assert_eq!(with_deadline(Duration::from_secs(5), || Ok(7)).unwrap(), 7);
        assert_eq!(ABANDONED_WALKS.load(Ordering::Acquire), before);
    }

    // Value: protects=a walk that panics is answered as an `Io` error naming the panic, rather than
    // as a vanished thread or a hung request; fails_when=`with_deadline` stops catching the walk's
    // panic (the answer becomes "ended without an answer"); why_new=no other test makes a walk
    // panic; seam=none (the closure is the walk itself)
    #[test]
    fn a_walk_that_panics_is_answered_as_an_io_error() {
        let _walks = walks_lock();
        let before = ABANDONED_WALKS.load(Ordering::Acquire);
        let result: Result<u8, FileError> =
            with_deadline(Duration::from_secs(5), || panic!("walk exploded"));
        assert!(
            matches!(&result, Err(FileError::Io(message)) if message.contains("panicked")),
            "{result:?}"
        );
        assert_eq!(ABANDONED_WALKS.load(Ordering::Acquire), before);
    }

    // Value: protects=a walk that panics AFTER it was left behind still comes off the count, so one
    // bad walk can't hold a hand-off off, or the resolve cap shut, until the agent restarts;
    // fails_when=the panic skips the state change that takes the count back; why_new=the
    // returned-walk test only covers a walk that ends normally; seam=none
    #[test]
    fn a_walk_that_panics_after_its_deadline_is_still_taken_off_the_count() {
        let _walks = walks_lock();
        let before = ABANDONED_WALKS.load(Ordering::Acquire);
        let (release, released) = std::sync::mpsc::channel::<()>();
        let result: Result<u8, FileError> = with_deadline(Duration::from_millis(100), move || {
            let _ = released.recv_timeout(Duration::from_secs(5));
            panic!("walk exploded late")
        });
        assert!(
            matches!(&result, Err(FileError::Io(message)) if message.starts_with(RESOLVE_TIMED_OUT)),
            "{result:?}"
        );
        assert_eq!(walks_left_behind(), before + 1);
        release.send(()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while ABANDONED_WALKS.load(Ordering::Acquire) != before
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            ABANDONED_WALKS.load(Ordering::Acquire),
            before,
            "a panicked walk is still counted"
        );
    }

    // Value: protects=hung walks can't pile up threads one per click: past `MAX_ABANDONED_WALKS`
    // left behind, `resolve` answers `Busy` without starting another; fails_when=`resolve` stops
    // checking the count before it walks; why_new=nothing else reaches the cap; seam=none
    #[test]
    fn a_resolve_is_refused_busy_while_too_many_earlier_walks_are_still_out() {
        struct Restore;
        impl Drop for Restore {
            fn drop(&mut self) {
                ABANDONED_WALKS.fetch_sub(MAX_ABANDONED_WALKS, Ordering::AcqRel);
            }
        }
        let _walks = walks_lock();
        let root = scratch("resolve-abandoned");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("f"), b"x").unwrap();
        let request = json!({"version": 1, "method": "resolve", "root": root, "path": "sub/../f"});
        let request = serde_json::to_vec(&request).unwrap();
        {
            ABANDONED_WALKS.fetch_add(MAX_ABANDONED_WALKS, Ordering::AcqRel);
            let _restore = Restore;
            let reply = execute(&request);
            assert!(reply["error"]["Busy"].is_string(), "{reply}");
        }
        assert_eq!(execute(&request)["result"]["path"], "f");
    }

    /// #327: `link/..` is the link TARGET's parent, which only the host can know.
    #[test]
    fn resolve_follows_a_link_before_its_parent_traversal() {
        let root = scratch("resolve-link");
        std::fs::create_dir_all(root.join("nested/dir")).unwrap();
        std::fs::write(root.join("nested/file.rb"), b"x").unwrap();
        std::fs::write(root.join("file.rb"), b"decoy").unwrap();
        symlink("nested/dir", root.join("link")).unwrap();
        assert_eq!(
            resolve_request(&root, "link/../file.rb")["result"]["path"],
            "nested/file.rb"
        );
        assert_eq!(
            resolve_request(&root, "./nested/./dir/../file.rb")["result"]["path"],
            "nested/file.rb"
        );
    }

    #[test]
    fn resolve_refuses_a_path_that_climbs_the_root_before_any_io() {
        // The root does not exist, so any lookup would answer `NotFound`: `Unsupported` means
        // the path was refused before one.
        let root = std::env::temp_dir().join("wr-file-test-resolve-no-such-root");
        for path in [
            "..",
            "../x",
            "a/../../x",
            "./../x",
            "/etc/passwd",
            "",
            "a\0b",
        ] {
            let reply = resolve_request(&root, path);
            assert!(
                reply["error"]["Unsupported"].is_string(),
                "{path:?}: {reply}"
            );
        }
    }

    #[test]
    fn resolve_refuses_a_link_out_of_the_root_and_the_root_itself() {
        let root = scratch("resolve-escape");
        let outside = scratch("resolve-escape-outside");
        std::fs::create_dir_all(outside.join("dir")).unwrap();
        std::fs::write(outside.join("secret"), b"top secret").unwrap();
        symlink(outside.join("dir"), root.join("out")).unwrap();
        std::fs::create_dir_all(root.join("sub")).unwrap();
        for path in ["out/../secret", "sub/.."] {
            let reply = resolve_request(&root, path);
            assert!(reply["error"]["Refused"].is_string(), "{path:?}: {reply}");
        }
    }

    // Value: protects=resolving works when the root the app names is itself a link (a symlinked
    // home or a macOS /tmp), answering the path under the REAL root; fails_when=`resolve_path`
    // compares against the root as given instead of its real path, refusing every click as
    // outside the root; why_new=`scratch` canonicalizes every root, so no test names a link;
    // seam=none
    #[test]
    fn resolve_works_when_the_root_is_itself_a_link() {
        let real = scratch("resolve-real-root");
        std::fs::create_dir_all(real.join("nested/dir")).unwrap();
        std::fs::write(real.join("nested/file.rb"), b"x").unwrap();
        symlink("nested/dir", real.join("link")).unwrap();
        let alias = real.with_file_name(format!(
            "{}-alias",
            real.file_name().unwrap().to_string_lossy()
        ));
        let _ = std::fs::remove_file(&alias);
        symlink(&real, &alias).unwrap();
        let reply = resolve_request(&alias, "link/../file.rb");
        std::fs::remove_file(&alias).unwrap();
        assert_eq!(reply["result"]["path"], "nested/file.rb", "{reply}");
    }

    /// What comes before the last `..` must exist, since only the host can say where it leads.
    /// What comes after it is `read`'s to judge, as it is for a path with no `..`.
    #[test]
    fn resolve_reports_a_missing_directory_before_the_parent_traversal_as_not_found() {
        let root = scratch("resolve-missing");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        let reply = resolve_request(&root, "nope/../x");
        assert!(reply["error"]["NotFound"].is_string(), "{reply}");
        assert_eq!(
            resolve_request(&root, "sub/../nope")["result"]["path"],
            "nope"
        );
    }

    // Value: protects=a link AFTER the last `..` keeps its own name, as a plain click on it would
    // (links before it come back as their target); fails_when=`resolve_path` canonicalizes the
    // whole path and answers the link's target; why_new=the other cases have no link after the
    // `..`; seam=none
    #[test]
    fn resolve_keeps_what_follows_the_last_parent_traversal_as_written() {
        let root = scratch("resolve-leaf-link");
        std::fs::create_dir_all(root.join("nested/dir")).unwrap();
        std::fs::create_dir_all(root.join("real")).unwrap();
        std::fs::write(root.join("nested/v2.rb"), b"x").unwrap();
        symlink("v2.rb", root.join("nested/current.rb")).unwrap();
        symlink("nested/dir", root.join("link")).unwrap();
        symlink("real", root.join("linkdir")).unwrap();
        assert_eq!(
            resolve_request(&root, "link/../current.rb")["result"]["path"],
            "nested/current.rb"
        );
        assert!(
            resolve_request(&root, "a/../linkdir/x.rb")["error"]["NotFound"].is_string(),
            "`a` is missing, so there is nothing to resolve the `..` against"
        );
        std::fs::create_dir_all(root.join("a")).unwrap();
        assert_eq!(
            resolve_request(&root, "a/../linkdir/x.rb")["result"]["path"],
            "linkdir/x.rb"
        );
    }

    // Value: protects=a `resolve` request counts against the same MAX_CONCURRENT_READS cap as a
    // `read`, because it canonicalizes through links that can sit on a hung network mount;
    // fails_when=`dispatch` stops taking a `ReadSlot` for "resolve", so a resolve is no longer
    // refused `Busy` while every slot is held; why_new=the other cap test drives `acquire_from` on
    // its own counter and `execute` skips `dispatch`, so nothing pins which methods take a slot;
    // seam=none (no other lib test reaches the global `READS`; only this one calls `dispatch`)
    #[test]
    fn a_resolve_is_refused_busy_while_every_read_slot_is_held() {
        // A resolve admitted here would read `ABANDONED_WALKS`, and the cap test's `Busy` must not
        // stand in for this one's.
        let _walks = walks_lock();
        #[derive(Clone, Default)]
        struct Capture(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);
        impl std::io::Write for Capture {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let capture = Capture::default();
        let writer: SharedWriter =
            std::sync::Arc::new(std::sync::Mutex::new(Box::new(capture.clone())));
        let subscriptions =
            Subscriptions::new(std::sync::Arc::clone(&writer), std::sync::Arc::new(|| {}));
        let _held: Vec<_> = (0..MAX_CONCURRENT_READS)
            .map(|_| ReadSlot::acquire().unwrap())
            .collect();
        // The root does not exist: were the resolve admitted it would answer `NotFound`, never `Busy`.
        let root = std::env::temp_dir().join("wr-file-test-resolve-busy-no-such-root");
        let request = json!({"version": 1, "method": "resolve", "root": root, "path": "f"});
        let envelope = Envelope::new(Service::File, 1, serde_json::to_vec(&request).unwrap());
        dispatch(&envelope, &writer, &subscriptions);
        let mut decoder = crate::protocol::envelope::EnvelopeDecoder::new();
        decoder.push(&capture.0.lock().unwrap());
        let reply = decoder
            .next_envelope()
            .unwrap()
            .expect("the refusal is written before dispatch returns");
        let reply: Value = serde_json::from_slice(&reply.payload[1..]).unwrap();
        assert!(reply["error"]["Busy"].is_string(), "{reply}");
    }

    #[test]
    fn unknown_fields_methods_and_versions_are_typed_errors() {
        for request in [
            json!({"version": 1, "method": "nope"}),
            json!({"version": 2, "method": "capabilities"}),
            json!({"version": 1, "method": "capabilities", "argv": ["x"]}),
        ] {
            let reply = execute(&serde_json::to_vec(&request).unwrap());
            assert!(reply["error"]["Unsupported"].is_string(), "{request}");
        }
        let reply = execute(br#"{"version":1,"method":"capabilities"}"#);
        assert_eq!(reply["result"]["version"], FILE_SERVICE_VERSION);
    }

    #[test]
    fn git_listing_matches_git_ls_files_including_untracked_and_awkward_names() {
        let root = scratch("list");
        git(&root, &["init", "-q", "-b", "main"]);
        std::fs::write(root.join(".gitignore"), "ignored.txt\n").unwrap();
        std::fs::write(root.join("tracked.txt"), b"a").unwrap();
        std::fs::write(root.join("ignored.txt"), b"b").unwrap();
        std::fs::write(root.join("untracked.txt"), b"c").unwrap();
        std::fs::write(root.join("with\nnewline.txt"), b"d").unwrap();
        git(&root, &["add", ".gitignore", "tracked.txt"]);
        let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        let result = &reply["result"];
        assert_eq!(result["exit_code"], 0, "{reply}");
        let names: Vec<&str> = result["stdout"]
            .as_str()
            .unwrap()
            .split('\0')
            .filter(|name| !name.is_empty())
            .collect();
        assert!(names.contains(&"tracked.txt"));
        assert!(names.contains(&"untracked.txt"));
        assert!(names.contains(&"with\nnewline.txt"));
        assert!(!names.contains(&"ignored.txt"), "{names:?}");
    }

    /// The app still sends `shared_root` on every listing (a jj-era field the agent ignores);
    /// `Request` is `deny_unknown_fields`, so losing the ignored field would reject every listing.
    #[test]
    fn a_listing_naming_a_shared_root_still_runs() {
        let root = scratch("shared-root-list");
        git(&root, &["init", "-q", "-b", "main"]);
        let request = json!({
            "version": 1, "method": "list", "backend": "git", "root": root, "shared_root": root,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert_eq!(reply["result"]["exit_code"], 0, "{reply}");
    }

    #[test]
    fn a_repository_fsmonitor_never_runs_during_a_listing() {
        let root = scratch("fsmonitor");
        git(&root, &["init", "-q", "-b", "main"]);
        std::fs::write(root.join("tracked.txt"), b"a").unwrap();
        git(&root, &["add", "tracked.txt"]);
        let marker = root.join("ran");
        let hook = root.join(".git/fsmonitor.sh");
        std::fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", marker.display())).unwrap();
        std::fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        git(&root, &["config", "core.fsmonitor", hook.to_str().unwrap()]);
        std::fs::write(root.join("untracked.txt"), b"c").unwrap();
        let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert_eq!(reply["result"]["exit_code"], 0, "{reply}");
        assert!(
            !marker.exists(),
            "a .git/config fsmonitor ran during a listing"
        );
    }

    #[test]
    fn listing_outside_a_repository_reports_the_tools_own_failure() {
        let root = scratch("not-a-repo");
        let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert_ne!(reply["result"]["exit_code"], 0, "{reply}");
    }

    #[test]
    fn a_listing_environment_scrubs_repository_overrides_and_pins_the_locale() {
        let vars = [
            ("GIT_DIR", "/elsewhere"),
            ("GIT_EXTERNAL_DIFF", "/bin/evil"),
            ("LC_ALL", "fr_FR.UTF-8"),
            ("HOME", "/home/someone"),
        ]
        .map(|(key, value)| (key.into(), value.into()));
        let env: BTreeMap<_, _> = scrubbed_environment(vars.into_iter()).into_iter().collect();
        assert!(!env.contains_key("GIT_DIR"));
        assert!(!env.contains_key("GIT_EXTERNAL_DIFF"));
        assert_eq!(env["LC_ALL"], "C");
        assert_eq!(env["GIT_OPTIONAL_LOCKS"], "0");
        assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
        assert_eq!(
            env["HOME"], "/home/someone",
            "everything else passes through"
        );
    }
}
