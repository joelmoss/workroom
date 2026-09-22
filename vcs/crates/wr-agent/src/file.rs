//! `Service::File`: directory listing, raw file reads and change notification, served by the host
//! that owns the files. Requests and replies are JSON on the same chunked envelope as `Service::Vcs`
//! (first payload byte 0 = continuation, 1 = final); a request is always one envelope.
//!
//! **Why this is not the exec service.** `Service::Vcs`'s exec runs `git` or `jj` with arbitrary argv,
//! which is arbitrary code execution by construction. File access has to be its own, narrower
//! service, because a transport that has to authenticate peers will authenticate them differently:
//! shell grade for exec, repository grade for this. So listing takes NO argv from the client — the
//! two commands are fixed here, chosen by `backend` — and reads take a repository-relative path that
//! is resolved and verified on this host.
//!
//! Methods:
//!
//! - `capabilities` — this service's version and limits. Probed on THIS service and never through the
//!   VCS `capabilities` reply, whose `reads` count is compared for equality by an older client.
//! - `list` — run the fixed listing command for `backend` and return its raw result.
//! - `read` — return one regular file's bytes, base64, under one of two symlink policies.
//! - `watch` / `unwatch` — subscribe to filesystem changes; see `watch.rs`.
//!
//! **Errors are this crate's own [`FileError`]**, not `wr_vcs_model::VcsError`: `build-apple.sh` hashes
//! `wr-vcs-model`, so adding a variant there would force a rebuild of the app's Rust xcframework for a
//! type only this agent and its Swift client care about.

use crate::protocol::envelope::{Envelope, Service};
use crate::session::SharedWriter;
use crate::vcs::{self, Permit, SnapshotLock};
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
/// the agent's worst-case read memory at roughly 4 × (8 + 10.7) MiB rather than 32 ×.
const MAX_CONCURRENT_READS: usize = 4;

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
    /// The 32-slot request budget is spent, or the jj working-copy lock could not be taken.
    LockContention(String),
    /// A jj listing without a registered shared repository — the lock lives there.
    Registration(String),
    /// A per-service cap was hit (concurrent reads, subscriptions).
    Busy(String),
}

impl From<VcsError> for FileError {
    fn from(error: VcsError) -> Self {
        match error {
            VcsError::LockContention => FileError::LockContention("jj working-copy lock".into()),
            VcsError::UnsupportedRepo(detail) => FileError::Registration(detail),
            other => FileError::Io(format!("{other:?}")),
        }
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

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Backend {
    Git,
    Jj,
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
    #[serde(default)]
    shared_root: Option<String>,
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
            let slot = if request.method == "read" {
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
        _ => Err(unsupported("unsupported file method")),
    }
}

// MARK: Listing

/// The listing command for each backend, FIXED here. `FileListing.command` (Swift) builds the same
/// two for the native path; `AgentFileIntegrationTests` lists one repository through both and
/// compares, so the two cannot drift apart unnoticed.
///
/// - git: tracked plus untracked-but-not-ignored, NUL-separated so a name with a newline survives.
/// - jj: the working-copy files. jj auto-tracks, so this reflects new files too — and it SNAPSHOTS,
///   which is why the jj branch below takes the working-copy lock.
fn listing_command(backend: Backend) -> (&'static str, Vec<String>) {
    match backend {
        Backend::Git => (
            "git",
            [
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z",
            ]
            .map(String::from)
            .to_vec(),
        ),
        Backend::Jj => ("jj", ["file", "list"].map(String::from).to_vec()),
    }
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
fn scrubbed_environment(
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
    let backend = request
        .backend
        .ok_or_else(|| unsupported("missing backend"))?;
    let (executable, args) = listing_command(backend);
    // jj snapshots the working copy as part of the listing, so it takes the same cross-process lock
    // the app's native writers and the read side's `working_status` take. The AGENT holds it here
    // (the discipline of #204's reads), never the client: a client that also held it would
    // self-deadlock against this acquire for 30s and fail as `LockContention`.
    let lock = match backend {
        Backend::Jj => Some(SnapshotLock::acquire(
            &root,
            request.shared_root.as_deref(),
        )?),
        Backend::Git => None,
    };
    let environment = listing_environment();
    let env: Vec<(&str, &str)> = environment
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    // The barrier rides into the child: if this agent dies mid-listing, the jj that is still
    // snapshotting keeps the flock until it really exits. Without it the lock dies with the agent and
    // a native writer enters the very operation the lock exists to exclude.
    let captured = vcs::run_exec_with(
        &root,
        executable,
        &args,
        LIST_TIMEOUT,
        None,
        &env,
        lock.as_ref().map(SnapshotLock::fd),
    )?;
    drop(lock);
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
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
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

    #[test]
    fn listing_outside_a_repository_reports_the_tools_own_failure() {
        let root = scratch("not-a-repo");
        let request = json!({"version": 1, "method": "list", "backend": "git", "root": root});
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert_ne!(reply["result"]["exit_code"], 0, "{reply}");
    }

    #[test]
    fn a_jj_listing_without_a_shared_repository_is_a_registration_error() {
        let root = scratch("jj-unregistered");
        let request = json!({"version": 1, "method": "list", "backend": "jj", "root": root});
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(reply["error"]["Registration"]
            .as_str()
            .unwrap()
            .contains("registration required"));
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
