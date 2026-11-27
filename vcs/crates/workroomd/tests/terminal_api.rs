//! The terminal API (#360, ADR 0079) and `workroom sessions` (#683) end to end: the real CLI
//! against a real daemon over its socket, as a coding agent in a pane runs it. Each test starts its
//! own daemon on a temporary socket and names it in `WORKROOM_DAEMON`; the CLI runs with a cleared
//! environment, so nothing here can reach another daemon.

#[allow(dead_code)] // not every helper is used here
mod common;

use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use common::{Spawned, Workspace, attach_with_env, has_terminal_state, start_daemon, wait_for};
use serde_json::{Value, json};
use wr_protocol::envelope::Service;

/// One run of the CLI: (stdout, stderr, exit code).
struct Run {
    stdout: String,
    stderr: String,
    code: i32,
}

impl Run {
    fn envelope(&self) -> Value {
        serde_json::from_str(&self.stdout).unwrap_or_else(|e| {
            panic!(
                "not one envelope ({e}): {:?} {:?}",
                self.stdout, self.stderr
            )
        })
    }
}

/// `workroom <args>`, naming no daemon, from a process whose parents hold none.
///
/// A CLI that names no daemon looks for one among its parents (#684), and a test run in a
/// Workroom pane has the developer's own daemon there. So the CLI runs in a subshell orphaned to
/// init: the shell that started it has exited before it starts, which a file (`go`) it waits for
/// says. Its output and exit code come back in files under `dir`.
fn workroom_outside_any_daemon(dir: &Path, args: &[&str]) -> Run {
    let mut attempt = 0;
    let at = loop {
        let at = dir.join(format!("orphan-{attempt}"));
        if std::fs::create_dir(&at).is_ok() {
            break at;
        }
        attempt += 1;
    };
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(
            "cd \"$1\" || exit 1; shift; \
             (while [ ! -e go ]; do sleep 0.02; done; \
              \"$0\" \"$@\" > stdout 2> stderr; echo $? > code.partial; mv code.partial code) &",
        )
        .arg(common::daemon_binary())
        .arg(&at)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("start the orphan");
    assert!(status.success());
    std::fs::write(at.join("go"), b"").expect("go");
    let code = at.join("code");
    assert!(
        wait_for(Duration::from_secs(20), || code.exists()),
        "the orphaned workroom never finished"
    );
    let read = |name: &str| std::fs::read_to_string(at.join(name)).unwrap_or_default();
    Run {
        stdout: read("stdout"),
        stderr: read("stderr"),
        code: read("code").trim().parse().unwrap_or(-1),
    }
}

/// `workroom <args>` with only `PATH`, `HOME` and, when given, `WORKROOM_DAEMON`. Given none, the
/// CLI looks for a daemon among this test's parents, so a run that must find none is
/// `workroom_outside_any_daemon`'s; one refused before any daemon is looked for can be this one's.
fn workroom(daemon: Option<&Path>, args: &[&str]) -> Run {
    workroom_with_stdin(daemon, args, None)
}

/// [`workroom`], reading `stdin` when given, else nothing.
fn workroom_with_stdin(daemon: Option<&Path>, args: &[&str], stdin: Option<&str>) -> Run {
    let mut command = Command::new(common::daemon_binary());
    command
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(socket) = daemon {
        command.env("WORKROOM_DAEMON", socket);
    }
    let mut child = command.spawn().expect("run workroom");
    if let Some(text) = stdin {
        let mut pipe = child.stdin.take().expect("stdin");
        pipe.write_all(text.as_bytes()).expect("write stdin");
    }
    let output = child.wait_with_output().expect("run workroom");
    Run {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        code: output.status.code().unwrap_or(-1),
    }
}

/// `workroom sessions --json`'s sessions, from a run that must succeed.
fn sessions(socket: &Path) -> Vec<Value> {
    let run = workroom(Some(socket), &["sessions", "--json"]);
    assert_eq!(run.code, 0, "{} {}", run.stdout, run.stderr);
    let envelope = run.envelope();
    assert_eq!(envelope["ok"], true);
    assert_eq!(envelope["schema_version"], 1);
    assert_eq!(envelope["command"], "sessions");
    envelope["sessions"].as_array().cloned().expect("sessions")
}

fn session<'a>(listing: &'a [Value], id: &str) -> &'a Value {
    listing
        .iter()
        .find(|session| session["id"] == id)
        .unwrap_or_else(|| panic!("no session {id} in {listing:?}"))
}

/// A session as the app makes one: its label, its workroom and its working directory.
fn open(socket: &Path, id: &str, label: &str, workroom: &str, cwd: &Path) -> Spawned {
    attach_with_env(
        socket,
        id,
        &[],
        &[
            ("WORKROOM_SESSION_TITLE", label),
            ("WORKROOM_SESSION_WORKROOM", workroom),
            ("WORKROOM_SESSION_CWD", cwd.to_str().unwrap()),
        ],
    )
}

/// Types `line` and Enter into an attached session's shell.
fn type_line(client: &mut Spawned, line: &str) {
    let stdin = client.stdin.as_mut().expect("stdin");
    stdin.write_all(line.as_bytes()).expect("type");
    stdin.write_all(b"\n").expect("type");
    stdin.flush().expect("flush");
}

/// Waits until a listing satisfies `done`, and returns it.
fn listing_until(socket: &Path, done: impl Fn(&[Value]) -> bool) -> Vec<Value> {
    let mut last = Vec::new();
    let reached = wait_for(Duration::from_secs(15), || {
        last = sessions(socket);
        done(&last)
    });
    assert!(reached, "the listing never got there: {last:#?}");
    last
}

/// Has `shell` run `command` with its stdout in `name` under `dir`, and returns what it wrote. The
/// file appears whole (written beside it, then renamed), so a half-written one is never read.
fn shell_output(shell: &mut Spawned, dir: &Path, name: &str, command: &str) -> String {
    let path = dir.join(name);
    let partial = dir.join(format!("{name}.partial"));
    type_line(
        shell,
        &format!(
            "{command} > '{}' 2>&1; mv '{}' '{}'",
            partial.display(),
            partial.display(),
            path.display()
        ),
    );
    assert!(
        wait_for(Duration::from_secs(20), || path.exists()),
        "the shell never wrote {name}"
    );
    std::fs::read_to_string(&path).expect("read the shell's output")
}

/// `KEY=value` lines starting `WORKROOM_`, sorted.
fn workroom_variables(env: &str) -> Vec<String> {
    let mut variables: Vec<String> = env
        .lines()
        .filter(|line| line.starts_with("WORKROOM_"))
        .map(str::to_string)
        .collect();
    variables.sort();
    variables
}

const SHELL: &str = "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11";
const OTHER: &str = "0b9d33c1-7a44-4e1b-8f00-6c2a1d0abeef";
const RUN: &str = "c0ffee00-1111-4222-8333-44445555beef";

#[test]
fn sessions_json_lists_every_field_of_every_session() {
    let workspace = Workspace::new("api-sessions");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let cwd = workspace.dir.canonicalize().unwrap();

    let _shell = open(&socket, SHELL, "server", "wr-1", &cwd);
    let _run = attach_with_env(
        &socket,
        RUN,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "sleep 30"),
            ("WORKROOM_SESSION_TITLE", "dev"),
        ],
    );
    let listing = listing_until(&socket, |listing| {
        listing.len() == 2 && listing.iter().all(|session| !session["cwd"].is_null())
    });

    let shell = session(&listing, SHELL);
    assert_eq!(shell["label"], "server");
    assert_eq!(shell["scope"], json!({"kind": "workroom", "id": "wr-1"}));
    assert_eq!(shell["run"], false);
    assert_eq!(shell["cwd"], cwd.to_str().unwrap());
    assert_eq!(shell["coding_agent"], Value::Null);
    assert_eq!(shell["resume"], Value::Null);
    // Every field, null or not: a caller never has to ask whether a key is there.
    for key in [
        "id",
        "label",
        "title",
        "scope",
        "run",
        "cwd",
        "coding_agent",
        "resume",
    ] {
        assert!(shell.get(key).is_some(), "{key} missing from {shell}");
    }
    let run = session(&listing, RUN);
    assert_eq!(run["run"], true);
    assert_eq!(run["label"], "dev");
    assert_eq!(run["scope"], Value::Null);

    // The same sessions for a person, each by its id's last 8 characters.
    let table = workroom(Some(&socket), &["sessions"]);
    assert_eq!(table.code, 0, "{}", table.stderr);
    assert!(table.stdout.starts_with("ID "), "{}", table.stdout);
    assert!(
        table.stdout.contains("1d0a8e11  server"),
        "{}",
        table.stdout
    );
}

/// Milliseconds since the epoch, as a client's `attached_at_ms` counts them.
fn now_ms() -> u64 {
    let since = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    u64::try_from(since.as_millis()).unwrap()
}

/// This machine's hostname, as a client on it says.
fn this_hostname() -> String {
    let output = Command::new("/bin/hostname").output().expect("hostname");
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

/// A client of `socket`'s daemon attached to `session` over a connection of its own, as the app's
/// service connection would attach one: with `size`, asking to be probed, and saying it is the
/// app's, on `hostname`. No app attaches over its service connection yet (#688), so this stands in
/// for one.
fn attach_as_app(
    socket: &Path,
    session: &str,
    hostname: &str,
    size: (u16, u16),
) -> common::RpcClient {
    let stream = UnixStream::connect(socket).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut client = common::RpcClient::over(stream.try_clone().unwrap(), stream);
    client.handshake();
    let request = wr_protocol::terminal::AttachRequest {
        id: wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(session)),
        shell: Some("/bin/sh".into()),
        columns: size.0,
        rows: size.1,
        env: vec![("WORKROOM_SESSION_KEEPALIVE".into(), "1".into())],
        client: Some(wr_protocol::terminal::ClientKind::App),
        hostname: Some(hostname.into()),
        ..Default::default()
    };
    client.send(
        Service::Terminal,
        1,
        wr_protocol::frame::Frame::new(wr_protocol::frame::FrameKind::Attach, request.encode()),
    );
    client
}

/// The clients `workroom sessions --clients --json` lists on `session`, from a run that must
/// succeed.
fn clients_of(socket: &Path, session: &str) -> Vec<Value> {
    let run = workroom(Some(socket), &["sessions", "--clients", "--json"]);
    assert_eq!(run.code, 0, "{} {}", run.stdout, run.stderr);
    let sessions = run.envelope()["sessions"].as_array().cloned().unwrap();
    self::session(&sessions, session)["clients"]
        .as_array()
        .cloned()
        .unwrap_or_else(|| panic!("no clients in {sessions:?}"))
}

/// `workroom sessions --clients` (#688) reports every field of each kind of client: a pane of
/// the app, the app's own connection and a `workroom attach` someone ran, each with its kind, its
/// machine, when it attached, its size, whether it owns the size and its keepalive, in the order
/// they attached. Asked of one session by its target too; without `--clients`, nothing changes.
#[test]
fn sessions_clients_reports_every_field_of_a_pane_an_app_connection_and_a_cli_caller() {
    let workspace = Workspace::new("api-clients");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let cwd = workspace.dir.canonicalize().unwrap();
    let before = now_ms();

    let _pane = open(&socket, SHELL, "server", "wr-1", &cwd);
    listing_until(&socket, |listing| listing.len() == 1);
    // The session is listed before its pane's attach lands: wait for the pane's client, or the
    // app's can attach first and the order below flips.
    assert!(
        wait_for(Duration::from_secs(15), || clients_of(&socket, SHELL).len()
            == 1),
        "the pane's client never attached"
    );
    let mut app = attach_as_app(&socket, SHELL, "mac-b.local", (100, 30));
    let mut clients = Vec::new();
    let mut attached = |app: &mut common::RpcClient, count: usize| {
        wait_for(Duration::from_secs(15), || {
            app.pump(std::time::Instant::now() + Duration::from_millis(10));
            clients = clients_of(&socket, SHELL);
            clients.len() == count
        })
    };
    // Each attached before the next, so they are listed in this order.
    assert!(attached(&mut app, 2), "the app's client never attached");
    // Typed by hand: none of the app's session variables.
    let _cli = attach_with_env(&socket, SHELL, &[], &[]);
    assert!(attached(&mut app, 3), "the typed attach never attached");
    let after = now_ms();

    let host = this_hostname();
    let [pane, app_client, cli] = clients.as_slice() else {
        unreachable!()
    };
    assert_eq!(pane["kind"], "pane", "{pane}");
    assert_eq!(pane["hostname"], host.as_str(), "{pane}");
    // Its stdio is a pipe, so it has no size, and can't own one.
    assert_eq!(pane["size"], json!({"columns": 0, "rows": 0}), "{pane}");
    assert_eq!(pane["owns_size"], false, "{pane}");
    assert_eq!(pane["keepalive"], "off", "{pane}");
    assert_eq!(app_client["kind"], "app", "{app_client}");
    assert_eq!(app_client["hostname"], "mac-b.local", "{app_client}");
    assert_eq!(
        app_client["size"],
        json!({"columns": 100, "rows": 30}),
        "{app_client}"
    );
    assert_eq!(
        app_client["owns_size"], true,
        "the first with a size: {app_client}"
    );
    // Probed every 15 s, so not a probe missed yet.
    assert_eq!(app_client["keepalive"], "answering", "{app_client}");
    assert_eq!(cli["kind"], "cli", "{cli}");
    assert_eq!(cli["hostname"], host.as_str(), "{cli}");
    assert_eq!(cli["owns_size"], false, "{cli}");
    assert_eq!(cli["keepalive"], "off", "{cli}");
    let times: Vec<u64> = clients
        .iter()
        .map(|client| client["attached_at_ms"].as_u64().expect("attached_at_ms"))
        .collect();
    assert!(
        times.windows(2).all(|pair| pair[0] <= pair[1]) && before <= times[0] && times[2] <= after,
        "{before} {times:?} {after}"
    );
    let mut ids: Vec<u64> = clients
        .iter()
        .map(|client| client["id"].as_u64().expect("id"))
        .collect();
    ids.dedup();
    assert_eq!(ids.len(), 3, "{clients:?}");

    // One session by its target, the same clients; and none asked for, no `clients`.
    let resolved = workroom(
        Some(&socket),
        &["sessions", "server", "--clients", "--json"],
    );
    assert_eq!(resolved.code, 0, "{}", resolved.stderr);
    assert_eq!(
        resolved.envelope()["sessions"][0]["clients"]
            .as_array()
            .map(Vec::len),
        Some(3)
    );
    assert!(sessions(&socket)[0].get("clients").is_none());

    // For a person: the session's row, then a row for each client under it, in the order they
    // attached, their columns lined up.
    let table = workroom(Some(&socket), &["sessions", "--clients"]);
    assert_eq!(table.code, 0, "{}", table.stderr);
    let lines: Vec<&str> = table.stdout.lines().collect();
    assert!(lines[0].starts_with("ID "), "{}", table.stdout);
    assert!(lines[1].starts_with("1d0a8e11  server"), "{}", table.stdout);
    let rows = &lines[2..];
    assert_eq!(rows.len(), 3, "{}", table.stdout);
    for (row, kind) in rows.iter().zip(["pane", "app", "cli"]) {
        assert!(row.starts_with(&format!("  └ {kind} ")), "{row}");
        assert!(
            row.contains(" attached ") && row.contains("s ago "),
            "{row}"
        );
    }
    let app_row = rows[1];
    for cell in [
        " mac-b.local ",
        " 100×30 ",
        " owns size ",
        "keepalive answering",
    ] {
        assert!(app_row.contains(cell), "{cell:?} in {app_row}");
    }
    assert!(rows[0].contains(" no size "), "{}", rows[0]);
    let column = |row: &str, cell: &str| {
        row.chars().count() - row[row.find(cell).unwrap()..].chars().count()
    };
    assert_eq!(
        column(rows[0], "attached"),
        column(rows[1], "attached"),
        "lined up: {}",
        table.stdout
    );

    // Its connection gone, the app's client is too.
    drop(app);
    assert!(
        wait_for(Duration::from_secs(15), || clients_of(&socket, SHELL).len()
            == 2),
        "the app's client never detached"
    );
}

/// Every session's shell is told which pane it is and which daemon holds it (#684), and still sees
/// none of the session's own `WORKROOM_SESSION_*` variables. The values are the daemon's own: an
/// attach client typed in another pane forwards that pane's, which never reach this one.
#[test]
fn a_sessions_shell_sees_its_pane_and_daemon_and_no_session_variables() {
    let workspace = Workspace::new("api-identity");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = attach_with_env(
        &socket,
        SHELL,
        &[],
        &[
            ("WORKROOM_SESSION_TITLE", "server"),
            ("WORKROOM_SESSION_WORKROOM", "wr-1"),
            ("WORKROOM_PANE", "an-outer-pane"),
            ("WORKROOM_DAEMON", "/an/outer/daemon.sock"),
            ("WORKROOM_BIN_DIR", "/an/outer/bin"),
        ],
    );
    let bin = format!("WORKROOM_BIN_DIR={}", bin_folder(&socket).display());
    let env = shell_output(&mut shell, &workspace.dir, "shell-env", "env");
    assert_eq!(
        workroom_variables(&env),
        [
            bin.clone(),
            format!("WORKROOM_DAEMON={}", socket.display()),
            format!("WORKROOM_PANE={SHELL}"),
        ],
        "{env}"
    );

    // A run session's command too: it runs under the run supervisor, not a shell of its own.
    let ran = workspace.dir.join("run-env");
    let _run = attach_with_env(
        &socket,
        RUN,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            (
                "WORKROOM_SESSION_COMMAND",
                &format!(
                    "env > '{0}.partial'; mv '{0}.partial' '{0}'; sleep 30",
                    ran.display()
                ),
            ),
        ],
    );
    assert!(
        wait_for(Duration::from_secs(20), || ran.exists()),
        "the run command never ran"
    );
    let env = std::fs::read_to_string(&ran).unwrap();
    assert_eq!(
        workroom_variables(&env),
        [
            bin,
            format!("WORKROOM_DAEMON={}", socket.display()),
            format!("WORKROOM_PANE={RUN}"),
        ],
        "{env}"
    );
}

/// The bin folder of `socket`'s daemon (#695).
fn bin_folder(socket: &Path) -> std::path::PathBuf {
    socket.with_extension("bin").join("path")
}

/// The copy of its binary the daemon on `socket` keeps (#681), which its link points at once made.
fn daemons_copy(socket: &Path) -> std::path::PathBuf {
    socket
        .with_extension("bin")
        .join(format!("workroom-{}", common::stated_daemon_build()))
}

/// Every session gets the daemon's bin folder first on the PATH it starts with, and once (#695),
/// whatever PATH the client sent, none included; the folder holds one entry, `workroom`, a link to
/// the daemon's copy of its own binary, which is the daemon's build.
#[test]
fn a_session_starts_with_the_daemons_bin_folder_first_and_its_one_link() {
    let workspace = Workspace::new("api-bin");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let bin = bin_folder(&socket);
    let link = bin.join("workroom");
    assert!(
        wait_for(Duration::from_secs(15), || std::fs::read_link(&link)
            .is_ok_and(|target| target == daemons_copy(&socket))),
        "the link never pointed at the copy: {:?}",
        std::fs::read_link(&link)
    );
    let entries: Vec<_> = std::fs::read_dir(&bin)
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name())
        .collect();
    assert_eq!(entries, ["workroom"], "the folder holds one entry");

    // A command session's environment is the one it was started with: no profile runs before it.
    for (case, id, path) in [
        (
            "given",
            "b1b1b1b1-0000-4000-8000-000000000001",
            Some("/usr/bin:/bin"),
        ),
        (
            "listed",
            "b1b1b1b1-0000-4000-8000-000000000002",
            Some(&*format!("/usr/bin:{}:/bin", bin.display())),
        ),
        ("none", "b1b1b1b1-0000-4000-8000-000000000003", None),
    ] {
        let out = workspace.dir.join(format!("bin-{case}"));
        let command = format!(
            "/bin/sh -c 'printf \"%s\\n\" \"$PATH\" \"$WORKROOM_BIN_DIR\" > {0}.partial; \
             \"$WORKROOM_BIN_DIR/workroom\" protocol >> {0}.partial; mv {0}.partial {0}; sleep 30'",
            out.display()
        );
        let mut env = vec![
            ("SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_COMMAND", command.as_str()),
        ];
        if let Some(path) = path {
            env.push(("PATH", path));
        }
        let client = attach_with_only(&socket, id, &env);
        assert!(
            wait_for(Duration::from_secs(20), || out.exists()),
            "{case}: the command never ran"
        );
        let seen = std::fs::read_to_string(&out).unwrap();
        let mut lines = seen.lines();
        let want = match path {
            Some(_) => format!("{}:/usr/bin:/bin", bin.display()),
            None => format!(
                "{}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                bin.display()
            ),
        };
        assert_eq!(lines.next(), Some(want.as_str()), "{case}: {seen}");
        assert_eq!(
            lines.next(),
            Some(&*bin.display().to_string()),
            "{case}: {seen}"
        );
        assert!(
            seen.contains(&format!("daemon-build {}\n", common::stated_daemon_build())),
            "{case}: the link is not the daemon's build: {seen}"
        );
        drop(client);
    }

    // The folder gone from under the daemon, as a `/tmp` cleaner takes it (this test's daemon's,
    // in this test's own workspace): the next session makes it and its link again.
    std::fs::remove_dir_all(&bin).expect("the daemon's bin folder");
    let out = workspace.dir.join("bin-again");
    let command = format!(
        "/bin/sh -c '\"$WORKROOM_BIN_DIR/workroom\" protocol > {0}.partial; mv {0}.partial {0}; \
         sleep 30'",
        out.display()
    );
    let _client = attach_with_only(
        &socket,
        "b1b1b1b1-0000-4000-8000-000000000004",
        &[
            ("SHELL", "/bin/sh"),
            ("PATH", "/usr/bin:/bin"),
            ("WORKROOM_SESSION_COMMAND", command.as_str()),
        ],
    );
    assert!(
        wait_for(Duration::from_secs(20), || out.exists()),
        "the command never ran"
    );
    assert_eq!(std::fs::read_link(&link).unwrap(), daemons_copy(&socket));
    assert!(
        std::fs::read_to_string(&out)
            .unwrap()
            .contains(&format!("daemon-build {}", common::stated_daemon_build())),
        "the link made again does not run the daemon's build"
    );
}

/// The start of a test home's `.zshenv`. Ubuntu's /etc/zsh/zshrc runs compinit unless told not to,
/// and on GitHub's runners, where a folder on `fpath` is writable by others, compinit asks
/// "Ignore insecure directories and continue [y] or abort compaudit and exit [n]?" and reads one
/// key: the first one the test typed (as in `real_shell`).
const ZSHENV_FOR_TESTS: &str = "skip_global_compinit=1\n";
/// The start of a test home's `.zshrc`: a prompt `wait_for_prompt` waits for.
const ZSHRC_PROMPT: &str = "PS1='PROMPT> '\n";

/// Waits for `shell`'s prompt (`ZSHRC_PROMPT`), so nothing is typed before the line editor reads
/// it. The reader goes on draining the pane while it is held.
fn wait_for_prompt(shell: &mut Spawned, case: &str) -> common::ClientReader {
    let mut screen = common::ClientReader::new(shell);
    let seen = screen.read_until("PROMPT> ", Duration::from_secs(30));
    assert!(
        seen.contains("PROMPT> "),
        "{case}: the shell never prompted: {seen:?}"
    );
    screen
}

/// An attach for session `id` with `env` and nothing else in its environment, which it forwards
/// to the session: none of this test's own, a developer's `ZDOTDIR` or `PATH` say.
fn attach_with_only(socket: &Path, id: &str, env: &[(&str, &str)]) -> Spawned {
    Spawned(
        Command::new(common::daemon_binary())
            .args(["attach", "--socket"])
            .arg(socket)
            .args(["--session", id])
            .env_clear()
            .envs(env.iter().copied())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn attach"),
    )
}

/// A login zsh whose `.zshrc` unsets `WORKROOM_BIN_DIR` keeps the PATH its startup files made
/// (#695): the user's own folder first, as for their own `workroom` build, and never an empty
/// entry, which would put the current directory on PATH.
#[test]
fn a_zsh_whose_startup_file_unsets_the_variable_keeps_its_own_path() {
    if !Path::new("/bin/zsh").exists() {
        eprintln!("skipped: no /bin/zsh");
        return;
    }
    let workspace = Workspace::new("api-bin-optout");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let home = workspace.dir.join("home");
    std::fs::create_dir(&home).unwrap();
    std::fs::write(home.join(".zshenv"), ZSHENV_FOR_TESTS).unwrap();
    std::fs::write(
        home.join(".zshrc"),
        format!("{ZSHRC_PROMPT}unset WORKROOM_BIN_DIR\npath=(/opt/mine $path)\n"),
    )
    .unwrap();
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty");
    let resources = resources.to_string_lossy().into_owned();
    let home = home.to_string_lossy().into_owned();
    for (case, id, integration) in [
        ("ghostty", "b3b3b3b3-0000-4000-8000-000000000001", true),
        ("plain", "b3b3b3b3-0000-4000-8000-000000000002", false),
    ] {
        let mut env = vec![
            ("SHELL", "/bin/zsh"),
            ("HOME", home.as_str()),
            ("PATH", "/usr/bin:/bin"),
            ("TERM", "xterm-256color"),
        ];
        if integration {
            env.push(("WORKROOM_SESSION_RESOURCES", resources.as_str()));
        }
        let mut shell = attach_with_only(&socket, id, &env);
        let _screen = wait_for_prompt(&mut shell, case);
        let seen = shell_output(
            &mut shell,
            &workspace.dir,
            &format!("zsh-optout-{case}"),
            "print -r -- \"[$PATH]\" \"[${WORKROOM_BIN_DIR-unset}]\"",
        );
        let path = seen
            .trim()
            .strip_prefix('[')
            .and_then(|rest| rest.split_once("] ["))
            .map(|(path, _)| path)
            .unwrap_or_else(|| panic!("{case}: {seen}"));
        assert!(path.starts_with("/opt/mine:"), "{case}: {seen}");
        assert!(
            !path
                .split(':')
                .any(|entry| entry.is_empty() || entry == "."),
            "{case}: an empty entry: {seen}"
        );
        assert!(seen.contains("[unset]"), "{case}: {seen}");
    }
}

/// A daemon started from `binary`, a file of the test's own standing in for an app bundle's.
/// Linux refuses to run a file another process forked meanwhile still has open for writing
/// (`ETXTBSY`), so the spawn is tried again until it runs.
fn start_daemon_from(binary: &Path, socket: &Path) -> Spawned {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let child = loop {
        let spawned = Command::new(binary)
            .args(["serve", "--socket"])
            .arg(socket)
            .args(["--idle-timeout", "60"])
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        match spawned {
            Err(e)
                if e.kind() == std::io::ErrorKind::ExecutableFileBusy
                    && std::time::Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(20));
            }
            other => break other.expect("spawn daemon"),
        }
    };
    let child = Spawned(child);
    assert!(
        common::wait_listening(socket, Duration::from_secs(30)),
        "daemon never listened on its socket"
    );
    child
}

/// An update whose CLI commands alone changed (#680) is installed over the file the daemon started
/// from, and nothing is handed off. The next session to start notices, and the daemon's copy is
/// made again from it: that session's `workroom`, and the one a pane opened before it reaches
/// through the same link, is the new binary, while the daemon goes on running its own program.
/// The old copy went with the rename over it; nothing staged is left.
#[test]
fn a_cli_only_update_reaches_every_panes_workroom() {
    let workspace = Workspace::new("api-bin-cli");
    let socket = workspace.socket();
    let app = workspace.dir.join("app");
    std::fs::create_dir(&app).unwrap();
    let source = app.join("workroom");
    std::fs::copy(common::daemon_binary(), &source).expect("copy the binary");
    let mut daemon = start_daemon_from(&source, &socket);
    let copy = daemons_copy(&socket);
    let link = bin_folder(&socket).join("workroom");
    assert!(
        wait_for(Duration::from_secs(15), || std::fs::read_link(&link)
            .is_ok_and(|target| target == copy)),
        "the link never pointed at the copy"
    );
    let env = [("SHELL", "/bin/sh"), ("PATH", "/usr/bin:/bin")];
    let mut before = attach_with_only(&socket, "b4b4b4b4-0000-4000-8000-000000000001", &env);
    let _ = shell_output(&mut before, &workspace.dir, "cli-ready", "true");

    // The update, staged and renamed into place as an installer does: the daemon build is the
    // same, and a byte more, which the loader ignores, makes it another file.
    let staged = app.join(".workroom.new");
    let mut bytes = std::fs::read(common::daemon_binary()).unwrap();
    bytes.push(b'\n');
    common::write_executable(&staged, &bytes);
    std::fs::rename(&staged, &source).unwrap();

    let mut after = attach_with_only(&socket, "b4b4b4b4-0000-4000-8000-000000000002", &env);
    assert!(
        wait_for(Duration::from_secs(20), || std::fs::read(&copy)
            .is_ok_and(|now| now == bytes)),
        "the copy was never made again from the update"
    );
    assert_eq!(std::fs::read_link(&link).unwrap(), copy);
    for (name, shell) in [("cli-before", &mut before), ("cli-after", &mut after)] {
        let seen = shell_output(
            shell,
            &workspace.dir,
            name,
            &format!(
                "{{ cmp \"$WORKROOM_BIN_DIR/workroom\" '{}' && echo SAME; \
                 \"$WORKROOM_BIN_DIR/workroom\" protocol; }}",
                source.display()
            ),
        );
        assert!(seen.contains("SAME"), "{name}: {seen}");
        assert!(
            seen.contains(&format!("daemon-build {}", common::stated_daemon_build())),
            "{name}: {seen}"
        );
    }
    assert!(daemon.0.try_wait().unwrap().is_none(), "the daemon ended");
    let mut left: Vec<String> = std::fs::read_dir(socket.with_extension("bin"))
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    let mut want = vec![
        "OWNER".to_string(),
        copy.file_name().unwrap().to_string_lossy().into_owned(),
        "path".to_string(),
        "shell".to_string(),
    ];
    want.sort();
    assert_eq!(left, want, "something staged was left");
}

/// A login zsh, the Mac's default shell, has the bin folder first once its startup files have run
/// (#695), with Ghostty's integration and without: macOS's `/etc/zprofile` reorders PATH
/// (`path_helper`), and here a `.zprofile` sets it outright and a `.zshrc` puts a folder ahead.
/// `workroom` by name is the link, and the shell's own `.zshenv`, `.zprofile` and `.zshrc` all ran.
#[test]
fn a_login_zsh_has_the_bin_folder_first_after_its_startup_files() {
    if !Path::new("/bin/zsh").exists() {
        eprintln!("skipped: no /bin/zsh");
        return;
    }
    let workspace = Workspace::new("api-bin-zsh");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let bin = bin_folder(&socket);
    let home = workspace.dir.join("home");
    std::fs::create_dir(&home).unwrap();
    std::fs::write(
        home.join(".zshenv"),
        format!("{ZSHENV_FOR_TESTS}export ZSHENV_RAN=1\n"),
    )
    .unwrap();
    std::fs::write(
        home.join(".zprofile"),
        "export PATH=/usr/bin:/bin\nexport ZPROFILE_RAN=1\n",
    )
    .unwrap();
    std::fs::write(
        home.join(".zshrc"),
        format!("{ZSHRC_PROMPT}path=(/opt/elsewhere $path)\nexport ZSHRC_RAN=1\n"),
    )
    .unwrap();
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty");
    let resources = resources.to_string_lossy().into_owned();
    let home = home.to_string_lossy().into_owned();
    for (case, id, integration) in [
        ("ghostty", "b2b2b2b2-0000-4000-8000-000000000001", true),
        ("plain", "b2b2b2b2-0000-4000-8000-000000000002", false),
    ] {
        let mut env = vec![
            ("SHELL", "/bin/zsh"),
            ("HOME", home.as_str()),
            ("PATH", "/usr/bin:/bin"),
            ("TERM", "xterm-256color"),
        ];
        if integration {
            env.push(("WORKROOM_SESSION_RESOURCES", resources.as_str()));
        } else {
            // The hook gone from under the daemon, as a `/tmp` cleaner takes it: a new session
            // writes it again before its shell is pointed at it, and the shell still reads its
            // startup files.
            let hook = socket.with_extension("bin").join("shell/zsh/.zshenv");
            std::fs::remove_file(&hook).expect("the daemon's hook");
        }
        let mut shell = attach_with_only(&socket, id, &env);
        let _screen = wait_for_prompt(&mut shell, case);
        let seen = shell_output(
            &mut shell,
            &workspace.dir,
            &format!("zsh-{case}"),
            "print -rl -- \"$PATH\" \"$ZSHENV_RAN$ZPROFILE_RAN$ZSHRC_RAN\" \"$(whence -p workroom)\" \
             \"${ZDOTDIR-unset}\" \"${+functions[_ghostty_precmd]}\"",
        );
        let mut lines = seen.lines();
        let path = lines.next().unwrap_or_default();
        assert_eq!(
            path.split(':').next(),
            Some(&*bin.display().to_string()),
            "{case}: {seen}"
        );
        assert_eq!(
            path.split(':')
                .filter(|entry| *entry == bin.display().to_string())
                .count(),
            1,
            "{case}: {seen}"
        );
        assert!(path.contains(":/opt/elsewhere:"), "{case}: {seen}");
        assert_eq!(
            lines.next(),
            Some("111"),
            "{case}: a startup file did not run: {seen}"
        );
        assert_eq!(
            lines.next(),
            Some(&*bin.join("workroom").display().to_string()),
            "{case}: {seen}"
        );
        // The hook gave the shell its own ZDOTDIR back: none.
        assert_eq!(lines.next(), Some("unset"), "{case}: {seen}");
        // Ghostty's integration still loaded behind the hook, where it was asked for.
        let loaded = if integration { "1" } else { "0" };
        assert_eq!(lines.next(), Some(loaded), "{case}: {seen}");
    }
}

/// `workroom sessions --json` run by `shell` with `prefix` before it (`env -i`, say): its envelope.
/// Through a `sh` of its own that waits for it, so the command is a grandchild of the session's
/// shell at least, as one a coding agent runs is.
fn sessions_from(shell: &mut Spawned, dir: &Path, name: &str, prefix: &str, args: &str) -> Value {
    let binary = common::daemon_binary();
    let output = shell_output(
        shell,
        dir,
        name,
        &format!(
            "{prefix} /bin/sh -c \"'{}' sessions --json {args}; exit \\$?\"",
            binary.display()
        ),
    );
    serde_json::from_str(&output).unwrap_or_else(|e| panic!("not one envelope ({e}): {output}"))
}

/// The ids an envelope lists, sorted.
fn listed_ids(envelope: &Value) -> Vec<String> {
    let mut ids: Vec<String> = envelope["sessions"]
        .as_array()
        .unwrap_or_else(|| panic!("no sessions in {envelope}"))
        .iter()
        .map(|session| session["id"].as_str().unwrap().to_string())
        .collect();
    ids.sort();
    ids
}

/// `sessions` in a pane lists its own workroom's sessions and names the pane as the caller;
/// `--all` lists every session. Outside any pane there is no scope, so every session is listed.
#[test]
fn sessions_in_a_pane_lists_its_workroom_and_all_widens_it() {
    let workspace = Workspace::new("api-scope");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let _neighbour = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let _elsewhere = open(&socket, RUN, "server", "wr-2", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);
    let mut ours = vec![SHELL.to_string(), OTHER.to_string()];
    ours.sort();

    let scoped = sessions_from(&mut shell, &workspace.dir, "scoped", "", "");
    assert_eq!(scoped["ok"], true, "{scoped}");
    assert_eq!(listed_ids(&scoped), ours, "{scoped}");
    assert_eq!(scoped["caller"], SHELL, "{scoped}");

    let all = sessions_from(&mut shell, &workspace.dir, "all", "", "--all");
    assert_eq!(listed_ids(&all).len(), 3, "{all}");
    assert_eq!(all["caller"], SHELL, "{all}");

    // From no pane: no caller, so no scope to keep to.
    let outside = workroom(Some(&socket), &["sessions", "--json"]).envelope();
    assert_eq!(listed_ids(&outside).len(), 3, "{outside}");
    assert_eq!(outside["caller"], Value::Null, "{outside}");
}

/// The daemon finds the pane from the connecting process, up through its parents to a session's
/// shell: without `WORKROOM_PANE`, and with one naming another pane, it is the pane the process
/// runs in. Without `WORKROOM_DAEMON` too (`env -i`), the CLI finds the daemon the same way, as
/// the nearest parent serving a socket. Either way the listing keeps to the pane's workroom.
#[test]
fn a_command_in_a_pane_without_its_variables_is_known_by_its_process() {
    let workspace = Workspace::new("api-peer");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let _neighbour = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let _elsewhere = open(&socket, RUN, "server", "wr-2", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);
    let mut ours = vec![SHELL.to_string(), OTHER.to_string()];
    ours.sort();

    for (name, prefix) in [
        ("no-pane", "env -u WORKROOM_PANE"),
        ("nothing", "env -i PATH=/usr/bin:/bin"),
    ] {
        let envelope = sessions_from(&mut shell, &workspace.dir, name, prefix, "");
        assert_eq!(envelope["ok"], true, "{prefix}: {envelope}");
        assert_eq!(envelope["caller"], SHELL, "{prefix}: {envelope}");
        assert_eq!(listed_ids(&envelope), ours, "{prefix}: {envelope}");
    }
    // A pane variable naming another live pane, one in the other workroom, is passed over: the
    // process runs in this pane, whatever it was handed.
    let another = sessions_from(
        &mut shell,
        &workspace.dir,
        "another",
        &format!("env WORKROOM_PANE={RUN}"),
        "",
    );
    assert_eq!(another["caller"], SHELL, "{another}");
    assert_eq!(listed_ids(&another), ours, "{another}");
    // As is one naming no session of this daemon (a stale one, say).
    let stale = sessions_from(
        &mut shell,
        &workspace.dir,
        "stale",
        "env WORKROOM_PANE=0b9d33c1-0000-4000-8000-000000000000",
        "",
    );
    assert_eq!(stale["caller"], SHELL, "{stale}");
}

/// A command whose process runs in no pane (under a daemonized tmux server, say, whose clients'
/// variables it was given) is the pane its `WORKROOM_PANE` names, when that is one of the daemon's
/// sessions; naming none of them, it has no caller.
#[test]
fn a_command_outside_every_pane_is_the_pane_it_names() {
    let workspace = Workspace::new("api-named");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let _neighbour = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let _elsewhere = open(&socket, RUN, "server", "wr-2", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);

    // This test's process is in none of this daemon's panes.
    let named = |pane: &str| {
        let output = Command::new(common::daemon_binary())
            .args(["sessions", "--json"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", std::env::temp_dir())
            .env("WORKROOM_DAEMON", &socket)
            .env("WORKROOM_PANE", pane)
            .stdin(Stdio::null())
            .output()
            .expect("run workroom");
        Run {
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            code: output.status.code().unwrap_or(-1),
        }
        .envelope()
    };
    let elsewhere = named(RUN);
    assert_eq!(elsewhere["caller"], RUN, "{elsewhere}");
    assert_eq!(listed_ids(&elsewhere), [RUN], "{elsewhere}");
    // `session.list` keeps to the caller's scope unless asked for `all`, as `sessions` does.
    let mut api = Api::connect(&socket);
    let unasked = api.request(&json!({"method": "session.list", "caller": OTHER}));
    assert_eq!(unasked["result"]["caller"], OTHER, "{unasked}");
    let mut ours = vec![SHELL.to_string(), OTHER.to_string()];
    ours.sort();
    assert_eq!(listed_ids(&unasked["result"]), ours, "{unasked}");
    let all = api.request(&json!({
        "method": "session.list",
        "params": {"all": true},
        "caller": OTHER,
    }));
    assert_eq!(listed_ids(&all["result"]).len(), 3, "{all}");
    let gone = named("0b9d33c1-0000-4000-8000-000000000000");
    assert_eq!(gone["caller"], Value::Null, "{gone}");
    assert_eq!(listed_ids(&gone).len(), 3, "{gone}");
}

/// A pane opened before its daemon gave shells their variables has neither, so it is known by
/// its process alone, and that holds across a hand-off: the program handed to keeps the pid, the
/// shells' parent, and the arguments that name its socket.
#[test]
fn a_pane_without_its_variables_is_known_across_a_hand_off() {
    let workspace = Workspace::new("api-peer-handoff");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let _neighbour = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let _elsewhere = open(&socket, RUN, "server", "wr-2", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);

    // Started now, run after the hand-off: it waits for `go`.
    let go = workspace.dir.join("go");
    let out = workspace.dir.join("after-hand-off");
    type_line(
        &mut shell,
        &format!(
            "(while [ ! -e '{go}' ]; do sleep 0.05; done; \
              env -i PATH=/usr/bin:/bin /bin/sh -c \"'{binary}' sessions --json; exit \\$?\" \
              > '{out}.partial'; mv '{out}.partial' '{out}') &",
            go = go.display(),
            binary = common::daemon_binary().display(),
            out = out.display(),
        ),
    );
    // Typed before the hand-off, or the shell may not have read the line yet.
    let started = workspace.dir.join("started");
    shell_output(&mut shell, &workspace.dir, "started", "echo started");
    assert!(started.exists());
    drop(shell);

    // Named `workroom`, as an installed one is: the CLI takes a parent for a daemon only when its
    // binary is named as one.
    let next = workspace.dir.join("next").join("workroom");
    std::fs::create_dir(workspace.dir.join("next")).expect("a folder for the next program");
    common::copy_daemon_binary(&next);
    let output = Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(&socket)
        .arg("--binary")
        .arg(&next)
        .arg("--force")
        .output()
        .expect("hand-off");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    std::fs::write(&go, b"").expect("go");
    assert!(
        wait_for(Duration::from_secs(20), || out.exists()),
        "the pane's command never ran"
    );
    let output = std::fs::read_to_string(&out).unwrap();
    let envelope: Value = serde_json::from_str(&output)
        .unwrap_or_else(|e| panic!("not one envelope ({e}): {output}"));
    assert_eq!(envelope["caller"], SHELL, "{envelope}");
    let mut ours = vec![SHELL.to_string(), OTHER.to_string()];
    ours.sort();
    assert_eq!(listed_ids(&envelope), ours, "{envelope}");
}

/// The live title follows the program's OSC 0 and OSC 2, beside the label the app gave, which it
/// never changes. Needs the shadow terminal, which is what parses them.
#[test]
fn a_sessions_live_title_follows_osc_0_and_2() {
    if !has_terminal_state() {
        eprintln!("skipped: needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-title");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let listing = listing_until(&socket, |listing| listing.len() == 1);
    assert_eq!(session(&listing, SHELL)["title"], Value::Null);

    type_line(&mut shell, r"printf '\033]2;build watch\007'");
    listing_until(&socket, |listing| listing[0]["title"] == "build watch");
    type_line(&mut shell, r"printf '\033]0;vim notes.md\033\\'");
    let listing = listing_until(&socket, |listing| listing[0]["title"] == "vim notes.md");
    assert_eq!(listing[0]["label"], "server");

    // A program's program status is its coding agent's state.
    type_line(
        &mut shell,
        r#"sh -c 'printf "\033]7501;state=working:app=claude:msg=VGVzdHM=\033\\"; sleep 20'"#,
    );
    let listing = listing_until(&socket, |listing| !listing[0]["coding_agent"].is_null());
    let agent = &listing[0]["coding_agent"];
    assert_eq!(agent["state"], "working", "{agent}");
    assert_eq!(agent["app"], "claude", "{agent}");
    assert_eq!(agent["waiting_on_user"], false, "{agent}");
}

/// A shell the daemon made has its own resume token, and a report it signs with it, from its own
/// pid, is the session's resume record in the listing (ADR 0082): the program and its folder,
/// never the command's arguments.
#[test]
fn a_shells_resume_report_is_its_record_in_the_listing() {
    // SAFETY: no preconditions.
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("skipped: a daemon running as root accepts no resume reports (ADR 0082)");
        return;
    }
    let workspace = Workspace::new("api-resume");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    // `nvim -S /secret/session.vim`, signed with `sha256sum` on Linux, `shasum` on macOS.
    type_line(
        &mut shell,
        r#"body="pid=$$:time=$(date +%s):argv=bnZpbQ==,LVM=,L3NlY3JldC9zZXNzaW9uLnZpbQ=="; mac=$({ printf '%s:%s' "$body" "$OSC7577_TOKEN" | sha256sum 2>/dev/null || printf '%s:%s' "$body" "$OSC7577_TOKEN" | shasum -a 256; } | cut -d' ' -f1); printf '\033]7577;%s:mac=%s\007' "$body" "$mac""#,
    );
    let listing = listing_until(&socket, |listing| !listing[0]["resume"].is_null());
    let resume = &listing[0]["resume"];
    assert_eq!(resume["program"], "nvim", "{resume}");
    let folder = workspace.dir.canonicalize().unwrap();
    assert_eq!(resume["cwd"], folder.to_str().unwrap(), "{resume}");
    assert!(
        resume["reported_at"].as_u64().unwrap() > 1_700_000_000_000,
        "{resume}"
    );
    let listed = Value::Array(listing.clone()).to_string();
    assert!(
        !listed.contains("session.vim"),
        "the arguments stay out of the listing: {listed}"
    );
}

/// A shell whose app turned "Resume programs after a restart" off (#827) gets no resume token, so
/// the report the test above signs makes no record. A mark printed after it is the control that
/// the daemon read past it.
#[test]
fn a_shell_whose_app_turned_resume_off_has_no_token_and_makes_no_record() {
    let workspace = Workspace::new("api-resume-off");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = attach_with_env(
        &socket,
        SHELL,
        &[],
        &[
            ("WORKROOM_SESSION_TITLE", "server"),
            ("WORKROOM_SESSION_WORKROOM", "wr-1"),
            ("WORKROOM_SESSION_CWD", workspace.dir.to_str().unwrap()),
            ("WORKROOM_SESSION_PROGRAM_RESUME", "off"),
        ],
    );
    listing_until(&socket, |listing| listing.len() == 1);
    let token = shell_output(
        &mut shell,
        &workspace.dir,
        "token",
        r#"printf '[%s]' "${OSC7577_TOKEN-none}""#,
    );
    assert_eq!(token, "[none]", "a shell with resume off has no token");
    type_line(
        &mut shell,
        r#"body="pid=$$:time=$(date +%s):argv=bnZpbQ==,LVM=,L3NlY3JldC9zZXNzaW9uLnZpbQ=="; mac=$({ printf '%s:%s' "$body" "$OSC7577_TOKEN" | sha256sum 2>/dev/null || printf '%s:%s' "$body" "$OSC7577_TOKEN" | shasum -a 256; } | cut -d' ' -f1); printf '\033]7577;%s:mac=%s\007' "$body" "$mac""#,
    );
    // The control: the daemon reads a session's output for reports before it sends it on, so a
    // mark printed after the report reaching this client means the report was read.
    let mut screen = common::ClientReader::new(&mut shell);
    type_line(&mut shell, r"printf '%s-%s\n' report read");
    let seen = screen.read_until("report-read", Duration::from_secs(30));
    assert!(
        seen.contains("report-read"),
        "the mark never came: {seen:?}"
    );
    let listing = sessions(&socket);
    assert!(
        listing[0]["resume"].is_null(),
        "no record: {}",
        listing[0]["resume"]
    );

    // A session `workroom new` opens from it is made as it was, resume off included.
    let (code, envelope) = from_pane(&mut shell, &workspace.dir, "new.json", "new");
    assert_eq!(code, 0, "{envelope}");
    let id = envelope["session"]["id"].as_str().unwrap().to_string();
    let said = run_in(
        &socket,
        &id,
        &workspace.dir,
        "new-token",
        r#"printf '[%s]' "${OSC7577_TOKEN-none}""#,
    );
    assert_eq!(
        said, "[none]",
        "a session opened from it has no token either"
    );

    // The control: one opened from a pane with resume on has its own, unless the daemon runs as
    // root, which gives none (ADR 0082).
    // SAFETY: no preconditions.
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let mut on = open(&socket, OTHER, "on", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);
    let (code, envelope) = from_pane(&mut on, &workspace.dir, "new-on.json", "new");
    assert_eq!(code, 0, "{envelope}");
    let id = envelope["session"]["id"].as_str().unwrap().to_string();
    let said = run_in(
        &socket,
        &id,
        &workspace.dir,
        "new-on-token",
        r#"printf '[%s]' "${OSC7577_TOKEN-none}""#,
    );
    assert_eq!(said.len(), 34, "a token of 32 hex digits: {said}");
}

/// libghostty's screen format has no title, so a hand-off carries it apart; without that, the
/// next program would list the session untitled until its program set the title again.
#[test]
fn a_hand_off_keeps_the_live_title() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-title-handoff");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    type_line(&mut shell, r"printf '\033]2;kept across\007'");
    listing_until(&socket, |listing| {
        listing.len() == 1 && listing[0]["title"] == "kept across"
    });
    drop(shell);

    let next = workspace.dir.join("next-workroom");
    common::copy_daemon_binary(&next);
    let output = Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(&socket)
        .arg("--binary")
        .arg(&next)
        .arg("--force")
        .output()
        .expect("hand-off");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let listing = sessions(&socket);
    assert_eq!(listing[0]["title"], "kept across", "{listing:?}");
    assert_eq!(listing[0]["label"], "server");
}

/// `workroom sessions <target>` with `--json`: the one session, or the error and its exit code.
fn target(socket: &Path, target: &str) -> Result<String, (i32, String, Vec<String>)> {
    let run = workroom(Some(socket), &["sessions", target, "--json"]);
    let envelope = run.envelope();
    if run.code == 0 {
        let sessions = envelope["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1, "{envelope}");
        return Ok(sessions[0]["id"].as_str().unwrap().to_string());
    }
    // Sorted: the listing is oldest first, and these sessions start at the same moment.
    let mut matches: Vec<String> = envelope["error"]["matches"]
        .as_array()
        .map(|matches| {
            matches
                .iter()
                .map(|session| session["id"].as_str().unwrap().to_string())
                .collect()
        })
        .unwrap_or_default();
    matches.sort();
    Err((
        run.code,
        envelope["error"]["kind"].as_str().unwrap().to_string(),
        matches,
    ))
}

#[test]
fn a_target_resolves_by_id_suffix_label_and_title_and_refuses_ambiguity() {
    let workspace = Workspace::new("api-targets");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut first = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let _second = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let _third = open(&socket, RUN, "tests", "wr-2", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);

    assert_eq!(target(&socket, SHELL), Ok(SHELL.into()));
    assert_eq!(target(&socket, &SHELL.to_uppercase()), Ok(SHELL.into()));
    assert_eq!(target(&socket, "8e11"), Ok(SHELL.into()));
    assert_eq!(
        target(&socket, "e11"),
        Err((3, "TargetNotFound".into(), vec![])),
        "a suffix is at least 4 characters"
    );
    assert_eq!(target(&socket, "server"), Ok(SHELL.into()));
    assert_eq!(
        target(&socket, "nothing"),
        Err((3, "TargetNotFound".into(), vec![]))
    );

    // Two ids end "beef", and two sessions are labelled "tests": nothing is chosen, both listed.
    for ambiguous in ["beef", "tests"] {
        assert_eq!(
            target(&socket, ambiguous),
            Err((3, "TargetAmbiguous".into(), vec![OTHER.into(), RUN.into()])),
            "{ambiguous}"
        );
    }
    let human = workroom(Some(&socket), &["sessions", "tests"]);
    assert_eq!(human.code, 3);
    assert_eq!(human.stdout, "");
    assert!(
        human
            .stderr
            .starts_with("Error: \"tests\" matches 2 sessions"),
        "{}",
        human.stderr
    );
    for id in [OTHER, RUN] {
        assert!(
            human.stderr.contains(&format!("  {id}  tests")),
            "{}",
            human.stderr
        );
    }

    if has_terminal_state() {
        type_line(&mut first, r"printf '\033]2;watcher\007'");
        listing_until(&socket, |listing| {
            listing.iter().any(|session| session["title"] == "watcher")
        });
        assert_eq!(target(&socket, "watcher"), Ok(SHELL.into()));
    }
}

#[test]
fn with_no_daemon_every_run_exits_7_daemon_unreachable() {
    let workspace = Workspace::new("api-no-daemon");
    let nowhere = workspace.dir.join("nobody.sock");
    let run = |daemon: Option<&Path>, args: &[&str]| match daemon {
        Some(_) => workroom(daemon, args),
        None => workroom_outside_any_daemon(&workspace.dir, args),
    };
    for daemon in [None, Some(nowhere.as_path())] {
        for args in [
            &["sessions", "--json"][..],
            &["sessions", "x", "--json"],
            &["send", "x", "hi", "--json"],
        ] {
            let run = run(daemon, args);
            assert_eq!(run.code, 7, "{args:?} {}", run.stdout);
            assert_eq!(run.envelope()["error"]["kind"], "DaemonUnreachable");
            assert_eq!(run.stderr, "");
        }
        let human = run(daemon, &["sessions"]);
        assert_eq!(human.code, 7);
        assert!(human.stderr.starts_with("Error: "), "{}", human.stderr);
    }
}

/// A daemon from before the terminal API would fail the whole connection on its service byte, so
/// the CLI checks the greeting, sends it nothing, and exits 7 `DaemonTooOld`, saying it needs
/// updating.
#[test]
fn a_daemon_older_than_the_terminal_api_is_sent_nothing() {
    let workspace = Workspace::new("api-old-daemon");
    let socket = workspace.socket();
    assert_too_old(&socket, &["sessions", "--json"], "sessions");
    // One that types, too: nothing it would type reaches the old daemon.
    assert_too_old(&socket, &["send", "x", "hi", "--json"], "send");
}

/// Every `api` subcommand checks the greeting as `sessions` does, and names itself in the failure.
#[test]
fn every_api_subcommand_is_refused_by_a_daemon_older_than_the_terminal_api() {
    let workspace = Workspace::new("api-old-daemon-api");
    let socket = workspace.socket();
    for (args, command) in [
        (&["api", "list", "--json"][..], "api list"),
        (
            &["api", "describe", "session.list", "--json"],
            "api describe",
        ),
        (&["api", "call", "session.list", "{}", "--json"], "api call"),
    ] {
        assert_too_old(&socket, args, command);
    }
}

/// `workroom <args>` against a fake daemon on `socket` that greets with the protocol before the
/// terminal API's: it exits 7 `DaemonTooOld` in `command`'s envelope, saying the daemon needs
/// updating, and sends nothing past the greeting.
fn assert_too_old(socket: &Path, args: &[&str], command: &str) {
    use std::io::Read;
    use wr_protocol::envelope::{Hello, MIN_TERMINAL_API_VERSION};

    let _ = std::fs::remove_file(socket);
    let listener = UnixListener::bind(socket).expect("bind fake daemon");
    let fake = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let hello = Hello {
            protocol_version: MIN_TERMINAL_API_VERSION - 1,
            build: "old".into(),
        };
        stream.write_all(&hello.encode()).expect("greet");
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut received = Vec::new();
        let mut chunk = [0u8; 4096];
        while let Ok(read) = stream.read(&mut chunk) {
            if read == 0 {
                break;
            }
            received.extend_from_slice(&chunk[..read]);
        }
        let (_, consumed) = Hello::decode(&received)
            .expect("a greeting")
            .expect("whole");
        received.len() - consumed
    });
    let run = workroom(Some(socket), args);
    assert_eq!(run.code, 7, "{args:?}: {}", run.stdout);
    let envelope = run.envelope();
    assert_eq!(envelope["error"]["kind"], "DaemonTooOld", "{envelope}");
    assert_eq!(envelope["command"], command, "{envelope}");
    let message = envelope["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("predates the terminal API") && message.contains("needs updating"),
        "{envelope}"
    );
    assert_eq!(
        fake.join().unwrap(),
        0,
        "{args:?}: bytes past the greeting reached the old daemon"
    );
}

/// The subset of JSON Schema the API's schemas use: `type` (one or a list), `required`,
/// `properties`, `items` and `enum`. Returns where `value` first breaks `schema`.
fn violation(schema: &Value, value: &Value, at: &str) -> Option<String> {
    let type_of = |value: &Value| match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(number) if number.is_u64() || number.is_i64() => "integer",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    };
    if let Some(types) = schema.get("type") {
        let allowed: Vec<&str> = match types {
            Value::String(one) => vec![one.as_str()],
            Value::Array(many) => many.iter().filter_map(Value::as_str).collect(),
            _ => vec![],
        };
        if !allowed.contains(&type_of(value)) {
            return Some(format!("{at}: {} is not {allowed:?}", type_of(value)));
        }
    }
    if let (Some(allowed), false) = (
        schema.get("enum").and_then(Value::as_array),
        value.is_null(),
    ) && !allowed.contains(value)
    {
        return Some(format!("{at}: {value} is not one of {allowed:?}"));
    }
    if let Value::Object(fields) = value {
        for key in schema["required"].as_array().into_iter().flatten() {
            if !fields.contains_key(key.as_str().unwrap()) {
                return Some(format!("{at}: missing {key}"));
            }
        }
        for (key, field) in fields {
            if let Some(property) = schema["properties"].get(key)
                && let Some(broken) = violation(property, field, &format!("{at}.{key}"))
            {
                return Some(broken);
            }
        }
    }
    if let (Value::Array(items), Some(item)) = (value, schema.get("items")) {
        for (index, element) in items.iter().enumerate() {
            if let Some(broken) = violation(item, element, &format!("{at}[{index}]")) {
                return Some(broken);
            }
        }
    }
    None
}

/// `schema` has at least one example under `examples`, and it accepts every one.
fn assert_examples_match(schema: &Value, at: &str) {
    let examples = schema["examples"]
        .as_array()
        .unwrap_or_else(|| panic!("{at} has no examples: {schema}"));
    assert!(!examples.is_empty(), "{at} has no examples");
    for (index, example) in examples.iter().enumerate() {
        assert_eq!(
            violation(schema, example, &format!("{at}.examples[{index}]")),
            None
        );
    }
}

/// A request to the terminal API over the daemon's own socket, as the CLI makes it.
struct Api(common::RpcClient);

impl Api {
    fn connect(socket: &Path) -> Api {
        let stream = UnixStream::connect(socket).expect("connect");
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut client = common::RpcClient::over(stream.try_clone().unwrap(), stream);
        client.handshake();
        Api(client)
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.request(&json!({"method": method, "params": params}))
    }

    /// Sends `request` whole, for one with more than a method and its params.
    fn request(&mut self, request: &Value) -> Value {
        let stream = self.0.take_stream();
        self.0.request(Service::TerminalApi, stream, request)
    }

    /// Calls `method`, a stream, and returns the stream it answers on and its first reply.
    fn stream(&mut self, method: &str, params: Value) -> (u32, Value) {
        let stream = self.0.take_stream();
        let first = self.0.request(
            Service::TerminalApi,
            stream,
            &json!({"method": method, "params": params}),
        );
        (stream, first)
    }

    /// The next whole reply on `stream`.
    fn reply_on(&mut self, stream: u32) -> Value {
        let mut assembled = Vec::new();
        loop {
            let envelope = self
                .0
                .envelope(Service::TerminalApi, stream, Duration::from_secs(20));
            let (last, body) = envelope.payload.split_first().expect("empty reply chunk");
            assembled.extend_from_slice(body);
            if *last == 1 {
                return serde_json::from_slice(&assembled).expect("a JSON reply");
            }
        }
    }
}

/// Every method publishes its schemas, and what each replies matches them: a listing, a resolve,
/// an ambiguous resolve's error and `api.describe` itself.
#[test]
fn every_method_publishes_schemas_its_replies_match() {
    let workspace = Workspace::new("api-schemas");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _first = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let _second = open(&socket, RUN, "tests", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);

    let mut api = Api::connect(&socket);
    let described = api.call("api.describe", json!({}));
    // The API's number is `revision` on the wire too, not the other services' `version`.
    assert_eq!(described["revision"], 1, "{described}");
    assert!(described.get("version").is_none(), "{described}");
    let methods = described["result"]["methods"]
        .as_array()
        .expect("methods")
        .clone();
    let schema = |name: &str, which: &str| {
        methods
            .iter()
            .find(|method| method["name"] == name)
            .unwrap_or_else(|| panic!("{name} is not described"))[which]
            .clone()
    };
    for method in &methods {
        assert!(
            method["input"].is_object() && method["output"].is_object(),
            "{method}"
        );
        // Both schemas carry JSON Schema's `examples`, each one a value the schema accepts, so a
        // caller sees what a reply looks like before it makes a request. `examples` is the only
        // place they are published.
        for which in ["input", "output"] {
            assert_examples_match(&method[which], &format!("{}.{which}", method["name"]));
        }
        assert!(method.get("example").is_none(), "{method}");
    }
    let error_schema = described["result"]["error_schema"].clone();
    assert_examples_match(&error_schema, "error_schema");
    assert!(described["result"].get("error").is_none(), "{described}");
    let request = json!({"method": "session.list", "params": {}, "caller": OTHER});
    assert_eq!(
        violation(&described["result"]["request"], &request, "request"),
        None
    );

    let cases = [
        ("api.describe", json!({}), &described),
        (
            "session.list",
            json!({}),
            &api.call("session.list", json!({})),
        ),
        (
            "session.list",
            json!({"all": true}),
            &api.call("session.list", json!({"all": true})),
        ),
        (
            "session.resolve",
            json!({"target": "beef"}),
            &api.call(
                "session.resolve",
                json!({"target": "1111-4222-8333-44445555beef"}),
            ),
        ),
        (
            "session.list",
            json!({"all": true, "clients": true}),
            &api.call("session.list", json!({"all": true, "clients": true})),
        ),
        (
            "session.resolve",
            json!({"target": "beef", "clients": true}),
            &api.call(
                "session.resolve",
                json!({"target": "1111-4222-8333-44445555beef", "clients": true}),
            ),
        ),
    ];
    for (name, params, reply) in cases {
        assert_eq!(violation(&schema(name, "input"), &params, name), None);
        assert_eq!(reply["revision"], 1, "{reply}");
        assert_eq!(
            violation(&schema(name, "output"), &reply["result"], name),
            None,
            "{reply}"
        );
    }
    // Each with its one client, the pane that opened it.
    let with_clients = api.call("session.list", json!({"all": true, "clients": true}));
    for session in with_clients["result"]["sessions"].as_array().unwrap() {
        assert_eq!(
            session["clients"].as_array().map(Vec::len),
            Some(1),
            "{session}"
        );
    }
    let refused = api.call("session.list", json!({"clients": "yes"}));
    assert_eq!(refused["error"]["kind"], "InvalidRequest", "{refused}");
    let ambiguous = api.call("session.resolve", json!({"target": "tests"}));
    assert_eq!(ambiguous["error"]["kind"], "TargetAmbiguous", "{ambiguous}");
    assert_eq!(violation(&error_schema, &ambiguous["error"], "error"), None);
    let unknown = api.call("session.nope", json!({}));
    assert_eq!(unknown["error"]["kind"], "InvalidRequest", "{unknown}");

    // A capture, which needs a screen to read.
    if has_terminal_state() {
        let params = json!({"target": RUN, "lines": 2, "unwrap": true});
        assert_eq!(
            violation(&schema("terminal.capture", "input"), &params, "capture"),
            None
        );
        let capture = api.call("terminal.capture", params);
        assert_eq!(
            violation(
                &schema("terminal.capture", "output"),
                &capture["result"],
                "capture"
            ),
            None,
            "{capture}"
        );
        assert_eq!(capture["revision"], 1, "{capture}");
    } else {
        let capture = api.call("terminal.capture", json!({"target": RUN}));
        assert_eq!(capture["error"]["kind"], "InternalError", "{capture}");
        assert_eq!(violation(&error_schema, &capture["error"], "error"), None);
    }
    let refused = api.call("terminal.capture", json!({"target": RUN, "lines": -1}));
    assert_eq!(refused["error"]["kind"], "InvalidRequest", "{refused}");

    // A send, typed into a shell (a no-op command), and one into the caller's own session.
    let params = json!({"target": OTHER, "text": ":\n"});
    assert_eq!(
        violation(&schema("terminal.send", "input"), &params, "send"),
        None
    );
    let sent = api.call("terminal.send", params);
    assert_eq!(sent["revision"], 1, "{sent}");
    assert_eq!(
        violation(&schema("terminal.send", "output"), &sent["result"], "send"),
        None,
        "{sent}"
    );
    let own = api.request(&json!({
        "method": "terminal.send",
        "params": {"target": OTHER, "text": "x"},
        "caller": OTHER,
    }));
    assert_eq!(own["error"]["kind"], "RefusedSelf", "{own}");
    assert_eq!(violation(&error_schema, &own["error"], "error"), None);

    // A command, which needs its shell's marks: `/bin/sh` sends none, so it is refused, once the
    // new session's grace for them is over, with nothing typed. One that runs is matched against
    // the output schema in `command_runs_in_a_shell_…`.
    let params = json!({"target": OTHER, "command": "true", "timeout_ms": 30_000});
    assert_eq!(
        violation(&schema("terminal.command", "input"), &params, "command"),
        None
    );
    let refused = api.call("terminal.command", params);
    let kind = if has_terminal_state() {
        "NoShellIntegration"
    } else {
        "InvalidRequest"
    };
    assert_eq!(refused["error"]["kind"], kind, "{refused}");
    assert_eq!(refused["more"], false, "{refused}");
    assert_eq!(violation(&error_schema, &refused["error"], "error"), None);

    // A wait answers on its stream when it ends: here at once, out of time.
    let params = json!({"target": "beef", "ended": true, "timeout_ms": 0});
    assert_eq!(
        violation(&schema("terminal.wait", "input"), &params, "params"),
        None
    );
    let timed_out = api.call("terminal.wait", params);
    assert_eq!(timed_out["error"]["kind"], "TargetAmbiguous", "{timed_out}");
    let timed_out = api.call(
        "terminal.wait",
        json!({"target": OTHER, "ended": true, "timeout_ms": 0}),
    );
    assert_eq!(timed_out["revision"], 1, "{timed_out}");
    assert_eq!(timed_out["more"], false, "{timed_out}");
    assert_eq!(timed_out["error"]["kind"], "WaitTimeout", "{timed_out}");
    assert_eq!(violation(&error_schema, &timed_out["error"], "error"), None);
    // A coding agent's turn: none to end in a shell, out of time at once.
    let params = json!({"target": OTHER, "turn": "next", "timeout_ms": 0});
    assert_eq!(
        violation(&schema("terminal.wait", "input"), &params, "params"),
        None
    );
    let turn = api.call("terminal.wait", params);
    let kind = if has_terminal_state() {
        "WaitTimeout"
    } else {
        "InvalidRequest"
    };
    assert_eq!(turn["error"]["kind"], kind, "{turn}");

    // A prompt, which a shell can't take: its replies are the prompt tests'.
    let params = json!({"target": OTHER, "text": "hi", "wait": true, "timeout_ms": 1000});
    assert_eq!(
        violation(&schema("terminal.prompt", "input"), &params, "params"),
        None
    );
    let refused = api.call("terminal.prompt", json!({"target": OTHER, "text": "hi"}));
    assert_eq!(refused["error"]["kind"], "NotAnAgent", "{refused}");
    assert_eq!(refused["more"], false, "{refused}");
    assert_eq!(violation(&error_schema, &refused["error"], "error"), None);

    // Events stream, every reply `more`, while the connection takes other requests: a snapshot,
    // a live event, a resume from it and one from a place this daemon never had.
    let params = json!({"all": true, "types": ["session.created"]});
    assert_eq!(
        violation(&schema("events.subscribe", "input"), &params, "params"),
        None
    );
    let output = schema("events.subscribe", "output");
    let matches = |reply: &Value| {
        assert_eq!(reply["revision"], 1, "{reply}");
        assert_eq!(reply["more"], true, "{reply}");
        assert_eq!(
            violation(&output, &reply["result"], "events"),
            None,
            "{reply}"
        );
        reply["result"].clone()
    };
    let (stream, first) = api.stream("events.subscribe", params.clone());
    assert_eq!(matches(&first)["event"], "session", "{first}");
    let mut event = first;
    while event["result"]["event"] != "snapshot-complete" {
        event = api.reply_on(stream);
        matches(&event);
    }
    let listed = api.call("session.list", json!({"all": true}));
    assert_eq!(
        listed["result"]["sessions"].as_array().map(Vec::len),
        Some(2)
    );
    let _third = open(&socket, SHELL, "third", "wr-2", &workspace.dir);
    let created = matches(&api.reply_on(stream));
    assert_eq!(created["event"], "session.created", "{created}");
    let mut since = params.clone();
    since["since"] = json!({"boot": created["boot"], "revision": created["revision"]});
    let resumed = matches(&api.stream("events.subscribe", since).1);
    assert_eq!(resumed["event"], "resumed", "{resumed}");
    assert_eq!(resumed["revision"], created["revision"], "{resumed}");
    let mut elsewhere = params;
    elsewhere["since"] = json!({"boot": "00000000-0000-4000-8000-000000000000", "revision": 1});
    let (gap, mut event) = api.stream("events.subscribe", elsewhere);
    while matches(&event)["event"] != "snapshot-complete" {
        event = api.reply_on(gap);
    }
    assert_eq!(event["result"]["reason"], "gap", "{event}");
    let refused = api.call("events.subscribe", json!({"types": ["session.renamed"]}));
    assert_eq!(refused["error"]["kind"], "InvalidRequest", "{refused}");
    assert_eq!(refused["more"], false, "{refused}");
}

/// Writes `lines` into a script in `dir` that clears the screen and its history, prints them, and
/// then waits, so a session running it shows exactly them and nothing typed.
fn known_content(dir: &Path, name: &str, lines: &str) -> String {
    let script = dir.join(format!("{name}.sh"));
    std::fs::write(
        &script,
        format!("printf '\\033[H\\033[2J\\033[3J'\n{lines}\nsleep 60\n"),
    )
    .expect("write the script");
    format!("sh {}", script.display())
}

/// `workroom capture <args>` against `socket`, once its stdout satisfies `ready`.
fn capture_until(socket: &Path, args: &[&str], ready: impl Fn(&Run) -> bool) -> Run {
    capture_awaiting(socket, args, "ready", ready)
}

/// [`capture_until`], whose failure names `what` it waited for.
fn capture_awaiting(socket: &Path, args: &[&str], what: &str, ready: impl Fn(&Run) -> bool) -> Run {
    let mut args = args.to_vec();
    args.insert(0, "capture");
    let mut last = None;
    let reached = wait_for(Duration::from_secs(20), || {
        let run = workroom(Some(socket), &args);
        let done = ready(&run);
        last = Some(run);
        done
    });
    let last = last.expect("a run");
    assert!(reached, "never {what}: {:?} {:?}", last.stdout, last.stderr);
    last
}

fn capture(socket: &Path, args: &[&str]) -> Run {
    capture_until(socket, args, |_| true)
}

/// A line longer than any pane here, with no spaces, so nothing trims it where it wraps.
fn long_line() -> String {
    (0..30).map(|n| format!("w{n:02}-abcde")).collect()
}

/// `capture` and each of its options against a session showing known content: 40 lines of history,
/// a coloured line, a line the pane wraps, and `END`.
#[test]
fn capture_reads_the_screen_its_history_and_wrapped_lines() {
    let workspace = Workspace::new("api-capture");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    if !has_terminal_state() {
        // No shadow terminal, so no screen to read: an internal error, and it says why.
        let run = workroom(Some(&socket), &["capture", "server", "--json"]);
        assert_eq!(run.code, 1, "{} {}", run.stdout, run.stderr);
        let error = &run.envelope()["error"];
        assert_eq!(error["kind"], "InternalError", "{error}");
        let message = error["message"].as_str().unwrap();
        assert!(
            message.contains("built without terminal-state"),
            "{message}"
        );
        return;
    }
    let long = long_line();
    type_line(
        &mut shell,
        &known_content(
            &workspace.dir,
            "content",
            &format!(
                "i=0; while [ $i -lt 40 ]; do echo \"hist $i\"; i=$((i+1)); done\n\
                 printf 'RED: \\033[31mred\\033[0m\\n'\necho {long}\necho END"
            ),
        ),
    );
    let plain = capture_until(&socket, &["server"], |run| run.stdout.ends_with("END\n"));
    assert_eq!(plain.code, 0, "{}", plain.stderr);
    assert_eq!(plain.stderr, "");

    let json = capture(&socket, &["server", "--json"]);
    assert_eq!(json.code, 0, "{}", json.stderr);
    let envelope = json.envelope();
    assert_eq!(envelope["ok"], true);
    assert_eq!(envelope["command"], "capture");
    assert_eq!(envelope["session"], SHELL);
    assert_eq!(envelope["text"].as_str().unwrap(), plain.stdout.trim_end());
    assert_eq!(envelope["alternate_screen"], false);
    assert_eq!(envelope["title"], Value::Null);
    assert_eq!(envelope["chunk"], 0);
    // A stream's end is the reply's `more`, not the result's.
    assert!(envelope.get("last").is_none(), "{envelope}");
    let columns = envelope["size"]["columns"].as_u64().unwrap() as usize;
    let rows = envelope["size"]["rows"].as_u64().unwrap() as usize;
    // Below END, at the start of the screen's last row.
    assert_eq!(envelope["cursor"], json!({"row": rows - 1, "column": 0}));

    // The screen: every row but the blank one under END. Above END are the long line's rows, the
    // coloured line, and the newest of the history.
    let wrapped = long.len().div_ceil(columns);
    let screen: Vec<&str> = plain.stdout.lines().collect();
    assert_eq!(screen.len(), rows - 1, "{screen:#?}");
    let history_shown = rows - 1 - wrapped - 2;
    assert_eq!(screen[0], format!("hist {}", 40 - history_shown));
    assert_eq!(screen[history_shown], "RED: red");
    assert_eq!(screen[history_shown + 1], &long[..columns]);
    assert!(!plain.stdout.contains('\u{1b}'));

    let more = capture(&socket, &["server", "--lines", "5"]);
    let more: Vec<&str> = more.stdout.lines().collect();
    assert_eq!(more.len(), screen.len() + 5);
    assert_eq!(more[0], format!("hist {}", 40 - history_shown - 5));
    assert_eq!(&more[5..], &screen[..]);

    let all = capture(&socket, &["server", "--all"]);
    assert_eq!(all.code, 0, "{}", all.stderr);
    let all: Vec<&str> = all.stdout.lines().collect();
    assert_eq!(all.len(), 40 + 1 + wrapped + 1, "{all:#?}");
    assert_eq!(all[0], "hist 0");
    assert_eq!(all.last(), Some(&"END"));

    let unwrapped = capture(&socket, &["server", "--unwrap"]);
    assert!(
        unwrapped.stdout.lines().any(|line| line == long),
        "{}",
        unwrapped.stdout
    );
    assert!(!plain.stdout.lines().any(|line| line == long));
    let unwrapped_all = capture(&socket, &["server", "--all", "--unwrap"]);
    assert_eq!(unwrapped_all.stdout.lines().count(), 40 + 1 + 1 + 1);

    let vt = capture(&socket, &["server", "--vt"]);
    assert!(vt.stdout.contains("\u{1b}["), "{:?}", vt.stdout);
    assert!(vt.stdout.contains("red") && vt.stdout.contains("END"));
}

/// A full-screen program's screen, title and cursor, and that it is on the alternate screen.
#[test]
fn capture_says_when_a_program_has_the_alternate_screen() {
    if !has_terminal_state() {
        eprintln!("skipped: needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-capture-alt");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "editor", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    type_line(&mut shell, "echo on the primary");
    type_line(
        &mut shell,
        &known_content(
            &workspace.dir,
            "fullscreen",
            "echo first on the primary\necho second on the primary\n\
             printf '\\033[?1049h\\033[H\\033[2J\\033]2;notes.md\\007FULL SCREEN\\r\\n  editing'",
        ),
    );
    let run = capture_until(&socket, &["editor", "--json"], |run| {
        run.code == 0 && run.envelope()["alternate_screen"] == true
    });
    let envelope = run.envelope();
    assert_eq!(envelope["text"], "FULL SCREEN\n  editing", "{envelope}");
    assert_eq!(envelope["title"], "notes.md");
    assert_eq!(envelope["cursor"], json!({"row": 1, "column": 9}));
    // The history is the shell's, under the program: the primary screen's lines, down to its last,
    // above the program's screen.
    let shell = "first on the primary\nsecond on the primary";
    for flag in ["--lines=50", "--all"] {
        let run = capture(&socket, &["editor", flag]);
        assert_eq!(run.code, 0, "{flag}: {}", run.stderr);
        assert_eq!(
            run.stdout,
            format!("{shell}\nFULL SCREEN\n  editing\n"),
            "{flag}"
        );
    }
    let one = capture(&socket, &["editor", "--lines=1", "--json"]).envelope();
    assert_eq!(one["alternate_screen"], true, "{one}");
    assert_eq!(
        one["text"], "second on the primary\nFULL SCREEN\n  editing",
        "{one}"
    );
}

/// `--all` on a long history: one envelope per chunk under `--json`, numbered from 0 with only the
/// last saying so, which together are the whole history; without `--json`, the same text.
#[test]
fn capture_all_streams_a_large_scrollback_in_chunks() {
    if !has_terminal_state() {
        eprintln!("skipped: needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-capture-all");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "logs", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    const LINES: usize = 30_000;
    // The script prints once the test says go, by making a file, so the flood never races the
    // client's detach.
    let go = workspace.dir.join("go");
    type_line(
        &mut shell,
        &known_content(
            &workspace.dir,
            "logs",
            &format!(
                "echo STARTED\nwhile [ ! -e '{}' ]; do sleep 0.05; done\n\
                 printf '\\033[H\\033[2J\\033[3J'\n\
                 awk 'BEGIN {{ for (i = 0; i < {LINES}; i++) \
                 printf \"line %05d the quick brown fox jumps over the lazy dog\\n\", i }}'\n\
                 echo DONE",
                go.display()
            ),
        ),
    );
    // Detached once the script has started and before it prints, so nothing waits on this test
    // reading the pane's output, and the typed line is not lost with the client.
    capture_awaiting(&socket, &["logs"], "STARTED, the script waiting", |run| {
        run.stdout.contains("STARTED\n")
    });
    drop(shell);
    std::fs::write(&go, "").expect("say go");
    capture_awaiting(&socket, &["logs"], "DONE, the flood printed", |run| {
        run.stdout.ends_with("DONE\n")
    });

    let json = capture(&socket, &["logs", "--all", "--json"]);
    assert_eq!(json.code, 0, "{}", json.stderr);
    let envelopes: Vec<Value> = json
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).expect("one envelope per line"))
        .collect();
    assert!(envelopes.len() > 4, "{} chunks", envelopes.len());
    let mut text = String::new();
    for (index, envelope) in envelopes.iter().enumerate() {
        assert_eq!(envelope["command"], "capture");
        assert_eq!(envelope["chunk"], index, "{envelope}");
        assert_eq!(envelope["session"], SHELL);
        assert!(envelope["size"]["columns"].is_u64(), "{envelope}");
        let chunk = envelope["text"].as_str().unwrap();
        assert!(
            chunk.len() <= 64 * 1024,
            "chunk {index} is {} bytes",
            chunk.len()
        );
        text += chunk;
    }
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), LINES + 1);
    for (n, line) in lines[..LINES].iter().enumerate() {
        assert_eq!(
            *line,
            format!("line {n:05} the quick brown fox jumps over the lazy dog")
        );
    }
    assert_eq!(lines[LINES], "DONE");

    let plain = capture(&socket, &["logs", "--all"]);
    assert_eq!(plain.stdout, text.clone() + "\n");

    // `api call` reads a stream to its end too: one envelope per reply, each saying whether `more`
    // follow, only the last saying none do, and together the same history.
    let called = workroom(
        Some(&socket),
        &[
            "api",
            "call",
            "terminal.capture",
            r#"{"target":"logs","all":true}"#,
            "--json",
        ],
    );
    assert_eq!(called.code, 0, "{}", called.stderr);
    let replies: Vec<Value> = called
        .stdout
        .lines()
        .map(|line| serde_json::from_str(line).expect("one envelope per line"))
        .collect();
    assert_eq!(replies.len(), envelopes.len());
    let mut streamed = String::new();
    for (index, reply) in replies.iter().enumerate() {
        assert_eq!(reply["command"], "api call");
        assert_eq!(reply["method"], "terminal.capture");
        assert_eq!(reply["more"], index + 1 < replies.len(), "{index}");
        assert_eq!(reply["result"]["chunk"], index);
        streamed += reply["result"]["text"].as_str().unwrap();
    }
    assert_eq!(streamed, text);

    // The daemon runs 4 captures from a copy at once (`api::MAX_CAPTURES`). Four streams whose
    // callers read one reply and stop hold all four; meanwhile a session keeps writing, which no
    // capture's format holds up; a fifth is refused as `Busy` (3), saying why; and once the four
    // hang up, a capture runs again.
    let mut ticker = open(&socket, OTHER, "ticker", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    type_line(
        &mut ticker,
        "i=0; while :; do echo \"tick $i\"; i=$((i+1)); sleep 0.02; done",
    );
    let held: Vec<Api> = (0..4)
        .map(|_| {
            let mut api = Api::connect(&socket);
            let first = api.call("terminal.capture", json!({"target": "logs", "all": true}));
            assert_eq!(first["more"], true, "{first}");
            api
        })
        .collect();
    let tick = |run: &Run| -> Option<u64> {
        run.stdout
            .lines()
            .rev()
            .find_map(|line| line.strip_prefix("tick ")?.parse().ok())
    };
    let before = tick(&capture_awaiting(&socket, &["ticker"], "a tick", |run| {
        tick(run).is_some()
    }))
    .unwrap();
    capture_awaiting(&socket, &["ticker"], "the ticks to go on", |run| {
        tick(run).is_some_and(|now| now > before + 5)
    });
    for args in [
        &["logs", "--all", "--json"][..],
        &["logs", "--lines", "5000", "--json"],
    ] {
        let refused = workroom(Some(&socket), &[&["capture"][..], args].concat());
        assert_eq!(refused.code, 3, "{args:?}: {}", refused.stdout);
        let error = &refused.envelope()["error"];
        assert_eq!(error["kind"], "Busy", "{error}");
        assert!(
            error["message"]
                .as_str()
                .unwrap()
                .contains("4 captures of history are already running"),
            "{error}"
        );
    }
    // The screen alone takes no place.
    assert_eq!(capture(&socket, &["logs"]).code, 0);
    drop(held);
    let again = capture_awaiting(
        &socket,
        &["logs", "--lines", "5000"],
        "a place again",
        |run| run.code == 0,
    );
    assert_eq!(
        again.stdout.lines().count(),
        5000 + rows_of(&again, &socket)
    );
}

/// The screen's rows of the session `logs`, which a `--lines` capture adds its history above.
fn rows_of(_run: &Run, socket: &Path) -> usize {
    let json = capture(socket, &["logs", "--json"]).envelope();
    // Every row but the blank one under DONE.
    json["size"]["rows"].as_u64().unwrap() as usize - 1
}

#[test]
fn capture_refuses_a_bad_command_line_and_a_target_it_cannot_find() {
    let workspace = Workspace::new("api-capture-usage");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);

    for (args, message) in [
        (&["capture", "--json"][..], "accepts 1 arg(s), received 0"),
        (
            &["capture", "a", "b", "--json"],
            "accepts 1 arg(s), received 2",
        ),
        (
            &["capture", "server", "--lines", "many", "--json"],
            "invalid argument \"many\" for \"--lines\" flag",
        ),
        (
            &["capture", "server", "--lines=-1", "--json"],
            "invalid argument \"-1\" for \"--lines\" flag",
        ),
        (
            &["capture", "server", "--all", "--lines", "3", "--json"],
            "none of the others can be",
        ),
    ] {
        let run = workroom(Some(&socket), args);
        assert_eq!(run.code, 1, "{args:?} {}", run.stdout);
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["kind"], "InternalError", "{args:?}");
        let said = envelope["error"]["message"].as_str().unwrap();
        assert!(said.contains(message), "{args:?}: {said}");
    }
    let missing = workroom(Some(&socket), &["capture", "nothing", "--json"]);
    assert_eq!(missing.code, 3);
    assert_eq!(missing.envelope()["error"]["kind"], "TargetNotFound");
    assert_eq!(missing.envelope()["command"], "capture");
    let unreachable = workroom_outside_any_daemon(&workspace.dir, &["capture", "server", "--json"]);
    assert_eq!(unreachable.code, 7);
    assert_eq!(unreachable.envelope()["error"]["kind"], "DaemonUnreachable");
}

/// `workroom api <args>` with `--json`, from a run that must succeed: its envelope.
fn api_json(socket: &Path, args: &[&str]) -> Value {
    let args: Vec<&str> = ["api"]
        .iter()
        .chain(args)
        .chain(&["--json"])
        .copied()
        .collect();
    let run = workroom(Some(socket), &args);
    assert_eq!(run.code, 0, "{args:?}: {} {}", run.stdout, run.stderr);
    let envelope = run.envelope();
    assert_eq!(envelope["ok"], true, "{envelope}");
    assert_eq!(envelope["schema_version"], 1, "{envelope}");
    // One name per payload shape: `api list`, `api describe` or `api call`.
    assert_eq!(
        envelope["command"],
        format!("api {}", args[1]),
        "{envelope}"
    );
    envelope
}

/// `api list` names every method the daemon has, each with what it does, and the API's revision.
#[test]
fn api_list_names_every_method_the_daemon_has() {
    let workspace = Workspace::new("api-list");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);

    let envelope = api_json(&socket, &["list"]);
    assert_eq!(envelope["revision"], 1, "{envelope}");
    let methods = envelope["methods"].as_array().expect("methods");
    let names: Vec<&str> = methods
        .iter()
        .map(|method| method["name"].as_str().unwrap())
        .collect();
    for name in ["api.describe", "session.list", "session.resolve"] {
        assert!(names.contains(&name), "{name} not in {names:?}");
    }
    // Every method the service describes, in its order: none left out, none made up.
    let described = Api::connect(&socket).call("api.describe", json!({}));
    let all: Vec<&str> = described["result"]["methods"]
        .as_array()
        .expect("methods")
        .iter()
        .map(|method| method["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, all);
    let summary = "The sessions that share the caller's scope, oldest first, or with `all: true` \
                   every session the daemon holds.";
    assert_eq!(methods[1]["summary"], summary);
    // The listing names them; the schemas are `describe`'s.
    assert!(methods[1].get("input").is_none(), "{envelope}");

    let human = workroom(Some(&socket), &["api", "list"]);
    assert_eq!((human.code, human.stderr.as_str()), (0, ""));
    assert!(
        human
            .stdout
            // Padded to the longest name, `session.run_control`, and two spaces.
            .contains(&format!("session.list         {summary}\n")),
        "{}",
        human.stdout
    );
}

/// `api describe METHOD` shows that one method's schemas, with examples, and the error's; a
/// method the daemon doesn't have is bad input (2), and a missing one a bad command line (1).
#[test]
fn api_describe_shows_one_methods_schemas_with_examples() {
    let workspace = Workspace::new("api-describe");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);

    let envelope = api_json(&socket, &["describe", "session.resolve"]);
    assert_eq!(envelope["revision"], 1, "{envelope}");
    let method = &envelope["method"];
    assert_eq!(method["name"], "session.resolve", "{envelope}");
    assert_eq!(method["input"]["required"], json!(["target"]), "{method}");
    assert_eq!(
        method["input"]["examples"],
        json!([{"target": "dev server"}]),
        "{method}"
    );
    assert_eq!(
        method["output"]["examples"][0]["session"]["label"], "dev server",
        "{method}"
    );
    assert_eq!(
        method["errors"],
        json!(["TargetNotFound", "TargetAmbiguous"])
    );
    // The error's schema is `error_schema`: a success envelope never has an `error`.
    assert_eq!(
        envelope["error_schema"]["required"],
        json!(["kind", "message"])
    );
    assert!(envelope.get("error").is_none(), "{envelope}");

    // For a person, the same description as indented JSON.
    let human = workroom(Some(&socket), &["api", "describe", "session.resolve"]);
    assert_eq!(human.code, 0, "{}", human.stderr);
    let shown: Value = serde_json::from_str(&human.stdout).expect("JSON");
    assert_eq!(shown, *method);
    assert!(human.stdout.starts_with("{\n  \""), "{}", human.stdout);

    let unknown = workroom(
        Some(&socket),
        &["api", "describe", "session.nope", "--json"],
    );
    assert_eq!(unknown.code, 2, "{}", unknown.stdout);
    assert_eq!(unknown.envelope()["error"]["kind"], "InvalidRequest");
    assert_eq!(unknown.envelope()["command"], "api describe");
    let missing = workroom(Some(&socket), &["api", "describe", "--json"]);
    assert_eq!(missing.code, 1, "{}", missing.stdout);
    assert_eq!(
        missing.envelope()["error"]["message"],
        "accepts 1 arg(s), received 0"
    );
}

/// `api call METHOD PARAMS` takes PARAMS inline, from `@FILE` or from stdin (`-`), and with none
/// sends `{}`. Its envelope carries the method's reply: `method`, `revision` and `result`.
#[test]
fn api_call_takes_params_inline_from_a_file_and_from_stdin() {
    let workspace = Workspace::new("api-call");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let params = workspace.dir.join("params.json");
    std::fs::write(&params, "{\"target\": \"server\"}\n").expect("write params");
    let at_file = format!("@{}", params.display());

    let resolved = |run: Run| {
        assert_eq!(run.code, 0, "{} {}", run.stdout, run.stderr);
        let envelope = run.envelope();
        assert_eq!(envelope["command"], "api call", "{envelope}");
        assert_eq!(envelope["method"], "session.resolve", "{envelope}");
        assert_eq!(envelope["revision"], 1, "{envelope}");
        envelope["result"]["session"]["id"].clone()
    };
    let call = |params: &str, stdin: Option<&str>| {
        workroom_with_stdin(
            Some(&socket),
            &["api", "call", "session.resolve", params, "--json"],
            stdin,
        )
    };
    assert_eq!(resolved(call(r#"{"target":"server"}"#, None)), SHELL);
    assert_eq!(resolved(call(&at_file, None)), SHELL);
    assert_eq!(resolved(call("-", Some("{\"target\": \"8e11\"}"))), SHELL);

    // No PARAMS is `{}`.
    let listed = api_json(&socket, &["call", "session.list"]);
    assert_eq!(listed["result"]["sessions"][0]["id"], SHELL, "{listed}");

    // For a person, the result as indented JSON.
    let human = workroom(
        Some(&socket),
        &["api", "call", "session.resolve", r#"{"target":"server"}"#],
    );
    assert_eq!(human.code, 0, "{}", human.stderr);
    let shown: Value = serde_json::from_str(&human.stdout).expect("JSON");
    assert_eq!(shown["session"]["id"], SHELL);

    // PARAMS that aren't JSON, or a file that can't be read, are bad input; so are parameters
    // the daemon refuses. A method's own errors keep their codes.
    let missing_file = format!("@{}", workspace.dir.join("nowhere.json").display());
    for (params, stdin) in [
        ("{not json", None),
        (missing_file.as_str(), None),
        ("-", Some("")),
        ("[1]", None),
        ("{}", None),
    ] {
        let run = call(params, stdin);
        assert_eq!(run.code, 2, "{params}: {}", run.stdout);
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["kind"], "InvalidRequest", "{envelope}");
        assert_eq!(envelope["command"], "api call", "{envelope}");
    }
    let nothing = call(r#"{"target":"nothing"}"#, None);
    assert_eq!(nothing.code, 3, "{}", nothing.stdout);
    assert_eq!(nothing.envelope()["error"]["kind"], "TargetNotFound");
    let unknown = workroom(Some(&socket), &["api", "call", "session.nope", "--json"]);
    assert_eq!(unknown.code, 2, "{}", unknown.stdout);
    assert_eq!(unknown.envelope()["error"]["kind"], "InvalidRequest");
    let extra = workroom(Some(&socket), &["api", "call", "session.list", "{}", "x"]);
    assert_eq!(extra.code, 1, "{}", extra.stderr);
    assert_eq!(
        extra.stderr,
        "Error: accepts between 1 and 2 arg(s), received 3\n"
    );
}

/// What `describe` publishes is what `call` gets: for every method `api list` names, a real reply
/// through `api call` matches the output schema `api describe` gives, and a real error matches the
/// error schema. A method added later fails here until it has a case, so none goes unchecked.
#[test]
fn every_methods_reply_through_api_call_matches_what_api_describe_publishes() {
    let workspace = Workspace::new("api-call-schemas");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut first = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut first);
    let _second = open(&socket, RUN, "tests", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| {
        listing.len() == 2 && listing.iter().all(|session| !session["cwd"].is_null())
    });
    // A stand-in coding agent to prompt, which needs the shadow terminal to take one.
    let mut agent_pane = open(&socket, SHELL, "agent", "wr-1", &workspace.dir);
    let mut agent_output = common::ClientReader::new(&mut agent_pane);
    let agent = FakeAgent::new(&workspace.dir, "codex");
    agent.launch(&mut agent_pane, &mut agent_output, "", prompted("hi").len());

    // Each method's params for one real call that succeeds.
    let cases = [
        ("terminal.prompt", json!({"target": SHELL, "text": "hi"})),
        ("api.describe", json!({})),
        ("session.list", json!({})),
        ("session.resolve", json!({"target": OTHER})),
        ("terminal.capture", json!({"target": OTHER, "lines": 2})),
        // A no-op command, typed into the shell.
        ("terminal.send", json!({"target": OTHER, "text": ":\n"})),
        (
            "terminal.command",
            json!({"target": OTHER, "command": "echo ran", "timeout_ms": 30000}),
        ),
        (
            "terminal.wait",
            json!({"target": OTHER, "regex": "API-CALL-WAITED", "timeout_ms": 30000}),
        ),
        // A run, from no pane, which the next two restart and then close.
        (
            "session.new",
            json!({
                "title": "api-call-new",
                "run": "sleep 60",
                "split": "right",
                "cwd": workspace.dir,
            }),
        ),
        (
            "session.run_control",
            json!({"target": "api-call-new", "action": "restart"}),
        ),
        ("session.close", json!({"target": "api-call-new"})),
        // The agent's pane, so the two named `tests` still are, for the ambiguity below.
        (
            "session.label",
            json!({"target": SHELL, "label": "api-call-label"}),
        ),
        ("events.subscribe", json!({"all": true})),
        // From a connection of its own, which holds no subscription there: `ended` false.
        ("events.unsubscribe", json!({"stream": 1})),
    ];
    let listed = api_json(&socket, &["list"]);
    for method in listed["methods"].as_array().expect("methods") {
        let name = method["name"].as_str().unwrap();
        let (_, params) = cases
            .iter()
            .find(|(case, _)| *case == name)
            .unwrap_or_else(|| panic!("{name} has no case here: add one"));
        // A capture needs a screen to read, which only terminal-state keeps, as a command's end
        // does; a command, a shell that sends marks; and a prompt, the modes to encode Enter for.
        if ["terminal.capture", "terminal.command", "terminal.prompt"].contains(&name)
            && !has_terminal_state()
        {
            continue;
        }
        if name == "terminal.command" {
            type_line(&mut first, INTEGRATED_SHELL);
            assert!(
                output
                    .read_until("IS> ", Duration::from_secs(20))
                    .contains("IS> "),
                "fixture: the integrated shell never prompted"
            );
        }
        // Printed 3 s from now, once the wait has started; split in the typed line, so its echo
        // is not the match.
        if name == "terminal.wait" {
            type_line(&mut first, "sleep 3; echo API-CALL'-'WAITED");
        }
        let described = api_json(&socket, &["describe", name]);
        let schema = &described["method"];
        assert_eq!(violation(&schema["input"], params, name), None);
        let params = params.to_string();
        // A stream that goes on until its caller hangs up: its snapshot, one envelope a line,
        // each with `more`.
        if name == "events.subscribe" {
            let mut stream = started(&socket, &["api", "call", name, &params, "--json"]);
            let stdout = stream.stdout.take().expect("stdout");
            let mut lines = std::io::BufRead::lines(std::io::BufReader::new(stdout));
            loop {
                let line = lines.next().expect("the snapshot ends").expect("a line");
                let called: Value = serde_json::from_str(&line).expect("an envelope");
                assert_eq!(called["command"], "api call", "{called}");
                assert_eq!(called["more"], true, "{called}");
                assert_eq!(called["revision"], described["revision"], "{called}");
                assert_eq!(
                    violation(&schema["output"], &called["result"], name),
                    None,
                    "{called}"
                );
                if called["result"]["event"] == "snapshot-complete" {
                    break;
                }
            }
            let _ = stream.kill();
            let _ = stream.wait();
            continue;
        }
        let called = api_json(&socket, &["call", name, &params]);
        assert_eq!(called["revision"], described["revision"], "{called}");
        assert_eq!(
            violation(&schema["output"], &called["result"], name),
            None,
            "{called}"
        );
    }
    agent.open("quit");

    let error_schema = api_json(&socket, &["describe", "session.list"])["error_schema"].clone();
    let ambiguous = workroom(
        Some(&socket),
        &[
            "api",
            "call",
            "session.resolve",
            r#"{"target":"tests"}"#,
            "--json",
        ],
    );
    assert_eq!(ambiguous.code, 3, "{}", ambiguous.stdout);
    let error = &ambiguous.envelope()["error"];
    assert_eq!(error["kind"], "TargetAmbiguous", "{error}");
    assert_eq!(
        error["matches"].as_array().map(Vec::len),
        Some(2),
        "{error}"
    );
    assert_eq!(violation(&error_schema, error, "error"), None);
}

/// With no daemon, every `api` subcommand exits 7, as every terminal API command does.
#[test]
fn api_with_no_daemon_exits_7() {
    let workspace = Workspace::new("api-call-no-daemon");
    for args in [
        &["api", "list", "--json"][..],
        &["api", "describe", "session.list", "--json"],
        &["api", "call", "session.list", "{}", "--json"],
    ] {
        let run = workroom_outside_any_daemon(&workspace.dir, args);
        assert_eq!(run.code, 7, "{args:?} {}", run.stdout);
        assert_eq!(run.envelope()["error"]["kind"], "DaemonUnreachable");
    }
}

/// `api call`'s failure for `run`: its exit code, kind and message, in `api call`'s envelope.
fn call_failure(run: &Run) -> (i32, String, String) {
    let envelope = run.envelope();
    assert_eq!(envelope["command"], "api call", "{envelope}");
    let text = |key: &str| {
        envelope["error"][key]
            .as_str()
            .unwrap_or_default()
            .to_string()
    };
    (run.code, text("kind"), text("message"))
}

/// PARAMS from a file or stdin is read no further than one byte past the 1 MiB a request can
/// carry, and more is `TooLarge` (2), before any daemon is looked for: so with none it exits 2,
/// not 7, and `yes | workroom api call METHOD -` ends instead of filling memory.
#[test]
fn api_call_refuses_params_over_the_limit_before_looking_for_a_daemon() {
    use wr_protocol::envelope::MAX_ENVELOPE_PAYLOAD;

    let workspace = Workspace::new("api-call-too-large");
    let over = "x".repeat(MAX_ENVELOPE_PAYLOAD + 1);
    let file = workspace.dir.join("big.json");
    std::fs::write(&file, &over).expect("write big params");
    let at_file = format!("@{}", file.display());
    let too_large = |from: &str| {
        (
            2,
            "TooLarge".to_string(),
            format!("PARAMS from {from} is over {MAX_ENVELOPE_PAYLOAD} bytes"),
        )
    };
    // With no daemon named, and with one named that isn't there.
    let nowhere = workspace.dir.join("nobody.sock");
    for daemon in [None, Some(nowhere.as_path())] {
        let from_file = workroom(daemon, &["api", "call", "session.list", &at_file, "--json"]);
        assert_eq!(
            call_failure(&from_file),
            too_large(&file.display().to_string())
        );
        let from_stdin = workroom_with_stdin(
            daemon,
            &["api", "call", "session.list", "-", "--json"],
            Some(&over),
        );
        assert_eq!(call_failure(&from_stdin), too_large("stdin"));
    }

    // Stdin that never ends.
    let mut yes = Command::new("/usr/bin/yes")
        .stdout(Stdio::piped())
        .spawn()
        .expect("run yes");
    let output = Command::new(common::daemon_binary())
        .args(["api", "call", "session.list", "-", "--json"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
        .stdin(yes.stdout.take().expect("yes's stdout"))
        .output()
        .expect("run workroom");
    let _ = yes.kill();
    let _ = yes.wait();
    let endless = Run {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        code: output.status.code().unwrap_or(-1),
    };
    assert_eq!(call_failure(&endless), too_large("stdin"));
}

/// PARAMS that aren't UTF-8 are a malformed request (2) that says so, not a file it "can't read".
#[test]
fn api_call_params_that_are_not_utf8_are_invalid() {
    let workspace = Workspace::new("api-call-not-utf8");
    let file = workspace.dir.join("latin1.json");
    std::fs::write(&file, b"{\"target\": \"caf\xe9\"}").expect("write params");
    let run = workroom(
        None,
        &[
            "api",
            "call",
            "session.resolve",
            &format!("@{}", file.display()),
            "--json",
        ],
    );
    let (code, kind, message) = call_failure(&run);
    assert_eq!((code, kind.as_str()), (2, "InvalidRequest"), "{message}");
    assert!(
        message.starts_with(&format!("PARAMS from {} isn't UTF-8", file.display())),
        "{message}"
    );
}

/// `workroom wait <args> --json`, from a run that must answer with one envelope.
fn wait(socket: &Path, args: &[&str]) -> (i32, Value) {
    let args: Vec<&str> = [&["wait"][..], args, &["--json"]].concat();
    let run = workroom(Some(socket), &args);
    (run.code, run.envelope())
}

/// A failed wait's exit code and error kind.
fn failed(outcome: (i32, Value)) -> (i32, String) {
    let (code, envelope) = outcome;
    assert_eq!(envelope["ok"], false, "{envelope}");
    (
        code,
        envelope["error"]["kind"].as_str().unwrap().to_string(),
    )
}

/// `terminal.wait`'s result schema, as the daemon describes it.
fn wait_schema(socket: &Path) -> Value {
    let described = Api::connect(socket).call("api.describe", json!({"method": "terminal.wait"}));
    described["result"]["methods"][0]["output"].clone()
}

/// A met wait's envelope: `wait`'s, with the API's result fields, which match its schema.
fn met(socket: &Path, outcome: (i32, Value)) -> Value {
    let (code, envelope) = outcome;
    assert_eq!(code, 0, "{envelope}");
    assert_eq!(envelope["ok"], true, "{envelope}");
    assert_eq!(envelope["command"], "wait", "{envelope}");
    assert_eq!(
        violation(&wait_schema(socket), &envelope, "result"),
        None,
        "{envelope}"
    );
    envelope
}

#[test]
fn wait_for_the_end_of_a_session_gives_its_exit_code_and_times_out_before_it() {
    let workspace = Workspace::new("api-wait-ended");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);

    // The short timeout is the one this test wants to pass.
    assert_eq!(
        failed(wait(&socket, &["server", "--ended", "--timeout", "1s"])),
        (8, "WaitTimeout".into())
    );

    // Ends 5 s from now, by when the wait has long started.
    type_line(&mut shell, "sleep 5; exit 3");
    let ended = met(
        &socket,
        wait(&socket, &["server", "--ended", "--timeout", "60s"]),
    );
    assert_eq!(ended["condition"], "ended");
    assert_eq!(ended["session"], SHELL);
    assert_eq!(ended["exit_code"], 3, "{ended}");

    // Gone, it is no longer a target.
    assert_eq!(
        failed(wait(&socket, &["server", "--ended"])),
        (3, "TargetNotFound".into())
    );
}

#[test]
fn wait_for_a_regex_counts_only_output_after_it_starts_unless_it_includes_the_screen() {
    let workspace = Workspace::new("api-wait-regex");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    // Split in the typed line, so the echo of the line is not the mark.
    type_line(&mut shell, r#"printf '\033[1mOLD\033[0m''MARK\n'"#);
    assert!(
        output
            .read_until("OLD\x1b[0mMARK\r\n", Duration::from_secs(20))
            .contains("OLD\x1b[0mMARK\r\n"),
        "the mark never printed"
    );

    // On the screen already, so it is not output that arrives after the wait starts.
    assert_eq!(
        failed(wait(
            &socket,
            &["server", "--regex", "OLDMARK", "--timeout", "1s"]
        )),
        (8, "WaitTimeout".into())
    );
    let screen = wait(
        &socket,
        &[
            "server",
            "--regex",
            "OLD(MARK)$",
            "--include-screen",
            "--timeout",
            "20s",
        ],
    );
    if has_terminal_state() {
        let screen = met(&socket, screen);
        assert_eq!(screen["condition"], "regex");
        assert_eq!(screen["match"], json!({"text": "OLDMARK"}), "{screen}");
        // The screen's top row starts the wait's text, where `\A` and a single-line `^` match.
        type_line(&mut shell, r#"printf '\033[H\033[2J'; printf 'TOP''ROW\n'"#);
        assert!(
            output
                .read_until("TOPROW\r\n", Duration::from_secs(20))
                .contains("TOPROW\r\n"),
            "the top row never printed"
        );
        for pattern in [r"\ATOP(ROW)", r"(?-m:^)TOP(ROW)"] {
            let top = met(
                &socket,
                wait(
                    &socket,
                    &[
                        "server",
                        "--regex",
                        pattern,
                        "--include-screen",
                        "--timeout",
                        "20s",
                    ],
                ),
            );
            assert_eq!(top["match"], json!({"text": "TOPROW"}), "{pattern}: {top}");
        }
    } else {
        // No shadow terminal, so no screen to look at: refused, rather than left to time out.
        assert_eq!(failed(screen), (2, "InvalidRequest".into()));
    }

    // Numbered lines, so a match says when it was printed: one wait after another sees a later
    // line, never one printed before it started.
    type_line(
        &mut shell,
        r#"i=0; while [ $i -lt 300 ]; do i=$((i+1)); echo "TICK-$i"; sleep 0.1; done"#,
    );
    let tick = |socket: &Path| {
        let found = met(
            socket,
            wait(
                socket,
                &["server", "--regex", r"TICK-\d+\r\n", "--timeout", "20s"],
            ),
        );
        let text = found["match"]["text"].as_str().unwrap().to_string();
        text.trim_start_matches("TICK-")
            .trim_end()
            .parse::<u32>()
            .unwrap_or_else(|_| panic!("not a tick: {text:?}"))
    };
    let first = tick(&socket);
    let second = tick(&socket);
    assert!(second > first, "{second} came before {first}");

    assert_eq!(
        failed(wait(
            &socket,
            &["server", "--regex", "(", "--timeout", "1s"]
        )),
        (2, "InvalidRequest".into())
    );
    let human = workroom(
        Some(&socket),
        &["wait", "server", "--regex", r"TICK-\d+", "--timeout", "20s"],
    );
    assert_eq!(human.code, 0, "{}", human.stderr);
    assert!(human.stdout.starts_with("TICK-"), "{}", human.stdout);
}

/// Output that goes quiet settles a regex wait, expect-style: a prompt with no line end meets
/// `$` once the program waits on its input. Output that keeps coming never does, however long
/// the line it grows, so the wait runs to its timeout.
#[test]
fn a_regex_wait_settles_when_the_output_goes_quiet_and_not_before() {
    let workspace = Workspace::new("api-wait-quiet");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    // The session is up, and named, before the wait looks for it.
    type_line(&mut shell, r#"echo "SHELL""-UP""#);
    assert!(
        output
            .read_until("SHELL-UP\r\n", Duration::from_secs(20))
            .contains("SHELL-UP\r\n"),
        "the shell never answered"
    );
    let prompt = started(
        &socket,
        &[
            "wait",
            "server",
            "--regex",
            "Password: $",
            "--timeout",
            "20s",
            "--json",
        ],
    );
    // Long enough for the wait to have started, and split so the typed line's echo isn't it.
    type_line(&mut shell, "sleep 3; printf 'Pass''word: '; read -r answer");
    let prompt = finished(prompt);
    assert_eq!(prompt.code, 0, "{} {}", prompt.stdout, prompt.stderr);
    assert_eq!(
        prompt.envelope()["match"],
        json!({"text": "Password: "}),
        "{}",
        prompt.stdout
    );
    type_line(&mut shell, "");

    // A dot every 10 ms, far within the quiet: the line never ends, nor goes quiet.
    type_line(
        &mut shell,
        "i=0; while [ $i -lt 800 ]; do i=$((i+1)); printf .; sleep 0.01; done",
    );
    assert_eq!(
        failed(wait(
            &socket,
            &["server", "--regex", r"\.+$", "--timeout", "3s"]
        )),
        (8, "WaitTimeout".into()),
        "settled while output kept coming"
    );
}

/// A program status and the shell's command end both come from the shadow terminal, which parses
/// OSC 7501 and OSC 133.
#[test]
fn wait_for_a_program_status_or_the_shells_command_to_finish() {
    let workspace = Workspace::new("api-wait-status");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    listing_until(&socket, |listing| listing.len() == 1);
    if !has_terminal_state() {
        for condition in [&["--status", "working"][..], &["--command-finished"]] {
            let args: Vec<&str> = [&["server"][..], condition, &["--timeout", "1s"]].concat();
            assert_eq!(
                failed(wait(&socket, &args)),
                (2, "InvalidRequest".into()),
                "{condition:?} needs the shadow terminal"
            );
        }
        return;
    }

    // `/bin/sh` sends no OSC 133 marks, so a command's end can't be seen: said once the new
    // session's grace for its first mark is over, long before the timeout.
    assert_eq!(
        failed(wait(
            &socket,
            &["server", "--command-finished", "--timeout", "30s"]
        )),
        (3, "NoShellIntegration".into())
    );
    type_line(&mut shell, r#"printf '\033]133;A\007'; echo "MARKS""-ON""#);
    assert!(
        output
            .read_until("MARKS-ON\r\n", Duration::from_secs(20))
            .contains("MARKS-ON\r\n")
    );
    // A command that starts and ends 4 s from now, once the wait has started.
    type_line(
        &mut shell,
        r"sleep 4; printf '\033]133;C\007'; printf '\033]133;D;7\007'",
    );
    let finished = met(
        &socket,
        wait(
            &socket,
            &["server", "--command-finished", "--timeout", "60s"],
        ),
    );
    assert_eq!(finished["condition"], "command_finished");
    assert_eq!(finished["exit_code"], 7, "{finished}");

    // Working now, which counts, then blocked 4 s from now.
    type_line(
        &mut shell,
        r#"sh -c 'printf "\033]7501;state=working:app=claude\033\\"; sleep 4; printf "\033]7501;state=blocked:app=claude\033\\"; sleep 30'"#,
    );
    let working = met(
        &socket,
        wait(
            &socket,
            &["server", "--status", "working", "--timeout", "20s"],
        ),
    );
    assert_eq!(working["status"], "working", "{working}");
    let blocked = met(
        &socket,
        wait(
            &socket,
            &["server", "--status", "blocked", "--timeout", "60s"],
        ),
    );
    assert_eq!(blocked["condition"], "status");
    assert_eq!(blocked["status"], "blocked", "{blocked}");
    assert_eq!(
        failed(wait(
            &socket,
            &["server", "--status", "done", "--timeout", "1s"]
        )),
        (8, "WaitTimeout".into())
    );
    let human = workroom(Some(&socket), &["wait", "server", "--status", "blocked"]);
    assert_eq!(
        (human.code, human.stdout.as_str()),
        (0, "status: blocked\n")
    );
}

/// A new session waited on at once has had no time for its shell's first prompt, so a
/// `--command-finished` wait isn't refused for want of its marks: it waits a short grace for them.
#[test]
fn a_command_finished_wait_on_a_new_session_waits_for_its_first_prompt() {
    if !has_terminal_state() {
        eprintln!("skipped: a command's end needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-wait-new");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    // Its first mark a second on, once the wait has started, well inside the grace; the command
    // ends 3 s after that.
    type_line(
        &mut shell,
        r"sleep 1; printf '\033]133;A\007'; sleep 3; printf '\033]133;C\007'; printf '\033]133;D;5\007'",
    );
    listing_until(&socket, |listing| listing.len() == 1);
    let finished = met(
        &socket,
        wait(
            &socket,
            &["server", "--command-finished", "--timeout", "60s"],
        ),
    );
    assert_eq!(finished["exit_code"], 5, "{finished}");
}

#[test]
fn wait_for_a_run_state_with_its_exit_code() {
    let workspace = Workspace::new("api-wait-run");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _run = attach_with_env(
        &socket,
        RUN,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "sleep 4; exit 3"),
            ("WORKROOM_SESSION_TITLE", "dev"),
        ],
    );
    // Exits 1 five seconds from now, by when its wait below has started.
    let _failing = attach_with_env(
        &socket,
        "d00dfeed-2222-4333-8444-55556666cafe",
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "sleep 5; exit 1"),
            ("WORKROOM_SESSION_TITLE", "failing"),
        ],
    );
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);

    // `--exit-code` doesn't filter: the run's exit answers the wait whatever its code, and another
    // code than the one asked for is `ExitCodeMismatch` (3), not a wait to the timeout.
    let started = std::time::Instant::now();
    let mismatch = wait(
        &socket,
        &[
            "failing",
            "--run",
            "exited",
            "--exit-code",
            "0",
            "--timeout",
            "120s",
        ],
    );
    assert!(
        started.elapsed() < Duration::from_secs(60),
        "it waited to its timeout"
    );
    assert!(
        mismatch.1["error"]["message"]
            .as_str()
            .unwrap()
            .contains("exited with code 1, not 0"),
        "{}",
        mismatch.1
    );
    // The code it did exit with, for a script to read.
    assert_eq!(
        mismatch.1["error"]["details"],
        json!({"exit_code": 1}),
        "{}",
        mismatch.1
    );
    assert_eq!(failed(mismatch), (3, "ExitCodeMismatch".into()));

    let exited = met(
        &socket,
        wait(
            &socket,
            &[
                "dev",
                "--run",
                "exited",
                "--exit-code",
                "3",
                "--timeout",
                "60s",
            ],
        ),
    );
    assert_eq!(exited["condition"], "run");
    assert_eq!(exited["run_state"], "exited", "{exited}");
    assert!(exited.get("run").is_none(), "{exited}");
    assert_eq!(exited["exit_code"], 3, "{exited}");
    // Exited is a state it stays in, so a later wait sees it at once.
    let human = workroom(
        Some(&socket),
        &["wait", "dev", "--run", "exited", "--timeout", "20s"],
    );
    assert_eq!(
        (human.code, human.stdout.as_str()),
        (0, "run: exited (exit code 3)\n")
    );
    assert_eq!(
        failed(wait(
            &socket,
            &[
                "dev",
                "--run",
                "exited",
                "--exit-code",
                "4",
                "--timeout",
                "60s"
            ]
        )),
        (3, "ExitCodeMismatch".into()),
        "exited already with 3, so refused at once"
    );
    let (code, refused) = wait(&socket, &["server", "--run", "running"]);
    assert_eq!(
        failed((code, refused.clone())),
        (2, "InvalidRequest".into()),
        "a shell has no run state"
    );
    // Pinned to its session's id for a hand-off, the wait still names the target as typed.
    let message = refused["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains(r#""server""#), "{message}");
    // Bad input is refused as such before an unknown target is looked for, as any request is.
    let bad = workroom(
        Some(&socket),
        &[
            "api",
            "call",
            "terminal.wait",
            r#"{"target":"nobody","status":"sleepy"}"#,
            "--json",
        ],
    );
    assert_eq!(
        (bad.code, bad.envelope()["error"]["kind"].clone()),
        (2, json!("InvalidRequest")),
        "{}",
        bad.stdout
    );
}

/// A restart's `stopping` lasts only until its supervisor starts the command again, a moment, far
/// less than the runs watcher takes between two reads of the run's status, yet a wait for it is
/// met: the supervisor logs every transition, and the watcher hands each to the run's waits. The
/// wait is started before the restarts, which go on until it answers, since nothing says when it
/// has reached the daemon; without the log, each is heard one time in fifty, or so.
#[test]
fn a_wait_for_a_runs_stopping_hears_it_across_a_restart() {
    // Short: the socket's path must fit a Unix socket's.
    let workspace = Workspace::new("api-wait-stop");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _run = attach_with_env(
        &socket,
        RUN,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "sleep 60"),
            ("WORKROOM_SESSION_TITLE", "dev"),
        ],
    );
    listing_until(&socket, |listing| listing.len() == 1);
    met(
        &socket,
        wait(&socket, &["dev", "--run", "running", "--timeout", "20s"]),
    );
    let restart = || {
        let mut payload: Vec<u8> = (0..16)
            .map(|at| u8::from_str_radix(&RUN.replace('-', "")[at * 2..at * 2 + 2], 16).unwrap())
            .collect();
        payload.push(wr_protocol::frame::RunSignal::Restart as u8);
        let reply = common::control(
            &socket,
            wr_protocol::frame::Frame::new(wr_protocol::frame::FrameKind::Signal, payload),
        );
        assert_eq!(reply.kind, wr_protocol::frame::FrameKind::Acknowledged);
    };
    for round in 0..2 {
        let mut stopping = started(
            &socket,
            &[
                "wait",
                "dev",
                "--run",
                "stopping",
                "--timeout",
                "20s",
                "--json",
            ],
        );
        let mut restarts = 0;
        while stopping.try_wait().expect("the wait").is_none() && restarts < 8 {
            std::thread::sleep(Duration::from_millis(1500));
            restart();
            restarts += 1;
        }
        let stopping = finished(stopping);
        assert_eq!(
            stopping.code, 0,
            "round {round}, {restarts} restarts: {} {}",
            stopping.stdout, stopping.stderr
        );
        assert_eq!(
            stopping.envelope()["run_state"],
            "stopping",
            "{}",
            stopping.stdout
        );
        // Running again, in the same session.
        met(
            &socket,
            wait(&socket, &["dev", "--run", "running", "--timeout", "20s"]),
        );
    }
}

/// A bad command line is 1, as for every command (they share one parser), and no daemon is 7.
#[test]
fn wait_takes_one_target_and_one_condition() {
    let workspace = Workspace::new("api-wait-usage");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    for args in [
        &["wait", "--ended", "--json"][..],
        &["wait", "a", "b", "--ended", "--json"],
        &["wait", "a", "--json"],
        &["wait", "a", "--ended", "--regex", "x", "--json"],
        // `false` is a regex: two conditions.
        &["wait", "a", "--regex", "false", "--ended", "--json"],
        &["wait", "a", "--ended", "--timeout", "soon", "--json"],
    ] {
        let run = workroom(Some(&socket), args);
        assert_eq!(run.code, 1, "{args:?} {}", run.stdout);
        assert_eq!(run.envelope()["error"]["kind"], "InternalError", "{args:?}");
    }
    let run = workroom_outside_any_daemon(&workspace.dir, &["wait", "a", "--ended", "--json"]);
    assert_eq!(run.code, 7, "{}", run.stdout);
    assert_eq!(run.envelope()["error"]["kind"], "DaemonUnreachable");
}

/// `workroom <args>` against `socket`, started now and left running: [`finished`] collects it.
fn started(socket: &Path, args: &[&str]) -> std::process::Child {
    Command::new(common::daemon_binary())
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
        .env("WORKROOM_DAEMON", socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run workroom")
}

fn finished(child: std::process::Child) -> Run {
    let output = child.wait_with_output().expect("run workroom");
    Run {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        code: output.status.code().unwrap_or(-1),
    }
}

/// A hand-off replaces the daemon's program in place and closes every client connection with the
/// old one, a waiting `workroom wait`'s included. The wait goes on: one for a state is sent again
/// to the new program, with what is left of its timeout, and is met there; one for an event is
/// `WaitInterrupted` (3), since what came between the two programs may have gone unseen. A daemon
/// that goes away for good is 7, as ever. Commands' ends are seen across it too: the shell's marks
/// came with it.
#[test]
fn a_wait_across_a_hand_off_goes_on_in_the_new_program() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-wait-handoff");
    let socket = workspace.socket();
    let daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    type_line(&mut shell, r#"printf '\033]133;A\007'; echo "MARKS""-ON""#);
    assert!(
        output
            .read_until("MARKS-ON\r\n", Duration::from_secs(20))
            .contains("MARKS-ON\r\n"),
        "fixture: the marks never printed"
    );
    // Blocked, and a command ended, once `go` exists: after the hand-off. Running before the
    // client goes: one dropped as soon as it is typed into may not have sent the line on yet, and
    // the shell then never runs it (as on Linux, #738's CI).
    let go = workspace.dir.join("go");
    type_line(
        &mut shell,
        &format!(
            r#"sh -c 'echo "LOOP""-ON"; while [ ! -e "{go}" ]; do sleep 0.05; done; printf "\033]7501;state=blocked:app=claude\033\\"; printf "\033]133;C\007\033]133;D;6\007"; sleep 30'"#,
            go = go.display()
        ),
    );
    assert!(
        output
            .read_until("LOOP-ON\r\n", Duration::from_secs(20))
            .contains("LOOP-ON\r\n"),
        "fixture: the waiting command never started"
    );
    drop(output);
    drop(shell);

    let status = started(
        &socket,
        &[
            "wait",
            "server",
            "--status",
            "blocked",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    let regex = started(
        &socket,
        &[
            "wait",
            "server",
            "--regex",
            "NEVER",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    // Time for both to reach the daemon before it is handed off: each says so if it didn't.
    std::thread::sleep(Duration::from_secs(3));
    let next = workspace.dir.join("next-workroom");
    common::copy_daemon_binary(&next);
    let handed = Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(&socket)
        .arg("--binary")
        .arg(&next)
        .arg("--force")
        .output()
        .expect("hand-off");
    assert_eq!(
        String::from_utf8_lossy(&handed.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&handed.stderr)
    );
    // In the new program, before anything happens: a session older than the marks' grace whose
    // marks came across with it.
    let command = started(
        &socket,
        &[
            "wait",
            "server",
            "--command-finished",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    std::thread::sleep(Duration::from_secs(3));
    std::fs::write(&go, b"").expect("go");

    let status = finished(status);
    assert!(
        status.stderr.contains("handed off during the wait"),
        "the wait never spanned the hand-off (it had 3 s to start): {}",
        status.stderr
    );
    assert_eq!(status.code, 0, "{} {}", status.stdout, status.stderr);
    assert_eq!(status.envelope()["status"], "blocked", "{}", status.stdout);
    let regex = finished(regex);
    assert_eq!(
        (regex.code, regex.envelope()["error"]["kind"].clone()),
        (3, json!("WaitInterrupted")),
        "{} {}",
        regex.stdout,
        regex.stderr
    );
    let command = finished(command);
    assert_eq!(command.code, 0, "{} {}", command.stdout, command.stderr);
    assert_eq!(command.envelope()["exit_code"], 6, "{}", command.stdout);

    // A daemon gone for good: nobody is listening to send the wait to again.
    let gone = started(
        &socket,
        &["wait", "server", "--ended", "--timeout", "60s", "--json"],
    );
    std::thread::sleep(Duration::from_secs(3));
    drop(daemon);
    let gone = finished(gone);
    assert_eq!(
        (gone.code, gone.envelope()["error"]["kind"].clone()),
        (7, json!("DaemonUnreachable")),
        "{} {}",
        gone.stdout,
        gone.stderr
    );
}

/// Sends `signal` to `child`.
fn signal(child: &std::process::Child, signal: i32) {
    let pid = i32::try_from(child.id()).expect("a pid");
    // SAFETY: `kill` takes plain integers; `pid` is a child this test started and hasn't reaped.
    assert_eq!(unsafe { libc::kill(pid, signal) }, 0, "kill {pid} {signal}");
}

/// A session that ends during a hand-off, after the old program last read it and before a wait
/// sent again reaches the new one, is gone from the new program's sessions. A wait for its end is
/// met, as the old program would have answered, and a wait for another state is `SessionEnded`
/// (3), never `TargetNotFound`: the wait named it by its id, pinned when it started. A target that
/// names no session is still `TargetNotFound`. The waits are stopped across the hand-off and
/// the end, so both happen before either is sent again.
#[test]
fn a_wait_whose_session_ends_during_a_hand_off_answers_as_ended() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    // Short: the socket's path has to fit a socket address.
    let workspace = Workspace::new("api-wait-gone");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    let go = workspace.dir.join("go");
    // The shell exits once `go` exists: after the hand-off.
    type_line(
        &mut shell,
        &format!(
            r#"sh -c 'echo "LOOP""-ON"; while [ ! -e "{go}" ]; do sleep 0.05; done'; exit"#,
            go = go.display()
        ),
    );
    assert!(
        output
            .read_until("LOOP-ON\r\n", Duration::from_secs(20))
            .contains("LOOP-ON\r\n"),
        "fixture: the waiting command never started"
    );
    drop(output);
    drop(shell);

    let ended = started(
        &socket,
        &["wait", "server", "--ended", "--timeout", "60s", "--json"],
    );
    let status = started(
        &socket,
        &[
            "wait",
            "server",
            "--status",
            "blocked",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    // Time for both to reach the daemon before they are stopped: each says so if it didn't.
    std::thread::sleep(Duration::from_secs(3));
    signal(&ended, libc::SIGSTOP);
    signal(&status, libc::SIGSTOP);
    let next = workspace.dir.join("next-workroom");
    common::copy_daemon_binary(&next);
    let handed = Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(&socket)
        .arg("--binary")
        .arg(&next)
        .arg("--force")
        .output()
        .expect("hand-off");
    assert_eq!(
        String::from_utf8_lossy(&handed.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&handed.stderr)
    );
    std::fs::write(&go, b"").expect("go");
    listing_until(&socket, <[Value]>::is_empty);
    signal(&ended, libc::SIGCONT);
    signal(&status, libc::SIGCONT);

    let ended = finished(ended);
    assert!(
        ended.stderr.contains("handed off during the wait"),
        "the wait never spanned the hand-off (it had 3 s to start): {}",
        ended.stderr
    );
    assert_eq!(ended.code, 0, "{} {}", ended.stdout, ended.stderr);
    assert_eq!(ended.envelope()["condition"], "ended", "{}", ended.stdout);
    assert!(ended.envelope()["session"].is_string(), "{}", ended.stdout);
    let status = finished(status);
    assert_eq!(
        (status.code, status.envelope()["error"]["kind"].clone()),
        (3, json!("SessionEnded")),
        "{} {}",
        status.stdout,
        status.stderr
    );
    // Not sent again: nothing names it.
    assert_eq!(
        failed(wait(&socket, &["server", "--ended", "--timeout", "1s"])),
        (3, "TargetNotFound".into())
    );
}

/// A running `workroom events`, whose stdout lines are read as they come.
struct Events {
    child: std::process::Child,
    lines: std::sync::mpsc::Receiver<String>,
    /// Every event read so far, in order.
    seen: Vec<Value>,
}

impl Events {
    /// `workroom events <args>` against `socket`.
    fn start(socket: &Path, args: &[&str]) -> Events {
        let mut child = started(socket, &[&["events"][..], args].concat());
        let stdout = child.stdout.take().expect("stdout");
        let (send, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            use std::io::BufRead;
            for line in std::io::BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                if send.send(line).is_err() {
                    return;
                }
            }
        });
        Events {
            child,
            lines,
            seen: Vec::new(),
        }
    }

    /// The next event, read within `within`.
    fn next(&mut self, within: Duration) -> Option<Value> {
        let line = self.lines.recv_timeout(within).ok()?;
        let event: Value = serde_json::from_str(&line)
            .unwrap_or_else(|e| panic!("not one JSON object a line ({e}): {line:?}"));
        self.seen.push(event.clone());
        Some(event)
    }

    /// Reads events until one `wanted` says is it, within 20 s, and returns it.
    fn until(&mut self, what: &str, wanted: impl Fn(&Value) -> bool) -> Value {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) {
            match self.next(left) {
                Some(event) if wanted(&event) => return event,
                Some(_) => {}
                None => break,
            }
        }
        panic!("no {what} within 20 s; events: {:#?}", self.seen);
    }

    /// How many events read so far are named `name`.
    fn count(&self, name: &str) -> usize {
        self.seen
            .iter()
            .filter(|event| event["event"] == name)
            .count()
    }

    /// Stops it, and returns what it said on stderr.
    fn stop(mut self) -> String {
        let _ = self.child.kill();
        let mut stderr = String::new();
        if let Some(mut pipe) = self.child.stderr.take() {
            use std::io::Read;
            let _ = pipe.read_to_string(&mut stderr);
        }
        stderr
    }
}

impl Drop for Events {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn is(event: &Value, name: &str, session: &str) -> bool {
    event["event"] == name && event["session"] == session
}

/// Every live event has `boot` and a `revision` higher than any before it.
fn assert_numbered(seen: &[Value], boot: &Value) {
    let mut last = 0;
    for event in seen {
        assert_eq!(&event["boot"], boot, "{event}");
        let revision = event["revision"].as_u64().expect("a revision");
        if event["event"]
            .as_str()
            .is_some_and(|name| name.contains('.'))
        {
            assert!(revision > last, "{revision} after {last}: {seen:#?}");
        }
        last = revision;
    }
}

/// `workroom events` prints one JSON object a line: each session as it is, `snapshot-complete`,
/// then live events as they happen, in order, every one with the same `boot` and a `revision`
/// that only rises. A session created, its coding agent's program status and its end, each once.
#[test]
fn events_are_a_snapshot_then_snapshot_complete_then_live_events_in_order() {
    let workspace = Workspace::new("api-events");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);

    let mut events = Events::start(&socket, &[]);
    let first = events.next(Duration::from_secs(20)).expect("a snapshot");
    assert!(is(&first, "session", SHELL), "{first}");
    assert_eq!(first["label"], "server", "{first}");
    assert_eq!(first["scope"], json!({"kind": "workroom", "id": "wr-1"}));
    assert_eq!(first["run"], false, "{first}");
    let complete = events.next(Duration::from_secs(20)).expect("its end");
    assert_eq!(complete["event"], "snapshot-complete", "{complete}");
    assert_eq!(complete["sessions"], json!([SHELL]), "{complete}");
    assert_eq!(complete["reason"], "subscribed", "{complete}");
    assert_eq!(complete["revision"], first["revision"], "{complete}");

    let mut other = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let created = events.until("session.created", |e| is(e, "session.created", OTHER));
    assert_eq!(created["label"], "tests", "{created}");
    assert_eq!(created["run_state"], Value::Null, "{created}");
    if has_terminal_state() {
        // From a program of its own, with its message in base64 ("Allow").
        type_line(
            &mut other,
            r#"sh -c 'printf "\033]7501;state=blocked:app=claude:msg=QWxsb3c=\033\\"; sleep 2'"#,
        );
        let status = events.until("its program status", |e| {
            is(e, "session.program_status", OTHER)
        });
        assert_eq!(status["coding_agent"]["state"], "blocked", "{status}");
        assert_eq!(status["coding_agent"]["app"], "claude", "{status}");
        assert_eq!(status["coding_agent"]["message"], "Allow", "{status}");
    }
    type_line(&mut other, "exit 3");
    let ended = events.until("session.ended", |e| is(e, "session.ended", OTHER));
    assert_eq!(ended["exit_code"], 3, "{ended}");
    assert_eq!(ended["scope"], json!({"kind": "workroom", "id": "wr-1"}));

    // Killed, as the app closing its pane does: ended, its exit code unknown.
    let id = wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(SHELL))
        .expect("an id")
        .0
        .to_vec();
    let reply = common::control(
        &socket,
        wr_protocol::frame::Frame::new(wr_protocol::frame::FrameKind::Kill, id),
    );
    assert_eq!(reply.kind, wr_protocol::frame::FrameKind::Acknowledged);
    let killed = events.until("the killed session's end", |e| {
        is(e, "session.ended", SHELL)
    });
    assert_eq!(killed["exit_code"], Value::Null, "{killed}");

    assert_numbered(&events.seen, &first["boot"]);
    assert!(first["boot"].is_string(), "{first}");
    assert_eq!(events.count("session.created"), 1, "{:#?}", events.seen);
    assert_eq!(events.count("session.ended"), 2, "{:#?}", events.seen);
    assert_eq!(events.count("snapshot-complete"), 1, "{:#?}", events.seen);
    events.stop();
}

/// `events.subscribe`'s output schema, as the daemon at `socket` publishes it.
fn events_schema(socket: &Path) -> Value {
    let described =
        Api::connect(socket).call("api.describe", json!({"method": "events.subscribe"}));
    described["result"]["methods"][0]["output"].clone()
}

/// Each client attaching and detaching is an event (#688), with its session, scope and the client
/// as it attached, in the snapshot's sessions too, and `--type` keeps to them: a pane, a
/// `workroom attach` someone ran and the app's connection, each leaving as it goes, its client
/// the one that attached. Every event matches the schema `api describe` publishes.
#[test]
fn events_tell_each_client_attaching_and_detaching() {
    let workspace = Workspace::new("api-events-clients");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _pane = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);

    let mut events = Events::start(&socket, &["--type", "client.attached,client.detached"]);
    let first = events.until("the snapshot", |e| is(e, "session", SHELL));
    let pane = first["clients"]
        .as_array()
        .and_then(|clients| clients.first())
        .cloned()
        .unwrap_or_else(|| panic!("the pane is not in the snapshot: {first}"));
    assert_eq!(pane["kind"], "pane", "{first}");
    assert_eq!(pane["hostname"], this_hostname().as_str(), "{first}");
    events.until("snapshot-complete", |e| e["event"] == "snapshot-complete");

    let cli = attach_with_env(&socket, SHELL, &[], &[]);
    let attached = events.until("the cli's attach", |e| is(e, "client.attached", SHELL));
    assert_eq!(attached["client"]["kind"], "cli", "{attached}");
    assert_eq!(attached["scope"], json!({"kind": "workroom", "id": "wr-1"}));
    let app = attach_as_app(&socket, SHELL, "mac-b.local", (100, 30));
    let app_attached = events.until("the app's attach", |e| is(e, "client.attached", SHELL));
    assert_eq!(app_attached["client"]["kind"], "app", "{app_attached}");
    assert_eq!(app_attached["client"]["hostname"], "mac-b.local");
    for key in ["id", "kind", "hostname", "attached_at_ms"] {
        assert!(
            app_attached["client"].get(key).is_some(),
            "{key}: {app_attached}"
        );
    }

    drop(app);
    let left = events.until("the app leaving", |e| is(e, "client.detached", SHELL));
    assert_eq!(left["client"], app_attached["client"], "{left}");
    drop(cli);
    let left = events.until("the cli leaving", |e| is(e, "client.detached", SHELL));
    assert_eq!(left["client"], attached["client"], "{left}");
    let live: Vec<&Value> = events
        .seen
        .iter()
        .skip_while(|e| e["event"] != "snapshot-complete")
        .skip(1)
        .collect();
    assert_eq!(live.len(), 4, "each once: {:#?}", events.seen);
    assert_numbered(&events.seen, &first["boot"]);
    let schema = events_schema(&socket);
    for event in &events.seen {
        assert_eq!(violation(&schema, event, "event"), None, "{event}");
    }
    events.stop();
}

/// A hand-off closes every client's connection, so the next program tells each client the events
/// held as detached, and a client attaching to it is numbered past every one before (#688), those
/// that left before the hand-off included: a stream that goes on across the hand-off hears the
/// pane leave and come back, attaching again itself (#681), as another client, never under a
/// number one before it had.
#[test]
fn clients_detach_across_a_hand_off_and_attach_again_numbered_past_the_last() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-clients-handoff");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _pane = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let mut events = Events::start(&socket, &["--type", "client.attached,client.detached"]);
    let first = events.until("the snapshot", |e| is(e, "session", SHELL));
    let before = first["clients"][0]["id"]
        .as_u64()
        .unwrap_or_else(|| panic!("no client in the snapshot: {first}"));
    events.until("snapshot-complete", |e| e["event"] == "snapshot-complete");
    // A second client, gone before the hand-off: the highest number given out, held by nobody.
    let second = attach_with_env(&socket, SHELL, &[], &[]);
    let gone = events.until("the second client", |e| is(e, "client.attached", SHELL));
    let gone = gone["client"]["id"].as_u64().expect("an id");
    assert!(gone > before, "{gone} after {before}");
    drop(second);
    events.until("the second client leaving", |e| {
        is(e, "client.detached", SHELL) && e["client"]["id"] == gone
    });

    hand_off(&socket, &workspace.dir);
    let left = events.until("the pane leaving", |e| {
        is(e, "client.detached", SHELL) && e["client"]["id"] == before
    });
    assert_eq!(left["client"], first["clients"][0], "{left}");
    // The pane attaches again itself, to the new program (#681).
    let back = events.until("the pane back", |e| is(e, "client.attached", SHELL));
    let after = back["client"]["id"].as_u64().expect("an id");
    assert_eq!(after, gone + 1, "numbered past the client that left first");
    assert_numbered(&events.seen, &first["boot"]);
    assert_eq!(events.count("snapshot-complete"), 1, "{:#?}", events.seen);
    assert_eq!(events.count("client.detached"), 2, "{:#?}", events.seen);
    let listed: Vec<Value> = clients_of(&socket, SHELL);
    assert_eq!(
        listed
            .iter()
            .map(|client| client["id"].as_u64())
            .collect::<Vec<_>>(),
        [Some(after)],
        "{listed:?}"
    );
    events.stop();
}

/// The events a `workroom events` that `shell` runs in the background writes to `name` under
/// `dir`, read once its snapshot is complete.
fn events_in_pane(shell: &mut Spawned, dir: &Path, name: &str, args: &str) -> std::path::PathBuf {
    let path = dir.join(name);
    type_line(
        shell,
        &format!(
            "'{}' events {args} > '{}' 2>&1 &",
            common::daemon_binary().display(),
            path.display()
        ),
    );
    assert!(
        wait_for(Duration::from_secs(20), || {
            std::fs::read_to_string(&path).is_ok_and(|text| text.contains("snapshot-complete"))
        }),
        "the pane's events never began: {:?}",
        std::fs::read_to_string(&path)
    );
    path
}

/// Each event a file of them holds, one a line.
fn events_written(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap_or_else(|e| panic!("{e}: {line:?}")))
        .collect()
}

/// Restarts run session `id`, as the app's restart does.
fn restart_run(socket: &Path, id: &str) {
    let mut payload: Vec<u8> = (0..16)
        .map(|at| u8::from_str_radix(&id.replace('-', "")[at * 2..at * 2 + 2], 16).unwrap())
        .collect();
    payload.push(wr_protocol::frame::RunSignal::Restart as u8);
    let reply = common::control(
        socket,
        wr_protocol::frame::Frame::new(wr_protocol::frame::FrameKind::Signal, payload),
    );
    assert_eq!(reply.kind, wr_protocol::frame::FrameKind::Acknowledged);
}

/// A run session's every transition is an event, in order, once each: `stopping` on a restart
/// too, which the run goes straight on from. The snapshot says the run's state as it stands.
#[test]
fn events_tell_every_run_state_a_restart_included() {
    let workspace = Workspace::new("api-events-run");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut events = Events::start(&socket, &["--type", "session.run_state"]);
    events.until("snapshot-complete", |e| e["event"] == "snapshot-complete");
    let _run = attach_with_env(
        &socket,
        RUN,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "sleep 60"),
            ("WORKROOM_SESSION_TITLE", "dev"),
        ],
    );
    events.until("running", |e| {
        is(e, "session.run_state", RUN) && e["run_state"] == "running"
    });
    let later = Events::start(&socket, &[]);
    let mut later = later;
    let snapshot = later.until("the run in a snapshot", |e| is(e, "session", RUN));
    assert_eq!(snapshot["run"], true, "{snapshot}");
    assert_eq!(snapshot["run_state"], "running", "{snapshot}");
    restart_run(&socket, RUN);
    events.until("running again", |e| {
        is(e, "session.run_state", RUN)
            && e["run_state"] == "running"
            && e["revision"].as_u64() > snapshot["revision"].as_u64()
    });
    let states: Vec<&str> = events
        .seen
        .iter()
        .filter(|e| e["event"] == "session.run_state")
        .map(|e| e["run_state"].as_str().unwrap())
        .collect();
    assert_eq!(
        states,
        ["starting", "running", "stopping", "starting", "running"],
        "{:#?}",
        events.seen
    );
    assert_eq!(
        events.count("session.created"),
        0,
        "--type keeps to its own"
    );
}

/// Hands the daemon on `socket` off to a copy of the binary under test.
fn hand_off(socket: &Path, dir: &Path) {
    let next = dir.join("next-workroom");
    if !next.exists() {
        common::copy_daemon_binary(&next);
    }
    let handed = Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(socket)
        .arg("--binary")
        .arg(&next)
        .arg("--force")
        .output()
        .expect("hand-off");
    assert_eq!(
        String::from_utf8_lossy(&handed.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&handed.stderr)
    );
}

/// A hand-off closes `workroom events`' connection with the old program, and it goes on in the
/// new one from where it stood: every event once, in order, the ones made while it was away (in
/// the old program before the hand-off, and in the new one before it asked again) included, and
/// no second snapshot. A daemon that started afresh instead can't go on from there: the sessions
/// come afresh, a snapshot that says `gap`, and stderr says events may have been missed.
#[test]
fn events_go_on_across_a_hand_off_from_their_boot_and_revision() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-events-handoff");
    let socket = workspace.socket();
    let daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let mut events = Events::start(&socket, &[]);
    let complete = events.until("snapshot-complete", |e| e["event"] == "snapshot-complete");
    let boot = complete["boot"].clone();

    // Stopped, so it reads nothing until the new program has made events of its own.
    signal(&events.child, libc::SIGSTOP);
    let mut other = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut other);
    // It exits once `go` exists: after the hand-off, which closes this client.
    let go = workspace.dir.join("go");
    type_line(
        &mut other,
        &format!(
            r#"sh -c 'echo "LOOP""-ON"; while [ ! -e "{go}" ]; do sleep 0.05; done'; exit 4"#,
            go = go.display()
        ),
    );
    assert!(
        output
            .read_until("LOOP-ON\r\n", Duration::from_secs(20))
            .contains("LOOP-ON\r\n"),
        "fixture: the waiting command never started"
    );
    drop(output);
    drop(other);
    hand_off(&socket, &workspace.dir);
    std::fs::write(&go, b"").expect("go");
    listing_until(&socket, |listing| listing.len() == 1);
    let _third = open(&socket, RUN, "third", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    signal(&events.child, libc::SIGCONT);

    events.until("the third session", |e| is(e, "session.created", RUN));
    // The sessions' own events: their clients' are
    // `clients_detach_across_a_hand_off_and_attach_again_numbered_past_the_last`'s.
    let live: Vec<(String, String)> = told(&events.seen)
        .into_iter()
        .filter(|(name, _)| name.starts_with("session."))
        .collect();
    assert_eq!(
        live,
        [
            pair("session.created", OTHER),
            pair("session.ended", OTHER),
            pair("session.created", RUN)
        ],
        "{:#?}",
        events.seen
    );
    let ended = events
        .seen
        .iter()
        .find(|e| is(e, "session.ended", OTHER))
        .unwrap();
    assert_eq!(ended["exit_code"], 4, "{ended}");
    assert_numbered(&events.seen, &boot);
    assert_eq!(events.count("snapshot-complete"), 1, "{:#?}", events.seen);
    assert_eq!(
        events.count("resumed"),
        0,
        "the CLI keeps `resumed` to itself"
    );

    // Another daemon, started afresh on the same socket: another boot.
    signal(&events.child, libc::SIGSTOP);
    drop(daemon);
    let _again = start_daemon(&socket);
    let _fourth = open(&socket, OTHER, "fourth", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    signal(&events.child, libc::SIGCONT);
    let gap = events.until("a snapshot after the gap", |e| {
        e["event"] == "snapshot-complete"
    });
    assert_eq!(gap["reason"], "gap", "{gap}");
    assert_ne!(gap["boot"], boot, "{gap}");
    assert_eq!(gap["sessions"], json!([OTHER]), "{gap}");
    let stderr = events.stop();
    assert!(
        stderr.contains("asking again from where the events stood"),
        "{stderr}"
    );
    assert!(stderr.contains("events may have been missed"), "{stderr}");
}

/// Tags session `id` with `workroom`, as the app's retag does.
fn retag(socket: &Path, id: &str, workroom: &str) {
    let mut payload = wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(id))
        .expect("an id")
        .0
        .to_vec();
    payload.extend_from_slice(workroom.as_bytes());
    let reply = common::control(
        socket,
        wr_protocol::frame::Frame::new(wr_protocol::frame::FrameKind::Retag, payload),
    );
    assert_eq!(reply.kind, wr_protocol::frame::FrameKind::Acknowledged);
}

/// From a pane, `--session` names the session wanted wherever it is: the pane's workroom is only
/// a default, which naming one overrides.
#[test]
fn events_for_a_session_named_from_a_pane_in_another_workroom() {
    let workspace = Workspace::new("api-events-named");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut away = open(&socket, RUN, "other-room", "wr-2", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    let named = events_in_pane(&mut shell, &workspace.dir, "named", "--session other-room");
    assert_eq!(
        told(&events_written(&named)),
        [
            pair("session", RUN),
            ("snapshot-complete".to_string(), String::new())
        ]
    );
    type_line(&mut away, "exit 2");
    assert!(
        wait_for(Duration::from_secs(20), || {
            events_written(&named)
                .iter()
                .any(|e| is(e, "session.ended", RUN))
        }),
        "{:#?}",
        events_written(&named)
    );
}

/// A session tagged with another workroom is `session.moved`, to the subscribers of the workroom
/// it leaves, of the one it joins and of every session. From then on it is the new one's: its
/// events reach that one's subscribers, not the old one's, and that one's snapshot holds it.
#[test]
fn a_session_moved_to_another_workroom_is_told_to_both() {
    let workspace = Workspace::new("api-events-moved");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let mut old = Events::start(&socket, &["--workroom", "wr-1"]);
    let mut new = Events::start(&socket, &["--workroom", "wr-2"]);
    let mut every = Events::start(&socket, &[]);
    for stream in [&mut old, &mut new, &mut every] {
        stream.until("snapshot-complete", |e| e["event"] == "snapshot-complete");
    }

    retag(&socket, SHELL, "wr-2");
    for stream in [&mut old, &mut new, &mut every] {
        let moved = stream.until("the move", |e| is(e, "session.moved", SHELL));
        assert_eq!(moved["scope"], json!({"kind": "workroom", "id": "wr-2"}));
        assert_eq!(
            moved["previous_scope"],
            json!({"kind": "workroom", "id": "wr-1"})
        );
    }
    let mut later = Events::start(&socket, &["--workroom", "wr-2"]);
    let held = later.until("its snapshot", |e| e["event"] == "snapshot-complete");
    assert_eq!(held["sessions"], json!([SHELL]), "{held}");
    let mut left = Events::start(&socket, &["--workroom", "wr-1"]);
    let empty = left.until("its snapshot", |e| e["event"] == "snapshot-complete");
    assert_eq!(empty["sessions"], json!([]), "{empty}");

    type_line(&mut shell, "exit 3");
    new.until("its end", |e| is(e, "session.ended", SHELL));
    every.until("its end", |e| is(e, "session.ended", SHELL));
    // Time for the old workroom's stream to have had it, had it been sent there.
    std::thread::sleep(Duration::from_secs(1));
    while old.next(Duration::from_millis(100)).is_some() {}
    assert_eq!(old.count("session.ended"), 0, "{:#?}", old.seen);
}

/// A filtered stream that hears nothing while more events than the daemon keeps go by still
/// resumes after a hand-off: the daemon told it where it stood (`place`, which `workroom events`
/// never prints), so it asks from there, not from a place long dropped.
#[test]
fn a_quiet_filtered_stream_resumes_after_a_hand_off_from_its_place() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-events-place");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let mut quiet = Events::start(&socket, &["--type", "session.ended"]);
    quiet.until("snapshot-complete", |e| e["event"] == "snapshot-complete");

    // More moves than the daemon keeps events, none of which the stream passes.
    for round in 0..1100 {
        retag(&socket, SHELL, if round % 2 == 0 { "wr-2" } else { "wr-1" });
    }
    // Time for a `place`, at most a second after the last.
    std::thread::sleep(Duration::from_secs(3));
    hand_off(&socket, &workspace.dir);
    let _other = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    common::control(
        &socket,
        wr_protocol::frame::Frame::new(
            wr_protocol::frame::FrameKind::Kill,
            wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(OTHER))
                .expect("an id")
                .0
                .to_vec(),
        ),
    );
    quiet.until("the end after the hand-off", |e| {
        is(e, "session.ended", OTHER)
    });
    assert_eq!(quiet.count("snapshot-complete"), 1, "{:#?}", quiet.seen);
    assert_eq!(quiet.count("place"), 0, "never printed");
    let stderr = quiet.stop();
    assert!(stderr.contains("asking again"), "{stderr}");
    assert!(!stderr.contains("may have been missed"), "{stderr}");
}

/// `(event, session)` of each event, the session's last 4 characters, for an assertion to read.
fn told(events: &[Value]) -> Vec<(String, String)> {
    events
        .iter()
        .map(|event| {
            let session = event["session"].as_str().unwrap_or_default();
            (
                event["event"].as_str().unwrap_or_default().to_string(),
                session[session.len().saturating_sub(4)..].to_string(),
            )
        })
        .collect()
}

fn pair(event: &str, session: &str) -> (String, String) {
    (event.to_string(), session[session.len() - 4..].to_string())
}

/// From a pane, `events` keeps to the pane's workroom unless `--all` widens it; from no pane it is
/// every session's. `--workroom`, `--session` and `--type` each keep to theirs, the snapshot to
/// the sessions they pass and the live events to those too. `--type` leaves the snapshot whole.
#[test]
fn events_keep_to_the_callers_workroom_and_to_each_filter() {
    let workspace = Workspace::new("api-events-filters");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut other = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);

    let scoped = events_in_pane(&mut shell, &workspace.dir, "scoped", "");
    let all = events_in_pane(&mut shell, &workspace.dir, "all", "--all");
    let mut second = Events::start(&socket, &["--workroom", "wr-2"]);
    let mut named = Events::start(&socket, &["--session", "tests"]);
    let mut ended = Events::start(&socket, &["--type", "session.ended"]);
    let mut nowhere = Events::start(&socket, &[]);
    for stream in [&mut second, &mut named, &mut ended, &mut nowhere] {
        stream.until("snapshot-complete", |e| e["event"] == "snapshot-complete");
    }

    let mut elsewhere = open(&socket, RUN, "elsewhere", "wr-2", &workspace.dir);
    // Its client follows it at once, the pane that created it (#688).
    second.until("its pane attached", |e| is(e, "client.attached", RUN));
    type_line(&mut other, "exit 4");
    named.until("its session's end", |e| is(e, "session.ended", OTHER));
    type_line(&mut elsewhere, "exit 5");
    second.until("its session's end", |e| is(e, "session.ended", RUN));
    nowhere.until("the last end", |e| is(e, "session.ended", RUN));
    ended.until("the last end", |e| is(e, "session.ended", RUN));
    assert!(
        wait_for(Duration::from_secs(20), || {
            events_written(&all)
                .iter()
                .any(|e| is(e, "session.ended", RUN))
        }),
        "--all never heard the last end: {:#?}",
        events_written(&all)
    );
    // Time for anything a filter should have kept back to have come, had it not.
    std::thread::sleep(Duration::from_secs(1));
    while named.next(Duration::from_millis(100)).is_some() {}
    while second.next(Duration::from_millis(100)).is_some() {}
    while ended.next(Duration::from_millis(100)).is_some() {}

    // A snapshot is in id order, and OTHER's sorts before SHELL's.
    let complete = ("snapshot-complete".to_string(), String::new());
    let with_snapshot = |live: &[(String, String)]| {
        let mut all = vec![pair("session", OTHER), pair("session", SHELL)];
        all.push(complete.clone());
        all.extend_from_slice(live);
        all
    };
    assert_eq!(
        told(&events_written(&scoped)),
        with_snapshot(&[pair("session.ended", OTHER)]),
        "the pane's workroom"
    );
    assert_eq!(
        told(&events_written(&all)),
        with_snapshot(&[
            pair("session.created", RUN),
            pair("client.attached", RUN),
            pair("session.ended", OTHER),
            pair("session.ended", RUN)
        ]),
        "--all"
    );
    assert_eq!(
        told(&nowhere.seen),
        told(&events_written(&all)),
        "from no pane"
    );
    assert_eq!(
        told(&second.seen),
        [
            complete.clone(),
            pair("session.created", RUN),
            pair("client.attached", RUN),
            pair("session.ended", RUN)
        ],
        "--workroom"
    );
    assert_eq!(
        told(&named.seen),
        [
            pair("session", OTHER),
            complete.clone(),
            pair("session.ended", OTHER)
        ],
        "--session"
    );
    assert_eq!(
        told(&ended.seen),
        with_snapshot(&[pair("session.ended", OTHER), pair("session.ended", RUN)]),
        "--type"
    );

    // Bad filters are refused before anything streams: a target that names no session is 3, and
    // a type that isn't one, or `--all` with `--workroom`, is bad input.
    let refused = |args: &[&str]| {
        let run = workroom(Some(&socket), args);
        (run.code, run.envelope()["error"]["kind"].clone())
    };
    assert_eq!(
        refused(&["events", "--session", "nobody", "--json"]),
        (3, json!("TargetNotFound"))
    );
    assert_eq!(
        refused(&["events", "--type", "session.renamed", "--json"]),
        (2, json!("InvalidRequest"))
    );
    assert_eq!(
        refused(&["events", "--all", "--workroom", "wr-1", "--json"]),
        (1, json!("InternalError"))
    );
}

/// What a [`raw_reader`] reads: the modes its program turns on (`setup`, a `printf` format) and
/// off after (`teardown`), how many bytes it reads, and what it hands them to (`od` for hex, say),
/// whose output goes to `name`.
struct Reading<'a> {
    name: &'a str,
    setup: &'a str,
    teardown: &'a str,
    count: usize,
    keep: &'a str,
}

/// Has the program in `pane` (session `id`) turn on its modes, put its terminal in raw mode and
/// read what `reading` says, its output in a file under `dir`; once it is reading, with its modes
/// in the daemon's shadow terminal, which a wait for what it prints after them says.
fn raw_reader(
    socket: &Path,
    pane: &mut Spawned,
    id: &str,
    dir: &Path,
    reading: Reading,
) -> std::path::PathBuf {
    let Reading {
        name,
        setup,
        teardown,
        count,
        keep,
    } = reading;
    let path = dir.join(name);
    let partial = dir.join(format!("{name}.partial"));
    let raw = dir.join(format!("{name}.raw"));
    // Split in the typed line, so the line's echo is not the mark.
    type_line(
        pane,
        &format!(
            "stty raw -echo; printf '{setup}READ''Y-{name}'; touch '{}'; head -c {count} | {keep} > \
             '{}'; mv '{}' '{}'; printf '{teardown}'; stty sane",
            raw.display(),
            partial.display(),
            partial.display(),
            path.display()
        ),
    );
    assert!(
        wait_for(Duration::from_secs(20), || raw.exists()),
        "{name}: the reader never started"
    );
    if has_terminal_state() {
        // The mark came after the modes, so once the shadow has it, it has them.
        let mark = format!("READY-{name}");
        let (code, ready) = wait(
            socket,
            &[id, "--regex", &mark, "--include-screen", "--timeout", "20s"],
        );
        assert_eq!(code, 0, "{name}: no mark: {ready}");
    }
    path
}

/// The bytes a [`raw_reader`] kept, once it has all it was waiting for.
fn read_raw(path: &Path) -> Vec<u8> {
    assert!(
        wait_for(Duration::from_secs(20), || path.exists()),
        "the reader never had all its bytes"
    );
    std::fs::read_to_string(path)
        .expect("read the hex")
        .split_whitespace()
        .map(|byte| u8::from_str_radix(byte, 16).expect("a hex byte"))
        .collect()
}

/// `workroom send <args> --json` run in `shell`, through a `sh` of its own as a coding agent
/// runs it: its exit code and envelope.
fn send_from(shell: &mut Spawned, dir: &Path, name: &str, args: &str) -> (i32, Value) {
    let output = shell_output(
        shell,
        dir,
        name,
        &format!(
            "/bin/sh -c \"'{}' send {args} --json; echo exit=\\$?\"",
            common::daemon_binary().display()
        ),
    );
    let (envelope, code) = output
        .rsplit_once("exit=")
        .unwrap_or_else(|| panic!("no exit status in {output:?}"));
    let envelope = serde_json::from_str(envelope.trim())
        .unwrap_or_else(|e| panic!("not one envelope ({e}): {output:?}"));
    (code.trim().parse().expect("an exit code"), envelope)
}

/// `workroom send` from one pane into another: the text as given, as a bracketed paste once the
/// program has turned that on, then each key encoded for the program's modes (the legacy
/// encoding, application cursor keys, the kitty keyboard protocol), then Enter. The reply says
/// which modes it typed for, and each send is a `session.input` event naming the pane it came
/// from. Typing into the caller's own pane is `RefusedSelf` (3) without `--allow-self`. A daemon
/// built without terminal-state can't read the modes: text goes as it is, never as a paste, and
/// keys are refused.
#[test]
fn send_types_text_and_keys_for_the_programs_modes_and_names_its_sender() {
    let workspace = Workspace::new("api-send");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut sender = open(&socket, SHELL, "sender", "wr-1", &workspace.dir);
    let mut target = open(&socket, OTHER, "target", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    let mut events = Events::start(&socket, &["--all", "--type", "session.input"]);
    events.until("the snapshot's end", |e| e["event"] == "snapshot-complete");

    let keys = "'echo hi' --key Up --key Ctrl+C --key Escape --enter";
    let paste = |text: &[u8]| [b"\x1b[200~".as_slice(), text, b"\x1b[201~"].concat();
    /// One send: the modes its program turns on and off, its arguments, what reaches the program
    /// and the `modes` its reply says.
    struct Case {
        name: &'static str,
        setup: &'static str,
        teardown: &'static str,
        args: &'static str,
        expected: Vec<u8>,
        said: Value,
    }
    let mut cases = Vec::new();
    if has_terminal_state() {
        let modes = |kitty: u32, cursor: bool, paste: bool| {
            json!({
                "kitty_keyboard_flags": kitty,
                "application_cursor_keys": cursor,
                "bracketed_paste": paste,
            })
        };
        cases.push(Case {
            name: "legacy",
            setup: "",
            teardown: "",
            args: keys,
            expected: b"echo hi\x1b[A\x03\x1b\r".to_vec(),
            said: modes(0, false, false),
        });
        cases.push(Case {
            name: "pasted-decckm",
            setup: "\\033[?2004h\\033[?1h",
            teardown: "\\033[?1l\\033[?2004l",
            args: keys,
            expected: [paste(b"echo hi"), b"\x1bOA\x03\x1b\r".to_vec()].concat(),
            said: modes(0, true, true),
        });
        // Ghostty consults DECCKM only for the legacy encoding.
        cases.push(Case {
            name: "kitty",
            setup: "\\033[?2004h\\033[?1h\\033[>1u",
            teardown: "\\033[<u\\033[?1l\\033[?2004l",
            args: keys,
            expected: [paste(b"echo hi"), b"\x1b[A\x1b[99;5u\x1b[27u\r".to_vec()].concat(),
            said: modes(1, true, true),
        });
    } else {
        // The program turned bracketed paste on, but the daemon can't know.
        cases.push(Case {
            name: "no-modes",
            setup: "\\033[?2004h",
            teardown: "\\033[?2004l",
            args: "'echo hi'",
            expected: b"echo hi".to_vec(),
            said: Value::Null,
        });
    }
    for Case {
        name,
        setup,
        teardown,
        args,
        expected,
        said,
    } in cases
    {
        let kept = raw_reader(
            &socket,
            &mut target,
            OTHER,
            &workspace.dir,
            Reading {
                name: &format!("{name}-typed"),
                setup,
                teardown,
                count: expected.len(),
                keep: "od -An -v -tx1",
            },
        );
        let (code, envelope) = send_from(
            &mut sender,
            &workspace.dir,
            name,
            &format!("{OTHER} {args}"),
        );
        assert_eq!(code, 0, "{name}: {envelope}");
        assert_eq!(envelope["command"], "send", "{envelope}");
        assert_eq!(envelope["session"], OTHER, "{envelope}");
        assert_eq!(envelope["caller"], SHELL, "{envelope}");
        assert_eq!(envelope["bytes"], expected.len(), "{envelope}");
        assert_eq!(envelope["modes"], said, "{name}: {envelope}");
        assert_eq!(
            String::from_utf8_lossy(&read_raw(&kept)),
            String::from_utf8_lossy(&expected),
            "{name}"
        );
        let told = events.until("the send's event", |e| e["event"] == "session.input");
        assert_eq!(told["session"], OTHER, "{told}");
        assert_eq!(told["sender"], SHELL, "{told}");
        assert_eq!(told["bytes"], expected.len(), "{told}");
        assert_eq!(told["scope"], json!({"kind": "workroom", "id": "wr-1"}));
    }
    if !has_terminal_state() {
        let (code, envelope) = send_from(
            &mut sender,
            &workspace.dir,
            "keys",
            &format!("{OTHER} --key Up"),
        );
        assert_eq!(code, 1, "{envelope}");
        assert_eq!(envelope["error"]["kind"], "InternalError", "{envelope}");
    }

    // Its own pane, by its variable: refused, and with `--allow-self` typed (a space before the
    // next command line, which changes nothing).
    let (code, envelope) = send_from(&mut sender, &workspace.dir, "self", "\\$WORKROOM_PANE x");
    assert_eq!(code, 3, "{envelope}");
    assert_eq!(envelope["error"]["kind"], "RefusedSelf", "{envelope}");
    let (code, envelope) = send_from(
        &mut sender,
        &workspace.dir,
        "allowed",
        "\\$WORKROOM_PANE ' ' --allow-self",
    );
    assert_eq!(code, 0, "{envelope}");
    assert_eq!(envelope["session"], SHELL, "{envelope}");
    let told = events.until("the send to itself", |e| e["event"] == "session.input");
    assert_eq!(
        (&told["session"], &told["sender"]),
        (&json!(SHELL), &json!(SHELL))
    );

    // From no pane, the sender is none.
    let outside = workroom(Some(&socket), &["send", OTHER, ":\n", "--json"]);
    assert_eq!(outside.code, 0, "{}", outside.stdout);
    assert_eq!(outside.envelope()["caller"], Value::Null);
    let told = events.until("the send from no pane", |e| e["event"] == "session.input");
    assert_eq!(told["sender"], Value::Null, "{told}");
    assert_eq!(
        events.count("session.input"),
        if has_terminal_state() { 5 } else { 3 },
        "a refused send is not told: {:#?}",
        events.seen
    );
}

/// A send is no client (ADR 0042): a session nobody is attached to stays detached at the size its
/// last client left, and the connection that sent it is sent its reply and nothing else, no
/// repaint and no keepalive probe.
#[test]
fn a_send_attaches_nothing_takes_no_size_and_gets_no_probes() {
    let workspace = Workspace::new("api-send-detached");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut target = open(&socket, OTHER, "target", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let before = shell_output(&mut target, &workspace.dir, "before", "stty size");
    drop(target);
    assert!(
        wait_for(Duration::from_secs(20), || {
            common::list_sessions(&socket).contains("detached")
        }),
        "the session never detached: {}",
        common::list_sessions(&socket)
    );

    let after = workspace.dir.join("after");
    let mut api = Api::connect(&socket);
    let sent = api.call(
        "terminal.send",
        json!({"target": OTHER, "text": format!("stty size > '{}'\n", after.display())}),
    );
    assert!(sent.get("error").is_none(), "{sent}");
    // Nothing more, on any service: no repaint, no probe, no output of the session's.
    assert_eq!(api.0.next(Duration::from_secs(2)).map(|e| e.service), None);
    assert!(api.0.seen.is_empty() && api.0.failures.is_empty());
    assert!(
        wait_for(Duration::from_secs(20), || std::fs::read_to_string(&after)
            .is_ok_and(|size| size.ends_with('\n'))),
        "the shell never ran what was sent"
    );
    assert_eq!(std::fs::read_to_string(&after).unwrap(), before);
    let listed = common::list_sessions(&socket);
    assert!(
        listed.contains("detached") && !listed.contains(" attached"),
        "{listed}"
    );
}

/// A send to a program reading slowly types for as long as it reads, up to the send's own
/// deadline, past the CLI's usual 10 s wait for an answer: the CLI waits it out rather than call
/// the daemon gone. A hand-off meanwhile waits for it, and is refused when it can't, rather than
/// cut it off: every byte arrives.
#[test]
fn a_send_to_a_slow_reader_outlasts_ten_seconds_and_a_hand_off() {
    const KIB: usize = 1024;
    const CHUNKS: usize = 150;
    let workspace = Workspace::new("api-send-slow");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut target = open(&socket, OTHER, "target", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    // At most 1 KiB each tenth of a second, one read each, so 15 s and more for all of it. The
    // count is written beside its file and renamed into it, so it appears whole: a shell's `>`
    // makes the file before `wc` has written anything, and a test that saw it then read "".
    let (ready, kept, counted) = (
        workspace.dir.join("slow-ready"),
        workspace.dir.join("slow-kept"),
        workspace.dir.join("slow"),
    );
    type_line(
        &mut target,
        &format!(
            "stty raw -echo; touch '{ready}'; : > '{kept}'; while [ $(wc -c < '{kept}') -lt {} \
             ]; do dd bs={KIB} count=1 2>/dev/null >> '{kept}'; sleep 0.1; done; wc -c < \
             '{kept}' > '{counted}.partial'; mv '{counted}.partial' '{counted}'; stty sane",
            CHUNKS * KIB,
            ready = ready.display(),
            kept = kept.display(),
            counted = counted.display(),
        ),
    );
    assert!(
        wait_for(Duration::from_secs(20), || ready.exists()),
        "the reader never started"
    );
    let started = std::time::Instant::now();
    let mut send = Command::new(common::daemon_binary())
        .args(["send", OTHER, "--stdin", "--json"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
        .env("WORKROOM_DAEMON", &socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run workroom send");
    send.stdin
        .take()
        .expect("stdin")
        .write_all("x".repeat(CHUNKS * KIB).as_bytes())
        .expect("write stdin");

    std::thread::sleep(Duration::from_secs(3));
    let next = workspace.dir.join("next-workroom");
    common::copy_daemon_binary(&next);
    let refused = Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(&socket)
        .arg("--binary")
        .arg(&next)
        .arg("--force")
        .output()
        .expect("hand-off");
    let said = String::from_utf8_lossy(&refused.stdout).into_owned()
        + &String::from_utf8_lossy(&refused.stderr);
    let at = started.elapsed();
    let sent = finished(send);
    assert!(
        !said.contains("handed off") && said.contains("a send typing into a session"),
        "the hand-off went ahead mid-send, {at:?} in: {said}; the send: {} {} in {:?}",
        sent.stdout,
        sent.stderr,
        started.elapsed()
    );

    assert_eq!(sent.code, 0, "{} {}", sent.stdout, sent.stderr);
    assert!(
        started.elapsed() > Duration::from_secs(10),
        "the send was answered in {:?}, before the CLI's usual wait was up",
        started.elapsed()
    );
    assert_eq!(sent.envelope()["bytes"], CHUNKS * KIB);
    assert!(
        wait_for(Duration::from_secs(20), || counted.exists()),
        "the program never had all of it"
    );
    assert_eq!(
        std::fs::read_to_string(&counted).unwrap().trim(),
        (CHUNKS * KIB).to_string()
    );
}

/// One send types at most 1 MiB, whole: from stdin, exactly that much reaches the program, in
/// chunked requests the CLI makes of it; a byte more is `TooLarge` (2) before any daemon is looked
/// for, and so is that much with a key after it, which the daemon refuses.
#[test]
fn a_send_types_one_mib_whole_and_refuses_more() {
    const MIB: usize = 1024 * 1024;
    let workspace = Workspace::new("api-send-large");
    let socket = workspace.socket();
    let nowhere = workspace.dir.join("nobody.sock");
    let over = workroom_with_stdin(
        Some(&nowhere),
        &["send", OTHER, "--stdin", "--json"],
        Some(&"x".repeat(MIB + 1)),
    );
    assert_eq!(over.code, 2, "{}", over.stdout);
    assert_eq!(over.envelope()["error"]["kind"], "TooLarge");
    assert_eq!(over.envelope()["command"], "send");

    let _daemon = start_daemon(&socket);
    let mut target = open(&socket, OTHER, "target", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let counted = raw_reader(
        &socket,
        &mut target,
        OTHER,
        &workspace.dir,
        Reading {
            name: "counted",
            setup: "",
            teardown: "",
            count: MIB,
            keep: "wc -c",
        },
    );
    let whole = workroom_with_stdin(
        Some(&socket),
        &["send", OTHER, "--stdin", "--json"],
        Some(&"x".repeat(MIB)),
    );
    assert_eq!(whole.code, 0, "{} {}", whole.stdout, whole.stderr);
    assert_eq!(whole.envelope()["bytes"], MIB);
    assert!(
        wait_for(Duration::from_secs(20), || counted.exists()),
        "the program never had all of it"
    );
    assert_eq!(
        std::fs::read_to_string(&counted).unwrap().trim(),
        MIB.to_string()
    );

    if has_terminal_state() {
        let past = workroom_with_stdin(
            Some(&socket),
            &["send", OTHER, "--stdin", "--enter", "--json"],
            Some(&"x".repeat(MIB)),
        );
        assert_eq!(past.code, 2, "{}", past.stdout);
        assert_eq!(past.envelope()["error"]["kind"], "TooLarge");
    }
}

/// A shell with OSC 133 integration, for `/bin/sh`, which has none and no preexec to send a C: a
/// loop that reads a line and runs it, as a shell does, sending A before its prompt (`IS> `), B
/// after it, C before it runs the line and D with its exit code after. A line typed as a bracketed
/// paste has the paste's markers taken off, and runs with `P=1`. Its prompt is split in the line
/// typed, so the echo is not the prompt.
const INTEGRATED_SHELL: &str = r#"e=$(printf '\033'); while printf '%s]133;A\007I''S> %s]133;B\007' "$e" "$e"; IFS= read -r l; do P=; case $l in "$e[200~"*) P=1; l=${l#"$e[200~"}; l=${l%"$e[201~"};; esac; printf '%s]133;C\007' "$e"; eval "$l"; printf '%s]133;D;%d\007' "$e" "$?"; done"#;

/// `workroom command <args> --json`'s exit code and envelope.
fn command(socket: &Path, args: &[&str]) -> (i32, Value) {
    let args: Vec<&str> = [&["command", "--json"][..], args].concat();
    let run = workroom(Some(socket), &args);
    (run.code, run.envelope())
}

/// A command's envelope, which ran: `command`'s, with the API's result fields, which match the
/// schema the daemon publishes.
fn ran(socket: &Path, outcome: (i32, Value)) -> Value {
    let (code, envelope) = outcome;
    assert_eq!(
        code,
        i32::try_from(envelope["exit_code"].as_i64().expect("an exit code")).unwrap(),
        "it exits with the command's own code: {envelope}"
    );
    ran_unknown(socket, (code, envelope))
}

/// [`ran`] for a command whose exit code may be unknown, which `workroom command` exits 1 for.
fn ran_unknown(socket: &Path, outcome: (i32, Value)) -> Value {
    let (code, envelope) = outcome;
    assert_eq!(envelope["ok"], true, "{envelope}");
    assert_eq!(envelope["command"], "command", "{envelope}");
    if envelope["exit_code"].is_null() {
        assert_eq!(code, 1, "an unknown exit code exits 1: {envelope}");
    }
    let described =
        Api::connect(socket).call("api.describe", json!({"method": "terminal.command"}));
    let schema = &described["result"]["methods"][0]["output"];
    assert_eq!(violation(schema, &envelope, "result"), None, "{envelope}");
    envelope
}

/// `command <args>` once the session can take it: asked again while it is `Busy` or has a
/// full-screen program up, for a pane the test has just told to finish what it was doing, for up
/// to 20 s. Its envelope, which ran.
fn command_when_ready(socket: &Path, args: &[&str]) -> Value {
    let mut last = None;
    let ready = wait_for(Duration::from_secs(20), || {
        let outcome = command(socket, args);
        let refused = ["Busy", "AlternateScreen"]
            .contains(&outcome.1["error"]["kind"].as_str().unwrap_or_default());
        last = Some(outcome);
        !refused
    });
    let outcome = last.expect("a run");
    assert!(ready, "the session never took the command: {}", outcome.1);
    ran(socket, outcome)
}

/// `workroom command TARGET -- COMMAND` runs the command in a session's shell and exits with its
/// code. Its output is what the command printed between its shell's marks, rendered as a capture
/// reads a screen: not the command line the shell echoed, nor the prompt after it. A new session
/// gets the marks' grace for its shell's first prompt before anything is typed. The command goes
/// as a bracketed paste once the shell has turned that on, with Enter after it. A shell already
/// running a command is `Busy`, the caller's own session `RefusedSelf`, a line end
/// `InvalidRequest`, and a command that outlasts `--timeout` `WaitTimeout` (8), left running.
#[test]
fn command_runs_in_a_shell_and_gives_its_code_and_the_output_between_its_marks() {
    let workspace = Workspace::new("api-command");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    if !has_terminal_state() {
        listing_until(&socket, |listing| listing.len() == 1);
        assert_eq!(
            failed(command(&socket, &["server", "--", "true"])),
            (2, "InvalidRequest".into()),
            "a command's end needs the shadow terminal"
        );
        return;
    }
    // Its first prompt a second from now: the command waits for it, within the new session's
    // grace, and only then types.
    type_line(&mut shell, &format!("sleep 1; {INTEGRATED_SHELL}"));
    listing_until(&socket, |listing| listing.len() == 1);
    let passed = ran(
        &socket,
        command(&socket, &["server", "--", r"printf 'one\ntwo\n'"]),
    );
    assert_eq!(passed["session"], SHELL, "{passed}");
    assert_eq!(passed["caller"], Value::Null, "{passed}");
    assert_eq!(passed["exit_code"], 0, "{passed}");
    assert_eq!(passed["output"], "one\ntwo", "{passed}");
    assert_eq!(passed["truncated"], false, "{passed}");
    assert!(
        output
            .read_until("two\r\n", Duration::from_secs(20))
            .contains("printf 'one\\ntwo\\n'"),
        "the command was typed at the prompt"
    );

    let failing = ran(
        &socket,
        command(
            &socket,
            &["server", "--", "sh", "-c", "'echo bad >&2; exit 3'"],
        ),
    );
    assert_eq!(
        (failing["exit_code"].clone(), failing["output"].clone()),
        (json!(3), json!("bad")),
        "{failing}"
    );
    let silent = ran(&socket, command(&socket, &["server", "--", "true"]));
    assert_eq!(silent["output"], "", "{silent}");
    let redrawn = ran(
        &socket,
        command(
            &socket,
            &["server", "--", r"printf '\033[1m10%%\033[0m\r100%%\n'"],
        ),
    );
    assert_eq!(redrawn["output"], "100%", "{redrawn}");
    let human = workroom(
        Some(&socket),
        &["command", "server", "printf", "%s-%s", "a", "b"],
    );
    assert_eq!(
        (human.code, human.stdout.as_str(), human.stderr.as_str()),
        (0, "a-b\n", "")
    );
    let human = workroom(
        Some(&socket),
        &[
            "command",
            "server",
            "--",
            "exit_code() { return 4; }; exit_code",
        ],
    );
    assert_eq!((human.code, human.stdout.as_str()), (4, ""));

    // A shell that has turned bracketed paste on is pasted the command, Enter after the paste.
    ran(
        &socket,
        command(&socket, &["server", "--", r"printf '\033[?2004h'"]),
    );
    let pasted = ran(
        &socket,
        command(&socket, &["server", "--", r#"echo "pasted=$P""#]),
    );
    assert_eq!(pasted["output"], "pasted=1", "{pasted}");

    // A command typed into the pane, running until `go` exists, owns the next command's end.
    let go = workspace.dir.join("go");
    type_line(
        &mut shell,
        &format!(
            r#"echo "SLEEP""ING"; while [ ! -e '{}' ]; do sleep 0.05; done"#,
            go.display()
        ),
    );
    assert!(
        output
            .read_until("SLEEPING\r\n", Duration::from_secs(20))
            .contains("SLEEPING\r\n"),
        "fixture: the pane's command never started"
    );
    assert_eq!(
        failed(command(&socket, &["server", "--", "true"])),
        (3, "Busy".into()),
        "the pane's command runs until `go` exists"
    );
    std::fs::write(&go, b"").expect("go");
    let after = command_when_ready(&socket, &["server", "--", "echo after"]);
    assert_eq!(after["output"], "after", "{after}");

    // Text typed at the prompt and not run: a command would be joined to it.
    shell
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(b": half")
        .expect("type");
    shell.stdin.as_mut().expect("stdin").flush().expect("flush");
    assert!(
        output
            .read_until(": half", Duration::from_secs(20))
            .contains(": half"),
        "fixture: the half-typed line never echoed"
    );
    assert_eq!(
        failed(command(&socket, &["server", "--", "echo NEVER-TYPED"])),
        (3, "Busy".into()),
        "a prompt holding `: half`"
    );
    type_line(&mut shell, "");
    let joined = command_when_ready(&socket, &["server", "--", "echo cleared"]);
    assert_eq!(joined["output"], "cleared", "{joined}");

    // A full-screen program the command puts up answers at once, the program left running; once
    // it is gone, the shell takes commands again.
    assert_eq!(
        failed(command(
            &socket,
            &[
                "server",
                "--",
                r"printf '\033[?1049hFULL'; read x; printf '\033[?1049l'"
            ]
        )),
        (3, "AlternateScreen".into())
    );
    type_line(&mut shell, "");
    let back = command_when_ready(&socket, &["server", "--", "echo back"]);
    assert_eq!(back["output"], "back", "{back}");

    // As printed, with `--vt`.
    let raw = ran(
        &socket,
        command(
            &socket,
            &["server", "--vt", "--", r"printf '\033[1mbold\033[0m\n'"],
        ),
    );
    assert_eq!(raw["output"], "\x1b[1mbold\x1b[0m\r\n", "{raw}");
    // And printed so, byte for byte, no line's end added: the pty's own `\r\n`.
    let human = workroom(
        Some(&socket),
        &["command", "server", "--vt", "--", "echo hello"],
    );
    assert_eq!((human.code, human.stdout.as_str()), (0, "hello\r\n"));

    // The caller's own session, and a command that is not one line.
    let own = Api::connect(&socket).request(&json!({
        "method": "terminal.command",
        "params": {"target": SHELL, "command": "true"},
        "caller": SHELL,
    }));
    assert_eq!(own["error"]["kind"], "RefusedSelf", "{own}");
    assert_eq!(
        failed(command(&socket, &["server", "--", "true\nfalse"])),
        (2, "InvalidRequest".into())
    );

    // A command refused on its thread holds nothing of its connection's: past the 64 waits one
    // connection holds, it runs.
    let mut api = Api::connect(&socket);
    for _ in 0..70 {
        let refused = api.call(
            "terminal.command",
            json!({"target": SHELL, "command": "echo NEVER-TYPED", "timeout_ms": 0}),
        );
        assert_eq!(refused["error"]["kind"], "WaitTimeout", "{refused}");
    }
    let same = api.call(
        "terminal.command",
        json!({"target": SHELL, "command": "echo same", "timeout_ms": 30_000}),
    );
    assert_eq!(same["result"]["output"], "same", "{same}");

    // Out of time before it is typed: nothing is.
    assert_eq!(
        failed(command(
            &socket,
            &["server", "--timeout", "0s", "--", "echo NEVER-TYPED"]
        )),
        (8, "WaitTimeout".into())
    );
    // A shell that replaced the one that ran the command shows its prompt with no D: the command
    // has ended, its code unknown, and the new shell takes the next.
    let script = workspace.dir.join("integrated.sh");
    std::fs::write(&script, INTEGRATED_SHELL).expect("the integrated shell's script");
    let replaced = ran_unknown(
        &socket,
        command(
            &socket,
            &["server", "--", &format!("exec sh '{}'", script.display())],
        ),
    );
    assert_eq!(replaced["exit_code"], Value::Null, "{replaced}");
    let next = ran(&socket, command(&socket, &["server", "--", "echo next"]));
    assert_eq!(next["output"], "next", "{next}");

    // Out of time, its command left running: one that waits until `stop` exists, which nothing
    // makes, so it is still running once the 3 s timeout has passed, and the shell is busy.
    let stop = workspace.dir.join("stop");
    assert_eq!(
        failed(command(
            &socket,
            &[
                "server",
                "--timeout",
                "3s",
                "--",
                &format!("while [ ! -e '{}' ]; do sleep 0.05; done", stop.display()),
            ]
        )),
        (8, "WaitTimeout".into())
    );
    assert_eq!(
        failed(command(&socket, &["server", "--", "true"])),
        (3, "Busy".into()),
        "the timed-out command runs until `stop` exists"
    );
    let screen = capture(&socket, &["server", "--json"]);
    assert!(
        !screen.envelope()["text"]
            .as_str()
            .unwrap()
            .contains("NEVER-TYPED"),
        "{}",
        screen.stdout
    );
}

/// The first of `paths` that is a shell this machine has, and that the daemon gives Ghostty's
/// integration to (not macOS's `/bin/bash`, a 3.2 that ignores `ENV`), or why there is none.
fn installed_shell(name: &str, paths: &[&str]) -> Result<String, String> {
    paths
        .iter()
        .filter(|path| !(cfg!(target_os = "macos") && **path == "/bin/bash"))
        .find(|path| Path::new(path).exists())
        .map(|path| (*path).to_string())
        .ok_or_else(|| format!("no {name} with Ghostty's integration here (looked in {paths:?})"))
}

/// A session running the real shell `path` with Workroom's bundled Ghostty integration, as the app
/// starts one: `WORKROOM_SESSION_RESOURCES` names the integration, which the daemon wires into the
/// shell's environment. Its home is a folder of this test's own, whose startup files give it the
/// prompt `PROMPT> ` and load the integration again in a shell `exec` starts, so no startup file of
/// the developer's is read. Returns once the prompt is up.
fn real_shell(socket: &Path, id: &str, path: &str, dir: &Path) -> (Spawned, common::ClientReader) {
    let home = dir.join(format!("home-{}", super_name(path)));
    std::fs::create_dir(&home).expect("a home of this test's own");
    let config = home.join(".config");
    std::fs::create_dir_all(config.join("fish")).expect("fish's config folder");
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty");
    let integration = resources.join("shell-integration");
    // The first shell has its integration from the daemon; one `exec` starts loads it here.
    let files = [
        // Debian's and Ubuntu's /etc/zsh/zshrc run compinit unless told not to, which stops at a
        // question when a directory on `fpath` is writable by others, as /usr/local's are on
        // GitHub's runners: the prompt never comes.
        (home.join(".zshenv"), "skip_global_compinit=1\n".to_string()),
        (
            home.join(".zshrc"),
            format!(
                "PS1='PROMPT> '\nRPROMPT='RIGHT'\nbindkey -e\nif [[ -n $WR_TEST_EXECED ]]; then autoload -Uz -- '{0}/zsh/ghostty-integration' && ghostty-integration; fi\nexport WR_TEST_EXECED=1\n",
                integration.display()
            ),
        ),
        (home.join(".bash_profile"), ". ~/.bashrc\n".to_string()),
        (
            home.join(".bashrc"),
            format!(
                "PS1='PROMPT> '\nif [ -n \"$WR_TEST_EXECED\" ]; then . '{0}/bash/ghostty.bash'; fi\nexport WR_TEST_EXECED=1\n",
                integration.display()
            ),
        ),
        (
            config.join("fish/config.fish"),
            format!(
                "function fish_prompt; echo -n 'PROMPT> '; end\nfunction fish_greeting; end\nif set -q WR_TEST_EXECED; source '{0}/fish/vendor_conf.d/ghostty-shell-integration.fish'; end\nset -gx WR_TEST_EXECED 1\n",
                integration.display()
            ),
        ),
    ];
    for (file, text) in files {
        std::fs::write(file, text).expect("a startup file");
    }
    let mut shell = attach_with_env(
        socket,
        id,
        &[],
        &[
            ("SHELL", path),
            ("WORKROOM_SESSION_RESOURCES", resources.to_str().unwrap()),
            ("WORKROOM_SESSION_TITLE", "real"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            ("HOME", home.to_str().unwrap()),
            ("ZDOTDIR", home.to_str().unwrap()),
            ("XDG_CONFIG_HOME", config.to_str().unwrap()),
            ("XDG_DATA_HOME", home.to_str().unwrap()),
            ("TERM", "xterm-256color"),
            ("TERM_PROGRAM", ""),
            ("ENV", ""),
            ("BASH_ENV", ""),
            ("PROMPT_COMMAND", ""),
        ],
    );
    let mut output = common::ClientReader::new(&mut shell);
    let seen = output.read_until("PROMPT> ", Duration::from_secs(30));
    assert!(
        seen.contains("PROMPT> "),
        "{path} never prompted; it showed {seen:?}"
    );
    (shell, output)
}

/// A shell path's last part.
fn super_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// `workroom command` in real bash, zsh and fish (each where this machine has it) with Workroom's
/// bundled Ghostty integration: a passing and a failing command's codes, two commands in one line,
/// output with no final newline (zsh's PROMPT_SP mark left out), and `exec` of the shell, which
/// shows its prompt with no D, answered with no exit code, the new shell taking the next command.
/// In zsh, half-typed text at the prompt and an open quote's PS2 are `Busy`, nothing typed.
#[test]
fn command_runs_in_real_shells_with_the_bundled_integration() {
    if !has_terminal_state() {
        eprintln!("skipped: a command's end needs a daemon built with terminal-state");
        return;
    }
    let shells = [
        (
            "bash",
            &[
                "/opt/homebrew/bin/bash",
                "/usr/local/bin/bash",
                "/bin/bash",
                "/usr/bin/bash",
            ][..],
        ),
        (
            "zsh",
            &["/opt/homebrew/bin/zsh", "/bin/zsh", "/usr/bin/zsh"][..],
        ),
        (
            "fish",
            &[
                "/opt/homebrew/bin/fish",
                "/usr/local/bin/fish",
                "/usr/bin/fish",
            ][..],
        ),
    ];
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty");
    if !resources.join("shell-integration").is_dir() {
        eprintln!(
            "skipped: no bundled shell integration at {} (a test run with only vcs/)",
            resources.display()
        );
        return;
    }
    let workspace = Workspace::new("api-command-real");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    for (name, paths) in shells {
        let path = match installed_shell(name, paths) {
            Ok(path) => path,
            Err(why) => {
                eprintln!("skipped {name}: {why}");
                continue;
            }
        };
        let id = match name {
            "bash" => "b0b0b0b0-0000-4000-8000-000000000691",
            "zsh" => "a0a0a0a0-0000-4000-8000-000000000691",
            _ => "f0f0f0f0-0000-4000-8000-000000000691",
        };
        let (mut shell, mut output) = real_shell(&socket, id, &path, &workspace.dir);
        // Out of time is a fixture that never ended a command: its screen says why.
        let run = |args: &[&str]| {
            let args: Vec<&str> = [&[id, "--timeout", "30s", "--"][..], args].concat();
            let outcome = command(&socket, &args);
            if outcome.1["error"]["kind"] == "WaitTimeout" {
                let screen = capture(&socket, &[id, "--vt", "--json"]);
                panic!("{name} {args:?}: no end: {:?}", screen.envelope()["text"]);
            }
            outcome
        };
        let passed = ran(&socket, run(&["echo one; echo two"]));
        assert_eq!(
            (passed["exit_code"].clone(), passed["output"].clone()),
            (json!(0), json!("one\ntwo")),
            "{name}: {passed}"
        );
        let failing = ran(&socket, run(&["sh -c 'echo bad; exit 3'"]));
        assert_eq!(
            (failing["exit_code"].clone(), failing["output"].clone()),
            (json!(3), json!("bad")),
            "{name}: {failing}"
        );
        let unended = ran(&socket, run(&["printf foo"]));
        assert_eq!(unended["output"], "foo", "{name}: {unended}");

        if name == "zsh" {
            // Every command here ran beside a right prompt, which is no text at the prompt.
            capture_awaiting(&socket, &[id, "--json"], "zsh's RPROMPT", |run| {
                run.envelope()["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("RIGHT"))
            });
            let stdin = shell.stdin.as_mut().expect("stdin");
            stdin.write_all(b": half").expect("type");
            stdin.flush().expect("flush");
            assert!(
                output
                    .read_until(": half", Duration::from_secs(20))
                    .contains(": half"),
                "fixture: zsh never echoed the half-typed line"
            );
            assert_eq!(
                failed(run(&["echo NEVER-TYPED"])),
                (3, "Busy".into()),
                "a prompt holding `: half`"
            );
            // Ctrl+A: the cursor at the line's start, the text all after it.
            let stdin = shell.stdin.as_mut().expect("stdin");
            stdin.write_all(b"\x01").expect("type");
            stdin.flush().expect("flush");
            capture_awaiting(
                &socket,
                &[id, "--json"],
                "the cursor at the line's start",
                |run| run.envelope()["cursor"]["column"] == "PROMPT> ".len(),
            );
            assert_eq!(
                failed(run(&["echo NEVER-TYPED"])),
                (3, "Busy".into()),
                "`: half` after the cursor"
            );
            // Run, it leaves the prompt empty; an open quote then goes on at PS2.
            type_line(&mut shell, "");
            let _ = command_when_ready(&socket, &[id, "--", "true"]);
            type_line(&mut shell, "echo \"open");
            assert!(
                output
                    .read_until("dquote> ", Duration::from_secs(20))
                    .contains("dquote> "),
                "fixture: zsh never showed PS2"
            );
            assert_eq!(
                failed(run(&["echo NEVER-TYPED"])),
                (3, "Busy".into()),
                "an open quote's PS2"
            );
            // Closed, the line runs and the prompt is empty again.
            type_line(&mut shell, "\"");
            let _ = command_when_ready(&socket, &[id, "--", "true"]);
        }

        let replaced = ran_unknown(&socket, run(&[&format!("exec {path}")]));
        assert!(
            replaced["exit_code"].is_null() || replaced["exit_code"] == 0,
            "{name}: {replaced}"
        );
        let next = command_when_ready(&socket, &[id, "--", "echo next"]);
        assert_eq!(next["output"], "next", "{name}: {next}");
        let screen = capture(&socket, &[id, "--json"]);
        assert!(
            !screen.envelope()["text"]
                .as_str()
                .unwrap()
                .contains("NEVER-TYPED"),
            "{name}: {}",
            screen.stdout
        );
        drop(output);
        drop(shell);
    }
}

/// A session whose shell sends no OSC 133 marks is `NoShellIntegration` (3), the command never
/// typed: a new one once the marks' grace is over, an older one at once.
#[test]
fn command_without_shell_integration_is_refused_with_nothing_typed() {
    if !has_terminal_state() {
        eprintln!("skipped: a command's end needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-command-none");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    for _ in 0..2 {
        assert_eq!(
            failed(command(
                &socket,
                &["server", "--timeout", "60s", "--", "echo NEVER-TYPED"]
            )),
            (3, "NoShellIntegration".into())
        );
    }
    let screen = capture(&socket, &["server", "--json"]);
    assert!(
        !screen.envelope()["text"]
            .as_str()
            .unwrap()
            .contains("NEVER-TYPED"),
        "{}",
        screen.stdout
    );
}

/// A hand-off while a command runs closes `workroom command`'s connection: it is
/// `WaitInterrupted` (3), as a wait for a command's end is, and is never typed again. The next
/// program saw no C for the command still running, and no prompt since, so it asks whether a
/// program has the shell's terminal: one has, so a command now is `Busy`.
#[test]
fn a_command_across_a_hand_off_is_interrupted_and_not_run_again() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-command-handoff");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut shell);
    type_line(&mut shell, INTEGRATED_SHELL);
    assert!(
        output
            .read_until("IS> ", Duration::from_secs(20))
            .contains("IS> "),
        "fixture: the integrated shell never prompted"
    );
    // Running until `go` exists, in one process the whole time, so a program other than the
    // shell has its terminal throughout.
    let go = workspace.dir.join("go");
    let running = started(
        &socket,
        &[
            "command",
            "server",
            "--json",
            "--timeout",
            "60s",
            "--",
            &format!(
                r#"echo "RUN""NING"; sh -c 'while [ ! -e "{}" ]; do sleep 0.05; done'"#,
                go.display()
            ),
        ],
    );
    assert!(
        output
            .read_until("RUNNING\r\n", Duration::from_secs(20))
            .contains("RUNNING\r\n"),
        "the command never started"
    );
    drop(output);
    drop(shell);
    hand_off(&socket, &workspace.dir);
    let running = finished(running);
    assert_eq!(
        (running.code, running.envelope()["error"]["kind"].clone()),
        (3, json!("WaitInterrupted")),
        "{} {}",
        running.stdout,
        running.stderr
    );
    assert_eq!(
        failed(command(&socket, &["server", "--", "echo NOT-NOW"])),
        (3, "Busy".into()),
        "a command typed now would go to the one running until `go` exists"
    );
    std::fs::write(&go, b"").expect("go");
    // Its prompt back (trimmed, as a capture trims), the command was run once.
    let after = |run: &Run| {
        let text = run.envelope()["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        text.rsplit_once("RUNNING")
            .is_some_and(|(_, after)| after.contains("IS>"))
    };
    let screen = capture_awaiting(&socket, &["server", "--json"], "its prompt back", after);
    let text = screen.envelope()["text"].as_str().unwrap().to_string();
    assert_eq!(text.matches("RUNNING").count(), 1, "{text}");
    assert!(!text.contains("NOT-NOW"), "{text}");
    // At its prompt again, a command runs.
    let again = ran(&socket, command(&socket, &["server", "--", "echo again"]));
    assert_eq!(again["output"], "again", "{again}");
    // Handed off again with the shell idle at its prompt: no prompt since, but the shell has its
    // terminal, so a command runs.
    hand_off(&socket, &workspace.dir);
    let idle = ran(&socket, command(&socket, &["server", "--", "echo idle"]));
    assert_eq!(idle["output"], "idle", "{idle}");
}

/// One stand-in coding agent (`common::FAKE_AGENT`), written as `claude`, `codex` or any other
/// name in a folder of its own and run by its absolute path, never a name looked up on PATH, so no
/// real coding agent is ever started: its program and the files it reads and writes.
struct FakeAgent {
    program: std::path::PathBuf,
}

impl FakeAgent {
    /// Writes the program as `name` in a folder of its own under `dir`, made here.
    fn new(dir: &Path, name: &str) -> FakeAgent {
        let folder = (0..)
            .map(|attempt| dir.join(format!("agent-{name}-{attempt}")))
            .find(|folder| std::fs::create_dir(folder).is_ok())
            .expect("a folder for the agent");
        let program = folder.join(name);
        common::write_executable(&program, common::FAKE_AGENT);
        FakeAgent { program }
    }

    fn file(&self, suffix: &str) -> std::path::PathBuf {
        let mut name = self.program.clone().into_os_string();
        name.push(format!(".{suffix}"));
        name.into()
    }

    /// Runs it in `shell`'s session, whose output `output` reads, by its absolute path, with
    /// `env` (`KEY=value` words) and reading `prompt_bytes`, and waits for it to be ready.
    fn launch(
        &self,
        shell: &mut Spawned,
        output: &mut common::ClientReader,
        env: &str,
        prompt_bytes: usize,
    ) {
        let mark = self
            .program
            .parent()
            .and_then(Path::file_name)
            .expect("the agent's folder")
            .to_string_lossy()
            .into_owned();
        type_line(
            shell,
            &format!(
                "{env} MARK={mark} N={prompt_bytes} '{}'",
                self.program.display()
            ),
        );
        let ready = format!("AGENT-{mark}");
        assert!(
            output
                .read_until(&ready, Duration::from_secs(20))
                .contains(&ready),
            "the stand-in agent never started"
        );
    }

    /// Lets it go on past `gate`: `go` (it reports `working`), `end` or `quit`.
    fn open(&self, gate: &str) {
        std::fs::write(self.file(gate), b"").expect("open the agent's gate");
    }

    /// What it read as its prompt, once it has read it all.
    fn typed(&self) -> Vec<u8> {
        let typed = self.file("typed");
        assert!(
            wait_for(Duration::from_secs(20), || typed.exists()),
            "the agent never read its whole prompt"
        );
        std::fs::read(typed).expect("read what the agent read")
    }
}

/// What a prompt of `text` types for a program with bracketed paste on: the paste, then Enter.
fn prompted(text: &str) -> Vec<u8> {
    [
        b"\x1b[200~".as_slice(),
        text.as_bytes(),
        b"\x1b[201~",
        b"\r",
    ]
    .concat()
}

/// `workroom prompt <args> --json`'s exit code and error kind, from a run that must fail.
fn prompt_refused(socket: &Path, args: &[&str]) -> (i32, String) {
    let args: Vec<&str> = [&["prompt"][..], args, &["--json"]].concat();
    let run = workroom(Some(socket), &args);
    let envelope = run.envelope();
    assert_eq!(envelope["ok"], false, "{envelope}");
    assert_eq!(envelope["command"], "prompt", "{envelope}");
    (
        run.code,
        envelope["error"]["kind"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
    )
}

/// `terminal.prompt`'s result schema, as the daemon describes it.
fn prompt_schema(socket: &Path) -> Value {
    let described = Api::connect(socket).call("api.describe", json!({"method": "terminal.prompt"}));
    described["result"]["methods"][0]["output"].clone()
}

/// `workroom prompt` types its text as a bracketed paste and then Enter, apart from it, into a
/// coding agent: one known by its program's name (`codex` here, which never reports until it
/// works), or one whose program reported program status and is in the foreground still. A shell
/// is `NotAnAgent` (3), even one that printed a report itself; an agent working, waiting on the
/// user or with bracketed paste off is `AgentBusy` (3). Without terminal-state the daemon can't
/// encode Enter, nor hear a status: `InternalError` (1), and `--wait` is `InvalidRequest` (2).
#[test]
fn prompt_types_a_paste_and_enter_only_into_a_coding_agent_that_can_take_it() {
    let workspace = Workspace::new("api-prompt");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, SHELL, "shell", "wr-1", &workspace.dir);
    let mut shell_output = common::ClientReader::new(&mut shell);
    let mut codex = open(&socket, OTHER, "codex", "wr-1", &workspace.dir);
    let mut codex_output = common::ClientReader::new(&mut codex);
    listing_until(&socket, |listing| listing.len() == 2);

    assert_eq!(
        prompt_refused(&socket, &["shell", "hi"]),
        (3, "NotAnAgent".into())
    );
    let agent = FakeAgent::new(&workspace.dir, "codex");
    let text = "fix the login test\nthen run them all";
    agent.launch(
        &mut codex,
        &mut codex_output,
        "APP=codex",
        prompted(text).len(),
    );
    if !has_terminal_state() {
        assert_eq!(
            prompt_refused(&socket, &["codex", text]),
            (1, "InternalError".into()),
            "Enter can't be encoded without the session's modes"
        );
        assert_eq!(
            prompt_refused(&socket, &["codex", text, "--wait"]),
            (2, "InvalidRequest".into())
        );
        return;
    }
    // Codex reports nothing until it works, so its turn's end could never be heard.
    assert_eq!(
        prompt_refused(&socket, &["codex", text, "--wait", "--timeout", "20s"]),
        (3, "NotAnAgent".into())
    );
    let run = workroom(Some(&socket), &["prompt", "codex", text, "--json"]);
    assert_eq!(run.code, 0, "{} {}", run.stdout, run.stderr);
    let envelope = run.envelope();
    assert_eq!(envelope["command"], "prompt", "{envelope}");
    assert_eq!(
        violation(&prompt_schema(&socket), &envelope, "result"),
        None,
        "{envelope}"
    );
    assert_eq!(envelope["session"], OTHER, "{envelope}");
    assert_eq!(envelope["status"], Value::Null, "{envelope}");
    assert_eq!(envelope["bytes"], prompted(text).len(), "{envelope}");
    assert_eq!(envelope["modes"]["bracketed_paste"], true, "{envelope}");
    // Its newline stays inside the paste, and Enter comes after the paste's end.
    assert_eq!(
        String::from_utf8_lossy(&agent.typed()),
        String::from_utf8_lossy(&prompted(text))
    );
    // Working: busy, and so it says.
    agent.open("go");
    listing_until(&socket, |listing| {
        session(listing, OTHER)["coding_agent"]["state"] == "working"
    });
    assert_eq!(
        prompt_refused(&socket, &["codex", "and the docs"]),
        (3, "AgentBusy".into())
    );
    agent.open("end");
    agent.open("quit");

    // A report the shell printed itself is no coding agent, nor one left over the shell by a
    // program that has gone.
    type_line(
        &mut shell,
        r"printf '\033]7501;state=done:app=claude\033\\'",
    );
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "done"
    });
    assert_eq!(
        prompt_refused(&socket, &["shell", "hi"]),
        (3, "NotAnAgent".into())
    );
    // A program known by its report, not its name, waiting on the user: an agent, and busy.
    let reporter = FakeAgent::new(&workspace.dir, "helper");
    reporter.launch(&mut shell, &mut shell_output, "FIRST=blocked", 1);
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "blocked"
    });
    assert_eq!(
        prompt_refused(&socket, &["shell", "hi"]),
        (3, "AgentBusy".into())
    );
    reporter.open("quit");
    // With its prompt not up, bracketed paste off: busy too.
    let starting = FakeAgent::new(&workspace.dir, "claude");
    starting.launch(&mut codex, &mut codex_output, "PASTE=0", 1);
    assert_eq!(
        prompt_refused(&socket, &["codex", "hi"]),
        (3, "AgentBusy".into())
    );
    starting.open("quit");
    // A last word that opens a completion gets a space, so Enter submits rather than pick. In a
    // pane of its own: the agents above still wait for the byte no prompt sent them.
    let mut mention_pane = open(&socket, RUN, "mention", "wr-1", &workspace.dir);
    let mut mention_output = common::ClientReader::new(&mut mention_pane);
    let mention = FakeAgent::new(&workspace.dir, "codex");
    let spaced = "look at @src/main.rs ";
    mention.launch(
        &mut mention_pane,
        &mut mention_output,
        "APP=codex",
        prompted(spaced).len(),
    );
    let run = workroom(
        Some(&socket),
        &["prompt", "mention", "look at @src/main.rs", "--json"],
    );
    assert_eq!(run.code, 0, "{} {}", run.stdout, run.stderr);
    assert_eq!(
        run.envelope()["bytes"],
        prompted(spaced).len(),
        "{}",
        run.stdout
    );
    assert_eq!(
        String::from_utf8_lossy(&mention.typed()),
        String::from_utf8_lossy(&prompted(spaced))
    );
    mention.open("quit");
}

/// An agent whose `done` the app has seen, which drops the record (the user looked at its pane),
/// has still reported a status: `prompt --wait` takes it, and does after a hand-off too. A new
/// program in the pane that never reported is `NotAnAgent` for a wait, as ever.
#[test]
fn a_prompt_wait_takes_an_agent_whose_done_was_seen_and_not_a_new_program() {
    if !has_terminal_state() {
        eprintln!("skipped: a prompt's wait needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-prompt-seen");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut pane = open(&socket, SHELL, "claude", "wr-1", &workspace.dir);
    let mut output = common::ClientReader::new(&mut pane);
    let mut other = open(&socket, OTHER, "next", "wr-1", &workspace.dir);
    let mut other_output = common::ClientReader::new(&mut other);
    listing_until(&socket, |listing| listing.len() == 2);

    // An agent that reported and went, then another program in its pane, which has never
    // reported: no agent to wait on. (Before the hand-off below, which ends the panes' clients.)
    // It reads exactly what the send types, the paste and its markers: a byte left over would be
    // read by the shell after it, ahead of the next program's command line.
    let pasted = prompted("x").len() - 1;
    let gone = FakeAgent::new(&workspace.dir, "claude");
    gone.launch(&mut other, &mut other_output, "FIRST=done", pasted);
    listing_until(&socket, |listing| {
        session(listing, OTHER)["coding_agent"]["state"] == "done"
    });
    let sent = workroom(Some(&socket), &["send", "next", "x", "--json"]);
    assert_eq!(sent.code, 0, "{}", sent.stdout);
    assert_eq!(sent.envelope()["bytes"], pasted, "{}", sent.stdout);
    assert_eq!(gone.typed(), prompted("x")[..pasted], "the paste, whole");
    for gate in ["go", "end", "quit"] {
        gone.open(gate);
    }
    assert!(
        other_output
            .read_until("-gone", Duration::from_secs(20))
            .contains("-gone"),
        "the first program never went"
    );
    let next = FakeAgent::new(&workspace.dir, "codex");
    next.launch(&mut other, &mut other_output, "APP=codex", 1);
    assert_eq!(
        prompt_refused(&socket, &["next", "hi", "--wait", "--timeout", "20s"]),
        (3, "NotAnAgent".into())
    );

    let agent = FakeAgent::new(&workspace.dir, "claude");
    agent.launch(
        &mut pane,
        &mut output,
        "PROBE=1 FIRST=done",
        prompted("go on").len(),
    );
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "done"
    });
    // The app's `seen`, as focusing the pane sends it: the `done` goes.
    let mut client = Api::connect(&socket);
    let stream = client.0.take_stream();
    let seen = client.0.request(
        Service::ProgramStatus,
        stream,
        &json!({
            "version": 1,
            "method": "seen",
            "session": SHELL,
            "revision": u64::MAX,
            "states": ["done"],
        }),
    );
    assert_eq!(seen["result"]["ok"], true, "{seen}");
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"].is_null()
    });
    hand_off(&socket, &workspace.dir);

    let waiting = started(
        &socket,
        &[
            "prompt",
            "claude",
            "go on",
            "--wait",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    assert_eq!(agent.typed(), prompted("go on"));
    agent.open("go");
    agent.open("end");
    let ended = finished(waiting);
    assert_eq!(ended.code, 0, "{} {}", ended.stdout, ended.stderr);
    assert_eq!(ended.envelope()["status"], "done", "{}", ended.stdout);
    agent.open("quit");
    next.open("quit");
}

/// The prompt's Enter goes only into an agent still ready for it, and its turn is only one a
/// `working` after that Enter starts (#692). The daemon waits 3 s between the paste and the Enter
/// here (its test-only seam), so the stand-in agent's reports land in between however busy the
/// machine is. One that starts working reading the paste is not sent the Enter: `AgentBusy`,
/// typed and not submitted, its text in the input box. One that runs a turn of its own, `working`
/// then `done`, before the Enter, is sent it, and `--wait` waits on past that turn (3 s and more)
/// for the one the Enter starts.
#[test]
fn a_prompt_presses_enter_only_into_an_agent_still_ready_and_waits_on_the_turn_it_starts() {
    if !has_terminal_state() {
        eprintln!("skipped: a prompt's checks need a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-prompt-enter");
    let socket = workspace.socket();
    let _daemon =
        common::start_daemon_with_env(&socket, &[], &[("WORKROOMD_TEST_ENTER_PAUSE_MS", "3000")]);
    let mut busy_pane = open(&socket, SHELL, "busy", "wr-1", &workspace.dir);
    let mut busy_output = common::ClientReader::new(&mut busy_pane);
    let mut own_pane = open(&socket, OTHER, "own", "wr-1", &workspace.dir);
    let mut own_output = common::ClientReader::new(&mut own_pane);
    listing_until(&socket, |listing| listing.len() == 2);

    let busy = FakeAgent::new(&workspace.dir, "claude");
    busy.launch(
        &mut busy_pane,
        &mut busy_output,
        "PROBE=1 FIRST=idle PRE=working",
        prompted("hi").len(),
    );
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "idle"
    });
    let run = workroom(Some(&socket), &["prompt", "busy", "hi", "--json"]);
    assert_eq!(run.code, 3, "{} {}", run.stdout, run.stderr);
    let error = &run.envelope()["error"];
    assert_eq!(error["kind"], "AgentBusy", "{error}");
    assert_eq!(
        error["details"],
        json!({"typed": true, "submitted": false}),
        "{error}"
    );
    assert!(
        error["message"]
            .as_str()
            .is_some_and(|message| message.contains("input box")),
        "{error}"
    );
    let pasted = prompted("hi");
    assert_eq!(
        busy.typed(),
        pasted[..pasted.len() - 1],
        "the paste, and no Enter"
    );
    busy.open("quit");

    let own = FakeAgent::new(&workspace.dir, "claude");
    own.launch(
        &mut own_pane,
        &mut own_output,
        "PROBE=1 FIRST=done PRE=turn",
        prompted("go on").len(),
    );
    listing_until(&socket, |listing| {
        session(listing, OTHER)["coding_agent"]["state"] == "done"
    });
    let mut waiting = started(
        &socket,
        &[
            "prompt",
            "own",
            "go on",
            "--wait",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    assert_eq!(own.typed(), prompted("go on"), "the paste, then the Enter");
    // Its own turn, between the paste and the Enter, is no answer.
    std::thread::sleep(Duration::from_secs(3));
    assert!(
        waiting.try_wait().expect("the wait's state").is_none(),
        "the wait answered on the turn the agent ran before the prompt's Enter"
    );
    own.open("go");
    own.open("end");
    let ended = finished(waiting);
    assert_eq!(ended.code, 0, "{} {}", ended.stdout, ended.stderr);
    assert_eq!(ended.envelope()["status"], "done", "{}", ended.stdout);
    own.open("quit");
}

/// `workroom prompt --wait` returns once the turn the prompt starts has ended, never on the
/// `done` the turn before left: it waits for a `working` reported after it typed the prompt (here
/// held back 3 s and more), then answers with the status the turn ended in. The API's stream says
/// each step as it happens: typed, the turn started, and its end, each reply in the published
/// shape.
#[test]
fn prompt_wait_ignores_a_stale_done_and_waits_for_a_fresh_working() {
    if !has_terminal_state() {
        eprintln!("skipped: a prompt's wait needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-prompt-wait");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut first = open(&socket, SHELL, "claude", "wr-1", &workspace.dir);
    let mut first_output = common::ClientReader::new(&mut first);
    let mut second = open(&socket, OTHER, "other", "wr-1", &workspace.dir);
    let mut second_output = common::ClientReader::new(&mut second);
    listing_until(&socket, |listing| listing.len() == 2);
    let agent = FakeAgent::new(&workspace.dir, "claude");
    agent.launch(
        &mut first,
        &mut first_output,
        "PROBE=1 FIRST=done",
        prompted("go on").len(),
    );
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "done"
    });

    let waiting = started(
        &socket,
        &[
            "prompt",
            "claude",
            "go on",
            "--wait",
            "--timeout",
            "60s",
            "--json",
        ],
    );
    assert_eq!(agent.typed(), prompted("go on"));
    // The `done` from before is there all along, and is no answer.
    std::thread::sleep(Duration::from_secs(3));
    let mut waiting = waiting;
    assert!(
        waiting.try_wait().expect("the wait's state").is_none(),
        "the wait answered on the done left from the turn before, within 3 s of the prompt"
    );
    agent.open("go");
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "working"
    });
    assert_eq!(
        prompt_refused(&socket, &["claude", "and again"]),
        (3, "AgentBusy".into())
    );
    assert!(waiting.try_wait().expect("the wait's state").is_none());
    agent.open("end");
    let ended = finished(waiting);
    assert_eq!(ended.code, 0, "{} {}", ended.stdout, ended.stderr);
    let envelope = ended.envelope();
    assert_eq!(envelope["status"], "done", "{envelope}");
    assert_eq!(
        violation(&prompt_schema(&socket), &envelope, "result"),
        None,
        "{envelope}"
    );
    // `wait --turn`: the turn under way has ended, now counting; the next is still to start,
    // whatever `done` is there. The short timeout is the one this test wants to pass.
    let current = workroom(
        Some(&socket),
        &["wait", "claude", "--turn", "current", "--timeout", "20s"],
    );
    assert_eq!(
        (current.code, current.stdout.as_str()),
        (0, "status: done\n"),
        "{}",
        current.stderr
    );
    assert_eq!(
        failed(wait(
            &socket,
            &["claude", "--turn", "next", "--timeout", "1s"]
        )),
        (8, "WaitTimeout".into())
    );
    agent.open("quit");

    // The API's stream, step by step, a turn that ends `blocked`.
    let streamed = FakeAgent::new(&workspace.dir, "claude");
    streamed.launch(
        &mut second,
        &mut second_output,
        "PROBE=1 FIRST=idle END=blocked",
        prompted("ask").len(),
    );
    listing_until(&socket, |listing| {
        session(listing, OTHER)["coding_agent"]["state"] == "idle"
    });
    let schema = prompt_schema(&socket);
    let mut api = Api::connect(&socket);
    let step = |reply: &Value, more: bool| {
        assert_eq!(reply["revision"], 1, "{reply}");
        assert_eq!(reply["more"], more, "{reply}");
        assert_eq!(
            violation(&schema, &reply["result"], "prompt"),
            None,
            "{reply}"
        );
        reply["result"]["status"].clone()
    };
    let (stream, typed) = api.stream(
        "terminal.prompt",
        json!({"target": OTHER, "text": "ask", "wait": true, "timeout_ms": 60_000}),
    );
    assert_eq!(step(&typed, true), Value::Null);
    assert_eq!(streamed.typed(), prompted("ask"));
    streamed.open("go");
    assert_eq!(step(&api.reply_on(stream), true), "working");
    streamed.open("end");
    assert_eq!(step(&api.reply_on(stream), false), "blocked");
    streamed.open("quit");

    let human = FakeAgent::new(&workspace.dir, "claude");
    human.launch(
        &mut second,
        &mut second_output,
        "FIRST=done",
        prompted("more").len(),
    );
    let waiting = started(&socket, &["prompt", "other", "more", "--wait"]);
    human.typed();
    human.open("go");
    human.open("end");
    let said = finished(waiting);
    assert_eq!(
        (said.code, said.stdout.as_str()),
        (0, "status: done\n"),
        "{}",
        said.stderr
    );
    human.open("quit");
}

/// A hand-off during `prompt --wait` closes the CLI's connection with the old program, and once
/// the prompt was typed it goes on waiting for its turn's end in the new one, never typing the
/// prompt again: for the turn under way, with an agent already working, and for a turn still to
/// start, where the `done` the turn before left, which the new program holds too, is still no
/// answer (3 s and more). An agent's bracketed paste crosses the hand-off, so it takes a prompt
/// after it.
#[test]
fn a_prompt_wait_across_a_hand_off_goes_on_in_the_new_program() {
    if !has_terminal_state() {
        eprintln!("skipped: a hand-off needs a daemon built with terminal-state");
        return;
    }
    let workspace = Workspace::new("api-prompt-handoff");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut working_pane = open(&socket, SHELL, "working", "wr-1", &workspace.dir);
    let mut starting_pane = open(&socket, OTHER, "starting", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    // Kept reading, so the sessions' output never stalls on a full pipe across the hand-off.
    let mut working_output = common::ClientReader::new(&mut working_pane);
    let mut starting_output = common::ClientReader::new(&mut starting_pane);
    let working = FakeAgent::new(&workspace.dir, "claude");
    working.launch(
        &mut working_pane,
        &mut working_output,
        "PROBE=1 FIRST=done",
        prompted("go on").len(),
    );
    let starting = FakeAgent::new(&workspace.dir, "claude");
    starting.launch(
        &mut starting_pane,
        &mut starting_output,
        "PROBE=1 FIRST=done",
        prompted("go on").len(),
    );
    listing_until(&socket, |listing| {
        [SHELL, OTHER]
            .iter()
            .all(|id| session(listing, id)["coding_agent"]["state"] == "done")
    });

    let prompt = |target: &str| {
        started(
            &socket,
            &[
                "prompt",
                target,
                "go on",
                "--wait",
                "--timeout",
                "90s",
                "--json",
            ],
        )
    };
    let (working_wait, mut starting_wait) = (prompt("working"), prompt("starting"));
    assert_eq!(working.typed(), prompted("go on"));
    assert_eq!(starting.typed(), prompted("go on"));
    working.open("go");
    listing_until(&socket, |listing| {
        session(listing, SHELL)["coding_agent"]["state"] == "working"
    });
    // Time for the turn's start and the typing to reach each CLI before the hand-off.
    std::thread::sleep(Duration::from_secs(3));
    hand_off(&socket, &workspace.dir);
    working.open("end");
    let ended = finished(working_wait);
    assert!(
        ended
            .stderr
            .contains("handed off after the prompt was typed"),
        "the wait never spanned the hand-off: {}",
        ended.stderr
    );
    assert_eq!(ended.code, 0, "{} {}", ended.stdout, ended.stderr);
    assert_eq!(ended.envelope()["status"], "done", "{}", ended.stdout);
    assert_eq!(ended.envelope()["session"], SHELL, "{}", ended.stdout);

    // The turn still to start: the new program's `done`, from before, is no answer.
    std::thread::sleep(Duration::from_secs(3));
    assert!(
        starting_wait
            .try_wait()
            .expect("the wait's state")
            .is_none(),
        "the wait answered across the hand-off on the done left from the turn before"
    );
    starting.open("go");
    starting.open("end");
    let ended = finished(starting_wait);
    assert!(
        ended
            .stderr
            .contains("handed off after the prompt was typed"),
        "the wait never spanned the hand-off: {}",
        ended.stderr
    );
    assert_eq!(ended.code, 0, "{} {}", ended.stdout, ended.stderr);
    assert_eq!(ended.envelope()["status"], "done", "{}", ended.stdout);
    assert_eq!(ended.envelope()["session"], OTHER, "{}", ended.stdout);

    // Still at its prompt, bracketed paste on as the old program read it.
    let again = workroom(Some(&socket), &["prompt", "working", "and then", "--json"]);
    assert_eq!(again.code, 0, "{} {}", again.stdout, again.stderr);
    assert_eq!(
        again.envelope()["modes"]["bracketed_paste"],
        true,
        "{}",
        again.stdout
    );
    working.open("quit");
    starting.open("quit");
}

/// `workroom <args>` as [`workroom`] runs it, with `env` too: a caller's `WORKROOM_PANE`, or the
/// `SHELL` a daemon `new` starts gives its sessions.
fn workroom_with_env(daemon: Option<&Path>, env: &[(&str, &str)], args: &[&str]) -> Run {
    let mut command = Command::new(common::daemon_binary());
    command
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
        .envs(env.iter().copied())
        .stdin(Stdio::null());
    if let Some(socket) = daemon {
        command.env("WORKROOM_DAEMON", socket);
    }
    let output = command.output().expect("run workroom");
    Run {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        code: output.status.code().unwrap_or(-1),
    }
}

/// Runs `workroom <args> --json` in `shell`'s pane and returns its exit code and envelope.
fn from_pane(shell: &mut Spawned, dir: &Path, name: &str, args: &str) -> (i32, Value) {
    let output = shell_output(
        shell,
        dir,
        name,
        &format!(
            "/bin/sh -c \"'{}' {args} --json; echo exit=\\$?\"",
            common::daemon_binary().display()
        ),
    );
    let (envelope, code) = output
        .rsplit_once("exit=")
        .unwrap_or_else(|| panic!("no exit status in {output:?}"));
    let envelope = serde_json::from_str(envelope.trim())
        .unwrap_or_else(|e| panic!("not one envelope ({e}): {output:?}"));
    (code.trim().parse().expect("an exit code"), envelope)
}

/// Waits for `path`, written whole by a session's shell, and returns it.
fn written(path: &Path) -> String {
    assert!(
        wait_for(Duration::from_secs(20), || path.exists()),
        "the session never wrote {}",
        path.display()
    );
    std::fs::read_to_string(path).expect("read what the session wrote")
}

/// Has session `target`'s shell run `command` with its output in `name` under `dir`, written
/// whole, through `workroom send` from no pane; returns what it wrote.
fn run_in(socket: &Path, target: &str, dir: &Path, name: &str, command: &str) -> String {
    let path = dir.join(name);
    let partial = dir.join(format!("{name}.partial"));
    // Its newline as text, not `--enter`, which a daemon without terminal-state can't encode.
    let line = format!(
        "{{ {command}; }} > '{}' 2>&1; mv '{}' '{}'\n",
        partial.display(),
        partial.display(),
        path.display()
    );
    let sent = workroom(Some(socket), &["send", target, &line]);
    assert_eq!(sent.code, 0, "{} {}", sent.stdout, sent.stderr);
    written(&path)
}

/// `workroom new` in a pane (#693) opens a session made as the pane's was, in its workroom: its
/// environment, a login shell of the pane's shell, the title as its label, and `--cwd` resolved
/// against the pane's folder. It prints the session, and says what the app is asked in
/// `opened`, as its `session.created` does: the pane that asked, the split, and the Mac whose
/// pane has the caller's session. Without `--split` the app opens a tab; with no `--title` the
/// session has no label. A folder that isn't one is `NotADirectory` (3), and a bad `--split` a bad
/// command line (1).
#[test]
fn new_in_a_pane_opens_a_session_in_its_workroom_and_asks_its_mac_to_show_it() {
    let workspace = Workspace::new("api-new");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = attach_with_env(
        &socket,
        SHELL,
        &[],
        &[
            ("WORKROOM_SESSION_TITLE", "agent"),
            ("WORKROOM_SESSION_WORKROOM", "wr-1"),
            ("WORKROOM_SESSION_CWD", workspace.dir.to_str().unwrap()),
            ("NEW_INHERITS", "from-the-pane"),
        ],
    );
    listing_until(&socket, |listing| listing.len() == 1);
    let web = workspace.dir.join("web");
    std::fs::create_dir(&web).expect("a folder to start in");
    let mut events = Events::start(&socket, &["--all", "--type", "session.created"]);
    events.until("the snapshot's end", |e| e["event"] == "snapshot-complete");

    let (code, envelope) = from_pane(
        &mut shell,
        &workspace.dir,
        "new.json",
        "new --title 'dev server' --split right --cwd web",
    );
    assert_eq!(code, 0, "{envelope}");
    assert_eq!(envelope["command"], "new", "{envelope}");
    assert_eq!(envelope["caller"], SHELL, "{envelope}");
    let session = &envelope["session"];
    let id = session["id"]
        .as_str()
        .expect("the new session's id")
        .to_string();
    assert_ne!(id, SHELL);
    assert_eq!(session["label"], "dev server", "{envelope}");
    assert_eq!(session["run"], false, "{envelope}");
    assert_eq!(
        session["scope"],
        json!({"kind": "workroom", "id": "wr-1"}),
        "the caller's scope: {envelope}"
    );
    let opened = json!({"by": SHELL, "split": "right", "hostname": this_hostname()});
    assert_eq!(envelope["opened"], opened, "{envelope}");
    let created = events.until("its creation", |e| is(e, "session.created", &id));
    assert_eq!(created["opened"], opened, "{created}");
    assert_eq!(created["label"], "dev server", "{created}");

    // The pane's environment, its own pane and daemon named, in the folder asked for.
    let said = run_in(
        &socket,
        &id,
        &workspace.dir,
        "inherited",
        "echo \"$NEW_INHERITS $WORKROOM_PANE\"; pwd -P",
    );
    let real_web = std::fs::canonicalize(&web).unwrap();
    assert_eq!(
        said,
        format!("from-the-pane {id}\n{}\n", real_web.display()),
        "the new session's environment and folder"
    );

    // A tab, and no label, when neither is asked for; the app's own sessions open nothing.
    let (code, plain) = from_pane(&mut shell, &workspace.dir, "plain.json", "new");
    assert_eq!(code, 0, "{plain}");
    assert_eq!(plain["session"]["label"], Value::Null, "{plain}");
    assert_eq!(plain["opened"]["split"], Value::Null, "{plain}");
    let plain_id = plain["session"]["id"].as_str().unwrap().to_string();
    let said = run_in(&socket, &plain_id, &workspace.dir, "plain", "pwd -P");
    assert_eq!(
        said,
        format!(
            "{}\n",
            std::fs::canonicalize(&workspace.dir).unwrap().display()
        ),
        "the pane's own folder"
    );
    let _app = open(&socket, OTHER, "app's", "wr-1", &workspace.dir);
    let app = events.until("the app's own session", |e| is(e, "session.created", OTHER));
    assert_eq!(app["opened"], Value::Null, "{app}");

    let (code, missing) = from_pane(
        &mut shell,
        &workspace.dir,
        "missing.json",
        "new --cwd no-such-folder",
    );
    assert_eq!(code, 3, "{missing}");
    assert_eq!(missing["error"]["kind"], "NotADirectory", "{missing}");
    let bad = workroom(Some(&socket), &["new", "--split", "left"]);
    assert_eq!(bad.code, 1, "{} {}", bad.stdout, bad.stderr);
    assert!(bad.stderr.contains("right or down"), "{}", bad.stderr);
}

/// `workroom new` never starts a daemon on a socket `WORKROOM_DAEMON` names (#693), which may be
/// anything: with none listening there it is 7, as every other command is, and nothing is
/// started. (This Mac's own daemon, the one `new` does start, is `daemon_to_ask`'s unit test's:
/// no test here may reach where the app keeps it.)
#[test]
fn new_starts_no_daemon_on_a_socket_a_variable_names() {
    let workspace = Workspace::new("api-new-start");
    let socket = workspace.dir.join("d.sock");
    let run = workroom_with_env(
        Some(&socket),
        &[("SHELL", "/bin/sh")],
        &["new", "--json", "--cwd", workspace.dir.to_str().unwrap()],
    );
    assert_eq!(run.code, 7, "{} {}", run.stdout, run.stderr);
    assert_eq!(
        run.envelope()["error"]["kind"],
        "DaemonUnreachable",
        "{}",
        run.stdout
    );
    std::thread::sleep(Duration::from_millis(500));
    assert!(!socket.exists(), "a daemon was started on the named socket");
}

/// `workroom new` from no pane (#693) opens a session with no scope, no caller and no Mac named
/// to show it: every Mac lists it with the detached standalone terminals, as `opened` with no
/// `by` tells the app.
#[test]
fn new_from_no_pane_has_no_scope_and_names_no_mac() {
    let workspace = Workspace::new("api-new-outside");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut events = Events::start(&socket, &["--all", "--type", "session.created"]);
    events.until("the snapshot's end", |e| e["event"] == "snapshot-complete");
    let run = workroom(
        Some(&socket),
        &["new", "--json", "--cwd", workspace.dir.to_str().unwrap()],
    );
    assert_eq!(run.code, 0, "{} {}", run.stdout, run.stderr);
    let envelope = run.envelope();
    assert_eq!(envelope["caller"], Value::Null, "{envelope}");
    assert_eq!(envelope["session"]["scope"], Value::Null, "{envelope}");
    let opened = json!({"by": null, "split": null, "hostname": null});
    assert_eq!(envelope["opened"], opened, "{envelope}");
    let id = envelope["session"]["id"].as_str().unwrap().to_string();
    let created = events.until("its creation", |e| is(e, "session.created", &id));
    assert_eq!(created["opened"], opened, "{created}");
    assert_eq!(created["scope"], Value::Null, "{created}");
    assert!(
        sessions(&socket)
            .iter()
            .any(|session| session["id"] == id.as_str())
    );
}

/// `close` names a session by id, id suffix or label, never by its live title, which its
/// program sets and anything it prints can change (#693): a target only a title matches is
/// `TargetNotFound`, and the session goes on.
#[test]
fn close_never_resolves_a_live_title() {
    if !has_terminal_state() {
        eprintln!("skipped: the live title is the shadow terminal's");
        return;
    }
    let workspace = Workspace::new("api-close-title");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut shell = open(&socket, OTHER, "labelled", "wr-1", &workspace.dir);
    type_line(&mut shell, "printf '\\033]2;titled-only\\007'");
    listing_until(&socket, |listing| {
        listing
            .iter()
            .any(|session| session["title"] == "titled-only")
    });
    let refused = workroom(Some(&socket), &["close", "titled-only", "--json"]);
    assert_eq!(refused.code, 3, "{} {}", refused.stdout, refused.stderr);
    let error = &refused.envelope()["error"];
    assert_eq!(error["kind"], "TargetNotFound", "{error}");
    assert!(
        error["message"]
            .as_str()
            .unwrap()
            .contains("never its live title"),
        "{error}"
    );
    assert!(
        sessions(&socket)
            .iter()
            .any(|session| session["id"] == OTHER)
    );
    // Other commands still take it.
    let resolved = workroom(Some(&socket), &["sessions", "titled-only", "--json"]);
    assert_eq!(resolved.code, 0, "{} {}", resolved.stdout, resolved.stderr);
    let closed = workroom(Some(&socket), &["close", "labelled"]);
    assert_eq!(closed.code, 0, "{} {}", closed.stdout, closed.stderr);
}

/// `workroom close` (#693) ends a session, and its `session.ended` says `closed`, so the app
/// closes its tab or split; a session that ends any other way says it wasn't. The caller's own is
/// `RefusedSelf` (3) without `--allow-self`, and a target nothing matches `TargetNotFound` (3).
/// A run session's supervisor is asked to quit first, and the session ends long before its grace.
#[test]
fn close_ends_a_session_says_so_in_its_end_and_refuses_the_callers_own() {
    let workspace = Workspace::new("api-close");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let mut caller = open(&socket, SHELL, "caller", "wr-1", &workspace.dir);
    let _target = open(&socket, OTHER, "target", "wr-1", &workspace.dir);
    let mut exits = open(&socket, RUN, "exits", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 3);
    let mut events = Events::start(&socket, &["--all", "--type", "session.ended"]);
    events.until("the snapshot's end", |e| e["event"] == "snapshot-complete");

    let (code, refused) = from_pane(&mut caller, &workspace.dir, "self.json", "close caller");
    assert_eq!(code, 3, "{refused}");
    assert_eq!(refused["error"]["kind"], "RefusedSelf", "{refused}");
    let (code, closed) = from_pane(&mut caller, &workspace.dir, "close.json", "close target");
    assert_eq!(code, 0, "{closed}");
    assert_eq!(closed["command"], "close", "{closed}");
    assert_eq!(closed["session"], OTHER, "{closed}");
    assert_eq!(closed["caller"], SHELL, "{closed}");
    let ended = events.until("its end", |e| is(e, "session.ended", OTHER));
    assert_eq!(ended["closed"], true, "{ended}");
    assert!(
        sessions(&socket)
            .iter()
            .all(|session| session["id"] != OTHER),
        "closed, it is gone"
    );

    type_line(&mut exits, "exit 4");
    let ended = events.until("the shell's own end", |e| is(e, "session.ended", RUN));
    assert_eq!(ended["closed"], false, "{ended}");
    assert_eq!(ended["exit_code"], 4, "{ended}");

    let (code, missing) = from_pane(&mut caller, &workspace.dir, "none.json", "close nobody");
    assert_eq!(code, 3, "{missing}");
    assert_eq!(missing["error"]["kind"], "TargetNotFound", "{missing}");

    // A run, from no pane: its supervisor quits, so it is gone well before the quit's grace.
    let made = workroom_with_env(
        Some(&socket),
        &[],
        &["new", "--title", "server", "--run", "sleep 60", "--json"],
    );
    assert_eq!(made.code, 0, "{} {}", made.stdout, made.stderr);
    let run = made.envelope()["session"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let waited = workroom(
        Some(&socket),
        &["wait", &run, "--run", "running", "--timeout", "20s"],
    );
    assert_eq!(waited.code, 0, "{} {}", waited.stdout, waited.stderr);
    let started = std::time::Instant::now();
    let closed = workroom(Some(&socket), &["close", "server"]);
    assert_eq!(closed.code, 0, "{} {}", closed.stdout, closed.stderr);
    assert!(
        started.elapsed() < Duration::from_secs(6),
        "the supervisor never quit: {:?}",
        started.elapsed()
    );
    let ended = events.until("the run's end", |e| is(e, "session.ended", &run));
    assert_eq!(ended["closed"], true, "{ended}");

    // The caller's own, allowed, from a process outside it that names it.
    let own = workroom_with_env(
        Some(&socket),
        &[("WORKROOM_PANE", SHELL)],
        &["close", SHELL, "--allow-self", "--json"],
    );
    assert_eq!(own.code, 0, "{} {}", own.stdout, own.stderr);
    assert_eq!(own.envelope()["caller"], SHELL, "{}", own.stdout);
    let ended = events.until("the caller's end", |e| is(e, "session.ended", SHELL));
    assert_eq!(ended["closed"], true, "{ended}");
}

/// `workroom run-control` (#693) restarts and stops a run session's command through its
/// supervisor's run signal, which its run states tell; a session that is no run is `NotARun` (3),
/// and an action other than restart or stop a bad command line (1).
#[test]
fn run_control_restarts_and_stops_a_run_and_refuses_a_shell() {
    let workspace = Workspace::new("api-run-control");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "shell", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 1);
    let made = workroom_with_env(
        Some(&socket),
        &[("WORKROOM_PANE", SHELL)],
        &["new", "--run", "sleep 60", "--title", "dev", "--json"],
    );
    assert_eq!(made.code, 0, "{} {}", made.stdout, made.stderr);
    let made = made.envelope();
    let run = made["session"]["id"].as_str().unwrap().to_string();
    assert_eq!(made["session"]["run"], true, "{made}");
    assert_eq!(
        made["session"]["scope"],
        json!({"kind": "workroom", "id": "wr-1"}),
        "{made}"
    );
    let mut events = Events::start(&socket, &["--session", &run, "--type", "session.run_state"]);
    events.until("the snapshot's end", |e| e["event"] == "snapshot-complete");
    let waited = workroom(
        Some(&socket),
        &["wait", "dev", "--run", "running", "--timeout", "20s"],
    );
    assert_eq!(waited.code, 0, "{} {}", waited.stdout, waited.stderr);

    let restarted = workroom(Some(&socket), &["run-control", "dev", "restart", "--json"]);
    assert_eq!(
        restarted.code, 0,
        "{} {}",
        restarted.stdout, restarted.stderr
    );
    let envelope = restarted.envelope();
    assert_eq!(envelope["command"], "run-control", "{envelope}");
    assert_eq!(envelope["action"], "restart", "{envelope}");
    assert_eq!(envelope["session"], run.as_str(), "{envelope}");
    events.until("stopping", |e| e["run_state"] == "stopping");
    events.until("running again", |e| e["run_state"] == "running");

    let stopped = workroom(Some(&socket), &["run-control", "dev", "stop"]);
    assert_eq!(
        (stopped.code, stopped.stdout.as_str()),
        (0, ""),
        "{}",
        stopped.stderr
    );
    events.until("stopped", |e| e["run_state"] == "stopped");

    // At once: no wait for the first status of a supervisor a shell never has.
    let asked = std::time::Instant::now();
    let shell = workroom(
        Some(&socket),
        &["run-control", "shell", "restart", "--json"],
    );
    assert!(
        asked.elapsed() < Duration::from_secs(3),
        "NotARun took {:?}",
        asked.elapsed()
    );
    assert_eq!(shell.code, 3, "{} {}", shell.stdout, shell.stderr);
    assert_eq!(
        shell.envelope()["error"]["kind"],
        "NotARun",
        "{}",
        shell.stdout
    );
    let bad = workroom(Some(&socket), &["run-control", "dev", "pause"]);
    assert_eq!(bad.code, 1, "{} {}", bad.stdout, bad.stderr);
}

/// `session.label` (`api call`, #694) through `workroom api call`, as `--json` gives its result.
fn label(socket: &Path, params: Value) -> Run {
    workroom(
        Some(socket),
        &[
            "api",
            "call",
            "session.label",
            &params.to_string(),
            "--json",
        ],
    )
}

/// A session's label is its tab's name (#694): `session.label` sets it, trimmed, and every
/// subscriber is told `session.labelled` once; the same label again changes nothing and is told
/// nothing, which is what ends the app's own rename heard back. The new label is a target and the
/// old one no longer is; an empty one clears it. A label without `label`, or for a target nothing
/// matches, is refused, and no event is told. Across a hand-off the label stays and the events go
/// on, each label told once.
/// Value: protects=the API's label and the app's tab name are one name every Mac hears change once; fails_when=set_label leaves the listing or targets on the old name, tells an unchanged label (an echo loop), or a hand-off drops the label or retells it; why_new=a session's label never changed after creation; seam=none
#[test]
fn a_label_set_through_the_api_is_the_sessions_and_told_once_across_a_hand_off() {
    let workspace = Workspace::new("api-label");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let _shell = open(&socket, SHELL, "server", "wr-1", &workspace.dir);
    let _other = open(&socket, OTHER, "tests", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| listing.len() == 2);
    let mut events = Events::start(&socket, &["--all", "--type", "session.labelled"]);
    events.until("snapshot-complete", |e| e["event"] == "snapshot-complete");

    let set = label(&socket, json!({"target": "server", "label": "  web  "}));
    assert_eq!(set.code, 0, "{} {}", set.stdout, set.stderr);
    let result = &set.envelope()["result"];
    assert_eq!(result["changed"], true, "{result}");
    assert_eq!(result["session"]["id"], SHELL, "{result}");
    assert_eq!(result["session"]["label"], "web", "trimmed: {result}");
    let told = events.until("the label", |e| is(e, "session.labelled", SHELL));
    assert_eq!(told["label"], "web", "{told}");
    assert_eq!(told["scope"], json!({"kind": "workroom", "id": "wr-1"}));

    let again = label(&socket, json!({"target": SHELL, "label": "web"}));
    assert_eq!(again.code, 0, "{} {}", again.stdout, again.stderr);
    assert_eq!(
        again.envelope()["result"]["changed"],
        false,
        "{}",
        again.stdout
    );
    assert_eq!(session(&sessions(&socket), SHELL)["label"], "web");
    assert_eq!(target(&socket, "web"), Ok(SHELL.into()));
    assert_eq!(
        target(&socket, "server"),
        Err((3, "TargetNotFound".into(), vec![])),
        "the old label names nothing"
    );

    let missing = label(&socket, json!({"target": SHELL}));
    assert_eq!(missing.code, 2, "{}", missing.stdout);
    assert_eq!(missing.envelope()["error"]["kind"], "InvalidRequest");
    let nobody = label(&socket, json!({"target": "nobody", "label": "x"}));
    assert_eq!(nobody.code, 3, "{}", nobody.stdout);
    assert_eq!(nobody.envelope()["error"]["kind"], "TargetNotFound");

    let cleared = label(&socket, json!({"target": "web", "label": ""}));
    assert_eq!(cleared.code, 0, "{} {}", cleared.stdout, cleared.stderr);
    assert_eq!(
        cleared.envelope()["result"]["session"]["label"],
        Value::Null
    );
    let told = events.until("the label cleared", |e| is(e, "session.labelled", SHELL));
    assert_eq!(told["label"], Value::Null, "{told}");
    let set = label(&socket, json!({"target": OTHER, "label": "db"}));
    assert_eq!(set.code, 0, "{} {}", set.stdout, set.stderr);
    events.until("the other's label", |e| is(e, "session.labelled", OTHER));
    assert_eq!(events.count("session.labelled"), 3, "{:#?}", events.seen);

    if !has_terminal_state() {
        events.stop();
        return;
    }
    hand_off(&socket, &workspace.dir);
    assert_eq!(session(&sessions(&socket), OTHER)["label"], "db", "carried");
    let set = label(&socket, json!({"target": "db", "label": "db2"}));
    assert_eq!(set.code, 0, "{} {}", set.stdout, set.stderr);
    let told = events.until("a label after the hand-off", |e| {
        is(e, "session.labelled", OTHER) && e["label"] == "db2"
    });
    assert_eq!(told["label"], "db2", "{told}");
    let labels: Vec<&Value> = events
        .seen
        .iter()
        .filter(|e| e["event"] == "session.labelled")
        .map(|e| &e["label"])
        .collect();
    assert_eq!(
        labels,
        [&json!("web"), &Value::Null, &json!("db"), &json!("db2")],
        "each label told once: {:#?}",
        events.seen
    );
    events.stop();
}

/// A `new` from a real zsh with Workroom's bundled Ghostty integration (#693) is made as that pane
/// was, integration and all, so `workroom command` runs in it at once: it waits for the new
/// shell's first mark, then answers with the command's code and output.
#[test]
fn a_new_session_has_its_callers_shell_integration_so_command_runs_in_it() {
    new_then_command(false);
}

/// So it is from a pane opened before the daemon was handed off to its next program (an app
/// update): the hand-off carries what the pane's shell was built from (table version 5).
#[test]
fn a_new_session_after_a_hand_off_still_has_its_callers_shell_integration() {
    new_then_command(true);
}

/// A `new` from a real zsh pane with the bundled integration, after a hand-off with `handed_off`,
/// then `command` in the new session.
fn new_then_command(handed_off: bool) {
    if !has_terminal_state() {
        eprintln!("skipped: a command's end needs a daemon built with terminal-state");
        return;
    }
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../macapp/Resources/ghostty");
    if !resources.join("shell-integration").is_dir() {
        eprintln!(
            "skipped: no bundled shell integration at {}",
            resources.display()
        );
        return;
    }
    let zsh = match installed_shell(
        "zsh",
        &["/opt/homebrew/bin/zsh", "/bin/zsh", "/usr/bin/zsh"],
    ) {
        Ok(zsh) => zsh,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let workspace = Workspace::new(if handed_off {
        "api-new-handed-off"
    } else {
        "api-new-integrated"
    });
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (mut caller, _output) = real_shell(&socket, SHELL, &zsh, &workspace.dir);
    if handed_off {
        hand_off(&socket, &workspace.dir);
    }
    let made = shell_output(
        &mut caller,
        &workspace.dir,
        "new.json",
        &format!("'{}' new --json", common::daemon_binary().display()),
    );
    let made: Value = serde_json::from_str(made.trim()).unwrap_or_else(|e| panic!("{e}: {made}"));
    let id = made["session"]["id"]
        .as_str()
        .expect("the new session")
        .to_string();
    let ran = workroom(
        Some(&socket),
        &[
            "command",
            &id,
            "--timeout",
            "30s",
            "--json",
            "--",
            "echo",
            "integrated",
        ],
    );
    assert_eq!(ran.code, 0, "{} {}", ran.stdout, ran.stderr);
    assert_eq!(ran.envelope()["exit_code"], 0, "{}", ran.stdout);
    assert_eq!(ran.envelope()["output"], "integrated", "{}", ran.stdout);
}
