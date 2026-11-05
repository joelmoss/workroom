use super::*;
use crate::daemon::rpc::is_busy;
use std::io::Read;
use std::os::unix::net::UnixStream;
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

#[test]
fn a_stream_that_ends_exactly_at_the_cap_is_not_flagged_but_one_byte_over_is() {
    let exact = Mutex::new(Vec::new());
    let flag = AtomicBool::new(false);
    drain_capped_flagged([7u8; 10].as_slice(), 10, &exact, &flag);
    assert_eq!(exact.lock().unwrap().len(), 10);
    assert!(!flag.load(Ordering::Acquire));
    let over = Mutex::new(Vec::new());
    drain_capped_flagged([7u8; 11].as_slice(), 10, &over, &flag);
    assert_eq!(over.lock().unwrap().len(), 10);
    assert!(flag.load(Ordering::Acquire));
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

/// The child's environment is EXACTLY the request's map — nothing of the daemon's own leaks
/// through. This is the property that keeps a daemon-routed commit from being authored under
/// the stale identity of whichever app launch first spawned this daemon; a key allowlist could
/// not provide it, because what git reads for identity, config, signing and hooks is
/// open-ended. `env` (not in the git allowlist) goes through `run_exec` directly, bypassing
/// `exec`'s executable restriction, specifically to observe what reaches the child.
#[test]
fn run_exec_replaces_the_daemons_environment_with_the_requests() {
    // A variable this process already has and the request does not set. Inherited rather than
    // set here: changing the environment of a test process whose other tests run on other
    // threads is unsound, which is why `set_var` is `unsafe` as of edition 2024.
    let request = [
        "PATH",
        "SSH_AUTH_SOCK",
        "GIT_AUTHOR_EMAIL",
        "GIT_CEILING_DIRECTORIES",
    ];
    let (inherited, _) = std::env::vars()
        .find(|(key, _)| !request.contains(&key.as_str()))
        .expect("the test process has a variable the request does not set");
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
    let leaked = format!("{inherited}=");
    assert!(
        !stdout.lines().any(|line| line.starts_with(&leaked)),
        "{inherited} reached the child"
    );
    std::fs::remove_dir_all(&root).unwrap();
}

/// A remote host's child environment (#229): the host's own, less what could point git at
/// another repository or let ssh prompt, with the app's pins on top.
#[test]
fn a_host_environment_is_the_hosts_own_with_the_pins_on_top_and_ssh_unable_to_prompt() {
    let pairs = |pairs: &[(&str, &str)]| {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect::<Vec<_>>()
    };
    let os = |pairs: Vec<(String, String)>| {
        pairs
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect::<Vec<(std::ffi::OsString, std::ffi::OsString)>>()
    };
    let own = pairs(&[
        ("HOME", "/home/workroom"),
        ("PATH", "/usr/bin:/bin"),
        ("GIT_DIR", "/elsewhere/.git"),
        ("SSH_ASKPASS", "/usr/bin/ask"),
        ("LC_ALL", "fr_FR.UTF-8"),
        ("GIT_SSH_COMMAND", "ssh -i /home/workroom/.ssh/deploy"),
    ]);
    let pins = pairs(&[("LC_ALL", "C"), ("GIT_TERMINAL_PROMPT", "0")])
        .into_iter()
        .collect();
    let env = host_environment(os(own).into_iter(), pins);
    assert_eq!(env["HOME"], "/home/workroom");
    assert_eq!(env["PATH"], "/usr/bin:/bin");
    assert!(!env.contains_key("GIT_DIR"));
    assert!(!env.contains_key("SSH_ASKPASS"));
    assert_eq!(env["LC_ALL"], "C", "a pin outranks the host's value");
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    assert_eq!(
        env["GIT_SSH_COMMAND"],
        "ssh -i /home/workroom/.ssh/deploy -o BatchMode=yes"
    );
    assert_eq!(env["SSH_ASKPASS_REQUIRE"], "never");

    // With none of its own, it gets none: set, it would outrank a repository's
    // `core.sshCommand`, where a deploy key usually lives.
    let bare = host_environment(std::iter::empty(), Default::default());
    assert!(!bare.contains_key("GIT_SSH_COMMAND"));
    assert_eq!(bare["SSH_ASKPASS_REQUIRE"], "never");

    // A variable that is not UTF-8 is dropped, not a panic.
    use std::os::unix::ffi::OsStringExt;
    let latin1 = vec![(
        std::ffi::OsString::from("LEGACY"),
        std::ffi::OsString::from_vec(vec![0xe9]),
    )];
    let env = host_environment(latin1.into_iter(), Default::default());
    assert!(!env.contains_key("LEGACY"));
}

#[test]
fn remote_git_reads_the_login_environment_from_home_not_a_clone() {
    let root = git_repo("host-login-home");
    let shell = profile_shell(
        &root,
        "export READ_FROM=\"$(pwd -P)\"\nexec /bin/sh -c \"$2\"\n",
    );
    let cache = OnceLock::new();
    let login = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    let home = std::fs::canonicalize(std::env::var_os("HOME").unwrap()).unwrap();
    assert_eq!(login["READ_FROM"], home.to_str().unwrap());
}

/// The daemon reads a host profile once, and every remote exec then applies the existing scrub
/// and request pins to that cached result. A profile may provide git/gh and credentials, but it
/// cannot redirect a repository or enable a graphical prompt.
#[test]
fn remote_git_uses_the_cached_login_environment_with_the_policy_on_top() {
    let root = git_repo("host-login-env");
    let shell = profile_shell(
        &root,
        "export FROM_PROFILE=host\nexport PATH=/home/u/.local/bin:$PATH\nexport GIT_DIR=/wrong/repo\nexport GIT_WORK_TREE=/wrong/worktree\nexport GIT_TERMINAL_PROMPT=1\nexport LC_ALL=fr_FR.UTF-8\nexport DISPLAY=:0\nexport SSH_ASKPASS=/host/ask\nexec /bin/sh -c \"$2\"\n",
    );
    let cache = OnceLock::new();
    let login = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    assert_eq!(login["FROM_PROFILE"], "host");
    assert!(login["PATH"].starts_with("/home/u/.local/bin:"));
    assert!(!login.contains_key("WORKROOM_SHELL_PROBE"));
    let env = host_environment(
        login.iter().map(|(key, value)| (key.into(), value.into())),
        BTreeMap::from([("LC_ALL".to_string(), "C".to_string())]),
    );
    assert_eq!(env["FROM_PROFILE"], "host");
    assert_eq!(env["LC_ALL"], "C");
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    assert!(!env.contains_key("GIT_DIR"));
    assert!(!env.contains_key("GIT_WORK_TREE"));
    assert!(!env.contains_key("DISPLAY"));
    assert!(!env.contains_key("SSH_ASKPASS"));
    assert_eq!(env["SSH_ASKPASS_REQUIRE"], "never");

    // Removing the shell proves the next exec never probes again: an uncached read would
    // fall back and lose FROM_PROFILE.
    std::fs::remove_file(&shell).unwrap();
    let again = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    assert!(std::ptr::eq(login, again));
    assert_eq!(again["FROM_PROFILE"], "host");
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_hanging_host_profile_falls_back_once_without_holding_remote_git() {
    let root = git_repo("host-login-timeout");
    let shell = profile_shell(&root, "sleep 30\n");
    let cache = OnceLock::new();
    let started = Instant::now();
    let env = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_millis(100));
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(!env["PATH"].is_empty());
    assert!(!env.contains_key("WORKROOM_SHELL_PROBE"));
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    let again = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    assert!(std::ptr::eq(env, again), "the fallback is cached too");
    std::fs::remove_dir_all(&root).unwrap();
}

fn profile_shell(root: &Path, body: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let shell = root.join("bash");
    let draft = root.join("profile.draft");
    std::fs::write(&draft, format!("#!/bin/sh\n{body}")).unwrap();
    // A simultaneous test fork must not inherit a writable descriptor to this executable
    // (ETXTBSY on Linux), as in run_script's script helper.
    assert!(
        Command::new("cp")
            .arg(&draft)
            .arg(&shell)
            .status()
            .unwrap()
            .success()
    );
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o755)).unwrap();
    shell
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
/// "nothing ran" and warns it would "misdiagnose a deleted workroom as a missing git/gh".
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
/// spawned by git/gh can outlive the parent") and the daemon did not: a DESCENDANT that calls
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

/// `descendants` must never walk init's own tree — a SIGKILL aimed at pid 1's descendants is
/// the worst outcome a bug here could have — and must terminate on a pid nothing can have.
#[test]
fn the_descendant_walk_refuses_init_and_terminates() {
    assert!(descendants(0).is_empty());
    assert!(descendants(1).is_empty());
    assert!(descendants(-1).is_empty());
    assert!(descendants(i32::MAX).is_empty());
    // Killing an empty set is a no-op, not a signal to the current process group.
    kill_recorded(&[]);
}

/// LOW 1: the bug this whole identity check exists for. `kill_recorded` used to SIGKILL by bare
/// pid, so a descendant that exited during the SIGTERM-to-SIGKILL grace period and whose pid was
/// handed to something else would be killed in its place. A `Descendant` whose recorded start
/// time cannot match anything real (`u64::MAX`) reproduces exactly that shape — the number is
/// right, the process behind it is not — without needing to actually win a real pid-reuse race.
#[test]
fn kill_recorded_never_signals_a_pid_whose_start_time_has_changed() {
    let mut child = Command::new("/bin/sleep")
        .arg("30")
        .spawn()
        .expect("spawn sleep");
    let pid = child.id() as i32;
    let impostor = crate::terminal::process::Descendant {
        pid,
        started: u64::MAX,
    };
    kill_recorded(&[impostor]);
    // Give a real SIGKILL time to land before checking: without the identity check this reaps
    // almost immediately.
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        child.try_wait().expect("try_wait").is_none(),
        "kill_recorded signalled a pid it no longer identifies"
    );
    let _ = child.kill();
    let _ = child.wait();
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
