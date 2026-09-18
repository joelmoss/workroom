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
    Arc, Mutex,
};
use std::time::{Duration, Instant};
use wr_vcs_model::{self as model, VcsError};

const MAX_RESPONSE: usize = 16 * 1024 * 1024;
const MAX_HISTORY_LIMIT: usize = 10000;
/// `CLIVCSWriter.commitTimeout` (Swift) is 600s, the longest legitimate write timeout. Bounds a
/// hostile/buggy request from wedging an exec thread indefinitely; the 32-slot `ACTIVE` permit
/// already bounds concurrency, this bounds duration.
/// The exec service's wire version, reported in `capabilities` so a client can tell a capable agent
/// from one that predates the service. A version, not a count — see the `capabilities` reply.
const EXEC_SERVICE_VERSION: u32 = 1;
const MAX_EXEC_TIMEOUT_MS: u64 = 610_000;
/// The ceiling must stay above `CLIVCSWriter.commitTimeout` (600s), or the transport would cut a
/// legitimate commit short — one with a slow `pre-commit` hook — before its own limit applied, and
/// the failure would read as a transport fault rather than the timeout it is. Checked at COMPILE
/// time: a lowered ceiling is a build error, not a test that someone runs later.
const _: () = assert!(MAX_EXEC_TIMEOUT_MS > 600_000);
/// Per-stream cap, matching `StatusCommandRunner.maxBytes`'s default on the Swift side.
const MAX_EXEC_STREAM: usize = 4 * 1024 * 1024;
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
/// commit/push/pull semantics.
///
/// One untouched classifier is necessary for criterion 2 ("typed failures... match pre-agent
/// behavior exactly") and was not sufficient: a review found it reached OPPOSITE verdicts because
/// the two paths fed it different input. Identical output needs three things, all now true —
/// the child sees the same environment (`env_clear` below), a missing tool exits 127 rather than
/// failing to spawn (`/usr/bin/env`), and a transport failure is not reported as "never ran"
/// (`AgentCommandRunner.outcomeUnknown`). One documented gap remains: an outcome-unknown result is
/// still offered a Retry, because suppressing it needs a new `VCSRemoteFailure` case.
///
/// **Never acquires `SnapshotLock`.** A caller that needs the JJ working-copy barrier for a
/// mutating command already holds it — `CLIVCSWriter`'s `gate: JJSnapshotGate` takes the same
/// `<shared>/.jj/workroom-vcs.lock` flock (`JJProcessBarrier`, shared by name with `SnapshotLock`
/// above) for the whole gated operation before any exec request goes out. Taking it again here
/// would self-deadlock the same actor for 30s and then fail as `LockContention`.
///
/// That argument holds only while the CLIENT's lock outlives this child, which is why
/// `JJSnapshotGate.run` shields the whole gated operation from task cancellation once it holds the
/// flock: unshielded, a cancelled commit returned at once and released it while this `jj commit`
/// kept running, letting another instance or a read-side snapshot enter the supposedly protected
/// operation. Known residual: if the AGENT dies mid-write the gate is released with the child
/// potentially still alive. Native has the same shape on app death. Closing it needs an
/// operation-scoped lock here with release-on-disconnect, which is a protocol change, not a patch.
///
/// **The child's environment is the request's `env`, wholesale** (`env_clear` in `run_exec`), never
/// this daemon's own. wr-agent is "negotiated with, never replaced", so its inherited environment is
/// a snapshot of whichever app launch first spawned it; an agent-routed commit was picking up that
/// snapshot's `GIT_AUTHOR_*`/`GIT_CONFIG_GLOBAL`/`HOME` and authoring under a stale identity. A key
/// allowlist could not fix it — what git and jj read for identity, config, signing and hooks is
/// open-ended — so `StatusCommandRunner.childEnvironment` builds one map for both paths.
///
/// **`args` is unvalidated and the `git`/`jj` `executable` enum is NOT a containment boundary.**
/// `git` with arbitrary argv is arbitrary code execution (`-c alias.x='!…'`, `-c core.hooksPath=…`,
/// `--exec-path`), the request's `PATH` decides which binary resolves, and `GIT_SSH_COMMAND` and the
/// config paths in `env` are further routes. That is acceptable only because the sole transport
/// today is a same-user unix socket, where every reachable caller could already spawn a shell
/// itself. Any transport that is not that — Phase 3's remote relay above all — must authenticate its
/// peer to SHELL grade, not repository grade, before carrying this service.
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
///
/// Publishes into a shared sink rather than returning, so `run_exec` can take what has drained so
/// far WITHOUT joining this thread. That matters because this thread can block forever: a
/// descendant that inherited the pipe (an ssh `ControlPersist` master, a daemonising credential
/// helper, gpg-agent auto-launched by `commit -S`) holds the write end open after the child is
/// reaped, and `setsid` puts it outside the process group `run_exec` signals.
fn drain_capped(mut source: impl Read, cap: usize, sink: &Mutex<Vec<u8>>) {
    let mut chunk = [0u8; 65536];
    loop {
        match source.read(&mut chunk) {
            Ok(0) => return,
            Ok(count) => {
                let mut collected = sink.lock().unwrap_or_else(|e| e.into_inner());
                if collected.len() < cap {
                    let take = (cap - collected.len()).min(count);
                    collected.extend_from_slice(&chunk[..take]);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

/// Direct children of `pid`, via `/usr/bin/pgrep -P` — the exact mechanism (and the exact reasoning)
/// of native's `ProcessTree.childPids`: `proc_listchildpids`' return value is ambiguous across
/// sources (bytes vs count), and mis-reading it would target the wrong pid for a SIGKILL, which is a
/// far worse failure than missing a child. Empty on any error.
fn child_pids(pid: i32) -> Vec<i32> {
    let Ok(output) = Command::new("/usr/bin/pgrep")
        .args(["-P", &pid.to_string()])
        .stderr(Stdio::null())
        .output()
    else {
        return Vec::new();
    };
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .filter_map(|field| field.parse::<i32>().ok())
        .filter(|&child| child > 1)
        .collect()
}

/// Every descendant of `pid`, breadth-first, nearest first. The Rust half of
/// `ProcessTree.descendants`, and split from the killing for a reason that file did not need to
/// face: this must be SNAPSHOTTED WHILE THE PARENT IS STILL ALIVE.
///
/// A descendant that calls `setsid` leaves the process group, so `kill(-pid, …)` never reaches it —
/// but it keeps its real ppid until its parent dies, so `pgrep -P` finds it right up to that moment.
/// Once the parent is reaped the orphan re-parents to init and both handles are gone: the group it
/// left, and a lineage that no longer leads back to us. Walking the tree at KILL time therefore
/// finds nothing, which is the hole native's `killTree` also has — it is called at `timeout + 2`,
/// by which point a `git` that exited on SIGTERM has long been reaped.
///
/// So the walk happens when SIGTERM is sent, and the recorded pids are what gets SIGKILLed later.
fn descendants(pid: i32) -> Vec<i32> {
    let mut collected: Vec<i32> = Vec::new();
    if pid <= 1 {
        return collected;
    }
    let mut seen: Vec<i32> = vec![pid];
    let mut queue = child_pids(pid);
    while !queue.is_empty() {
        let next = queue.remove(0);
        if next <= 1 || seen.contains(&next) {
            continue;
        }
        seen.push(next);
        collected.push(next);
        queue.extend(child_pids(next));
    }
    collected
}

/// SIGKILL the recorded descendants deepest first, so a parent cannot observe a child's death and
/// respawn before it is itself killed — `ProcessTree.killTree`'s ordering, for its reason.
///
/// Carries the same small, unavoidable PID-reuse window native does, and slightly more of it because
/// these pids were read earlier: by the time this runs some may have exited, and a pid could in
/// principle have been reused. Native accepted that trade at `timeout + 2` for the same reason —
/// the alternative is leaving a process running against the user's repository after the call that
/// started it has returned.
fn kill_recorded(descendants: &[i32]) {
    for pid in descendants.iter().rev() {
        unsafe { libc::kill(*pid, libc::SIGKILL) };
    }
}

/// How long to keep trying to reap a process we have SIGKILLed before giving up on it. SIGKILL
/// cannot be caught, so this is generous for the normal case; it exists for the abnormal one, where
/// the leader is unkillable (uninterruptible I/O) and the alternative is blocking this thread — and
/// therefore holding one of the 32 shared `ACTIVE` permits — forever.
const REAP_GRACE: Duration = Duration::from_secs(2);

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
    // `/usr/bin/env <executable>`, byte-for-byte what native does
    // (`StatusCommandRunner.run`: `proc.executableURL = /usr/bin/env`). Not a style choice — it is
    // what makes a MISSING tool exit 127 (`env` ran and searched PATH) instead of failing to spawn.
    // Spawning the program directly made that an Io error, which the client reported as
    // `launchFailed`, the value whose own doc reserves it for "nothing ran" and warns it would
    // "misdiagnose a deleted workroom as a missing git/jj/gh". Mapping `ErrorKind::NotFound` to 127
    // by hand could not fix it either: `posix_spawn` returns ENOENT for a missing cwd AND a missing
    // executable, so the two stay indistinguishable. Letting `env` do the lookup makes 127/126 its
    // real exit codes, and narrows a spawn failure here to the cases that genuinely never ran — a
    // vanished cwd, or `/usr/bin/env` itself being absent.
    let mut command = Command::new("/usr/bin/env");
    command
        .arg(executable)
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
        // `env_clear` first, then adopt the request's map wholesale: the child must see EXACTLY the
        // environment `StatusCommandRunner.childEnvironment` built in the app, never this daemon's
        // own. wr-agent is "negotiated with, never replaced", so its inherited environment is a
        // snapshot of whichever app launch first spawned it — an agent-routed commit was picking up
        // that snapshot's `GIT_AUTHOR_*`/`GIT_CONFIG_GLOBAL`/`HOME` and authoring under a stale
        // identity. A key allowlist could not fix that: what git and jj read for identity, config,
        // signing and hooks is open-ended. That one function also applies this codebase's subprocess
        // baseline (`GIT_OPTIONAL_LOCKS`, `GIT_TERMINAL_PROMPT`, `LC_ALL=C`, and the removal of
        // `GIT_EXTERNAL_DIFF` and the `GIT_DIR` family) so both paths get it from one place.
        .env_clear()
        .envs(env.iter().copied());
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
    let out_sink = Arc::new(Mutex::new(Vec::new()));
    let err_sink = Arc::new(Mutex::new(Vec::new()));
    let out = {
        let sink = Arc::clone(&out_sink);
        std::thread::spawn(move || drain_capped(stdout_pipe, MAX_EXEC_STREAM, &sink))
    };
    let err = {
        let sink = Arc::clone(&err_sink);
        std::thread::spawn(move || drain_capped(stderr_pipe, MAX_EXEC_STREAM, &sink))
    };

    let pid = child.id() as i32;
    let start = Instant::now();
    let mut timed_out = false;
    let mut sent_term = false;
    let mut sent_kill = false;
    let mut killed_at: Option<Instant> = None;
    // Recorded at SIGTERM time, used at SIGKILL time — see `descendants`' doc for why it cannot be
    // walked at the point of the kill.
    let mut recorded: Vec<i32> = Vec::new();
    // `None` ⇒ we killed it and it never became reapable within `REAP_GRACE`. Reported rather than
    // waited on: this used to be `break 'wait child.wait()`, an UNBOUNDED wait, and a child that had
    // left the process group never received the SIGKILL above it, so that wait had nothing to wait
    // for. Codex reproduced 4.1s on a 100ms timeout with one `os.setpgid`.
    let status = 'wait: loop {
        if let Ok(Some(status)) = child.try_wait() {
            break 'wait Some(status);
        }
        let elapsed = start.elapsed();
        if elapsed >= timeout {
            timed_out = true;
            if !sent_term {
                sent_term = true;
                // Snapshot BEFORE signalling: SIGTERM may reap the leader within microseconds, and
                // an orphaned `setsid` descendant is unreachable from that moment on.
                recorded = descendants(pid);
                unsafe { libc::kill(-pid, libc::SIGTERM) };
            } else if elapsed >= timeout + Duration::from_secs(2) {
                if !sent_kill {
                    sent_kill = true;
                    // Recorded tree first, then group: the tree reaches a descendant that left the
                    // group, the group reaches one that spawned after the snapshot.
                    kill_recorded(&recorded);
                    unsafe { libc::kill(-pid, libc::SIGKILL) };
                    killed_at = Some(Instant::now());
                } else if killed_at.is_some_and(|at| at.elapsed() >= REAP_GRACE) {
                    break 'wait None;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    // Two independent jobs, deliberately not fused. Fusing them (escalate only while a reader is
    // still running) let a timed-out descendant survive: if it redirects stdout/stderr, both readers
    // finish, the drain loop exits, and the SIGKILL never fires — leaving it free to keep modifying
    // the repository after this result releases the caller's gate.
    //
    // 1. Timeout escalation. The wait loop above already SIGKILLs when the LEADER outlives the
    //    grace; this covers the leader exiting promptly on SIGTERM while group members do not. The
    //    remaining grace is honoured rather than skipped — `git`/`jj` can exit on SIGTERM while a
    //    hook is still cleaning up, and cutting that short can leave hook-owned locks behind
    //    (`CLIVCSWriter.commitTimeout`: "Killing a commit is categorically more dangerous than
    //    killing a fetch"). Never on a normal exit: killing the group because a reader thread has
    //    not been scheduled yet would kill a hook's legitimate background work, measured at ~1.5% of
    //    successful large-output runs.
    //
    //    Like native's `ProcessTree.killTree` at `timeout + 2`, this signals a pid that has already
    //    been reaped, so it carries the same (small, unavoidable) PID-reuse window. It reaches only
    //    the process group; a descendant that `setsid`s escapes both this and native.
    if timed_out && !sent_kill {
        let kill_at = start + timeout + Duration::from_secs(2);
        while Instant::now() < kill_at {
            std::thread::sleep(Duration::from_millis(10));
        }
        // The recorded set, not a fresh walk: the leader is already reaped on this path, so
        // `pgrep -P` would find nothing — the orphan re-parented to init the moment its parent died.
        // This is the branch the snapshot exists for.
        kill_recorded(&recorded);
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    // 2. Drain bound, mirroring `StatusCommandRunner`'s `_ = drain.wait(timeout: .now() + 2)` and
    //    for the reason its comment gives: a descendant that inherited the pipe can hold the write
    //    end open after the child is reaped, so joining unconditionally would block forever. Forever
    //    is not merely a hung request here — this thread is the one `dispatch` spawned, so its
    //    `Permit` never drops, one of the 32 `ACTIVE` slots shared with every read leaks, and
    //    `is_busy()` stays true so the daemon never idle-exits either. After the deadline we take
    //    what drained and DETACH the readers; each exits on its own when the descendant finally
    //    closes the pipe, writing into a sink nobody reads. That costs a thread and up to 4 MiB per
    //    occurrence, which is bounded per call and vastly better than leaking a permit.
    let drained_by = Instant::now() + Duration::from_secs(2);
    while !(out.is_finished() && err.is_finished()) && Instant::now() < drained_by {
        std::thread::sleep(Duration::from_millis(10));
    }
    let take = |sink: &Mutex<Vec<u8>>| {
        std::mem::take(&mut *sink.lock().unwrap_or_else(|e| e.into_inner()))
    };
    // Unreapable after SIGKILL: report what a killed process reports rather than blocking on it.
    // `timed_out` is already true on this path (nothing else reaches it), so the client classifies
    // this as `VCSRemoteFailure.timedOut` exactly as it would a child we did manage to reap — the
    // outcome is the same fact, and the ONLY difference is whether this thread waited forever to
    // state it. Deliberately not `outcomeUnknown`: we know what happened to this command.
    //
    // The handle is moved to a detached thread rather than dropped: Rust's `Child::drop` does not
    // wait, so dropping it here would leave a zombie nothing ever reaps. Mirrors the drain detach
    // below — one parked thread that ends whenever the process finally does.
    let Some(status) = status else {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        return Ok(Captured {
            stdout: take(&out_sink),
            stderr: take(&err_sink),
            exit_code: 137,
            timed_out: true,
            signaled: true,
        });
    };
    Ok(Captured {
        stdout: take(&out_sink),
        stderr: take(&err_sink),
        // Never -1: that value IS `CommandResult.launchFailed` in Swift ("nothing ran"), and a
        // process that got this far demonstrably ran. `code()` is None only when signaled, and a
        // signaled status always carries a signal number, so the fallback is unreachable — pinned
        // to 128+SIGKILL (the shell's own convention) rather than to a Swift sentinel.
        exit_code: status
            .code()
            .unwrap_or_else(|| status.signal().unwrap_or(137)),
        timed_out,
        signaled: status.signal().is_some(),
    })
}

/// Headroom left for everything in an exec reply that is not the two captured streams: the keys,
/// the exit code, the two booleans, the envelope framing, and JSON's own punctuation. Generous on
/// purpose — the cost of over-reserving is a few KiB of output, the cost of under-reserving is the
/// whole reply being replaced by an error.
const EXEC_REPLY_RESERVE: usize = 64 * 1024;

/// How many bytes this text costs once JSON-escaped, which is what `MAX_RESPONSE` actually bounds.
///
/// The expansion is why the two caps could not both be satisfied: a control byte serializes as
/// `\u0001`, six bytes for one, so two streams at `MAX_EXEC_STREAM` (4 MiB each) reach 48 MiB of
/// wire form against a 16 MiB ceiling. Codex reproduced it with 3 MiB of `0x01`.
fn escaped_len(text: &str) -> usize {
    text.chars()
        .map(|c| match c {
            '"' | '\\' | '\n' | '\r' | '\t' => 2,
            c if (c as u32) < 0x20 => 6,
            c => c.len_utf8(),
        })
        .sum()
}

/// The longest prefix of `text` whose escaped form fits `budget`, cut on a character boundary.
///
/// Head rather than tail, matching `drain_capped` and native's `StatusCommandRunner.readCapped`:
/// git and jj put the line that classifies a failure first, and a tail-truncated stderr would lose
/// it. Silent, also matching those two — the markers `CLIVCSWriter.classify` matches live in this
/// text, so injecting a "truncated" notice here could only create a false positive.
fn truncate_to_escaped_budget(text: &str, budget: usize) -> &str {
    let mut used = 0;
    for (index, c) in text.char_indices() {
        let cost = match c {
            '"' | '\\' | '\n' | '\r' | '\t' => 2,
            c if (c as u32) < 0x20 => 6,
            c => c.len_utf8(),
        };
        if used + cost > budget {
            return &text[..index];
        }
        used += cost;
    }
    text
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
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let stdin = stdin.as_deref().map(latin1_bytes).transpose()?;
    let captured = run_exec(
        &dir,
        executable.as_str(),
        &args,
        timeout,
        stdin.as_deref(),
        &env,
    )?;
    let stdout = String::from_utf8_lossy(&captured.stdout);
    let stderr = String::from_utf8_lossy(&captured.stderr);
    // Truncate HERE rather than letting `send` refuse the reply. `send`'s blanket
    // `PartialData` replacement is right for a read — half a history is not a history — but for an
    // exec it threw away the exit status of a command that ran to completion, reporting a known
    // outcome as an unknown one. Native truncates the output and still classifies; so does this.
    //
    // stderr gets first call on the budget: it is what `CLIVCSWriter.classify` matches on, so losing
    // it turns a diagnosable failure into `.other` with git's own words missing. stdout takes the
    // slack, which in practice is nearly all of it — stderr is tiny on every ordinary command.
    let budget = MAX_RESPONSE - EXEC_REPLY_RESERVE;
    let (stdout, stderr) = if escaped_len(&stdout) + escaped_len(&stderr) > budget {
        let err_budget = escaped_len(&stderr).min(budget / 2);
        (
            truncate_to_escaped_budget(&stdout, budget - err_budget),
            truncate_to_escaped_budget(&stderr, err_budget),
        )
    } else {
        (stdout.as_ref(), stderr.as_ref())
    };
    Ok(json!({
        "stdout": stdout,
        "stderr": stderr,
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
        // `exec` is the exec service's own version, NOT a method count. The count it replaced
        // (`writes: 8`) described a CLIENT-side Swift protocol: wr-agent implements one generic
        // exec service and has never had eight write methods to report. Nothing here could keep
        // that number true, and the client compared it for equality — so adding a ninth method to
        // that Swift protocol, a change this side fully supports, silently dropped every user to
        // native writes with no log line.
        //
        // The highest version this agent speaks. `exec` rejects anything but 1 today; a future
        // version bumps this and decides then whether it still accepts 1.
        return Ok(json!({"version": 1, "reads": 9, "exec": EXEC_SERVICE_VERSION}));
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
    fn capabilities_reports_the_read_count_and_the_exec_service_version() {
        let reply = execute(br#"{"version":1,"method":"capabilities"}"#);
        assert_eq!(reply["result"]["reads"], 9);
        // A VERSION, not a count of anything. The client requires `>=` its own, so this must never
        // become a number that describes the caller's side — that was the defect it replaced.
        assert_eq!(reply["result"]["exec"], EXEC_SERVICE_VERSION);
        assert!(
            reply["result"].get("writes").is_none(),
            "the method count is gone; nothing here could keep it true"
        );
    }

    /// The child's environment is EXACTLY the request's map — nothing of the daemon's own leaks
    /// through. This is the property that keeps an agent-routed commit from being authored under
    /// the stale identity of whichever app launch first spawned this daemon; a key allowlist could
    /// not provide it, because what git and jj read for identity, config, signing and hooks is
    /// open-ended. `env` (not in the git/jj allowlist) goes through `run_exec` directly, bypassing
    /// `exec`'s executable restriction, specifically to observe what reaches the child.
    #[test]
    fn run_exec_replaces_the_daemons_environment_with_the_requests() {
        std::env::set_var("WORKROOM_DAEMON_ONLY", "stale-daemon-value");
        let root = git_repo("run-exec-env");
        let captured = run_exec(
            &root,
            "env",
            &[],
            Duration::from_secs(5),
            None,
            &[
                ("PATH", "/usr/local/bin:/usr/bin:/bin"),
                ("SSH_AUTH_SOCK", "/tmp/allowed.sock"),
                ("GIT_AUTHOR_EMAIL", "fresh@example.com"),
            ],
        )
        .unwrap();
        let stdout = String::from_utf8_lossy(&captured.stdout);
        assert!(stdout.contains("SSH_AUTH_SOCK=/tmp/allowed.sock"));
        assert!(stdout.contains("GIT_AUTHOR_EMAIL=fresh@example.com"));
        // The daemon's own environment must not reach the child at all.
        assert!(!stdout.contains("WORKROOM_DAEMON_ONLY"));
        std::env::remove_var("WORKROOM_DAEMON_ONLY");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The regression that motivated bounding the drain: a child that exits promptly while leaving
    /// a BACKGROUND descendant holding its stdout must not hold the exec thread (and with it one of
    /// the 32 `ACTIVE` permits) for the descendant's lifetime. Before the bound, this returned in
    /// ~4s instead of ~0s, and each occurrence leaked a permit permanently.
    #[test]
    fn exec_does_not_wait_on_a_descendant_that_outlives_the_child() {
        let root = git_repo("run-exec-straggler");
        let started = Instant::now();
        let captured = run_exec(
            &root,
            "sh",
            &["-c".to_string(), "sleep 5 & echo done; exit 0".to_string()],
            Duration::from_secs(30),
            None,
            &[("PATH", "/usr/bin:/bin")],
        )
        .unwrap();
        let elapsed = started.elapsed();
        assert_eq!(captured.exit_code, 0);
        assert!(!captured.timed_out);
        assert!(String::from_utf8_lossy(&captured.stdout).contains("done"));
        assert!(
            elapsed < Duration::from_secs(4),
            "run_exec waited {elapsed:?} on a background descendant"
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Native spawns `/usr/bin/env git`, so a missing tool exits 127 and `CLIVCSWriter.classify`
    /// answers `.toolMissing`. Spawning the program directly used to raise an Io error instead,
    /// which the client reported as `launchFailed` — the value whose own doc reserves it for
    /// "nothing ran" and warns it would "misdiagnose a deleted workroom as a missing git/jj/gh".
    #[test]
    fn exec_reports_a_missing_tool_as_127_not_a_service_error() {
        let root = git_repo("run-exec-missing");
        let empty = root.join("empty-bin");
        std::fs::create_dir_all(&empty).unwrap();
        let captured = run_exec(
            &root,
            "git",
            &["status".to_string()],
            Duration::from_secs(5),
            None,
            &[("PATH", empty.to_str().unwrap())],
        )
        .unwrap();
        assert_eq!(captured.exit_code, 127);
        assert!(!captured.signaled);
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A vanished working directory stays a service error — that IS "nothing ran", and conflating
    /// it with 127 is the mirror of the bug above.
    #[test]
    fn exec_reports_a_vanished_directory_as_an_error_not_127() {
        let root = git_repo("run-exec-gone");
        let missing = root.join("not-there");
        let failed = run_exec(
            &missing,
            "git",
            &["status".to_string()],
            Duration::from_secs(5),
            None,
            &[("PATH", "/usr/bin:/bin")],
        );
        assert!(failed.is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The clamp is the only thing between a client's `timeout_ms` and a thread that waits on it,
    /// and both ends of it matter: 0 would make every command time out before it started, and an
    /// unbounded value would park an `ACTIVE` permit for as long as the caller asked. Asserted
    /// through the clamp expression `exec` actually uses, so a changed bound fails here.
    #[test]
    fn the_exec_timeout_clamp_holds_at_both_ends() {
        let clamp = |ms: u64| Duration::from_millis(ms.clamp(1, MAX_EXEC_TIMEOUT_MS));
        // Zero is raised to 1ms, never passed through: a 0ms deadline kills the child immediately.
        assert_eq!(clamp(0), Duration::from_millis(1));
        assert_eq!(clamp(1), Duration::from_millis(1));
        assert_eq!(clamp(u64::MAX), Duration::from_millis(MAX_EXEC_TIMEOUT_MS));
        assert_eq!(
            clamp(MAX_EXEC_TIMEOUT_MS + 1),
            Duration::from_millis(MAX_EXEC_TIMEOUT_MS)
        );
        // In range, it is the caller's value untouched.
        assert_eq!(clamp(5_000), Duration::from_millis(5_000));
    }

    /// The exec envelope carries its OWN version, and it is checked before anything is spawned. The
    /// read path's guard is covered by `version_and_path_errors_are_explicit`; this is the write
    /// path's, and it has to fail as `BackendVersion` specifically — `RepositoryRouter` keys its
    /// fall-back-to-native decision on that case, so any other error would strand the user instead.
    #[test]
    fn an_exec_request_with_an_unsupported_version_is_refused_before_spawning() {
        let root = git_repo("exec-version");
        let request = json!({
            "version": 2,
            "kind": "exec",
            "executable": "git",
            // A command with an observable side effect: if the guard ever moves after the spawn,
            // this file appears and the assertion below catches it.
            "args": ["init", "-q", "spawned-anyway"],
            "dir": root.to_str().unwrap(),
            "timeout_ms": 5000,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(
            reply["error"]["BackendVersion"].as_str().is_some(),
            "expected BackendVersion, got {reply}"
        );
        assert!(
            !root.join("spawned-anyway").exists(),
            "the child ran anyway"
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Two separate properties, and the second is the one that matters. The cap bounds what is
    /// KEPT; the loop must go on reading past it, because the child writes into a pipe whose buffer
    /// is ~64 KiB — stop reading and the child blocks on write forever, which is a hang, not a
    /// truncation. `StatusCommandRunner.readCapped` has the same shape for the same reason.
    #[test]
    fn drain_capped_bounds_what_it_keeps_and_still_reads_to_eof() {
        // A source larger than the cap AND larger than any pipe buffer.
        let cap = 1024;
        let source = vec![b'x'; 256 * 1024];
        let sink = Mutex::new(Vec::new());
        drain_capped(source.as_slice(), cap, &sink);
        assert_eq!(sink.lock().unwrap().len(), cap, "the cap did not hold");

        // Drained to EOF through a REAL pipe, which is where refusing to read past the cap would
        // deadlock rather than merely truncate. The writer completes only if the reader kept going.
        let (reader, mut writer) = std::io::pipe().unwrap();
        let payload = vec![b'y'; 512 * 1024];
        let expected = payload.len();
        let pump = std::thread::spawn(move || {
            std::io::Write::write_all(&mut writer, &payload).unwrap();
            expected
        });
        let piped = Mutex::new(Vec::new());
        drain_capped(reader, cap, &piped);
        assert_eq!(
            pump.join().unwrap(),
            expected,
            "the writer never finished, so the reader stopped short of EOF"
        );
        assert_eq!(piped.lock().unwrap().len(), cap);
    }

    /// The rejection branch, which the round-trip test above cannot reach: every byte 0x00-0xFF is
    /// representable, so only a client that sent something OTHER than a Latin-1-decoded string gets
    /// here. Refusing is the point — truncating a pathspec payload would stage the wrong files.
    #[test]
    fn latin1_bytes_rejects_a_character_outside_the_byte_range() {
        for text in ["\u{0100}", "é\u{20AC}", "ok-then-\u{1F600}"] {
            assert!(
                latin1_bytes(text).is_err(),
                "accepted a non-Latin-1 payload: {text:?}"
            );
        }
        // The boundary either side, to pin where the rejection starts.
        assert!(latin1_bytes("\u{00FF}").is_ok());
        assert!(latin1_bytes("\u{0100}").is_err());
    }

    /// The gap against native, which `ProcessTree.killTree` has covered since it was written ("helpers
    /// spawned by git/gh can outlive the parent") and the agent did not: a DESCENDANT that calls
    /// `setsid` leaves the process group, so `kill(-pid, …)` never reaches it. It then goes on
    /// running — and, if it inherited the pipes, holding this request's readers open — after the
    /// result has released the caller's gate.
    ///
    /// The leader itself cannot escape: `run_exec` sets `process_group(0)`, which makes it a group
    /// leader, and `setsid` is EPERM for a group leader. So the descendant is the whole of the gap,
    /// and asserting the leader's timing would prove nothing.
    ///
    /// ENVIRONMENT: needs a real process table. Under a sandbox that hides other processes, `pgrep`
    /// returns nothing, the snapshot comes back empty and this fails in a way indistinguishable from
    /// the bug — measured, not guessed. If it fails, check `descendants()` sees anything at all
    /// before believing the kill path is broken.
    #[test]
    fn exec_kills_a_descendant_that_escaped_the_process_group() {
        let root = git_repo("setsid-escape");
        let marker = root.join("still-alive");
        // The grandchild leaves the group, waits out the whole escalation, and only THEN writes.
        // If it is still alive at that point the marker appears, which is the failure this catches.
        let program = format!(
            "import os,sys,time\n\
             if os.fork() == 0:\n\
             \x20   os.setsid()\n\
             \x20   time.sleep(6)\n\
             \x20   open({:?}, 'w').close()\n\
             \x20   sys.exit(0)\n\
             time.sleep(30)\n",
            marker.to_str().unwrap()
        );
        let captured = run_exec(
            &root,
            "python3",
            &["-c".into(), program],
            // Not 100ms: python's own start-up is ~50ms and the fork follows it, so a tighter
            // deadline races the grandchild into existence and the snapshot finds an empty tree —
            // which looks exactly like the bug this asserts against.
            Duration::from_millis(1500),
            None,
            &[("PATH", "/usr/bin:/bin")],
        )
        .unwrap();
        assert!(captured.timed_out, "the timeout was not reported");

        // Past the grandchild's own sleep, so its write would have happened by now if it survived.
        std::thread::sleep(Duration::from_secs(6));
        assert!(
            !marker.exists(),
            "a setsid descendant outlived the kill and kept running"
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// `descendants` walks parsed `pgrep` output, so it must terminate on shapes a process table
    /// cannot produce but a parse can — and it must never reach init. A SIGKILL aimed at pid 1 is
    /// the worst outcome a bug here could have, so the floor is enforced by value.
    #[test]
    fn the_descendant_walk_refuses_init_and_terminates() {
        assert!(descendants(0).is_empty());
        assert!(descendants(1).is_empty());
        assert!(descendants(-1).is_empty());
        // An impossible pid has no children, so the walk ends immediately rather than looping.
        assert!(
            child_pids(i32::MAX).is_empty(),
            "pgrep invented children for an impossible pid"
        );
        assert!(descendants(i32::MAX).is_empty());
        // Killing an empty set is a no-op, not a signal to the current process group.
        kill_recorded(&[]);
    }

    /// The two caps could not both be satisfied: `MAX_EXEC_STREAM` allows 4 MiB per stream, and a
    /// control byte JSON-escapes to six, so two full streams reach 48 MiB against `MAX_RESPONSE`'s
    /// 16 MiB ceiling. `send` then replaced the WHOLE reply with `PartialData` — discarding the exit
    /// status of a command that ran to completion and reporting a known outcome as an unknown one.
    ///
    /// Codex's repro, 3 MiB of `0x01`.
    #[test]
    fn a_huge_control_heavy_reply_keeps_its_exit_status() {
        let root = git_repo("huge-output");
        // 3 MiB of 0x01 on stdout, then a non-zero exit — the two facts that must both survive.
        let program = "import sys; sys.stdout.write('\\x01' * (3 * 1024 * 1024)); sys.exit(3)";
        // `run_exec` directly rather than `execute`: the executable allowlist is git/jj only, and
        // neither will emit 3 MiB of control bytes on demand. The reply's wire size is then asserted
        // against the same budget `exec` applies, which is the contract under test.
        let captured = run_exec(
            &root,
            "python3",
            &["-c".into(), program.into()],
            Duration::from_secs(30),
            None,
            &[("PATH", "/usr/bin:/bin")],
        )
        .unwrap();
        assert_eq!(captured.exit_code, 3, "the child's own exit code was lost");
        assert_eq!(captured.stdout.len(), 3 * 1024 * 1024);

        // The reply `exec` would build for that capture must fit the wire ceiling, so `send` never
        // reaches its blanket replacement.
        let stdout = String::from_utf8_lossy(&captured.stdout);
        let stderr = String::from_utf8_lossy(&captured.stderr);
        let budget = MAX_RESPONSE - EXEC_REPLY_RESERVE;
        assert!(
            escaped_len(&stdout) > budget,
            "the fixture no longer exceeds the budget, so this proves nothing"
        );
        let err_budget = escaped_len(&stderr).min(budget / 2);
        let kept = truncate_to_escaped_budget(&stdout, budget - err_budget);
        let reply = json!({
            "version": 1,
            "result": {
                "stdout": kept,
                "stderr": truncate_to_escaped_budget(&stderr, err_budget),
                "exit_code": captured.exit_code,
                "timed_out": captured.timed_out,
                "signaled": captured.signaled,
            }
        });
        let wire = serde_json::to_vec(&reply).unwrap();
        assert!(
            wire.len() <= MAX_RESPONSE,
            "reply is {} bytes, over the {MAX_RESPONSE} ceiling",
            wire.len()
        );
        // Truncated, not emptied: the user still gets everything that fits.
        assert!(!kept.is_empty(), "truncation threw the whole stream away");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// The budget accounting itself, away from multi-MiB fixtures.
    #[test]
    fn escaped_length_and_truncation_agree_on_the_expansion() {
        // A control byte costs six on the wire, a quote two, plain ASCII one.
        assert_eq!(escaped_len("\u{0001}"), 6);
        assert_eq!(escaped_len("\""), 2);
        assert_eq!(escaped_len("\n"), 2);
        assert_eq!(escaped_len("abc"), 3);
        // And that is what serde actually produces, minus the two surrounding quotes.
        for sample in ["\u{0001}\u{0002}", "a\"b\\c", "plain", "tab\there", "é"] {
            assert_eq!(
                escaped_len(sample),
                serde_json::to_string(sample).unwrap().len() - 2,
                "escaped_len disagrees with serde for {sample:?}"
            );
        }

        // Truncation never exceeds the budget and never splits a character.
        assert_eq!(
            truncate_to_escaped_budget("\u{0001}\u{0001}", 6),
            "\u{0001}"
        );
        assert_eq!(truncate_to_escaped_budget("\u{0001}", 5), "");
        assert_eq!(truncate_to_escaped_budget("abc", 99), "abc");
        // A multi-byte character is kept whole or dropped whole — a split would panic on the slice.
        assert_eq!(truncate_to_escaped_budget("é", 1), "");
        assert_eq!(truncate_to_escaped_budget("aé", 2), "a");
    }
}
