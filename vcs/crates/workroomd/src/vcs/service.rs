//! Versioned VCS requests over Service::Vcs. Capability negotiation is separate from the terminal
//! greeting. Each nonzero stream is one request. Reply JSON is chunked; the first payload byte is
//! 0 for continuation, 1 for final. Maximum assembled reply is 16MiB. Requests are never replayed.
use crate::daemon::rpc::{MAX_RESPONSE, PartialRequests, Permit, SharedWriter, reassemble, send};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    Arc, Mutex, OnceLock,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};
use wr_protocol::envelope::{Envelope, Service};
use wr_protocol::reply::Reply;
use wr_vcs_model::{self as model, VcsError};

const MAX_HISTORY_LIMIT: usize = 10000;
/// The exec service's wire version, reported in `capabilities` so a client can tell a capable daemon
/// from one that predates the service. A version, not a count — see the `capabilities` reply.
///
/// 3 added what a REMOTE host's writes need (#229): `host_environment`, `barrier_root` (since
/// ignored), and the `stat` request. 2 added chunked request reassembly; 1 accepted only
/// single-envelope requests.
const EXEC_SERVICE_VERSION: u32 = 3;
/// `CLIVCSWriter.commitTimeout` (Swift) is 600s, the longest legitimate write timeout. Bounds a
/// hostile/buggy request from wedging an exec thread indefinitely; the 32-slot `ACTIVE` permit
/// already bounds concurrency, this bounds duration.
const MAX_EXEC_TIMEOUT_MS: u64 = 610_000;
/// The ceiling must stay above `CLIVCSWriter.commitTimeout` (600s), or the transport would cut a
/// legitimate commit short — one with a slow `pre-commit` hook — before its own limit applied, and
/// the failure would read as a transport fault rather than the timeout it is. Checked at COMPILE
/// time: a lowered ceiling is a build error, not a test that someone runs later.
const _: () = assert!(MAX_EXEC_TIMEOUT_MS > 600_000);
/// Per-stream cap, matching `StatusCommandRunner.maxBytes`'s default on the Swift side.
const MAX_EXEC_STREAM: usize = 4 * 1024 * 1024;

/// Remote requests use this host's login environment, never the Mac's. Read it at the first remote
/// exec and keep it for this daemon's lifetime; concurrent requests share one bounded probe. Local
/// requests still use their supplied environment without reading a login profile.
static HOST_LOGIN_ENVIRONMENT: OnceLock<BTreeMap<String, String>> = OnceLock::new();
/// The serve command chooses this once, before any request threads start. Workroom's remote
/// daemons use `--idle-timeout never`; the Mac's local daemon uses the default idle lifetime and
/// keeps the environment the app supplied when it spawned it.
static READS_LOGIN_ENVIRONMENT: OnceLock<bool> = OnceLock::new();

pub(crate) fn configure_read_environment(remote: bool) {
    let _ = READS_LOGIN_ENVIRONMENT.set(remote);
}

fn cached_login_environment<'a>(
    cache: &'a OnceLock<BTreeMap<String, String>>,
    shell: &str,
    timeout: Duration,
) -> &'a BTreeMap<String, String> {
    cache.get_or_init(|| {
        // Home, never a clone: this runs unattended, for reads of directories nobody has trusted.
        let home = std::env::var_os("HOME").unwrap_or_else(|| "/".into());
        crate::cli::run_script::login_environment(shell, Path::new(&home), timeout, |reason| {
            crate::note!(
                "remote git: couldn't read the login shell's environment ({reason}); using the daemon's own"
            );
        })
    })
}

fn login_environment() -> &'static BTreeMap<String, String> {
    let shell = crate::terminal::shell::user_shell(std::env::var_os("SHELL"));
    cached_login_environment(
        &HOST_LOGIN_ENVIRONMENT,
        &shell,
        crate::cli::run_script::PROBE_TIMEOUT,
    )
}

/// Read-side git children (diffs and the File service's listing) use the cached profile on a remote
/// daemon, and the app-supplied inherited environment on a local one. Both keep the existing scrub
/// and pins, without changing the daemon's own process environment. Local exec requests still use
/// their explicit client environment; remote exec requests explicitly select the login profile.
pub(crate) fn host_read_environment() -> BTreeMap<String, String> {
    if !READS_LOGIN_ENVIRONMENT.get().copied().unwrap_or(false) {
        return scrubbed_environment(std::env::vars_os())
            .into_iter()
            .collect();
    }
    host_environment(
        login_environment()
            .iter()
            .map(|(key, value)| (key.into(), value.into())),
        BTreeMap::new(),
    )
}

/// `file::listing_environment` over an explicit variable set, so the scrub and the pins can be tested
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    version: u32,
    #[serde(default)]
    root: Option<String>,
    /// Accepted and ignored: the app still sends a repository's shared root, which only the
    /// removed jj backend read.
    ///
    /// ponytail: kept only so `deny_unknown_fields` does not reject the app's request. Prune
    /// once a protocol gate or a stable hand-off covers app/daemon skew (see TODOS.md).
    #[serde(default, rename = "shared_root")]
    _shared_root: Option<String>,
    /// Must still be present on a read, as before. Only `git` is a backend now: a request naming
    /// `jj` fails to deserialize and is answered with the per-request error reply.
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

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Backend {
    Git,
}

/// A write command, run to completion and reported back raw — argv, cwd, stdin and timeout in;
/// exit code, stdout, stderr, `timed_out`, `signaled` out. Every request-building, output-parsing
/// and failure-classification decision (`CLIVCSWriter.classify`/`.classifyCommit`, the pathspec
/// and refspec injection defenses, the retry/abort taxonomy) stays in Swift and sees exactly the
/// bytes it would see from a local `git` — this is deliberately NOT a reimplementation of
/// commit/push/pull semantics.
///
/// One untouched classifier is necessary for criterion 2 ("typed failures... match pre-daemon
/// behavior exactly") and was not sufficient: a review found it reached OPPOSITE verdicts because
/// the two paths fed it different input. Identical output needs three things, all now true —
/// the child sees the same environment (`env_clear` below), a missing tool exits 127 rather than
/// failing to spawn (`/usr/bin/env`), and a transport failure is not reported as "never ran"
/// (`DaemonCommandRunner.outcomeUnknown`). An outcome-unknown result is its own
/// `VCSRemoteFailure`/`VCSCommitFailure` case, and its recovery follows idempotence
/// (`VCSSyncPresenter.retryAction`): a lost push or pull offers `.fetch`, which resolves the doubt,
/// a lost fetch or rebase abort offers itself, and a lost commit offers no action at all.
///
/// **The child's environment is the request's `env`, wholesale** (`env_clear` in `run_exec`), never
/// this daemon's own. workroomd is "negotiated with, never replaced", so its inherited environment is
/// a snapshot of whichever app launch first spawned it; a daemon-routed commit was picking up that
/// snapshot's `GIT_AUTHOR_*`/`GIT_CONFIG_GLOBAL`/`HOME` and authoring under a stale identity. A key
/// allowlist could not fix it — what git reads for identity, config, signing and hooks is
/// open-ended — so `StatusCommandRunner.childEnvironment` builds one map for both paths.
///
/// **`args` is unvalidated and the `git` `executable` enum is NOT a containment boundary.**
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
    /// total bijection over every byte 0x00-0xFF, so `DaemonCommandRunner.swift`'s
    /// `String(data:encoding:.isoLatin1)` never fails and `latin1_bytes` below is its exact inverse
    /// — every byte round-trips, at roughly the original size for ordinary text.
    #[serde(default)]
    stdin: Option<String>,
    #[serde(default)]
    env: std::collections::BTreeMap<String, String>,
    /// Set by the app for a REMOTE host (#229): `env` is then only policy pins, and the child's
    /// environment is built from the host's cached login environment (`host_environment`). The
    /// app sends nothing from the Mac there: its `HOME` and `PATH` name nothing on this machine, and
    /// its `SSH_AUTH_SOCK` and git identity are the user's Mac credentials.
    #[serde(default)]
    host_environment: bool,
    /// Accepted and ignored: an older app names the shared root of a jj repository whose
    /// working-copy barrier the daemon should hold across the command. There is no barrier now.
    ///
    /// ponytail: kept only so `deny_unknown_fields` does not reject an older app's request. Prune
    /// once a protocol gate or a stable hand-off covers app/daemon skew (see TODOS.md).
    #[serde(default, rename = "barrier_root")]
    _barrier_root: Option<String>,
}

/// The child environment for a remote host: its cached login environment, with the file
/// service's scrub and pins (`scrubbed_environment`, so the two host-side paths agree), no graphical
/// prompt helper, and the request's pins on top.
///
/// ssh is kept from prompting WITHOUT setting `GIT_SSH_COMMAND`, which would outrank a repository's
/// own `core.sshCommand`, the usual home of a deploy key, and so replace the host's ssh for every
/// repository on it. It cannot prompt anyway: `SSH_ASKPASS_REQUIRE=never` rules out a helper, and a
/// supervised daemon has no terminal for one. A `GIT_SSH_COMMAND` the host sets itself is kept and
/// gets `BatchMode`, as the app does locally (`StatusCommandRunner.networkEnvironment`).
///
/// Built from `vars_os`, not `vars`, which panics on one variable that is not UTF-8 and would take
/// the exec thread down before it replied.
fn host_environment(
    own: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
    pins: std::collections::BTreeMap<String, String>,
) -> std::collections::BTreeMap<String, String> {
    let mut env: std::collections::BTreeMap<String, String> =
        scrubbed_environment(own).into_iter().collect();
    env.remove("SSH_ASKPASS");
    env.remove("DISPLAY");
    env.extend(pins);
    if let Some(ssh) = env
        .get("GIT_SSH_COMMAND")
        .map(|command| command.trim().to_string())
        .filter(|command| !command.is_empty())
    {
        env.insert("GIT_SSH_COMMAND".into(), format!("{ssh} -o BatchMode=yes"));
    }
    env.insert("SSH_ASKPASS_REQUIRE".into(), "never".into());
    env
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ExecKind {
    Exec,
}

/// Filesystem facts for the app's write-failure classifier (`CLIVCSWriter`), which reads a
/// repository's git directory to tell a parked rebase, a leftover lock file or the last fetch. On a
/// remote host that directory is here, so the app asks for the facts and keeps every decision on
/// its own side (#229): one classifier, fed the same facts either way. Added with exec version 3.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StatRequest {
    version: u32,
    kind: StatKind,
    /// Absolute paths. What exists there, whether it is a directory, and when it was modified.
    paths: Vec<String>,
    /// Paths among `paths` whose text to return as well, when a small regular file: a worktree's
    /// `.git` is a file that names its git directory.
    #[serde(default)]
    read: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum StatKind {
    Stat,
}

/// Far more than the dozen paths one classification asks about, and small enough that a request
/// cannot turn this into a filesystem walk.
const MAX_STAT_PATHS: usize = 64;
/// A worktree's `.git` file is one line.
const MAX_STAT_TEXT: u64 = 4096;

fn stat(request: StatRequest) -> model::Result<Value> {
    let StatRequest {
        version,
        kind: StatKind::Stat,
        paths,
        read,
    } = request;
    if version != 1 {
        return Err(VcsError::BackendVersion(
            "unsupported VCS service version".into(),
        ));
    }
    if paths.len() > MAX_STAT_PATHS {
        return Err(io("too many paths in one stat request"));
    }
    let entries = paths
        .iter()
        .map(|path| {
            // One path this cannot take (relative, or with a `..` from an unstandardized `gitdir:`
            // or a hook's message) reads as absent, as a missing file would, rather than failing the
            // whole request and taking every other fact with it.
            let Ok(target) = absolute(path) else {
                return Ok(json!({ "path": path, "exists": false, "is_dir": false,
                                  "modified_at": null, "text": null }));
            };
            // Follows links, as `FileManager.fileExists` does for the same question in the app.
            let metadata = std::fs::metadata(&target).ok();
            let text = metadata
                .as_ref()
                .filter(|m| read.contains(path) && m.is_file() && m.len() <= MAX_STAT_TEXT)
                .and_then(|_| std::fs::read_to_string(&target).ok());
            let modified = metadata
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|since| since.as_secs_f64());
            Ok(json!({
                "path": path,
                "exists": metadata.is_some(),
                "is_dir": metadata.as_ref().is_some_and(|m| m.is_dir()),
                "modified_at": modified,
                "text": text,
            }))
        })
        .collect::<model::Result<Vec<Value>>>()?;
    Ok(json!({ "entries": entries }))
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Executable {
    Git,
}
impl Executable {
    fn as_str(self) -> &'static str {
        match self {
            Executable::Git => "git",
        }
    }
}

pub(crate) fn io(error: impl std::fmt::Display) -> VcsError {
    VcsError::Io(error.to_string())
}
fn required(value: &Option<String>) -> model::Result<&str> {
    value
        .as_deref()
        .ok_or_else(|| io("missing request parameter"))
}
pub(crate) fn absolute(value: &str) -> model::Result<PathBuf> {
    if !value.starts_with('/')
        || value.contains('\0')
        || value.split('/').any(|s| s == "." || s == "..")
    {
        return Err(io("invalid absolute repository path"));
    }
    Ok(PathBuf::from(value))
}
pub(crate) fn relative(value: &str) -> model::Result<&str> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains('\0')
        || value.split('/').any(|s| s == "." || s == "..")
    {
        return Err(io("invalid relative file path"));
    }
    Ok(value)
}

pub fn execute(bytes: &[u8]) -> Value {
    // `kind` distinguishes an exec request from the existing read `Request`; its absence (every
    // read request in the wild, and every request before this field existed) means "read", so the
    // wire format already spoken by `DaemonVCSReader` is untouched.
    let result = serde_json::from_slice::<Value>(bytes)
        .map_err(io)
        .and_then(|value| match value.get("kind").and_then(Value::as_str) {
            Some("exec") => serde_json::from_value::<ExecRequest>(value)
                .map_err(io)
                .and_then(exec),
            Some("stat") => serde_json::from_value::<StatRequest>(value)
                .map_err(io)
                .and_then(stat),
            _ => serde_json::from_value::<Request>(value)
                .map_err(io)
                .and_then(read),
        });
    json!(Reply::new(1, result))
}

pub(crate) struct Captured {
    pub(crate) stdout: Vec<u8>,
    /// `stdout` was cut at the stream cap: the child wrote more than was kept. A truncated capture
    /// can end mid-line, or mid-filename, so a consumer that parses it must not treat it as whole.
    pub(crate) stdout_truncated: bool,
    pub(crate) stderr: Vec<u8>,
    pub(crate) exit_code: i32,
    pub(crate) timed_out: bool,
    pub(crate) signaled: bool,
}

/// Drain a pipe to EOF on its own thread (mirrors `StatusCommandRunner.readCapped`): a blocking
/// read is safe here because it runs off the thread that watches for timeout/exit, and keeps
/// draining past `cap` so the child can never block on a full pipe buffer.
///
/// Publishes into a shared sink rather than returning, so `run_exec` can take what has drained so
/// far WITHOUT joining this thread. That matters because this thread can block forever: a
/// descendant that inherited the pipe (an ssh `ControlPersist` master, a daemonising credential
/// helper, gpg-daemon auto-launched by `commit -S`) holds the write end open after the child is
/// reaped, and `setsid` puts it outside the process group `run_exec` signals.
fn drain_capped(source: impl Read, cap: usize, sink: &Mutex<Vec<u8>>) {
    drain_capped_flagged(source, cap, sink, &AtomicBool::new(false));
}

/// `drain_capped`, also raising `overflowed` the moment a byte is dropped for lack of room. A
/// stream that ends EXACTLY at `cap` does not raise it, so the flag means "something was lost",
/// never "the buffer is full".
fn drain_capped_flagged(
    mut source: impl Read,
    cap: usize,
    sink: &Mutex<Vec<u8>>,
    overflowed: &AtomicBool,
) {
    let mut chunk = [0u8; 65536];
    loop {
        match source.read(&mut chunk) {
            Ok(0) => return,
            Ok(count) => {
                let mut collected = sink.lock().unwrap_or_else(|e| e.into_inner());
                let take = cap.saturating_sub(collected.len()).min(count);
                collected.extend_from_slice(&chunk[..take]);
                if take < count {
                    overflowed.store(true, Ordering::Release);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

/// Every descendant of `pid`, snapshotted with its start time via
/// [`crate::terminal::process::descendants`] — the same walk `session::terminate` uses to reach a
/// `setsid` grandchild, and split from the killing for a reason that file did not need to face:
/// this must be SNAPSHOTTED WHILE THE PARENT IS STILL ALIVE.
///
/// A descendant that calls `setsid` leaves the process group, so `kill(-pid, …)` never reaches it —
/// but it keeps its real ppid until its parent dies, so the walk finds it right up to that moment.
/// Once the parent is reaped the orphan re-parents to init and both handles are gone: the group it
/// left, and a lineage that no longer leads back to us. Walking the tree at KILL time therefore
/// finds nothing, which is the hole native's `killTree` also has — it is called at `timeout + 2`,
/// by which point a `git` that exited on SIGTERM has long been reaped.
///
/// So the walk happens when SIGTERM is sent, and the recorded descendants are what gets checked and
/// SIGKILLed later. `pid <= 1` is refused outright: `process::descendants` does not special-case
/// init the way this call site must not — `pid` is always a freshly spawned child's own pid, but a
/// SIGKILL aimed at init's whole descendant tree is the worst outcome a bug here could have.
pub(crate) fn descendants(pid: i32) -> Vec<crate::terminal::process::Descendant> {
    if pid <= 1 {
        return Vec::new();
    }
    crate::terminal::process::descendants(&[pid])
}

/// SIGKILL whichever recorded descendants are still the SAME process, checked with
/// [`crate::terminal::process::Descendant::is_running`] rather than by bare pid — the identity
/// check `session::terminate` already applies before its own SIGKILL sweep.
///
/// Without it this call carried a PID-reuse window strictly worse than native's: these pids were
/// read at SIGTERM time and this runs roughly two seconds later, long enough on a busy machine for
/// a descendant to exit and its number to be handed to something unrelated. `is_running` compares
/// the process's start time against the one recorded at the snapshot, so a pid whose occupant has
/// changed reads as not-running and is left alone — the small, unavoidable window native accepts is
/// only "the pid exited and nothing new has it yet", never "the pid now names someone else".
pub(crate) fn kill_recorded(descendants: &[crate::terminal::process::Descendant]) {
    for descendant in descendants.iter().filter(|d| d.is_running()) {
        // SAFETY: `kill` takes no pointers; `is_running` is the pid-reuse guard described above.
        unsafe { libc::kill(descendant.pid, libc::SIGKILL) };
    }
}

/// How long to keep trying to reap a process we have SIGKILLed before giving up on it. SIGKILL
/// cannot be caught, so this is generous for the normal case; it exists for the abnormal one, where
/// the leader is unkillable (uninterruptible I/O) and the alternative is blocking this thread — and
/// therefore holding one of the 32 shared `ACTIVE` permits — forever.
pub(crate) const REAP_GRACE: Duration = Duration::from_secs(2);

/// Test shorthand for `run_exec_with`.
#[cfg(test)]
fn run_exec(
    dir: &Path,
    executable: &str,
    args: &[String],
    timeout: Duration,
    stdin: Option<&[u8]>,
    env: &[(&str, &str)],
) -> model::Result<Captured> {
    run_exec_with(dir, executable, args, timeout, stdin, env)
}

/// Run `executable` to completion, capturing everything a `StatusCommandRunning` conformer needs
/// to classify the outcome exactly as the native path would. Mirrors `StatusCommandRunner.run`'s
/// SIGTERM-then-grace-then-SIGKILL shape (`CLIVCSWriter.commitTimeout`'s doc: "Killing a commit is
/// categorically more dangerous than killing a fetch" — an immediate SIGKILL denies a `post-commit`
/// hook the chance to exit cleanly and can leave `index.lock` behind).
pub(crate) fn run_exec_with(
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
    // "misdiagnose a deleted workroom as a missing git/gh". Mapping `ErrorKind::NotFound` to 127
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
        // own. workroomd is "negotiated with, never replaced", so its inherited environment is a
        // snapshot of whichever app launch first spawned it — a daemon-routed commit was picking up
        // that snapshot's `GIT_AUTHOR_*`/`GIT_CONFIG_GLOBAL`/`HOME` and authoring under a stale
        // identity. A key allowlist could not fix that: what git reads for identity, config,
        // signing and hooks is open-ended. That one function also applies this codebase's subprocess
        // baseline (`GIT_OPTIONAL_LOCKS`, `GIT_TERMINAL_PROMPT`, `LC_ALL=C`, and the removal of
        // `GIT_EXTERNAL_DIFF` and the `GIT_DIR` family) so both paths get it from one place.
        .env_clear()
        .envs(env.iter().copied());
    // Set last so no request environment can widen it: git must not discover an ANCESTOR
    // repository from `dir` (see `ceiling_directories`).
    if let Some(ceiling) = wr_vcs_git::diff::ceiling_directories(dir) {
        command.env("GIT_CEILING_DIRECTORIES", ceiling);
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
    let out_sink = Arc::new(Mutex::new(Vec::new()));
    let err_sink = Arc::new(Mutex::new(Vec::new()));
    let out_overflow = Arc::new(AtomicBool::new(false));
    let out = {
        let sink = Arc::clone(&out_sink);
        let overflow = Arc::clone(&out_overflow);
        std::thread::spawn(move || {
            drain_capped_flagged(stdout_pipe, MAX_EXEC_STREAM, &sink, &overflow)
        })
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
    let mut recorded: Vec<crate::terminal::process::Descendant> = Vec::new();
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
                // SAFETY: `kill` takes no pointers; `-pid` is the group the child leads.
                unsafe { libc::kill(-pid, libc::SIGTERM) };
            } else if elapsed >= timeout + Duration::from_secs(2) {
                if !sent_kill {
                    sent_kill = true;
                    // Recorded tree first, then group: the tree reaches a descendant that left the
                    // group, the group reaches one that spawned after the snapshot.
                    kill_recorded(&recorded);
                    // SAFETY: as for the SIGTERM above.
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
    //    remaining grace is honoured rather than skipped — `git` can exit on SIGTERM while a
    //    hook is still cleaning up, and cutting that short can leave hook-owned locks behind
    //    (`CLIVCSWriter.commitTimeout`: "Killing a commit is categorically more dangerous than
    //    killing a fetch"). Never on a normal exit: killing the group because a reader thread has
    //    not been scheduled yet would kill a hook's legitimate background work, measured at ~1.5% of
    //    successful large-output runs.
    //
    //    It first SIGKILLs the descendants recorded before the SIGTERM (`kill_recorded`, which
    //    skips any whose start time changed, so a reused pid is never signalled) — that is what
    //    reaches one that `setsid`ed out of the group — and then the process group itself. The group
    //    signal, like native's `ProcessTree.killTree` at `timeout + 2`, still names a leader pid that
    //    has already been reaped, the same small PID-reuse window.
    if timed_out && !sent_kill {
        let kill_at = start + timeout + Duration::from_secs(2);
        while Instant::now() < kill_at {
            std::thread::sleep(Duration::from_millis(10));
        }
        // The recorded set, not a fresh walk: the leader is already reaped on this path, so
        // `pgrep -P` would find nothing — the orphan re-parented to init the moment its parent died.
        // This is the branch the snapshot exists for.
        kill_recorded(&recorded);
        // SAFETY: `kill` takes no pointers; the reaped-leader pid-reuse window is the one above.
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
            stdout_truncated: out_overflow.load(Ordering::Acquire),
            stderr: take(&err_sink),
            exit_code: 137,
            timed_out: true,
            signaled: true,
        });
    };
    Ok(Captured {
        stdout: take(&out_sink),
        stdout_truncated: out_overflow.load(Ordering::Acquire),
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
pub(crate) const EXEC_REPLY_RESERVE: usize = 64 * 1024;

/// An UPPER BOUND on what this text costs once JSON-escaped, which is what `MAX_RESPONSE` bounds.
///
/// A bound, not an exact count: serde emits `\b` (0x08) and `\f` (0x0C) as two bytes where this
/// charges six. Over-estimating is the safe direction — it truncates fractionally early and can
/// never overflow the ceiling — and getting it exact would mean tracking serde's escape table here,
/// which is a coupling worth more than the handful of bytes it buys.
///
/// The expansion is why the two caps could not both be satisfied: a control byte serializes as
/// `\u0001`, six bytes for one, so two streams at `MAX_EXEC_STREAM` (4 MiB each) reach 48 MiB of
/// wire form against a 16 MiB ceiling. Codex reproduced it with 3 MiB of `0x01`.
pub(crate) fn escaped_len(text: &str) -> usize {
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
/// git puts the line that classifies a failure first, and a tail-truncated stderr would lose
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

/// The exact inverse of `DaemonCommandRunner.swift`'s `String(data:encoding:.isoLatin1)` — see
/// `ExecRequest.stdin`'s doc. Every `char` a Latin-1-decoded string can contain is U+0000-U+00FF
/// by construction; a value outside that range means the client sent something else, so this
/// rejects rather than silently truncates it.
fn latin1_bytes(text: &str) -> model::Result<Vec<u8>> {
    text.chars()
        .map(|c| u8::try_from(c as u32).map_err(|_| io("stdin is not Latin-1")))
        .collect()
}

/// Cut the two captured streams down to what fits one reply, returning them unchanged when they
/// already do — which is every ordinary command.
///
/// A function for `exec_timeout`'s reason: the test that covers it must call the code the reply is
/// actually built from, not a copy of the arithmetic.
fn bound_exec_streams<'a>(stdout: &'a str, stderr: &'a str) -> (&'a str, &'a str) {
    let budget = MAX_RESPONSE - EXEC_REPLY_RESERVE;
    if escaped_len(stdout) + escaped_len(stderr) <= budget {
        return (stdout, stderr);
    }
    let err_budget = escaped_len(stderr).min(budget / 2);
    (
        truncate_to_escaped_budget(stdout, budget - err_budget),
        truncate_to_escaped_budget(stderr, err_budget),
    )
}

/// The deadline `run_exec` is given for a requested `timeout_ms`.
///
/// A function rather than an inline `clamp` so a test can assert the REAL expression: a test that
/// rewrites the clamp for itself stays green when the clamp is deleted from here, which is exactly
/// what the first version of its test did.
fn exec_timeout(timeout_ms: u64) -> Duration {
    Duration::from_millis(timeout_ms.clamp(1, MAX_EXEC_TIMEOUT_MS))
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
        host_environment: from_host,
        _barrier_root: _,
    } = request;
    if version != 1 {
        return Err(VcsError::BackendVersion(
            "unsupported VCS service version".into(),
        ));
    }
    let dir = absolute(&dir)?;
    let timeout = exec_timeout(timeout_ms);
    let env = if from_host {
        host_environment(
            login_environment()
                .iter()
                .map(|(key, value)| (key.into(), value.into())),
            env,
        )
    } else {
        env
    };
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let stdin = stdin.as_deref().map(latin1_bytes).transpose()?;
    let captured = run_exec_with(
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
    let (stdout, stderr) = bound_exec_streams(&stdout, &stderr);
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
        // (`writes: 8`) described a CLIENT-side Swift protocol: workroomd implements one generic
        // exec service and has never had eight write methods to report. Nothing here could keep
        // that number true, and the client compared it for equality — so adding a ninth method to
        // that Swift protocol, a change this side fully supports, silently dropped every user to
        // native writes with no log line.
        //
        // The highest version this daemon speaks. `exec` rejects anything but 1 today; a future
        // version bumps this and decides then whether it still accepts 1.
        return Ok(json!({"version": 1, "reads": 9, "exec": EXEC_SERVICE_VERSION}));
    }
    if request.limit.is_some_and(|limit| limit > MAX_HISTORY_LIMIT) {
        return Err(VcsError::PartialData(format!(
            "history request exceeds {MAX_HISTORY_LIMIT} commits"
        )));
    }
    let root = absolute(required(&request.root)?)?;
    // Required as before; only `git` deserializes (see `Backend`), so nothing below varies on it.
    request.backend.ok_or_else(|| io("missing backend"))?;
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
    let environment = host_read_environment();
    let value = match request.method.as_str() {
        "log" => serde_json::to_value(wr_vcs_git::log_page(
            &root,
            request.limit.unwrap_or(100).min(MAX_HISTORY_LIMIT),
        )?),
        "changeset" => serde_json::to_value(wr_vcs_git::changeset_with_environment(
            &root,
            &param(rev)?,
            Some(&environment),
        )?),
        "current_ref" => serde_json::to_value(wr_vcs_git::current_ref(&root)?),
        "working_status" => serde_json::to_value(
            wr_vcs_git::diff::working_status_with_environment(&root, Some(&environment))?,
        ),
        "file_diff" => {
            let change =
                wr_vcs_git::changeset_with_environment(&root, &param(rev)?, Some(&environment))?;
            serde_json::to_value(wr_vcs_git::diff::committed_patch_with_environment(
                &root,
                &change.commit,
                &param(path)?,
                Some(&environment),
            )?)
        }
        "working_file_diff" if working => {
            serde_json::to_value(wr_vcs_git::diff::working_patch_with_environment(
                &root,
                &param(path)?,
                Some(&environment),
            )?)
        }
        "file_content" => serde_json::to_value(wr_vcs_git::file_content(
            &root,
            &param(rev)?,
            &param(path)?,
            false,
        )?),
        "commit_parent_file_content" => serde_json::to_value(wr_vcs_git::file_content(
            &root,
            &param(rev)?,
            &param(path)?,
            true,
        )?),
        "working_base_file_content" if working => serde_json::to_value(wr_vcs_git::file_content(
            &root,
            "HEAD",
            &param(path)?,
            false,
        )?),
        _ => return Err(VcsError::UnsupportedRepo("unsupported VCS read".into())),
    };
    value.map_err(io)
}

pub fn dispatch(partial: &mut PartialRequests, envelope: &Envelope, writer: &SharedWriter) {
    if envelope.stream == 0 {
        return;
    }
    // Before the permit: a non-final chunk does no work and must not hold one of the 32 slots for
    // however long the rest of the request takes to arrive. The permit is taken when the request is
    // COMPLETE, which is when it starts costing something.
    let bytes = match reassemble(partial, envelope) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => return,
        Err(error) => {
            send(
                writer,
                Service::Vcs,
                envelope.stream,
                json!(Reply::error(1, error)),
            );
            return;
        }
    };
    let Some(permit) = Permit::acquire() else {
        send(
            writer,
            Service::Vcs,
            envelope.stream,
            json!(Reply::error(1, VcsError::LockContention)),
        );
        return;
    };
    let writer = Arc::clone(writer);
    let stream = envelope.stream;
    std::thread::spawn(move || {
        let _permit = permit;
        send(&writer, Service::Vcs, stream, execute(&bytes));
    });
}

#[cfg(test)]
mod tests;
