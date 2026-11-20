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

/// `workroom <args>` with only `PATH`, `HOME` and, when given, `WORKROOM_DAEMON`.
fn workroom(daemon: Option<&Path>, args: &[&str]) -> Run {
    let mut command = Command::new(common::daemon_binary());
    command
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", std::env::temp_dir())
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
    std::fs::copy(common::daemon_binary(), &next).expect("copy");
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
    for daemon in [None, Some(nowhere.as_path())] {
        for args in [&["sessions", "--json"][..], &["sessions", "x", "--json"]] {
            let run = workroom(daemon, args);
            assert_eq!(run.code, 7, "{args:?} {}", run.stdout);
            assert_eq!(run.envelope()["error"]["kind"], "DaemonUnreachable");
            assert_eq!(run.stderr, "");
        }
        let human = workroom(daemon, &["sessions"]);
        assert_eq!(human.code, 7);
        assert!(human.stderr.starts_with("Error: "), "{}", human.stderr);
    }
}

/// A daemon from before the terminal API would fail the whole connection on its service byte, so
/// the CLI checks the greeting, sends it nothing, and exits 7 `DaemonTooOld`, saying it needs
/// updating.
#[test]
fn a_daemon_older_than_the_terminal_api_is_sent_nothing() {
    use std::io::Read;
    use wr_protocol::envelope::{Hello, MIN_TERMINAL_API_VERSION};

    let workspace = Workspace::new("api-old-daemon");
    let socket = workspace.socket();
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
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
    let run = workroom(Some(&socket), &["sessions", "--json"]);
    assert_eq!(run.code, 7, "{}", run.stdout);
    let envelope = run.envelope();
    assert_eq!(envelope["error"]["kind"], "DaemonTooOld");
    let message = envelope["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("predates the terminal API") && message.contains("needs updating"),
        "{envelope}"
    );
    assert_eq!(
        fake.join().unwrap(),
        0,
        "bytes past the greeting reached the old daemon"
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
        let stream = self.0.take_stream();
        self.0.request(
            Service::TerminalApi,
            stream,
            &json!({"method": method, "params": params}),
        )
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
    assert_eq!(described["version"], 1, "{described}");
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
        assert_eq!(
            violation(&method["input"], &method["example"], "example"),
            None,
            "{method}"
        );
        // Both schemas carry JSON Schema's `examples`, each one a value the schema accepts, so a
        // caller sees what a reply looks like before it makes a request.
        for which in ["input", "output"] {
            assert_examples_match(&method[which], &format!("{}.{which}", method["name"]));
        }
        assert_eq!(
            method["input"]["examples"][0], method["example"],
            "{method}"
        );
    }
    let error_schema = described["result"]["error"].clone();
    assert_examples_match(&error_schema, "error");

    let cases = [
        ("api.describe", json!({}), &described),
        (
            "session.list",
            json!({}),
            &api.call("session.list", json!({})),
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
        assert_eq!(reply["version"], 1, "{reply}");
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
}
