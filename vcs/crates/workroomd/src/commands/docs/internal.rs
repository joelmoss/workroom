//! `reference/internal-apis.md`: everything the Mac app uses beyond the terminal API, documented
//! for anyone who finds it useful and promised to no one (ADR 0079's 2026-11-23 amendment).
//!
//! Generated where there is a registry: the services and frames from `wr_protocol`'s own enums
//! (each described by a match with no wildcard, so a new one fails to build until it is here), the
//! protocol versions from its constants, the daemon's subcommands from the binary's usage text,
//! and the hidden commands and flags from the commands table. The JSON services' methods have no
//! registry, only the `match` each service dispatches with, so their rows are written here and a
//! test reads those matches from the daemon's source and fails when a method is in one and not
//! the other ([`SERVICES`]).

use super::super::{COMMANDS, Command, Flag};
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
            "A remote workroom's repository: Git reads (history, changes, diffs, file \
             contents), `git` runs for writes, and file stats.",
        ),
        Service::File => (
            "File",
            MIN_FILE_VERSION.to_string(),
            "A remote workroom's files: listing, reading, resolving paths and watching for \
             changes.",
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
            "Says the client sends something at least every 15 s, so the daemon may close the \
             connection after 60 s of silence. Answered `Acknowledged`.",
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
               continuation and `1` for the last, and a reply is at most 16 MiB. A read is \
               `{\"version\": 1, \"root\", \"backend\": \"git\", \"method\", …}` with `limit`, \
               `revision`, `path` and `base` as it needs them; a write or a stat names its \
               `kind` instead. A reply is `{\"version\": 1, \"result\": …}` or `{\"version\": 1, \
               \"error\": …}`. The app sends it for remote workrooms; a local workroom's \
               repository is read on the Mac.",
        requests: &[
            Request {
                method: "capabilities",
                shape: "→ `{version, reads, exec}`: the read version, how many reads, and the \
                        exec service's version.",
                app: "Before anything else on a connection to a host.",
            },
            Request {
                method: "log",
                shape: "`limit` → a page of history.",
                app: "The History tab.",
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
                app: "The Changes tab.",
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
                app: "Every Git write on a remote workroom (commit, push, pull and the rest), \
                      which the app classifies as it would a local `git`.",
            },
            Request {
                method: "stat",
                shape: "`kind: stat`, `paths` (at most 64), `read` → each path's `exists`, \
                        `is_dir`, `modified_at` and, for a small file in `read`, its `text`.",
                app: "Checking files on a host, such as a project's scripts.",
            },
        ],
        source: include_str!("../../vcs/service.rs"),
        function: None,
        scrutinees: &["request.method.as_str()", "value.get(\"kind\")"],
    },
    JsonService {
        name: "File",
        wire: "JSON on the VCS service's chunked envelope, one envelope per request. Paths are \
               relative to the repository and resolved on the host.",
        requests: &[
            Request {
                method: "capabilities",
                shape: "→ the service's version and limits.",
                app: "Before the first file request on a connection.",
            },
            Request {
                method: "list",
                shape: "`root` → the repository's files, from a fixed `git` listing.",
                app: "Listing a remote workroom's files.",
            },
            Request {
                method: "read",
                shape: "`root`, `path` → one file's bytes, base64.",
                app: "Opening a file in a remote workroom.",
            },
            Request {
                method: "resolve",
                shape: "`root`, `path` → the repository path a path with `..` or links names on \
                        the host.",
                app: "Opening a file path clicked in a remote terminal.",
            },
            Request {
                method: "watch",
                shape: "`root`, `subscription` → changes, sent on stream 0 until `unwatch`.",
                app: "Refreshing what the app shows of a remote workroom when its files change.",
            },
            Request {
                method: "unwatch",
                shape: "`subscription` → stops it.",
                app: "Closing what watched.",
            },
        ],
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
        source: include_str!("../../host/forward.rs"),
        function: Some("request"),
        scrutinees: &["request.method.as_str()"],
    },
    JsonService {
        name: "ProgramStatus",
        wire: "JSON, one envelope per request, each answered `{\"version\": 1, \"result\" | \
               \"error\"}`. Events go to stream 0: one `status` per session, \
               `snapshot-complete`, then each change. What programs send is OSC 7501, \
               described in the repository's `docs/program-status.md`.",
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
        source: include_str!("../../terminal/program_status.rs"),
        function: Some("dispatch"),
        scrutinees: &["request.get(\"method\").and_then(Value::as_str)"],
    },
];

/// When the app runs each of the daemon's subcommands.
const SUBCOMMANDS: &[(&str, &str)] = &[
    (
        "serve",
        "Starts the daemon: on the Mac when it first needs one, on a host from its supervisor.",
    ),
    (
        "attach",
        "What every pane runs, which libghostty forks; with `--dial`, a remote pane's.",
    ),
    (
        "relay",
        "What a host driver runs on the far side of ssh or a container's exec.",
    ),
    (
        "list",
        "Checks a host's daemon and its sessions during bootstrap.",
    ),
    (
        "program-status",
        "Not run by the app: a way to see what it is told.",
    ),
    (
        "hand-off",
        "Updates a running daemon in place, on the Mac and on hosts.",
    ),
    (
        "handoff-check",
        "Run by the daemon handing off, against the binary it would become.",
    ),
    (
        "credential",
        "A local container's Git credential helper, and its relay.",
    ),
    (
        "run-script",
        "Runs a remote workroom's setup and teardown scripts.",
    ),
    (
        "run-supervisor",
        "What a run session's pty runs around its command.",
    ),
    (
        "protocol",
        "Asks a binary which protocol it speaks before using it.",
    ),
];

/// When the app runs each hidden command.
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
fn daemon_subcommands() -> Vec<String> {
    let start = ROUTE
        .find("const DAEMON_SUBCOMMANDS: &[&str] = &[")
        .expect("cli::route's DAEMON_SUBCOMMANDS");
    let end = ROUTE[start..].find("];").expect("its end") + start;
    let mut names = literals(&ROUTE[start..end]);
    names.push("list".to_string());
    names
}

/// Every double-quoted string in `text`.
fn literals(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('"') {
        let after = &rest[open + 1..];
        let Some(close) = after.find('"') else { break };
        out.push(after[..close].to_string());
        rest = &after[close + 1..];
    }
    out
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

/// A hidden command's section, and its subcommands'.
fn hidden_section(command: &Command, parent: Option<&Command>, app: &str) -> String {
    let path = match parent {
        Some(parent) => format!("{} {}", parent.name, command.name),
        None => command.name.to_string(),
    };
    let level = if parent.is_some() { "####" } else { "###" };
    let mut text = format!("{level} `workroom {path}`\n\n{}.", escaped(command.short));
    if !app.is_empty() {
        text += &format!(" The app runs it for: {}", escaped(app));
    }
    text += "\n\n";
    if let Some(long) = command.long {
        text += &escaped(long);
        text += "\n\n";
    }
    if parent.is_none() && command.mac_only {
        text += "Runs on a Mac only.\n\n";
    }
    text += &format!("```text\nworkroom {}\n```\n\n", command.usage);
    // A subcommand that takes its parent's flags lists them; its parent, with none of its own, says
    // so only when it has no subcommands either.
    if !(command.flags.is_empty() && !command.subcommands.is_empty()) {
        text += &flags_table(command.flags);
        text += "\n";
    }
    for sub in command.subcommands {
        text += &hidden_section(sub, Some(command), "");
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
             To notice a change, compare the daemon's protocol version (`workroom protocol` \
             prints it) and `workroom --version` with the ones you built against, and the \
             terminal API's `revision`, which `workroom api describe` shows. This page is \
             generated from the `workroom` binary's source, so it describes the build it came \
             with.\n\n";

    text += "## The socket\n\n\
             Every daemon listens on one Unix socket: on the Mac, the one the app starts in its \
             Application Support folder; on a host, the one its supervisor starts. A Workroom \
             terminal names it in `WORKROOM_DAEMON`. The socket is the only security boundary: \
             anything that can reach it can do what its user can.\n\n\
             Both sides first send a greeting, then every message is an envelope that names its \
             service and stream:\n\n\
             ```text\n\
             Hello:     \"WRA1\" | protocol_version: u16 | build_len: u8 | build: [u8]\n\
             Envelope:  service: u8 | stream: u32 | length: u32 | payload: [u8]\n\
             ```\n\n";
    text += &format!(
        "Integers are big-endian, and a payload is at most {} bytes. Both sides speak the lower \
         of their two versions, and a client checks the daemon's own version before it uses a \
         service that arrived later, since an older daemon drops what it doesn't know. This \
         build speaks protocol {PROTOCOL_VERSION}. Each request opens a stream of its own; a \
         service's events, where it has any, come on stream 0.\n\n",
        envelope::MAX_ENVELOPE_PAYLOAD
    );
    text += "## Services\n\n| Byte | Service | Since protocol | What it is for |\n\
             | ---- | ------- | -------------- | -------------- |\n";
    for each in services() {
        let (name, since, what) = service(each);
        text += &format!(
            "| `{:#04x}` | {name} | {since} | {} |\n",
            each as u8,
            cell(what)
        );
    }

    text += "\n## Terminal and Control frames\n\n\
             The Terminal and Control services carry frames: one byte of kind, a big-endian \
             `u32` length, then the payload, at most 1 MiB. A pane's `workroom attach` sends \
             `Attach` and then the user's typing and size; the app's own connection to each \
             daemon sends the Control frames, to list the sessions it shows as detached, close \
             one, hand the daemon off to a newer build, restart or stop a Run tab, and move a \
             session to another workroom.\n\n\
             | Byte | Frame | Direction | Since protocol | Payload | What it does |\n\
             | ---- | ----- | --------- | -------------- | ------- | ------------ |\n";
    for kind in frames() {
        let (direction, since, payload, what) = frame(kind);
        text += &format!(
            "| `{:#04x}` | `{kind:?}` | {direction} | {since} | {} | {} |\n",
            kind as u8,
            cell(payload),
            cell(what)
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

    text += "\n## JSON services\n\n";
    for each in SERVICES {
        text += &format!("### {}\n\n{}\n\n", each.name, escaped(each.wire));
        text += "| Request | Takes and answers | When the app sends it |\n\
                 | ------- | ----------------- | --------------------- |\n";
        for request in each.requests {
            text += &format!(
                "| `{}` | {} | {} |\n",
                request.method,
                cell(request.shape),
                cell(request.app)
            );
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

    text += "## The daemon's subcommands\n\n\
             The same binary is the daemon. These subcommands are its own, never the CLI's \
             commands, and `list` is the daemon's only with `--socket`. On a host the binary is \
             installed as `workroomd`, the name this text uses:\n\n";
    text += &format!("```text\n{}\n```\n\n", usage());
    text += "| Subcommand | When the app runs it |\n| ---------- | -------------------- |\n";
    for (name, app) in SUBCOMMANDS {
        text += &format!("| `{name}` | {} |\n", cell(app));
    }

    text += "\n## Hidden commands\n\n\
             The CLI has commands that `workroom --help` doesn't list, because the app runs \
             them, not people. They take `--json` and keep the [JSON output \
             contract](json-output.md) like every other command, and their kinds are in its \
             tables. Shell completion runs one more, `workroom __complete ARGS… WORD` (and \
             `__completeNoDesc`), which prints what to complete.\n\n";
    for command in COMMANDS.iter().filter(|command| command.hidden) {
        let app = HIDDEN
            .iter()
            .find(|(name, _)| *name == command.name)
            .map_or("", |(_, app)| *app);
        text += &hidden_section(command, None, app);
    }
    text += "## Hidden flags\n\n\
             Flags of public commands that `--help` doesn't list, because the app passes them.\n\n\
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

    use super::*;

    /// The text of the first `fn name` in `source`: from its line to the `}` that closes it, the
    /// next one indented as its line is.
    fn function<'a>(source: &'a str, name: &str) -> &'a str {
        let head = source
            .find(&format!("fn {name}("))
            .unwrap_or_else(|| panic!("no fn {name}: the test reads its requests from it"));
        let start = source[..head].rfind('\n').map_or(0, |newline| newline + 1);
        let indent: String = source[start..].chars().take_while(|c| *c == ' ').collect();
        let end = source[start..]
            .find(&format!("\n{indent}}}\n"))
            .map_or(source.len(), |end| start + end);
        &source[start..end]
    }

    /// `source` with what is no code blanked out, byte for byte, so offsets and lines stay: the
    /// insides of strings, raw strings and char literals, comments, and anything not ASCII.
    fn blanked(source: &str) -> Vec<u8> {
        let bytes = source.as_bytes();
        let mut out = bytes.to_vec();
        let blank = |out: &mut Vec<u8>, range: std::ops::Range<usize>| {
            for byte in &mut out[range] {
                if *byte != b'\n' {
                    *byte = b' ';
                }
            }
        };
        let mut index = 0;
        while index < bytes.len() {
            let rest = &source.as_bytes()[index..];
            if rest.starts_with(b"//") {
                let end = source[index..]
                    .find('\n')
                    .map_or(bytes.len(), |end| index + end);
                blank(&mut out, index..end);
                index = end;
            } else if rest.starts_with(b"r#\"") {
                let end = source[index + 3..]
                    .find("\"#")
                    .map_or(bytes.len(), |end| index + 3 + end);
                blank(&mut out, index + 3..end);
                index = end + 2;
            } else if rest[0] == b'"' {
                let mut end = index + 1;
                while end < bytes.len() && bytes[end] != b'"' {
                    end += if bytes[end] == b'\\' { 2 } else { 1 };
                }
                blank(&mut out, index + 1..end.min(bytes.len()));
                index = end + 1;
            } else if rest[0] == b'\'' && rest.get(2) == Some(&b'\'') {
                blank(&mut out, index + 1..index + 2);
                index += 3;
            } else {
                if !rest[0].is_ascii() {
                    out[index] = b' ';
                }
                index += 1;
            }
        }
        out
    }

    /// Each `match` on `scrutinee` in `source`: the text inside its braces.
    fn match_blocks<'a>(source: &'a str, scrutinee: &str) -> Vec<&'a str> {
        let code = blanked(source);
        let head = format!("match {scrutinee}");
        let mut blocks = Vec::new();
        let mut from = 0;
        while let Some(found) = source[from..].find(&head) {
            let at = from + found + head.len();
            from = at;
            // The scrutinee may go on (`.and_then(…)`): the block is the brace that ends its line.
            let line_end = source[at..].find('\n').map_or(source.len(), |end| at + end);
            let Some(open) = code[at..line_end]
                .iter()
                .rposition(|byte| *byte == b'{')
                .map(|brace| at + brace)
            else {
                continue;
            };
            let mut depth = 0usize;
            let end = (open..code.len())
                .find(|&index| {
                    match code[index] {
                        b'{' => depth += 1,
                        b'}' => depth -= 1,
                        _ => return false,
                    }
                    depth == 0
                })
                .expect("a match block ends");
            blocks.push(&source[open + 1..end]);
        }
        blocks
    }

    /// The strings an arm's pattern names, in each arm at the block's top level: the lines that
    /// start at its depth and hold `=>` in code.
    fn arm_methods(block: &str) -> Vec<String> {
        let code = blanked(block);
        let mut depth = 0i32;
        let mut methods = Vec::new();
        let mut start = 0;
        for line in block.split_inclusive('\n') {
            let line_code = &code[start..start + line.len()];
            start += line.len();
            let arrow = line_code.windows(2).position(|pair| pair == b"=>");
            if depth == 0
                && let Some(arrow) = arrow
            {
                // The pattern, without its guard (`"x" if working`), whose strings are no method.
                let pattern = line_code[..arrow]
                    .windows(4)
                    .position(|word| word == b" if ")
                    .unwrap_or(arrow);
                methods.extend(literals(&line[..pattern]));
            }
            for byte in line_code {
                match byte {
                    b'{' | b'(' | b'[' => depth += 1,
                    b'}' | b')' | b']' => depth -= 1,
                    _ => {}
                }
            }
        }
        methods
    }

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

    /// Every entry an Attach is read for is documented, and only those.
    #[test]
    fn every_attach_entry_is_documented() {
        let decode = function(TERMINAL_PAYLOADS, "decode");
        let keys = regex::Regex::new(r#"b"([A-Z]+)" =>"#).unwrap();
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
        let page = page();
        let hidden: BTreeSet<&str> = COMMANDS
            .iter()
            .filter(|command| command.hidden)
            .map(|command| command.name)
            .collect();
        for name in [
            "add-project",
            "delete-project",
            "host",
            "include-archive",
            "skill",
        ] {
            assert!(hidden.contains(name), "{name}");
        }
        let documented: BTreeSet<&str> = HIDDEN.iter().map(|(name, _)| *name).collect();
        assert_eq!(
            hidden, documented,
            "HIDDEN must say when the app runs each one"
        );
        for command in COMMANDS.iter().filter(|command| command.hidden) {
            assert!(page.contains(&format!("\n### `workroom {}`\n", command.name)));
            for flag in command.flags {
                assert!(
                    page.contains(&format!("| `--{}` |", flag.name)),
                    "{}",
                    flag.name
                );
            }
            for sub in command.subcommands {
                assert!(page.contains(&format!(
                    "\n#### `workroom {} {}`\n",
                    command.name, sub.name
                )));
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

    #[test]
    fn arms_are_read_from_a_match() {
        let source = "fn f() {\n    match request.method.as_str() {\n        \"a\" => x,\n        \
                      \"b\" if y => {\n            match z { \"inner\" => 1 }\n        }\n        \
                      _ => return Err(r#\"{\"method\": \"no\"}\"#),\n    }\n}\n";
        let blocks = match_blocks(source, "request.method.as_str()");
        assert_eq!(blocks.len(), 1);
        assert_eq!(arm_methods(blocks[0]), ["a", "b"]);
    }
}
