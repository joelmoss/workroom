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
    // Every field, null or not: a caller never has to ask whether a key is there.
    for key in [
        "id",
        "label",
        "title",
        "scope",
        "run",
        "cwd",
        "coding_agent",
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
        ],
    );
    let env = shell_output(&mut shell, &workspace.dir, "shell-env", "env");
    assert_eq!(
        workroom_variables(&env),
        [
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
            format!("WORKROOM_DAEMON={}", socket.display()),
            format!("WORKROOM_PANE={RUN}"),
        ],
        "{env}"
    );
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
        for args in [&["sessions", "--json"][..], &["sessions", "x", "--json"]] {
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
            .contains(&format!("session.list      {summary}\n")),
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
    let _second = open(&socket, RUN, "tests", "wr-1", &workspace.dir);
    listing_until(&socket, |listing| {
        listing.len() == 2 && listing.iter().all(|session| !session["cwd"].is_null())
    });

    // Each method's params for one real call that succeeds.
    let cases = [
        ("api.describe", json!({})),
        ("session.list", json!({})),
        ("session.resolve", json!({"target": OTHER})),
        ("terminal.capture", json!({"target": OTHER, "lines": 2})),
        (
            "terminal.wait",
            json!({"target": OTHER, "regex": "API-CALL-WAITED", "timeout_ms": 30000}),
        ),
    ];
    let listed = api_json(&socket, &["list"]);
    for method in listed["methods"].as_array().expect("methods") {
        let name = method["name"].as_str().unwrap();
        let (_, params) = cases
            .iter()
            .find(|(case, _)| *case == name)
            .unwrap_or_else(|| panic!("{name} has no case here: add one"));
        // A capture needs a screen to read, which only terminal-state keeps.
        if name == "terminal.capture" && !has_terminal_state() {
            continue;
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
        let called = api_json(&socket, &["call", name, &params]);
        assert_eq!(called["revision"], described["revision"], "{called}");
        assert_eq!(
            violation(&schema["output"], &called["result"], name),
            None,
            "{called}"
        );
    }

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

    // `/bin/sh` sends no OSC 133 marks, so a command's end can't be seen.
    assert_eq!(
        failed(wait(
            &socket,
            &["server", "--command-finished", "--timeout", "5s"]
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
    assert_eq!(
        failed(wait(&socket, &["server", "--run", "running"])),
        (2, "InvalidRequest".into()),
        "a shell has no run state"
    );
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
    // Blocked, and a command ended, once `go` exists: after the hand-off.
    let go = workspace.dir.join("go");
    type_line(
        &mut shell,
        &format!(
            r#"sh -c 'while [ ! -e "{go}" ]; do sleep 0.05; done; printf "\033]7501;state=blocked:app=claude\033\\"; printf "\033]133;C\007\033]133;D;6\007"; sleep 30'"#,
            go = go.display()
        ),
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
