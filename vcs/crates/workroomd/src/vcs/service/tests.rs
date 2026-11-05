use super::*;
use crate::daemon::rpc::is_busy;
use crate::exec::run_exec;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use wr_protocol::envelope::{EnvelopeDecoder, Hello};
use wr_protocol::frame::{Frame, FrameKind};

#[test]
fn version_and_path_errors_are_explicit() {
    assert!(
        execute(br#"{"version":99,"method":"capabilities"}"#)
            .get("error")
            .is_some()
    );
    assert_eq!(
        execute(br#"{"version":1,"method":"capabilities"}"#)["result"]["reads"],
        9
    );
    for root in ["relative", "/tmp/../other", "/tmp/./other", "/tmp/\0other"] {
        let request = json!({"version":1,"method":"log","backend":"git","root":root});
        assert!(
            execute(&serde_json::to_vec(&request).unwrap())
                .get("error")
                .is_some()
        );
    }
    // The jj backend is gone: naming it fails to parse and is answered per request, not by
    // special handling.
    let request = json!({"version":1,"method":"log","backend":"jj","root":"/definitely-absent"});
    assert!(
        execute(&serde_json::to_vec(&request).unwrap())
            .get("error")
            .is_some()
    );
}

/// A VCS request that is slow in flight must block neither control frames nor disconnect, and
/// must keep `is_busy()` true until the work itself ends. The request is a real `git` exec that
/// a shell alias holds until the test releases it (capped, so a failed test cannot leave it
/// running for long).
#[test]
fn a_slow_vcs_request_does_not_block_control_or_disconnect() {
    let root = git_repo("slow-request");
    let release = std::env::temp_dir().join(format!("wr-vcs-release-{}", std::process::id()));
    let _ = std::fs::remove_file(&release);
    let hold = format!(
        "!i=0; while [ ! -e {} ] && [ $i -lt 400 ]; do sleep 0.02; i=$((i+1)); done",
        release.display()
    );
    let (mut client, server) = UnixStream::pair().unwrap();
    client
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .unwrap();
    let worker = std::thread::spawn(move || {
        crate::daemon::serve::handle_connection(
            server,
            crate::terminal::session::SessionStore::new(),
        )
    });
    client.write_all(&Hello::current("test").encode()).unwrap();
    let mut hello = Vec::new();
    while Hello::decode(&hello).unwrap().is_none() {
        let mut byte = [0];
        client.read_exact(&mut byte).unwrap();
        hello.push(byte[0]);
    }
    let request = exec_request(&root, "git", &["-c", &format!("alias.hold={hold}"), "hold"]);
    client
        .write_all(&Envelope::new(Service::Vcs, 7, request).encode())
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
    // The control reply arrived while the exec is still held, and the daemon counts it as work.
    assert!(is_busy());
    drop(client);
    worker.join().unwrap().unwrap();
    // Disconnect returned with the request still running; it ends only once released.
    assert!(is_busy());
    std::fs::write(&release, b"").unwrap();
    // Judged from the one reading that saw it idle: another test's permit (a File request
    // refused busy holds one for microseconds) may land after it, and a second reading would
    // see that instead.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let released = loop {
        if !is_busy() {
            break true;
        }
        if std::time::Instant::now() >= deadline {
            break false;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    };
    assert!(released);
    let _ = std::fs::remove_file(&release);
    std::fs::remove_dir_all(root).unwrap();
}

/// Test-side inverse of `latin1_bytes`, standing in for `DaemonCommandRunner.swift`'s
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
    let root = std::env::temp_dir().join(format!("wr-vcs-exec-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    for args in [
        vec!["init", "-q", "-b", "main"],
        vec!["config", "user.name", "Test"],
        vec!["config", "user.email", "test@example.com"],
    ] {
        assert!(
            Command::new("git")
                .args(args)
                .current_dir(&root)
                .status()
                .unwrap()
                .success()
        );
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

/// A folder that is not itself a repository (a workspace Jujutsu left, or a broken empty
/// `.git`) inside another repository: git there must not discover the ANCESTOR and act on it,
/// even when the request's own environment tries to widen the ceiling.
#[test]
fn exec_never_discovers_an_ancestor_repository() {
    let root = git_repo("ceiling");
    let control = execute(&exec_request(
        &root,
        "git",
        &["rev-parse", "--show-toplevel"],
    ));
    assert_eq!(control["result"]["exit_code"], 0, "control: {control}");
    let inner = root.join("inner");
    std::fs::create_dir_all(inner.join(".git")).unwrap();
    let mut request: Value = serde_json::from_slice(&exec_request(
        &inner,
        "git",
        &["rev-parse", "--show-toplevel"],
    ))
    .unwrap();
    request["env"] = json!({
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "GIT_CEILING_DIRECTORIES": "/nonexistent",
    });
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert!(
        reply["result"]["stderr"]
            .as_str()
            .unwrap_or_default()
            .contains("not a git repository"),
        "git found the ancestor: {reply}"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

/// The ceiling is the parent of the RESOLVED directory: a symlinked workroom whose link sits
/// in a different folder from its target must not leave the target's parent open.
#[test]
fn exec_through_a_symlinked_directory_still_stops_at_its_real_root() {
    let root = git_repo("ceiling-link");
    let real = root.join("plain").join("proj");
    std::fs::create_dir_all(real.join(".git")).unwrap();
    let links = root.join("links");
    std::fs::create_dir_all(&links).unwrap();
    std::os::unix::fs::symlink(&real, links.join("proj")).unwrap();
    let reply = execute(&exec_request(
        &links.join("proj"),
        "git",
        &["rev-parse", "--show-toplevel"],
    ));
    assert!(
        reply["result"]["stderr"]
            .as_str()
            .unwrap_or_default()
            .contains("not a git repository"),
        "git found the ancestor through the link: {reply}"
    );
    std::fs::remove_dir_all(&root).unwrap();
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
fn exec_rejects_an_executable_outside_the_git_allowlist() {
    let root = git_repo("disallowed");
    // `jj` was allowed before its removal; an older app naming it now gets an error reply.
    for executable in ["sh", "jj"] {
        let request = json!({
            "version": 1, "kind": "exec", "executable": executable, "args": ["--version"],
            "dir": root.to_str().unwrap(), "timeout_ms": 1000,
        });
        let reply = execute(&serde_json::to_vec(&request).unwrap());
        assert!(reply.get("error").is_some(), "{executable}: {reply}");
    }
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

/// An older app still names a `barrier_root` on every remote command. It is accepted and
/// ignored: the command runs normally on a git repository.
#[test]
fn an_exec_naming_a_barrier_root_from_an_older_app_still_runs() {
    let root = git_repo("barrier-root-git");
    let mut request: Value =
        serde_json::from_slice(&exec_request(&root, "git", &["status"])).unwrap();
    request["barrier_root"] = json!(root.to_str().unwrap());
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert_eq!(reply["result"]["exit_code"], 0, "{reply}");
    std::fs::remove_dir_all(&root).unwrap();
}

/// The app still sends `shared_root` on every read (a jj-era field the daemon now ignores), and
/// `Request` is `deny_unknown_fields`: dropping or renaming the ignored field would reject every
/// read from a registered repository.
#[test]
fn a_read_naming_a_shared_root_still_runs() {
    let root = git_repo("shared-root-read");
    let request =
        json!({"version":1,"method":"current_ref","backend":"git","root":root,"shared_root":root});
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    assert!(reply.get("result").is_some(), "{reply}");
    std::fs::remove_dir_all(&root).unwrap();
}

/// The facts the app's classifier reads from a git directory (#229), for a path that is a
/// directory, a file whose text was asked for, and one that is not there.
#[test]
fn stat_reports_what_is_at_each_path() {
    let root = git_repo("stat");
    let git = root.join(".git");
    std::fs::write(root.join("pointer"), "gitdir: /elsewhere\n").unwrap();
    let request = json!({
        "version": 1,
        "kind": "stat",
        "paths": [git, root.join("pointer"), git.join("rebase-merge")],
        "read": [root.join("pointer")],
    });
    let reply = execute(&serde_json::to_vec(&request).unwrap());
    let entries = reply["result"]["entries"].as_array().expect("entries");
    assert_eq!(entries[0]["exists"], true);
    assert_eq!(entries[0]["is_dir"], true);
    assert!(entries[0]["modified_at"].as_f64().unwrap() > 0.0);
    assert_eq!(entries[0]["text"], Value::Null, "text was not asked for");
    assert_eq!(entries[1]["is_dir"], false);
    assert_eq!(entries[1]["text"], "gitdir: /elsewhere\n");
    assert_eq!(entries[2]["exists"], false);
    assert_eq!(entries[2]["modified_at"], Value::Null);

    let relative = json!({"version": 1, "kind": "stat", "paths": ["relative/path", git]});
    let reply = execute(&serde_json::to_vec(&relative).unwrap());
    assert_eq!(reply["result"]["entries"][0]["exists"], false, "{reply}");
    assert_eq!(
        reply["result"]["entries"][1]["exists"], true,
        "one bad path spoiled the rest"
    );
    let many: Vec<String> = (0..=MAX_STAT_PATHS).map(|i| format!("/tmp/{i}")).collect();
    let too_many = json!({"version": 1, "kind": "stat", "paths": many});
    assert!(execute(&serde_json::to_vec(&too_many).unwrap())["error"].is_object());
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

/// The clamp is the only thing between a client's `timeout_ms` and a thread that waits on it,
/// and both ends of it matter: 0 would make every command time out before it started, and an
/// unbounded value would park an `ACTIVE` permit for as long as the caller asked. Calls
/// `exec_timeout`, the function `exec` uses, so deleting the clamp reddens this.
#[test]
fn the_exec_timeout_clamp_holds_at_both_ends() {
    // `exec_timeout` itself, not a copy of its arithmetic — the whole point of extracting it.
    let clamp = exec_timeout;
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
    // `run_exec` directly rather than `execute`: the executable allowlist is git only, and
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

    // `bound_exec_streams` is what `exec` builds its reply from, so deleting the bounding from
    // `exec` reddens this — the previous version re-implemented the arithmetic here and stayed
    // green against its own reverted fix.
    let stdout = String::from_utf8_lossy(&captured.stdout);
    let stderr = String::from_utf8_lossy(&captured.stderr);
    assert!(
        escaped_len(&stdout) > MAX_RESPONSE - EXEC_REPLY_RESERVE,
        "the fixture no longer exceeds the budget, so this proves nothing"
    );
    let (kept, kept_err) = bound_exec_streams(&stdout, &stderr);
    let reply = json!({
        "version": 1,
        "result": {
            "stdout": kept,
            "stderr": kept_err,
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
///
/// `escaped_len` is an upper BOUND, so the assertions below are `>=` against serde except for
/// the classes where the two agree exactly. `\b` and `\f` are the whole of the difference and
/// are asserted as over-estimates rather than quietly omitted from the sample.
#[test]
fn escaped_length_bounds_the_expansion_it_is_used_to_budget() {
    // A control byte costs six on the wire, a quote two, plain ASCII one.
    assert_eq!(escaped_len("\u{0001}"), 6);
    assert_eq!(escaped_len("\""), 2);
    assert_eq!(escaped_len("\n"), 2);
    assert_eq!(escaped_len("abc"), 3);
    // Exact for everything but `\b`/`\f`, and never UNDER serde's real cost for anything —
    // which is the only property the budget depends on.
    for sample in [
        "\u{0001}\u{0002}",
        "a\"b\\c",
        "plain",
        "tab\there",
        "é",
        "\u{007F}",
    ] {
        assert_eq!(
            escaped_len(sample),
            serde_json::to_string(sample).unwrap().len() - 2,
            "escaped_len disagrees with serde for {sample:?}"
        );
    }
    for sample in ["\u{0008}", "\u{000C}", "a\u{0008}b"] {
        assert!(
            escaped_len(sample) >= serde_json::to_string(sample).unwrap().len() - 2,
            "escaped_len UNDER-counts {sample:?}, which could overflow the ceiling"
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
