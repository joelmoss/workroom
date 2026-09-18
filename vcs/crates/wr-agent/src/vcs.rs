//! Versioned VCS requests over Service::Vcs. Capability negotiation is separate from the terminal
//! greeting. Each nonzero stream is one request. Reply JSON is chunked; the first payload byte is
//! 0 for continuation, 1 for final. Maximum assembled reply is 16MiB. Requests are never replayed.
use crate::protocol::envelope::{Envelope, Service, MAX_ENVELOPE_PAYLOAD};
use crate::session::SharedWriter;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use wr_vcs_model::{self as model, VcsError};

const MAX_RESPONSE: usize = 16 * 1024 * 1024;
const MAX_HISTORY_LIMIT: usize = 10000;
/// `CLIVCSWriter.commitTimeout` (Swift) is 600s, the longest legitimate write timeout. Bounds a
/// hostile/buggy request from wedging an exec thread indefinitely; the 32-slot `ACTIVE` permit
/// already bounds concurrency, this bounds duration.
const MAX_EXEC_TIMEOUT_MS: u64 = 610_000;
/// Per-stream cap, matching `StatusCommandRunner.maxBytes`'s default on the Swift side.
const MAX_EXEC_STREAM: usize = 4 * 1024 * 1024;
/// Env vars an exec request may forward to the child, resolved by the client rather than re-derived
/// here — the agent's own inherited environment may predate the request and carry a stale value
/// (see `AgentCommandRunner.swift`). `PATH` is always sent, from the SAME `ShellEnvironment.path()`
/// the native writer uses via `/usr/bin/env`: wr-agent is a long-lived daemon that "is negotiated
/// with, never replaced" (`LocalAgentVCS`), so its own inherited PATH at spawn time can predate a
/// tool install and is never refreshed; without this, a write that would succeed natively could fail
/// to find `git`/`jj` through an old agent. The rest is `StatusCommandRunner.networkEnvironment`'s
/// set, sent only for a network write. Anything else in the request's `env` map is silently dropped.
const ALLOWED_EXEC_ENV_KEYS: &[&str] = &[
    "PATH",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GIT_SSH_COMMAND",
    "GIT_CONFIG_GLOBAL",
    "XDG_CONFIG_HOME",
    "SSH_ASKPASS_REQUIRE",
];
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

/// A write command, run to completion and reported back raw — argv, cwd, stdin and timeout in;
/// exit code, stdout, stderr, `timed_out`, `signaled` out. Every request-building, output-parsing
/// and failure-classification decision (`CLIVCSWriter.classify`/`.classifyCommit`, the pathspec
/// and refspec injection defenses, the retry/abort taxonomy) stays in Swift and sees exactly the
/// bytes it would see from a local `git`/`jj` — this is deliberately NOT a reimplementation of
/// commit/push/pull semantics, so criterion 2 ("typed failures... match pre-agent behavior
/// exactly") holds by construction rather than by keeping two classifiers in sync.
///
/// **Never acquires `SnapshotLock`.** A caller that needs the JJ working-copy barrier for a
/// mutating command already holds it — `CLIVCSWriter`'s `gate: JJSnapshotGate` takes the same
/// `<shared>/.jj/workroom-vcs.lock` flock (`JJProcessBarrier`, shared by name with `SnapshotLock`
/// above) for the whole gated operation before any exec request goes out. Taking it again here
/// would self-deadlock the same actor for 30s and then fail as `LockContention`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExecRequest {
    version: u32,
    kind: ExecKind,
    executable: Executable,
    args: Vec<String>,
    dir: String,
    timeout_ms: u64,
    /// Latin-1 (ISO 8859-1), not UTF-8: a pathspec payload is NUL-separated and paths are not
    /// guaranteed valid UTF-8, so decoding this as UTF-8 (or sending it as a JSON byte-number array,
    /// ~3-4x larger on the wire for ordinary text) would either corrupt or bloat it. Latin-1 is a
    /// total bijection over every byte 0x00-0xFF, so `AgentCommandRunner.swift`'s
    /// `String(data:encoding:.isoLatin1)` never fails and `latin1_bytes` below is its exact inverse
    /// — every byte round-trips, at roughly the original size for ordinary text.
    #[serde(default)]
    stdin: Option<String>,
    #[serde(default)]
    env: std::collections::BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ExecKind {
    Exec,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Executable {
    Git,
    Jj,
}
impl Executable {
    fn as_str(self) -> &'static str {
        match self {
            Executable::Git => "git",
            Executable::Jj => "jj",
        }
    }
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
    // `kind` distinguishes an exec request from the existing read `Request`; its absence (every
    // read request in the wild, and every request before this field existed) means "read", so the
    // wire format already spoken by `AgentVCSReader` is untouched.
    let result = serde_json::from_slice::<Value>(bytes)
        .map_err(io)
        .and_then(|value| {
            if value.get("kind").and_then(Value::as_str) == Some("exec") {
                serde_json::from_value::<ExecRequest>(value)
                    .map_err(io)
                    .and_then(exec)
            } else {
                serde_json::from_value::<Request>(value)
                    .map_err(io)
                    .and_then(read)
            }
        });
    match result {
        Ok(result) => json!({"version": 1, "result": result}),
        Err(error) => json!({"version": 1, "error": error}),
    }
}

struct Captured {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    exit_code: i32,
    timed_out: bool,
    signaled: bool,
}

/// Drain a pipe to EOF on its own thread (mirrors `StatusCommandRunner.readCapped`): a blocking
/// read is safe here because it runs off the thread that watches for timeout/exit, and keeps
/// draining past `cap` so the child can never block on a full pipe buffer.
fn drain_capped(mut source: impl Read, cap: usize) -> Vec<u8> {
    let mut collected = Vec::new();
    let mut chunk = [0u8; 65536];
    loop {
        match source.read(&mut chunk) {
            Ok(0) => return collected,
            Ok(count) => {
                if collected.len() < cap {
                    let take = (cap - collected.len()).min(count);
                    collected.extend_from_slice(&chunk[..take]);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return collected,
        }
    }
}

/// Run `executable` to completion, capturing everything a `StatusCommandRunning` conformer needs
/// to classify the outcome exactly as the native path would. Mirrors `StatusCommandRunner.run`'s
/// SIGTERM-then-grace-then-SIGKILL shape (`CLIVCSWriter.commitTimeout`'s doc: "Killing a commit is
/// categorically more dangerous than killing a fetch" — an immediate SIGKILL denies a `post-commit`
/// hook the chance to exit cleanly and can leave `index.lock` behind).
fn run_exec(
    dir: &Path,
    executable: &str,
    args: &[String],
    timeout: Duration,
    stdin: Option<&[u8]>,
    env: &[(&str, &str)],
) -> model::Result<Captured> {
    let mut command = Command::new(executable);
    command
        .current_dir(dir)
        .args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        // Same baseline as every other subprocess in this codebase (`StatusCommandRunner.run`,
        // `wr_vcs_git::diff::run_bounded`): disable git's own lock-contention retries and terminal
        // prompting, and pin the message locale so Swift's stderr-substring classifiers keep working.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        // A workroom can be a clone of an untrusted repo; never run an inherited external-diff/askpass
        // helper or reach for a graphical prompt this headless agent has no display for.
        .env_remove("GIT_EXTERNAL_DIFF")
        .env_remove("SSH_ASKPASS")
        .env_remove("DISPLAY")
        .envs(env.iter().copied());
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
        command.env_remove(key);
    }
    let mut child = command.spawn().map_err(io)?;

    if let Some(payload) = stdin {
        let mut handle = child.stdin.take().expect("piped stdin");
        let payload = payload.to_vec();
        // Off the waiting thread: a payload larger than the pipe buffer blocks until the child
        // drains it, and the child may not start reading until after argv parsing.
        std::thread::spawn(move || {
            let _ = handle.write_all(&payload);
            // `handle` drops here, closing the write end so the child sees EOF.
        });
    }

    let stdout_pipe = child.stdout.take().expect("piped stdout");
    let stderr_pipe = child.stderr.take().expect("piped stderr");
    let out = std::thread::spawn(move || drain_capped(stdout_pipe, MAX_EXEC_STREAM));
    let err = std::thread::spawn(move || drain_capped(stderr_pipe, MAX_EXEC_STREAM));

    let pid = child.id() as i32;
    let start = Instant::now();
    let mut timed_out = false;
    let mut sent_term = false;
    let status = 'wait: loop {
        if let Ok(Some(status)) = child.try_wait() {
            break 'wait status;
        }
        let elapsed = start.elapsed();
        if elapsed >= timeout {
            timed_out = true;
            if !sent_term {
                sent_term = true;
                unsafe { libc::kill(-pid, libc::SIGTERM) };
            } else if elapsed >= timeout + Duration::from_secs(2) {
                unsafe { libc::kill(-pid, libc::SIGKILL) };
                break 'wait child.wait().map_err(io)?;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let stdout = out.join().map_err(|_| io("stdout reader panicked"))?;
    let stderr = err.join().map_err(|_| io("stderr reader panicked"))?;
    Ok(Captured {
        stdout,
        stderr,
        exit_code: status
            .code()
            .unwrap_or_else(|| status.signal().unwrap_or(-1)),
        timed_out,
        signaled: status.signal().is_some(),
    })
}

/// Keep only the env vars an exec request is allowed to set — see `ALLOWED_EXEC_ENV_KEYS`. Pure,
/// so the allowlist itself is unit-testable without spawning anything.
fn filter_exec_env(env: &std::collections::BTreeMap<String, String>) -> Vec<(&str, &str)> {
    env.iter()
        .filter(|(key, _)| ALLOWED_EXEC_ENV_KEYS.contains(&key.as_str()))
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect()
}

/// The exact inverse of `AgentCommandRunner.swift`'s `String(data:encoding:.isoLatin1)` — see
/// `ExecRequest.stdin`'s doc. Every `char` a Latin-1-decoded string can contain is U+0000-U+00FF
/// by construction; a value outside that range means the client sent something else, so this
/// rejects rather than silently truncates it.
fn latin1_bytes(text: &str) -> model::Result<Vec<u8>> {
    text.chars()
        .map(|c| u8::try_from(c as u32).map_err(|_| io("stdin is not Latin-1")))
        .collect()
}

fn exec(request: ExecRequest) -> model::Result<Value> {
    let ExecRequest {
        version,
        kind: ExecKind::Exec,
        executable,
        args,
        dir,
        timeout_ms,
        stdin,
        env,
    } = request;
    if version != 1 {
        return Err(VcsError::BackendVersion(
            "unsupported VCS service version".into(),
        ));
    }
    let dir = absolute(&dir)?;
    let timeout = Duration::from_millis(timeout_ms.clamp(1, MAX_EXEC_TIMEOUT_MS));
    let env = filter_exec_env(&env);
    let stdin = stdin.as_deref().map(latin1_bytes).transpose()?;
    let captured = run_exec(
        &dir,
        executable.as_str(),
        &args,
        timeout,
        stdin.as_deref(),
        &env,
    )?;
    Ok(json!({
        "stdout": String::from_utf8_lossy(&captured.stdout),
        "stderr": String::from_utf8_lossy(&captured.stderr),
        "exit_code": captured.exit_code,
        "timed_out": captured.timed_out,
        "signaled": captured.signaled,
    }))
}

fn read(request: Request) -> model::Result<Value> {
    if request.version != 1 {
        return Err(VcsError::BackendVersion(
            "unsupported VCS service version".into(),
        ));
    }
    if request.method == "capabilities" {
        return Ok(json!({"version": 1, "reads": 9, "writes": 8}));
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

    /// Test-side inverse of `latin1_bytes`, standing in for `AgentCommandRunner.swift`'s
    /// `String(data:encoding:.isoLatin1)`.
    fn latin1_string(bytes: &[u8]) -> String {
        bytes.iter().map(|&b| b as char).collect()
    }

    #[test]
    fn latin1_bytes_is_the_exact_inverse_of_latin1_string_for_every_byte_value() {
        let all_bytes: Vec<u8> = (0..=255).collect();
        assert_eq!(latin1_bytes(&latin1_string(&all_bytes)).unwrap(), all_bytes);
    }

    fn git_repo(name: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("wr-vcs-exec-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for args in [
            vec!["init", "-q", "-b", "main"],
            vec!["config", "user.name", "Test"],
            vec!["config", "user.email", "test@example.com"],
        ] {
            assert!(Command::new("git")
                .args(args)
                .current_dir(&root)
                .status()
                .unwrap()
                .success());
        }
        root
    }

    fn exec_request(dir: &Path, executable: &str, args: &[&str]) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "version": 1,
            "kind": "exec",
            "executable": executable,
            "args": args,
            "dir": dir.to_str().unwrap(),
            "timeout_ms": 5000,
        }))
        .unwrap()
    }

    #[test]
    fn exec_runs_a_real_command_and_reports_its_own_output() {
        let root = git_repo("basic");
        let reply = execute(&exec_request(
            &root,
            "git",
            &["rev-parse", "--is-inside-work-tree"],
        ));
        let result = &reply["result"];
        assert_eq!(result["exit_code"], 0);
        assert_eq!(result["timed_out"], false);
        assert_eq!(result["signaled"], false);
        assert!(result["stdout"].as_str().unwrap().trim() == "true");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn exec_captures_a_failing_commands_exit_code_and_stderr() {
        let root = git_repo("failing");
        let reply = execute(&exec_request(
            &root,
            "git",
            &["rev-parse", "--verify", "bogus-ref"],
        ));
        let result = &reply["result"];
        assert_eq!(result["exit_code"], 128);
        assert!(!result["stderr"].as_str().unwrap().is_empty());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn exec_rejects_an_executable_outside_the_git_jj_allowlist() {
        let root = git_repo("disallowed");
        let request = json!({
            "version": 1, "kind": "exec", "executable": "sh", "args": ["-c", "echo hi"],
            "dir": root.to_str().unwrap(), "timeout_ms": 1000,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(reply.get("error").is_some());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn exec_feeds_stdin_to_the_child() {
        let root = git_repo("stdin");
        std::fs::write(root.join("file"), "one\n").unwrap();
        let command = json!({
            "version": 1, "kind": "exec", "executable": "git",
            "args": ["hash-object", "--stdin"], "dir": root.to_str().unwrap(), "timeout_ms": 5000,
            "stdin": latin1_string(b"two\n"),
        });
        let reply = execute(&serde_json::to_vec(&command).unwrap());
        let result = &reply["result"];
        assert_eq!(result["exit_code"], 0);
        // `git hash-object --stdin` prints the SHA of exactly what it read.
        let expected = Command::new("git")
            .args(["hash-object", "--stdin"])
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write as _;
                child.stdin.take().unwrap().write_all(b"two\n")?;
                child.wait_with_output()
            })
            .unwrap();
        assert_eq!(
            result["stdout"].as_str().unwrap().trim(),
            String::from_utf8_lossy(&expected.stdout).trim()
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// `stdin` round-trips via Latin-1 specifically so invalid-UTF-8 bytes (e.g. a raw pathspec
    /// entry from a non-Mac-originated filename) survive the wire exactly — decoding as UTF-8 would
    /// have silently replaced them with U+FFFD, corrupting the commit rather than failing loudly.
    #[test]
    fn exec_stdin_preserves_bytes_that_are_not_valid_utf8() {
        let root = git_repo("stdin-binary");
        let payload: Vec<u8> = vec![0x66, 0x6f, 0x6f, 0xff, 0xfe, 0x00, 0x62, 0x61, 0x72];
        assert!(
            String::from_utf8(payload.clone()).is_err(),
            "fixture must be invalid UTF-8"
        );
        let command = json!({
            "version": 1, "kind": "exec", "executable": "git",
            "args": ["hash-object", "--stdin"], "dir": root.to_str().unwrap(), "timeout_ms": 5000,
            "stdin": latin1_string(&payload),
        });
        let reply = execute(&serde_json::to_vec(&command).unwrap());
        let result = &reply["result"];
        assert_eq!(result["exit_code"], 0);
        let expected = Command::new("git")
            .args(["hash-object", "--stdin"])
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write as _;
                child.stdin.take().unwrap().write_all(&payload)?;
                child.wait_with_output()
            })
            .unwrap();
        assert_eq!(
            result["stdout"].as_str().unwrap().trim(),
            String::from_utf8_lossy(&expected.stdout).trim()
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn exec_times_out_and_kills_a_wedged_process_within_the_sigterm_grace() {
        let root = git_repo("timeout");
        let start = Instant::now();
        let captured = run_exec(
            &root,
            "sleep",
            &["30".into()],
            Duration::from_millis(100),
            None,
            &[],
        )
        .unwrap();
        assert!(captured.timed_out);
        assert!(captured.signaled);
        // SIGTERM at 100ms, grace to 2.1s, SIGKILL — must not run anywhere near the full 30s sleep.
        assert!(start.elapsed() < Duration::from_secs(5));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The one property the whole design leans on (see `ExecRequest`'s doc): a caller that already
    /// holds the JJ snapshot barrier for a gated write must be able to run an exec request against
    /// the SAME repository without the agent trying to take that barrier again. If `exec` ever
    /// acquires `SnapshotLock`, this test hangs for 30s and then fails instead of returning quickly.
    #[test]
    fn exec_never_contends_with_a_held_snapshot_barrier() {
        let root =
            std::env::temp_dir().join(format!("wr-vcs-exec-barrier-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".jj/repo")).unwrap();
        let held = SnapshotLock::acquire(&root, root.to_str()).unwrap();
        let start = Instant::now();
        let reply = execute(&exec_request(&root, "jj", &["--version"]));
        assert!(reply.get("result").is_some(), "exec failed: {reply:?}");
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "exec waited on the snapshot barrier instead of running independently"
        );
        drop(held);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn capabilities_reports_both_read_and_write_counts() {
        let reply = execute(br#"{"version":1,"method":"capabilities"}"#);
        assert_eq!(reply["result"]["reads"], 9);
        assert_eq!(reply["result"]["writes"], 8);
    }

    #[test]
    fn filter_exec_env_drops_everything_outside_the_allowlist() {
        let mut env = std::collections::BTreeMap::new();
        env.insert("SSH_AUTH_SOCK".to_string(), "/tmp/agent.sock".to_string());
        env.insert(
            "WORKROOM_NOT_ALLOWED".to_string(),
            "should-not-pass".to_string(),
        );
        // PATH is allowlisted deliberately (see `ALLOWED_EXEC_ENV_KEYS`'s doc) so an agent-routed
        // write can find a `git`/`jj` install its own long-lived process predates.
        env.insert("PATH".to_string(), "/usr/local/bin:/usr/bin".to_string());
        let filtered = filter_exec_env(&env);
        assert_eq!(
            filtered,
            vec![
                ("PATH", "/usr/local/bin:/usr/bin"),
                ("SSH_AUTH_SOCK", "/tmp/agent.sock")
            ]
        );
    }

    #[test]
    fn run_exec_only_applies_the_env_pairs_it_is_given() {
        // `env` (not in the git/jj allowlist) is used directly via `run_exec`, bypassing `exec`'s
        // executable restriction, specifically to observe what actually reaches the child — the
        // allowlist filter itself is `filter_exec_env`'s job, covered above.
        let root = git_repo("run-exec-env");
        let captured = run_exec(
            &root,
            "env",
            &[],
            Duration::from_secs(5),
            None,
            &[("SSH_AUTH_SOCK", "/tmp/allowed.sock")],
        )
        .unwrap();
        let stdout = String::from_utf8_lossy(&captured.stdout);
        assert!(stdout.contains("SSH_AUTH_SOCK=/tmp/allowed.sock"));
        assert!(!stdout.contains("GIT_DIR="));
        std::fs::remove_dir_all(&root).unwrap();
    }
}
