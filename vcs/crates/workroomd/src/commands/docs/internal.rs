//! `reference/internal-apis.md`: everything the Mac app uses beyond the terminal API, documented
//! for anyone who finds it useful and promised to no one (ADR 0079's 2026-11-23 amendment).
//!
//! Generated where there is a registry: the services and frames from `wr_protocol`'s own enums
//! (each described by a match with no wildcard, so a new one fails to build until it is here), the
//! protocol versions from its constants, the daemon's subcommands from the binary's usage text,
//! and the hidden commands and flags from the commands table. The JSON services' methods have no
//! registry, only the `match` each service dispatches with, so their rows are written here and a
//! test reads those matches from the daemon's source and fails when a method is in one and not
//! the other ([`SERVICES`]). Every name a row quotes is checked against the fields, keys and
//! variants in that service's source, and every number is a constant read from it ([`render`]).

use super::super::{COMMANDS, Command, Flag};
use super::source::{constant, json_keys, literals, struct_fields};
use super::{HEADER, cell, escaped, front_matter};
use wr_protocol::envelope::{
    self, MIN_FILE_VERSION, MIN_FORWARD_VERSION, MIN_HANDOFF_VERSION, MIN_HOST_ATTACH_VERSION,
    MIN_LAYOUT_VERSION, MIN_PINGS_VERSION, MIN_PROGRAM_STATUS_VERSION, MIN_RETAG_VERSION,
    MIN_RUN_VERSION, MIN_SUPPORTED_VERSION, MIN_TERMINAL_API_VERSION, MIN_VCS_VERSION,
    PROTOCOL_VERSION, Service,
};
use wr_protocol::frame::{FrameKind, RunSignal};

/// The page, under `docs-site/pages`.
pub(super) const PAGE: &str = "reference/internal-apis.md";

/// The binary's usage text, which lists the daemon's subcommands (`main.rs`).
const MAIN: &str = include_str!("../../main.rs");

/// The daemon's subcommands, as `cli::route` names them.
const ROUTE: &str = include_str!("../../cli/route.rs");

/// The Terminal service's payloads, whose Attach entries are read in `AttachRequest::decode`.
const TERMINAL_PAYLOADS: &str = include_str!("../../../../wr-protocol/src/terminal.rs");

/// The VCS service, whose limits are its own constants.
const VCS_SOURCE: &str = include_str!("../../vcs/service.rs");

/// The ProgramStatus service, whose events are its `Serialize` structs.
const PROGRAM_STATUS_SOURCE: &str = include_str!("../../terminal/program_status.rs");

/// The File service's watches, whose events are written in `json!`.
const WATCH_SOURCE: &str = include_str!("../../vcs/watch.rs");

/// The line under every section: what this page promises.
const UNSTABLE: &str = "Internal: not covered by ADR 0079's compatibility promise, and may change in \
                        any release.";

/// A number the page quotes, by the name of the constant it is: `$n{NAME}` writes it as a number,
/// `$size{NAME}` as bytes (`4 KiB`, `16 MiB`) and `$s{NAME}` as seconds.
fn quoted_constant(name: &str) -> u64 {
    match name {
        "MAX_RESPONSE" => crate::daemon::rpc::MAX_RESPONSE as u64,
        "MAX_PAYLOAD_SIZE" => wr_protocol::frame::MAX_PAYLOAD_SIZE as u64,
        "MAX_ENVELOPE_PAYLOAD" => envelope::MAX_ENVELOPE_PAYLOAD as u64,
        "SERVICE_DEADLINE" => crate::daemon::serve::SERVICE_DEADLINE.as_secs(),
        // The app pings four times in each deadline (ADR 0075).
        "PING_INTERVAL" => crate::daemon::serve::SERVICE_DEADLINE.as_secs() / 4,
        "PROTOCOL_VERSION" => PROTOCOL_VERSION.into(),
        "MIN_TERMINAL_API_VERSION" => MIN_TERMINAL_API_VERSION.into(),
        other => constant(VCS_SOURCE, other),
    }
}

/// `text` with each `$n{…}`, `$size{…}` and `$s{…}` written as the constant it names.
fn render(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find('$') {
        out += &rest[..at];
        let after = &rest[at + 1..];
        let (form, name, tail) = after
            .split_once('{')
            .and_then(|(form, more)| more.split_once('}').map(|(name, tail)| (form, name, tail)))
            .unwrap_or_else(|| panic!("a $ with no {{NAME}} in {text:?}"));
        let value = quoted_constant(name);
        out += &match form {
            "n" => value.to_string(),
            "s" => format!("{value} s"),
            "size" if value.is_multiple_of(1 << 20) => format!("{} MiB", value >> 20),
            "size" if value.is_multiple_of(1 << 10) => format!("{} KiB", value >> 10),
            "size" => format!("{value} bytes"),
            other => panic!("no ${other}{{…}} in {text:?}"),
        };
        rest = tail;
    }
    out + rest
}

/// Every service, by its byte.
fn services() -> Vec<Service> {
    (0..=u8::MAX).filter_map(Service::from_u8).collect()
}

/// A service's name, the protocol version it arrived at, and what it is for.
fn service(service: Service) -> (&'static str, String, &'static str) {
    match service {
        Service::Control => (
            "Control",
            MIN_SUPPORTED_VERSION.to_string(),
            "Session control not tied to one attach: list, kill, hand off, signal a run, \
             retag, and say the connection pings. Its frames are the Terminal service's \
             framing.",
        ),
        Service::Terminal => (
            "Terminal",
            MIN_SUPPORTED_VERSION.to_string(),
            "One attach to a session's pty: the session's output, and the client's typing and \
             size. `workroom attach`, which every pane runs, speaks it.",
        ),
        Service::Vcs => (
            "VCS",
            MIN_VCS_VERSION.to_string(),
            "A workroom's repository, read and written where its files are: Git reads \
             (history, changes, diffs, file contents), `git` runs for writes, and file stats.",
        ),
        Service::File => (
            "File",
            MIN_FILE_VERSION.to_string(),
            "A workroom's files: listing, reading, resolving paths and watching for changes.",
        ),
        Service::Status => (
            "Status",
            "4, retired".to_string(),
            "Retired. Every request is answered `{\"unsupported\": …}` for apps that still ask.",
        ),
        Service::Forward => (
            "Forward",
            MIN_FORWARD_VERSION.to_string(),
            "Port forwarding: one loopback TCP connection on the daemon's machine per stream, or \
             a listener whose connections the client claims.",
        ),
        Service::Layout => (
            "Layout",
            MIN_LAYOUT_VERSION.to_string(),
            "Each remote workroom's tabs and splits, kept on its host so every Mac opens the \
             same ones.",
        ),
        Service::ProgramStatus => (
            "ProgramStatus",
            MIN_PROGRAM_STATUS_VERSION.to_string(),
            "What each session's program reports through OSC 7501 (a coding agent working, \
             done or waiting on you), and how its shell's last long command ended.",
        ),
        Service::TerminalApi => (
            "Terminal API",
            MIN_TERMINAL_API_VERSION.to_string(),
            "The public terminal API. Not internal: see the [terminal API \
             reference](terminal-api.md).",
        ),
    }
}

/// Every frame kind, by its byte.
fn frames() -> Vec<FrameKind> {
    (0..=u8::MAX).filter_map(FrameKind::from_u8).collect()
}

/// A frame's direction, the protocol version it arrived at, its payload and what it does.
fn frame(kind: FrameKind) -> (&'static str, u16, &'static str, &'static str) {
    const TO_DAEMON: &str = "to the daemon";
    const TO_CLIENT: &str = "to the client";
    match kind {
        FrameKind::Attach => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "The 16-byte session id, then NUL-terminated `KEY=VALUE` entries (below).",
            "Attaches to the session, creating it unless `CREATE=0`. Answered `Attached`, then \
             the session's screen and its `Output`, or `Failure`.",
        ),
        FrameKind::Input => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "Bytes.",
            "Typed into the session's pty.",
        ),
        FrameKind::Resize => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "Columns and rows, then the width and height in pixels, each a big-endian `u16`.",
            "The client's window size. The session follows the size of the client that last \
             typed or clicked.",
        ),
        FrameKind::Attached => (
            TO_CLIENT,
            MIN_SUPPORTED_VERSION,
            "None.",
            "The attach was accepted.",
        ),
        FrameKind::Output => (
            TO_CLIENT,
            MIN_SUPPORTED_VERSION,
            "Bytes.",
            "What the session's program printed.",
        ),
        FrameKind::Exited => (
            TO_CLIENT,
            MIN_SUPPORTED_VERSION,
            "The shell's exit code, a big-endian `i32`.",
            "The session ended.",
        ),
        FrameKind::Failure => (
            TO_CLIENT,
            MIN_SUPPORTED_VERSION,
            "A UTF-8 reason.",
            "A request failed. `no session …` means the session is gone.",
        ),
        FrameKind::List => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "None.",
            "Lists the live sessions. Answered `Sessions`.",
        ),
        FrameKind::Info => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "None.",
            "Reserved: the app's frame decoder knows its byte, and this daemon answers nothing \
             to it.",
        ),
        FrameKind::Kill => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "The 16-byte session id.",
            "Ends the session. Answered `Acknowledged` once its processes are gone.",
        ),
        FrameKind::KillAll => (
            TO_DAEMON,
            MIN_SUPPORTED_VERSION,
            "None.",
            "Ends every session. Answered `Acknowledged`.",
        ),
        FrameKind::HandOff => (
            TO_DAEMON,
            MIN_HANDOFF_VERSION,
            "`force` as one byte, then the absolute path of a binary.",
            "Replaces the daemon's program with that binary in place, keeping every session \
             and its processes. Answered `Acknowledged` with `handing off` or `current`, or \
             `Failure` with why it was refused.",
        ),
        FrameKind::Signal => (
            TO_DAEMON,
            MIN_RUN_VERSION,
            "The 16-byte session id, then one run signal byte (below).",
            "Asks a run session's supervisor to restart, stop or quit its command. Answered \
             `Acknowledged` once sent.",
        ),
        FrameKind::Retag => (
            TO_DAEMON,
            MIN_RETAG_VERSION,
            "The 16-byte session id, then the workroom as UTF-8.",
            "Tags a live session with another workroom. Answered `Acknowledged`.",
        ),
        FrameKind::Pings => (
            TO_DAEMON,
            MIN_PINGS_VERSION,
            "None.",
            "Says the client sends something at least every $s{PING_INTERVAL}, so the daemon \
             may close the connection after $s{SERVICE_DEADLINE} of silence. Answered \
             `Acknowledged`.",
        ),
        FrameKind::Peer => (
            TO_DAEMON,
            MIN_HOST_ATTACH_VERSION,
            "NUL-terminated `KEY=VALUE` entries: the ssh login's environment.",
            "Sent by `relay` alone, right after the greeting, and never answered. Sessions \
             this connection creates from the host's environment are built from it.",
        ),
        FrameKind::Sessions => (
            TO_CLIENT,
            MIN_SUPPORTED_VERSION,
            "A count, then each session's id, pid, tty, folder, whether it is attached and its \
             metadata.",
            "The answer to `List`.",
        ),
        FrameKind::Acknowledged => (
            TO_CLIENT,
            MIN_SUPPORTED_VERSION,
            "None, or a UTF-8 word.",
            "A control request was done.",
        ),
    }
}

/// What a run signal asks a supervisor to do.
fn run_signal(signal: RunSignal) -> &'static str {
    match signal {
        RunSignal::Restart => "`SIGUSR1`: stop the command and run it again in place.",
        RunSignal::Stop => "`SIGUSR2`: stop the command and keep the pane.",
        RunSignal::Quit => "`SIGTERM`: stop the command, then end the session.",
    }
}

/// One entry an Attach can carry, and what it says.
const ATTACH_ENTRIES: &[(&str, &str)] = &[
    (
        "SHELL",
        "The shell to start, when the attach creates the session.",
    ),
    ("COMMAND", "The command to run in place of a login shell."),
    ("CWD", "The folder it starts in."),
    (
        "RESOURCES",
        "Ghostty's resources folder, whose shell integration the shell is pointed at.",
    ),
    ("COLS", "The client's columns."),
    ("ROWS", "The client's rows."),
    ("XPIXELS", "The client's width in pixels; 0 for unknown."),
    ("YPIXELS", "The client's height in pixels; 0 for unknown."),
    (
        "CREATE",
        "`0`: attach only to a session that exists, never create one. A restored pane sends it.",
    ),
    (
        "HOST",
        "`1`: build the session from the host's own environment and account (a remote pane).",
    ),
    (
        "CLIENT",
        "The client's kind, `pane`, `app` or `cli`, as `sessions --clients` reports it.",
    ),
    (
        "HOSTNAME",
        "The machine the client is on: for a pane, the Mac showing it.",
    ),
    (
        "ENV:NAME",
        "One variable for the session's environment, the client's own, not the daemon's.",
    ),
];

/// One JSON request a service dispatches: its method (or, for VCS writes, its `kind`), what it
/// takes and answers, and when the app sends it.
struct Request {
    method: &'static str,
    shape: &'static str,
    app: &'static str,
}

/// A JSON service's requests, and where the daemon dispatches them, for the test that holds the
/// two together.
struct JsonService {
    name: &'static str,
    /// What every request and reply looks like.
    wire: &'static str,
    requests: &'static [Request],
    /// The structs the service reads its requests into, each of whose fields a row names.
    request_types: &'static [&'static str],
    /// The daemon's source, the function that dispatches, and each expression it matches the
    /// method on: the test reads every method from those.
    source: &'static str,
    function: Option<&'static str>,
    scrutinees: &'static [&'static str],
}

const SERVICES: &[JsonService] = &[
    JsonService {
        name: "VCS",
        wire: "JSON on the chunked envelope: each payload starts with one byte, `0` for a \
               continuation and `1` for the last, and a reply is at most $size{MAX_RESPONSE}. A read is \
               `{\"version\": 1, \"root\", \"backend\": \"git\", \"method\", …}` with `limit`, \
               `revision`, `path` and `base` as it needs them; a write or a stat names its \
               `kind` instead. A reply is `{\"version\": 1, \"result\": …}` or `{\"version\": 1, \
               \"error\": …}`. The app sends it to the daemon where a workroom's files are: \
               this Mac's for a local workroom, which falls back to the Mac's own Git when that \
               daemon can't answer, and its host's for a remote one.",
        requests: &[
            Request {
                method: "capabilities",
                shape: "→ `{version, reads, exec}`: the read version, how many reads, and the \
                        exec service's version.",
                app: "Before anything else on a connection.",
            },
            Request {
                method: "log",
                shape: "`limit` (at most $n{MAX_HISTORY_LIMIT}) → a page of history.",
                app: "Showing a workroom's history.",
            },
            Request {
                method: "changeset",
                shape: "`revision` → one commit's files and stats.",
                app: "Selecting a commit.",
            },
            Request {
                method: "current_ref",
                shape: "→ the branch and commit checked out.",
                app: "The branch shown for the workroom.",
            },
            Request {
                method: "working_status",
                shape: "→ uncommitted changes.",
                app: "Showing a workroom's changes.",
            },
            Request {
                method: "file_diff",
                shape: "`revision`, `path` → one file's diff in a commit.",
                app: "A file's diff in a commit.",
            },
            Request {
                method: "working_file_diff",
                shape: "`path`, `base: working_copy` → one file's uncommitted diff.",
                app: "A changed file's diff.",
            },
            Request {
                method: "file_content",
                shape: "`revision`, `path` → a file's contents at a commit.",
                app: "Showing a file as it was.",
            },
            Request {
                method: "commit_parent_file_content",
                shape: "`revision`, `path` → the file in the commit's parent.",
                app: "The left side of a commit's diff.",
            },
            Request {
                method: "working_base_file_content",
                shape: "`path`, `base: working_copy` → the file at `HEAD`.",
                app: "The left side of an uncommitted diff.",
            },
            Request {
                method: "exec",
                shape: "`kind: exec`, `executable: git`, `args`, `dir`, `timeout_ms`, and \
                        optional `stdin`, `env` and `host_environment` → `stdout`, `stderr`, \
                        `exit_code`, `timed_out`, `signaled`.",
                app: "Git writes (commit, push, pull and the rest), whose output the app reads \
                      as it would a `git` it ran itself.",
            },
            Request {
                method: "stat",
                shape: "`kind: stat`, `paths` (at most $n{MAX_STAT_PATHS}), `read` → each \
                        path's `exists`, `is_dir`, `modified_at` and, for a file of at most \
                        $size{MAX_STAT_TEXT} in `read`, its `text`.",
                app: "Checking whether paths exist on a host, and reading small files there.",
            },
        ],
        request_types: &["Request", "ExecRequest", "StatRequest"],
        source: VCS_SOURCE,
        function: None,
        scrutinees: &["request.method.as_str()", "value.get(\"kind\")"],
    },
    JsonService {
        name: "File",
        wire: "JSON on the VCS service's chunked envelope, one envelope per request: \
               `{\"version\": 1, \"method\", \"root\", …}` with `path`, `symlinks`, `max_bytes` \
               and `subscription` as it needs them. Paths are relative to the repository and \
               resolved where its files are. The app sends it as it sends VCS requests, falling \
               back to reading a local workroom's files itself.",
        requests: &[
            Request {
                method: "capabilities",
                shape: "→ the service's `version`, `max_read_bytes` and `max_subscriptions`.",
                app: "Before the first file request on a connection.",
            },
            Request {
                method: "list",
                shape: "`root` → the repository's files, from a fixed `git` listing.",
                app: "Listing a workroom's files.",
            },
            Request {
                method: "read",
                shape: "`root`, `path`, optional `max_bytes`, and `symlinks`: \
                        `follow_within_root` (the file viewer: a link is followed only to a \
                        target inside the root) or `refuse` (a diff, where a link is its target's \
                        path) → one file's bytes, base64.",
                app: "Opening a file, and the files of a diff.",
            },
            Request {
                method: "resolve",
                shape: "`root`, `path` → the repository path a path with `..` or links names, \
                        resolved where the files are.",
                app: "Opening a file path clicked in a terminal.",
            },
            Request {
                method: "watch",
                shape: "`root`, `subscription` → changes, sent on stream 0 until `unwatch`.",
                app: "Refreshing what the app shows of a workroom when its files change.",
            },
            Request {
                method: "unwatch",
                shape: "`subscription` → stops it.",
                app: "Closing what watched.",
            },
        ],
        request_types: &["Request"],
        source: include_str!("../../vcs/file.rs"),
        function: None,
        scrutinees: &["request.method.as_str()"],
    },
    JsonService {
        name: "Layout",
        wire: "JSON on the chunked envelope. The daemon never parses a layout: it is the app's \
               own JSON, kept as bytes beside `serve --screens`. A daemon with no screens folder \
               keeps none and says so.",
        requests: &[
            Request {
                method: "capabilities",
                shape: "→ `{version, available, maxBlobBytes, maxKeys}`.",
                app: "Before reading a remote workroom's layout.",
            },
            Request {
                method: "get",
                shape: "`key` → `{revision, blob}`; revision 0 and no blob for a key never \
                        written.",
                app: "Opening a remote workroom.",
            },
            Request {
                method: "put",
                shape: "`key`, `expected` (the revision read), `blob` → `{revision}`, or a \
                        `stale` error with the current one.",
                app: "Saving a remote workroom's tabs and splits when they change.",
            },
        ],
        request_types: &[],
        source: include_str!("../../host/layout.rs"),
        function: Some("handle"),
        scrutinees: &["method"],
    },
    JsonService {
        name: "Forward",
        wire: "Each payload is one opcode byte, then a body: `0x01` OPEN (the JSON request, \
               once), `0x02` REPLY (`{\"version\": 1, \"result\" | \"error\"}`), `0x03` DATA \
               (the connection's bytes), `0x04` EOF (a half-close), `0x05` CLOSE (the stream is \
               done; the daemon's is always its last word on it), `0x06` ACCEPTED (a listener \
               has a connection to claim).",
        requests: &[
            Request {
                method: "open",
                shape: "`host` (a loopback address), `port` → `{opened: true}`, then DATA both \
                        ways.",
                app: "A port forwarded from a remote workroom, one stream per connection to \
                      it.",
            },
            Request {
                method: "listen",
                shape: "`port` → a listener on the host's loopback, which sends ACCEPTED per \
                        connection.",
                app: "Forwarding a port from the Mac to the host, such as Git's credential \
                      relay.",
            },
            Request {
                method: "accept",
                shape: "`listener` → claims one waiting connection on a new stream.",
                app: "Each ACCEPTED connection.",
            },
        ],
        request_types: &["Request"],
        source: include_str!("../../host/forward.rs"),
        function: Some("request"),
        scrutinees: &["request.method.as_str()"],
    },
    JsonService {
        name: "ProgramStatus",
        wire: "JSON, one envelope per request, each answered `{\"version\": 1, \"result\" | \
               \"error\"}`. Events go to stream 0, as the next section shows. What programs \
               send is OSC 7501, described in the repository's \
               [docs/program-status.md](https://github.com/joelmoss/workroom/blob/master/docs/program-status.md).",
        requests: &[
            Request {
                method: "subscribe",
                shape: "→ `{available: true}`, then the events. A daemon built without its \
                        terminal state answers `available: false`.",
                app: "On every daemon connection, for the tabs' status marks and alerts.",
            },
            Request {
                method: "unsubscribe",
                shape: "→ `{ok: true}`.",
                app: "When the app stops listening.",
            },
            Request {
                method: "seen",
                shape: "`session`, `revision`, optional `states` → drops the `done` and \
                        `error` reports shown as of `revision`.",
                app: "You looked at the pane.",
            },
            Request {
                method: "clear",
                shape: "`session` → drops every report.",
                app: "Clear Status.",
            },
        ],
        request_types: &[],
        source: PROGRAM_STATUS_SOURCE,
        function: Some("dispatch"),
        scrutinees: &["request.get(\"method\").and_then(Value::as_str)"],
    },
];

/// Who runs each of the daemon's subcommands, and when.
const SUBCOMMANDS: &[(&str, &str)] = &[
    (
        "serve",
        "The app, on the Mac when it first needs a daemon; a host's supervisor, on a host. A \
         hand-off starts the next program as `serve --handoff <table>`.",
    ),
    (
        "attach",
        "Every pane: it is what libghostty forks; with `--dial`, a remote pane's.",
    ),
    (
        "relay",
        "A host driver, on the far side of ssh or a container's exec.",
    ),
    (
        "list",
        "The app's host bootstrap, to check a host's daemon and its sessions.",
    ),
    (
        "program-status",
        "Nobody: it is for a person, to see what the app is told.",
    ),
    (
        "hand-off",
        "The app, to update a running daemon in place, on the Mac and on hosts.",
    ),
    (
        "handoff-check",
        "The daemon handing off, against the binary it would become, before it replaces \
         itself.",
    ),
    (
        "credential",
        "Git, as a local container workroom's credential helper; `credential relay` is set up \
         when the container is.",
    ),
    (
        "run-script",
        "The app, to run a remote workroom's setup and teardown scripts on its host.",
    ),
    (
        "run-supervisor",
        "The daemon: it is what a run session's pty runs around its command.",
    ),
    (
        "protocol",
        "The app, to ask a binary which protocol it speaks before using it.",
    ),
];

/// When the app runs each hidden command, by its command path (`hidden_commands`).
const HIDDEN: &[(&str, &str)] = &[
    (
        "add-project",
        "Adding a project, and with `--clone`, cloning one from a URL first.",
    ),
    (
        "claim-provisioned",
        "At launch, moving the remote workrooms a build made into its own config.",
    ),
    ("delete-project", "Removing a project."),
    (
        "host",
        "Storing or clearing a project's or a remote workroom's host descriptor.",
    ),
    (
        "include-archive",
        "Creating a remote workroom: the project's `.worktreeinclude` files, packed to copy over.",
    ),
    (
        "skill",
        "Settings ▸ AI Agents, and each host's bootstrap, to install or remove the Workroom skill.",
    ),
];

/// The usage text of `workroomd`'s subcommands, as the binary prints it.
fn usage() -> &'static str {
    let start = MAIN.find("\"usage:\n").expect("main.rs's usage text") + "\"usage:\n".len();
    let end = MAIN[start..].find("\n\"\n").expect("the usage text's end") + start;
    &MAIN[start..end]
}

/// The daemon's subcommands, as `cli::route` lists them, and `list`, which is the daemon's with
/// `--socket`.
pub(super) fn daemon_subcommands() -> Vec<String> {
    let start = ROUTE
        .find("const DAEMON_SUBCOMMANDS: &[&str] = &[")
        .expect("cli::route's DAEMON_SUBCOMMANDS");
    let end = ROUTE[start..].find("];").expect("its end") + start;
    let mut names = literals(&ROUTE[start..end]);
    names.push("list".to_string());
    names
}

/// A hidden command's flags, hidden ones included, as a table.
fn flags_table(flags: &[Flag]) -> String {
    if flags.is_empty() {
        return "No flags.\n".to_string();
    }
    let mut text = String::from(
        "| Flag | Takes a value | Required | Usage |\n| ---- | ---- | ---- | ---- |\n",
    );
    for flag in flags {
        text += &format!(
            "| `--{}` | {} | {} | {} |\n",
            flag.name,
            if flag.takes_value { "yes" } else { "" },
            if flag.required { "yes" } else { "" },
            cell(flag.usage)
        );
    }
    text
}

/// Every hidden command, at any depth, by command path (`host`, or a hidden subcommand under a
/// public command): the outermost hidden one of each branch, whose section holds those under it.
fn hidden_commands() -> Vec<(String, &'static Command)> {
    fn walk(command: &'static Command, path: String, out: &mut Vec<(String, &'static Command)>) {
        if command.hidden {
            out.push((path, command));
            return;
        }
        for sub in command.subcommands {
            walk(sub, format!("{path} {}", sub.name), out);
        }
    }
    let mut out = Vec::new();
    for command in COMMANDS {
        walk(command, command.name.to_string(), &mut out);
    }
    out
}

/// A hidden command's section at `path`, with `app` saying when the app runs it, and its
/// subcommands' below it.
fn hidden_section(command: &Command, path: &str, app: &str, sub: bool) -> String {
    let level = if sub { "####" } else { "###" };
    let mut text = format!("{level} `workroom {path}`\n\n{}.", escaped(command.short));
    if !app.is_empty() {
        text += &format!(" The app runs it for: {}", escaped(app));
    }
    text += "\n\n";
    if let Some(long) = command.long {
        text += &escaped(long);
        text += "\n\n";
    }
    // A command only a person may run says so first: under a coding agent its refusal comes
    // before `MacOnly` (#793).
    let says = (!sub)
        .then(|| super::super::needs_the_user::says(command.name))
        .flatten();
    if let Some(says) = &says {
        text += &escaped(says);
        text += "\n\n";
    }
    if !sub && command.mac_only {
        text += if says.is_some() {
            "Otherwise it runs on a Mac only.\n\n"
        } else {
            "Runs on a Mac only.\n\n"
        };
    }
    text += &format!("```text\nworkroom {}\n```\n\n", command.usage);
    // A subcommand that takes its parent's flags lists them; its parent, with none of its own, says
    // so only when it has no subcommands either.
    if !(command.flags.is_empty() && !command.subcommands.is_empty()) {
        text += &flags_table(command.flags);
        text += "\n";
    }
    for each in command.subcommands {
        text += &hidden_section(each, &format!("{path} {}", each.name), "", true);
    }
    text
}

/// The hidden flags of public commands, and their public subcommands', by command path.
fn hidden_flags() -> Vec<(String, &'static Flag)> {
    fn walk(command: &'static Command, path: &str, out: &mut Vec<(String, &'static Flag)>) {
        if command.hidden {
            return;
        }
        for flag in command.flags.iter().filter(|flag| flag.hidden) {
            out.push((path.to_string(), flag));
        }
        for sub in command.subcommands {
            walk(sub, &format!("{path} {}", sub.name), out);
        }
    }
    let mut out = Vec::new();
    for command in COMMANDS {
        walk(command, command.name, &mut out);
    }
    out
}

/// One kind of event a service sends on stream 0, and what each of its fields says. Its fields
/// are read from the code that writes it (`read`), and each needs a line here.
struct StreamEvent {
    /// Its section's heading.
    heading: &'static str,
    says: &'static str,
    read: fn() -> Vec<String>,
    fields: &'static [(&'static str, &'static str)],
}

const STREAM_EVENTS: &[StreamEvent] = &[
    StreamEvent {
        heading: "ProgramStatus `status`",
        says: "A session's records, as they are now: one per session in the snapshot that \
               follows `subscribe`, then one each time they change.",
        read: || struct_fields(PROGRAM_STATUS_SOURCE, "StatusEvent"),
        fields: &[
            ("event", "`status`."),
            ("boot", "Names the daemon's numbering of these events."),
            ("session", "The session's id."),
            (
                "revision",
                "The session's revision of its records, which `seen` names.",
            ),
            (
                "reporting",
                "Whether a program run in the session is reporting now, until its prompt, a \
                 reset or its end.",
            ),
            ("records", "Its records, each as the next table says."),
            (
                "run",
                "Only on a run session: what its supervisor last wrote, such as `running` or \
                 `exited 3`.",
            ),
        ],
    },
    StreamEvent {
        heading: "ProgramStatus `status` records",
        says: "One record of a `status` event's `records`: what one program said through OSC \
               7501, or how the shell's last long command ended.",
        read: || struct_fields(PROGRAM_STATUS_SOURCE, "WireRecord"),
        fields: &[
            (
                "id",
                "The record's id, as the program gave it; empty for its main one.",
            ),
            ("state", "`idle`, `working`, `done`, `blocked` or `error`."),
            (
                "kind",
                "What a blocked program needs: `none`, `permission`, `question` or `auth`.",
            ),
            ("progress", "Its progress in percent, or -1 for none."),
            ("app", "The program, such as `claude-code`."),
            ("title", "Its title."),
            ("message", "Its message."),
            (
                "episode",
                "Which time this record blocked, counted across the session; 0 until it first \
                 does.",
            ),
            ("notify", "Whether the app may alert for it."),
            (
                "exitCode",
                "Only on the shell command's record: the command's exit code.",
            ),
        ],
    },
    StreamEvent {
        heading: "ProgramStatus `snapshot-complete`",
        says: "The snapshot's end. Live `status` events follow.",
        read: || struct_fields(PROGRAM_STATUS_SOURCE, "SnapshotComplete"),
        fields: &[
            ("event", "`snapshot-complete`."),
            ("boot", "As `status` gives it."),
            ("sessions", "The ids of the snapshot's sessions."),
        ],
    },
    StreamEvent {
        heading: "ProgramStatus `ended`",
        says: "A session ended, and its records with it.",
        read: || struct_fields(PROGRAM_STATUS_SOURCE, "EndedEvent"),
        fields: &[
            ("event", "`ended`."),
            ("boot", "As `status` gives it."),
            ("session", "The session's id."),
        ],
    },
    StreamEvent {
        heading: "File `changed`",
        says: "Files under a watched root changed.",
        read: || json_keys(WATCH_SOURCE, "\"event\": \"changed\""),
        fields: &[
            ("event", "`changed`."),
            ("subscription", "The `watch` it belongs to."),
            ("paths", "The absolute paths that changed."),
            (
                "overflow",
                "Whether more changed than were listed, so the app reads everything again.",
            ),
        ],
    },
    StreamEvent {
        heading: "File `ended`",
        says: "A watch ended without an `unwatch`.",
        read: || json_keys(WATCH_SOURCE, "\"event\": \"ended\""),
        fields: &[
            ("event", "`ended`."),
            ("subscription", "The `watch` that ended."),
            ("reason", "Why, such as `root_removed`."),
        ],
    },
];

/// A `##` section's heading, and the line every section of this page starts with.
fn section(title: &str) -> String {
    format!("## {title}\n\n*{UNSTABLE}*\n\n")
}

/// The whole page.
pub(super) fn page() -> String {
    let mut text = front_matter(
        "Internal APIs",
        "The daemon services, frames, subcommands and hidden commands the Workroom app uses \
         beyond the terminal API, documented for anyone who finds them useful, with no promise \
         that they stay the same.",
        true,
    );
    text += "> [!WARNING]\n\
             > These are what the Workroom app uses to talk to its daemons and its CLI. They are \
             documented for anyone who finds them useful, but they are not covered by the \
             terminal API's compatibility promise, and may change in any release, without \
             notice. For anything a script or a coding agent relies on, use the [terminal \
             API](terminal-api.md), which only ever adds.\n\n\
             To notice a change, compare the protocol version and the version you built \
             against: `workroom protocol` prints the protocol that `workroom` binary speaks (a \
             daemon says its own in its greeting, below), and `workroom version` prints its \
             version. Compare the terminal API's `revision` too, which `workroom api describe` \
             shows. This page is generated from the `workroom` binary's source, so it describes \
             the build it came with.\n\n";

    text += &section("The socket");
    text += "Every daemon listens on one Unix socket. On the Mac, it is the one the app starts in \
             its Application Support folder (`<bundle>/sessions/workroomd`), or, when that path \
             is too long for a socket's name, in a folder of its own under `/tmp` \
             (`/tmp/workroom-<uid>-<bundle>`). On a host, it is the one its supervisor starts. A \
             Workroom terminal names it in `WORKROOM_DAEMON`. The socket is the only security \
             boundary: anything that can reach it can do what its user can.\n\n\
             Both sides first send a greeting, then every message is an envelope that names its \
             service and stream:\n\n\
             ```text\n\
             Hello:     \"WRA1\" | protocol_version: u16 | build_len: u8 | build: [u8]\n\
             Envelope:  service: u8 | stream: u32 | length: u32 | payload: [u8]\n\
             ```\n\n";
    text += &render(
        "Integers are big-endian, and a payload is at most $size{MAX_ENVELOPE_PAYLOAD}. Both \
         sides speak the lower of their two versions, and a client checks the daemon's own \
         version before it uses a service that arrived later, since an older daemon drops what \
         it doesn't know. This build speaks protocol $n{PROTOCOL_VERSION}. Each request opens a \
         stream of its own; a service's events, where it has any, come on stream 0.\n\n",
    );
    text += &section("Services");
    text += "| Byte | Service | Since protocol | What it is for |\n\
             | ---- | ------- | -------------- | -------------- |\n";
    for each in services() {
        let (name, since, what) = service(each);
        text += &format!(
            "| `{:#04x}` | {name} | {since} | {} |\n",
            each as u8,
            cell(what)
        );
    }

    text += "\n";
    text += &section("Terminal and Control frames");
    text += &render(
        "The Terminal and Control services carry frames: one byte of kind, a big-endian \
             `u32` length, then the payload, at most $size{MAX_PAYLOAD_SIZE}. A pane's `workroom attach` sends \
             `Attach` and then the user's typing and size; the app's own connection to each \
             daemon sends the Control frames, to list the sessions it shows as detached, close \
             one, hand the daemon off to a newer build, restart or stop a Run tab, and move a \
             session to another workroom.\n\n\
             | Byte | Frame | Direction | Since protocol | Payload | What it does |\n\
             | ---- | ----- | --------- | -------------- | ------- | ------------ |\n",
    );
    for kind in frames() {
        let (direction, since, payload, what) = frame(kind);
        text += &format!(
            "| `{:#04x}` | `{kind:?}` | {direction} | {since} | {} | {} |\n",
            kind as u8,
            cell(payload),
            cell(&render(what))
        );
    }
    text += "\n### Attach entries\n\n| Entry | What it says |\n| ----- | ------------ |\n";
    for (entry, what) in ATTACH_ENTRIES {
        text += &format!("| `{entry}` | {} |\n", cell(what));
    }
    text += "\n### Run signals\n\nThe byte a `Signal` frame carries.\n\n\
             | Byte | What it asks |\n| ---- | ------------ |\n";
    for signal in (0..=u8::MAX).filter_map(RunSignal::from_u8) {
        text += &format!("| `{}` | {} |\n", signal as u8, cell(run_signal(signal)));
    }

    text += "\n";
    text += &section("JSON services");
    for each in SERVICES {
        text += &format!("### {}\n\n{}\n\n", each.name, escaped(&render(each.wire)));
        text += "| Request | Takes and answers | When the app sends it |\n\
                 | ------- | ----------------- | --------------------- |\n";
        for request in each.requests {
            text += &format!(
                "| `{}` | {} | {} |\n",
                request.method,
                cell(&render(request.shape)),
                cell(request.app)
            );
        }
        text += "\n";
    }
    text += &section("Events on stream 0");
    text += "The ProgramStatus service sends its events to every subscribed connection, and the \
             File service its watches' changes. Each table lists an event's fields as the \
             daemon writes them.\n\n";
    for each in STREAM_EVENTS {
        text += &format!(
            "### {}\n\n{}\n\n| Field | What it says |\n| ----- | ------------ |\n",
            each.heading,
            escaped(each.says)
        );
        for field in (each.read)() {
            let says = each
                .fields
                .iter()
                .find(|(name, _)| *name == field)
                .map(|(_, says)| *says)
                .unwrap_or_else(|| {
                    panic!(
                        "{} has a field `{field}` STREAM_EVENTS doesn't describe",
                        each.heading
                    )
                });
            text += &format!("| `{field}` | {} |\n", cell(says));
        }
        text += "\n";
    }
    text += "### The terminal API, as the app uses it\n\n\
             The app makes one subscription to each daemon's [terminal API](terminal-api.md): \
             `events.subscribe` with `all: true` for `session.input` (the typing marker on a pane \
             another session types into), `session.created` and `session.ended` (what `workroom \
             new` and `workroom close` ask of the app) and `session.labelled` (tab names), and \
             `events.unsubscribe` when it stops listening. It calls `session.label` when you \
             rename a tab, and `api.describe` to learn which event types an older daemon has. \
             Those are public, and described there.\n\n";

    text += &section("The daemon's subcommands");
    text += "The same binary is the daemon. These subcommands are its own, never the CLI's \
             commands, and `list` is the daemon's only with `--socket`. On a host the binary is \
             installed as `workroomd`, the name this text uses:\n\n";
    text += &format!("```text\n{}\n```\n\n", usage());
    text += "A hand-off starts the daemon's next program in place as `serve --socket <path> \
             --handoff <table>`, the table naming the sessions it takes over; nothing else passes \
             `--handoff`.\n\n";
    text += "| Subcommand | Who runs it |\n| ---------- | ----------- |\n";
    for (name, app) in SUBCOMMANDS {
        text += &format!("| `{name}` | {} |\n", cell(app));
    }

    text += "\n";
    text += &section("Hidden commands");
    text += "The CLI has commands that `workroom --help` doesn't list, because the app runs \
             them, not people. They take `--json` and keep the [JSON output \
             contract](json-output.md) like every other command, and their kinds are in its \
             tables. Shell completion runs one more, `workroom __complete ARGS… WORD` (and \
             `__completeNoDesc`), which prints what to complete.\n\n";
    for (path, command) in hidden_commands() {
        let app = HIDDEN
            .iter()
            .find(|(name, _)| *name == path)
            .map_or("", |(_, app)| *app);
        text += &hidden_section(command, &path, app, false);
    }
    text += &section("Hidden flags");
    text += "Flags of public commands that `--help` doesn't list, because the app passes them.\n\n\
             | Command | Flag | Takes a value | Usage |\n| ------- | ---- | ---- | ----- |\n";
    for (path, flag) in hidden_flags() {
        text += &format!(
            "| `workroom {path}` | `--{}` | {} | {} |\n",
            flag.name,
            if flag.takes_value { "yes" } else { "" },
            cell(flag.usage)
        );
    }
    text
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::super::source::{arm_methods, function, match_blocks};
    use super::*;

    /// Every method a service dispatches, read from its source: each match on the method, and
    /// each comparison of the method with a name.
    fn dispatched(each: &JsonService) -> BTreeSet<String> {
        let source = match each.function {
            Some(name) => function(each.source, name),
            None => each.source,
        };
        let mut methods = BTreeSet::new();
        for scrutinee in each.scrutinees {
            let blocks = match_blocks(source, scrutinee);
            assert!(
                !blocks.is_empty(),
                "{}: no `match {scrutinee}` to read its requests from",
                each.name
            );
            for block in blocks {
                methods.extend(arm_methods(block));
            }
        }
        let comparison = regex::Regex::new(r#"method\s*==\s*(?:Some\()?"([a-z_]+)""#).unwrap();
        for found in comparison.captures_iter(source) {
            methods.insert(found[1].to_string());
        }
        methods
    }

    /// The coverage test: every request each JSON service dispatches is on the page, and every
    /// request on the page is one it dispatches, so a new one can't go undocumented.
    #[test]
    fn every_request_the_daemon_dispatches_is_documented() {
        for each in SERVICES {
            let documented: BTreeSet<String> = each
                .requests
                .iter()
                .map(|request| request.method.to_string())
                .collect();
            assert_eq!(
                dispatched(each),
                documented,
                "the {} service's requests (left, read from its source) and the internal APIs \
                 page's (right) differ: document the new one in `docs::internal::SERVICES`",
                each.name
            );
        }
    }

    /// How each service's requests are documented. A match with no wildcard, so a new service
    /// can't be added without saying where its requests are.
    enum Covered {
        /// The Terminal and Control frames, from `FrameKind`.
        Frames,
        /// A JSON service, by its name in [`SERVICES`].
        Json(&'static str),
        /// Retired: it answers every request alike.
        Retired,
        /// The terminal API, on its own page.
        Public,
    }

    fn covered(service: Service) -> Covered {
        match service {
            Service::Control | Service::Terminal => Covered::Frames,
            Service::Vcs => Covered::Json("VCS"),
            Service::File => Covered::Json("File"),
            Service::Status => Covered::Retired,
            Service::Forward => Covered::Json("Forward"),
            Service::Layout => Covered::Json("Layout"),
            Service::ProgramStatus => Covered::Json("ProgramStatus"),
            Service::TerminalApi => Covered::Public,
        }
    }

    /// Every service's requests are on a page: each JSON service has its rows in [`SERVICES`],
    /// and every entry there is one.
    #[test]
    fn every_services_requests_are_documented() {
        let mut json: Vec<&str> = Vec::new();
        for each in services() {
            match covered(each) {
                Covered::Json(name) => json.push(name),
                Covered::Frames => assert!(!frames().is_empty()),
                Covered::Retired | Covered::Public => {}
            }
        }
        let mut documented: Vec<&str> = SERVICES.iter().map(|each| each.name).collect();
        json.sort_unstable();
        documented.sort_unstable();
        assert_eq!(json, documented);
    }

    /// Every entry an Attach is read for is documented, and only those.
    #[test]
    fn every_attach_entry_is_documented() {
        let decode = function(TERMINAL_PAYLOADS, "decode");
        let keys = regex::Regex::new(r#"b"([A-Z0-9_]+)" =>"#).unwrap();
        let mut read: BTreeSet<String> = keys
            .captures_iter(decode)
            .map(|found| found[1].to_string())
            .collect();
        assert!(decode.contains("strip_prefix(b\"ENV:\")"));
        read.insert("ENV:NAME".to_string());
        let documented: BTreeSet<String> = ATTACH_ENTRIES
            .iter()
            .map(|(key, _)| key.to_string())
            .collect();
        assert_eq!(read, documented);
    }

    /// Every service and frame is a row, from its enum, and the services' and frames' bytes are
    /// the ones the wire uses.
    #[test]
    fn every_service_and_frame_is_a_row() {
        let page = page();
        assert_eq!(services().len(), 9);
        for each in services() {
            assert!(page.contains(&format!("| `{:#04x}` | {} |", each as u8, service(each).0)));
        }
        for kind in frames() {
            assert!(page.contains(&format!("| `{:#04x}` | `{kind:?}` |", kind as u8)));
        }
        assert!(page.contains("| `0x08` | Terminal API |"));
        assert!(page.contains("| `0x25` | `HandOff` |"));
    }

    /// Every one of the daemon's subcommands is in the usage text and has a row, and every row is
    /// one of them.
    #[test]
    fn every_daemon_subcommand_is_documented() {
        let names: BTreeSet<String> = daemon_subcommands().into_iter().collect();
        assert!(names.contains("serve") && names.contains("hand-off"));
        let usage = format!("\n{}\n", usage());
        for name in &names {
            assert!(
                usage.contains(&format!("\n  workroomd {name} "))
                    || usage.contains(&format!("\n  workroomd {name}\n")),
                "{name} isn't in main.rs's usage text"
            );
        }
        let documented: BTreeSet<String> = SUBCOMMANDS
            .iter()
            .map(|(name, _)| name.to_string())
            .collect();
        assert_eq!(names, documented);
    }

    /// Every hidden command has a section, with its subcommands and every flag, and says when the
    /// app runs it; every hidden flag of a public command has a row.
    #[test]
    fn every_hidden_command_and_flag_is_documented() {
        // Every command and subcommand the table holds that is hidden, or under a hidden one,
        // walked here on its own rather than through `hidden_commands`.
        fn walk(command: &Command, path: String, hidden: bool, out: &mut Vec<String>) {
            let hidden = hidden || command.hidden;
            if hidden {
                out.push(path.clone());
            }
            for sub in command.subcommands {
                walk(sub, format!("{path} {}", sub.name), hidden, out);
            }
        }
        let page = page();
        let mut every = Vec::new();
        for command in COMMANDS {
            walk(command, command.name.to_string(), false, &mut every);
        }
        for path in &every {
            assert!(
                page.contains(&format!("### `workroom {path}`\n")),
                "the hidden `workroom {path}` has no section"
            );
        }
        let outermost: BTreeSet<String> = hidden_commands()
            .into_iter()
            .map(|(path, _)| path)
            .collect();
        for name in [
            "add-project",
            "delete-project",
            "host",
            "include-archive",
            "skill",
        ] {
            assert!(outermost.contains(name), "{name}");
        }
        let documented: BTreeSet<String> =
            HIDDEN.iter().map(|(name, _)| name.to_string()).collect();
        assert_eq!(
            outermost, documented,
            "HIDDEN must say when the app runs each one"
        );
        for (_, command) in hidden_commands() {
            for flag in command
                .flags
                .iter()
                .chain(command.subcommands.iter().flat_map(|sub| sub.flags))
            {
                assert!(
                    page.contains(&format!("| `--{}` |", flag.name)),
                    "{}",
                    flag.name
                );
            }
        }
        let flags = hidden_flags();
        assert!(!flags.is_empty());
        for (path, flag) in flags {
            assert!(page.contains(&format!("| `workroom {path}` | `--{}` |", flag.name)));
        }
    }

    #[test]
    fn the_page_says_it_promises_nothing() {
        let page = page();
        assert!(page.contains(HEADER));
        assert!(page.contains("\nnightly: true\n"));
        assert!(page.contains("not covered by the terminal API's compatibility promise"));
        assert!(page.contains("may change in any release"));
    }

    /// Every `##` section starts with the line saying it is internal, so a reader who lands on
    /// one by its anchor (`json-output.md` links `#hidden-commands`) reads it first.
    #[test]
    fn every_section_says_it_is_internal() {
        let page = page();
        let sections: Vec<&str> = page.split("\n## ").skip(1).collect();
        assert!(sections.len() >= 8);
        for each in sections {
            let (heading, body) = each.split_once('\n').expect("a heading line");
            assert!(
                body.starts_with(&format!("\n*{UNSTABLE}*\n")),
                "## {heading} doesn't start with the internal line"
            );
        }
    }

    /// The words a row quotes (in code spans) are names its service's source has: a key or a
    /// string it writes or reads, a field of the types it reads requests into, or a variant (as
    /// `follow_within_root` is `FollowWithinRoot`). And every field of those types is quoted by
    /// some row or by the service's wire line, so none goes undescribed.
    #[test]
    fn every_name_a_row_quotes_is_in_its_services_source() {
        let span = regex::Regex::new(r"`([^`]*)`").unwrap();
        let word = regex::Regex::new(r"\b([a-z][A-Za-z0-9_]*)\b").unwrap();
        for each in SERVICES {
            let mut fields: Vec<String> = Vec::new();
            for name in each.request_types {
                fields.extend(struct_fields(each.source, name));
            }
            let known = |name: &str| {
                let camel: String = name
                    .split('_')
                    .map(|part| {
                        let mut chars = part.chars();
                        chars.next().map_or(String::new(), |first| {
                            first.to_ascii_uppercase().to_string() + chars.as_str()
                        })
                    })
                    .collect();
                ["true", "false", "null"].contains(&name)
                    || fields.iter().any(|field| field == name)
                    || each.source.contains(&format!("\"{name}\""))
                    || regex::Regex::new(&format!(r"\b{camel}\b"))
                        .unwrap()
                        .is_match(each.source)
            };
            let mut quoted: BTreeSet<String> = BTreeSet::new();
            for text in each
                .requests
                .iter()
                .map(|request| request.shape)
                .chain([each.wire])
            {
                for code in span.captures_iter(&render(text)) {
                    for name in word.captures_iter(&code[1]) {
                        quoted.insert(name[1].to_string());
                    }
                }
            }
            for request in each.requests {
                for code in span.captures_iter(&render(request.shape)) {
                    for name in word.captures_iter(&code[1]) {
                        assert!(
                            known(&name[1]),
                            "the {} service's `{}` row quotes `{}`, which its source doesn't have",
                            each.name,
                            request.method,
                            &name[1]
                        );
                    }
                }
            }
            for field in fields {
                if [
                    "version",
                    "method",
                    "kind",
                    "backend",
                    "shared_root",
                    "barrier_root",
                ]
                .contains(&field.as_str())
                {
                    continue;
                }
                assert!(
                    quoted.contains(&field),
                    "the {} service reads `{field}`, which no row describes",
                    each.name
                );
            }
        }
    }

    /// Every event on stream 0 is described with the fields its code writes, and only those.
    #[test]
    fn every_stream_event_is_described_with_its_fields() {
        for each in STREAM_EVENTS {
            let read: BTreeSet<String> = (each.read)().into_iter().collect();
            let described: BTreeSet<String> = each
                .fields
                .iter()
                .map(|(name, _)| name.to_string())
                .collect();
            assert_eq!(read, described, "{}", each.heading);
        }
        assert!(page().contains("| `exitCode` |"));
    }

    /// The numbers the page quotes are the constants they name.
    #[test]
    fn the_limits_are_the_constants() {
        assert_eq!(render("$n{MAX_HISTORY_LIMIT}"), "10000");
        assert_eq!(render("$size{MAX_STAT_TEXT}"), "4 KiB");
        assert_eq!(render("$size{MAX_RESPONSE}"), "16 MiB");
        assert_eq!(
            render("$s{PING_INTERVAL} and $s{SERVICE_DEADLINE}"),
            "15 s and 60 s"
        );
        let page = page();
        assert!(!page.contains("$n{") && !page.contains("$size{") && !page.contains("$s{"));
        assert!(page.contains("at most 1 MiB"));
    }
}
