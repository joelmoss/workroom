//! Versioned VCS requests over Service::Vcs. Capability negotiation is separate from the terminal
//! greeting. Each nonzero stream is one request. Reply JSON is chunked; the first payload byte is
//! 0 for continuation, 1 for final. Maximum assembled reply is 16MiB. Requests are never replayed.
use crate::daemon::rpc::{
    EXEC_REPLY_RESERVE, MAX_RESPONSE, PartialRequests, Permit, SharedWriter, escaped_len,
    reassemble, send,
};
use crate::exec::{absolute, io, relative, run_exec};
use crate::host::environment::{host_environment, host_login_environment, host_read_environment};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
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
/// the child sees the same environment (`env_clear` in `exec::run_exec`), a missing tool exits
/// 127 rather than failing to spawn (`/usr/bin/env`), and a transport failure is not reported as
/// "never ran" (`DaemonCommandRunner.outcomeUnknown`). An outcome-unknown result is its own
/// `VCSRemoteFailure`/`VCSCommitFailure` case, and its recovery follows idempotence
/// (`VCSSyncPresenter.retryAction`): a lost push or pull offers `.fetch`, which resolves the doubt,
/// a lost fetch or rebase abort offers itself, and a lost commit offers no action at all.
///
/// **The child's environment is the request's `env`, wholesale** (`env_clear` in
/// `exec::run_exec`), never this daemon's own. workroomd is "negotiated with, never replaced",
/// so its inherited environment is a snapshot of whichever app launch first spawned it; a
/// daemon-routed commit was picking up that snapshot's `GIT_AUTHOR_*`/`GIT_CONFIG_GLOBAL`/`HOME` and
/// authoring under a stale identity. A key allowlist could not fix it — what git reads for identity,
/// config, signing and hooks is open-ended — so `StatusCommandRunner.childEnvironment` builds one
/// map for both paths.
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

fn required(value: &Option<String>) -> model::Result<&str> {
    value
        .as_deref()
        .ok_or_else(|| io("missing request parameter"))
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

/// The longest prefix of `text` whose escaped form fits `budget`, cut on a character boundary.
///
/// Head rather than tail, matching `wr_exec::drain_capped` and native's
/// `StatusCommandRunner.readCapped`: git puts the line that classifies a failure first, and a
/// tail-truncated stderr would lose it. Silent, also matching those two — the markers
/// `CLIVCSWriter.classify` matches live in this text, so injecting a "truncated" notice here could
/// only create a false positive.
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
            host_login_environment()
                .iter()
                .map(|(key, value)| (key.into(), value.into())),
            env,
        )
    } else {
        env
    };
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
