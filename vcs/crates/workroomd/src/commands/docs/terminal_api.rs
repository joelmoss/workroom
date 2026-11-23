//! `reference/terminal-api.md`: the terminal API (ADR 0079) as `api.describe` describes it. Every
//! method's purpose, parameters, result, errors and example come from the methods table the
//! daemon serves (`terminal::api::METHODS`) and the schemas beside it, so the page can't drift from
//! a daemon built from the same source.
//!
//! What the schemas don't say is kept here, each in a small table a test holds to them: which
//! fields each event carries ([`EVENTS`]; the schema is one flat object), and the CLI command that
//! does what each method does ([`CLI`]).

use serde_json::Value;

use super::super::COMMANDS;
use super::super::kind::Kind;
use super::{HEADER, cell, escaped, front_matter, kinds};
use crate::terminal::api::{
    DISPATCH_ERRORS, METHODS, Method, REVISION, client_schema, error_schema, session_schema,
};
use crate::terminal::events::name;
use wr_protocol::envelope::MIN_TERMINAL_API_VERSION;

/// The page, under `docs-site/pages`.
pub(super) const PAGE: &str = "reference/terminal-api.md";

/// The command a method's example shows beside `api call`, by method: the one that sends the
/// same request, with the example's parameters as its flags. None where no command does.
const CLI: &[(&str, Option<&str>)] = &[
    ("api.describe", Some("workroom api describe session.list")),
    ("session.list", Some("workroom sessions --clients")),
    ("session.resolve", Some("workroom sessions \"dev server\"")),
    (
        "terminal.capture",
        Some("workroom capture \"dev server\" --lines 100 --unwrap"),
    ),
    (
        "terminal.send",
        Some("workroom send \"dev server\" \"npm test\" --enter"),
    ),
    (
        "terminal.command",
        Some("workroom command tests --timeout 10m -- npm test"),
    ),
    (
        "terminal.wait",
        Some("workroom wait \"dev server\" --regex 'ready in \\d+ ms' --timeout 30s"),
    ),
    (
        "terminal.prompt",
        Some("workroom prompt claude \"Run the tests and fix what fails\" --wait --timeout 10m"),
    ),
    (
        "session.new",
        Some("workroom new --title \"dev server\" --run \"npm run dev\" --split right"),
    ),
    (
        "session.run_control",
        Some("workroom run-control \"dev server\" restart"),
    ),
    ("session.close", Some("workroom close \"dev server\"")),
    ("session.label", None),
    (
        "events.subscribe",
        Some("workroom events --type session.program_status,session.run_state"),
    ),
    ("events.unsubscribe", None),
];

/// One kind of event `events.subscribe` streams: its name, what it says, and the fields it carries
/// beside `event`, `boot` and `revision`, which every event has.
struct Event {
    name: &'static str,
    says: &'static str,
    fields: &'static [&'static str],
}

/// Every event, in the order a stream meets them: a snapshot's, then the live ones.
const EVENTS: &[Event] = &[
    Event {
        name: name::SESSION,
        says: "One session as it is, in a snapshot.",
        fields: &[
            "session",
            "scope",
            "label",
            "title",
            "run",
            "cwd",
            "coding_agent",
            "run_state",
            "exit_code",
            "clients",
        ],
    },
    Event {
        name: name::SNAPSHOT_COMPLETE,
        says: "The snapshot's end. Live events follow.",
        fields: &["sessions", "reason"],
    },
    Event {
        name: name::RESUMED,
        says: "The subscription went on after its `since`. Live events follow.",
        fields: &[],
    },
    Event {
        name: name::PLACE,
        says: "Where a filtered stream stands, once events its filters skipped have moved it \
               on, at most once a second. Resume from it as from any event; `workroom events` \
               never prints it.",
        fields: &[],
    },
    Event {
        name: name::CREATED,
        says: "A session was created.",
        fields: &[
            "session",
            "scope",
            "label",
            "title",
            "run",
            "cwd",
            "coding_agent",
            "run_state",
            "exit_code",
            "clients",
            "opened",
        ],
    },
    Event {
        name: name::ENDED,
        says: "A session ended.",
        fields: &["session", "scope", "exit_code", "closed"],
    },
    Event {
        name: name::PROGRAM_STATUS,
        says: "Its coding agent's state, program or waiting on the user changed, or its message \
               did while it isn't working.",
        fields: &["session", "scope", "coding_agent"],
    },
    Event {
        name: name::RUN_STATE,
        says: "Its run moved to another state, passing ones included.",
        fields: &["session", "scope", "run_state", "exit_code"],
    },
    Event {
        name: name::MOVED,
        says: "It was tagged with another scope. Sent to the subscribers of both.",
        fields: &["session", "scope", "previous_scope"],
    },
    Event {
        name: name::CLIENT_ATTACHED,
        says: "A client attached to it.",
        fields: &["session", "scope", "client"],
    },
    Event {
        name: name::CLIENT_DETACHED,
        says: "A client left it. A session's end is its clients' too, with no \
               `client.detached` each.",
        fields: &["session", "scope", "client"],
    },
    Event {
        name: name::INPUT,
        says: "`terminal.send` typed into it, or a command or prompt did. Never the text.",
        fields: &["session", "scope", "sender", "bytes"],
    },
    Event {
        name: name::LABELLED,
        says: "It was given another label, by `session.label` or by its tab renamed in the app.",
        fields: &["session", "scope", "label"],
    },
];

/// The fields every event has.
const EVERY_EVENT: &[&str] = &["event", "boot", "revision"];

fn method(name: &str) -> &'static Method {
    METHODS
        .iter()
        .find(|method| method.name == name)
        .unwrap_or_else(|| panic!("no method {name}"))
}

/// What `api.describe` answers for one method, as the daemon builds it: `api.describe`'s own
/// example is the real description of `session.list`, so its `request` is the one every
/// description has (the schema of a request is no method's, so this is where it is served).
fn described() -> Value {
    (method("api.describe").result_example)()
}

/// A schema's type, as a table cell says it: the shared objects by a link to their section.
fn type_of(schema: &Value) -> String {
    if *schema == session_schema() {
        return "[session](#the-session-object)".to_string();
    }
    if *schema == client_schema() {
        return "[client](#the-client-object)".to_string();
    }
    let types: Vec<&str> = match &schema["type"] {
        Value::String(one) => vec![one.as_str()],
        Value::Array(several) => several.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    };
    if types.is_empty() {
        return "any".to_string();
    }
    types
        .iter()
        .map(|kind| match *kind {
            "array" => format!("array of {}", type_of(&schema["items"])),
            other => other.to_string(),
        })
        .collect::<Vec<_>>()
        .join(" or ")
}

/// A schema's description, with what its other keywords say: its values, default and minimum.
fn described_as(schema: &Value) -> String {
    let mut text = cell(schema["description"].as_str().unwrap_or_default());
    let mut add = |more: String| {
        if !text.is_empty() {
            text.push(' ');
        }
        text += &more;
    };
    if let Some(values) = schema["enum"].as_array() {
        let values: Vec<String> = values
            .iter()
            .map(|value| match value {
                Value::String(text) => format!("`{text}`"),
                other => format!("`{other}`"),
            })
            .collect();
        add(format!("One of {}.", values.join(", ")));
    }
    if let Some(default) = schema.get("default") {
        add(format!("Default `{default}`."));
    }
    if let Some(minimum) = schema.get("minimum") {
        add(format!("At least {minimum}."));
    }
    text
}

/// Whether a schema is an object whose fields are listed under it, as rows of their own.
fn has_fields(schema: &Value) -> bool {
    *schema != session_schema()
        && *schema != client_schema()
        && schema["properties"]
            .as_object()
            .is_some_and(|fields| !fields.is_empty())
}

/// One row per field of `schema`, its required ones first, and each nested object's fields after
/// it, named by their path (`since.boot`, `sessions[].id`).
fn field_rows(schema: &Value, prefix: &str, out: &mut String) {
    let Some(fields) = schema["properties"].as_object() else {
        return;
    };
    let required: Vec<&str> = schema["required"]
        .as_array()
        .map(|names| names.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mut names: Vec<&String> = fields.keys().collect();
    names.sort_by_key(|name| (!required.contains(&name.as_str()), name.as_str()));
    for name in names {
        let field = &fields[name.as_str()];
        let path = format!("{prefix}{name}");
        let needed = if required.contains(&name.as_str()) {
            "yes"
        } else {
            ""
        };
        *out += &format!(
            "| `{path}` | {} | {needed} | {} |\n",
            cell(&type_of(field)),
            described_as(field)
        );
        if has_fields(field) {
            field_rows(field, &format!("{path}."), out);
        } else if has_fields(&field["items"]) {
            field_rows(&field["items"], &format!("{path}[]."), out);
        }
    }
}

/// A table of `schema`'s fields, or a line saying it has none.
fn fields_table(schema: &Value) -> String {
    let mut rows = String::new();
    field_rows(schema, "", &mut rows);
    if rows.is_empty() {
        return "None.\n".to_string();
    }
    format!(
        "| Field | Type | Required | Description |\n| ----- | ---- | -------- | ----------- |\n{rows}"
    )
}

/// `value` as a JSON block.
fn json_block(value: &Value) -> String {
    format!(
        "```json\n{}\n```\n",
        serde_json::to_string_pretty(value).expect("JSON")
    )
}

/// A word for a POSIX shell, single-quoted.
fn quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// The kind `code` names; every code a method lists is the registry's.
fn kind(code: &str) -> Kind {
    let kind = Kind::from_code(code);
    assert_eq!(kind.code(), code, "{code} is no kind in the registry");
    kind
}

/// A kind, with its exit code, linked to the table of `json-output.md` its row is in.
fn kind_link(code: &str) -> String {
    let kind = kind(code);
    let (table, _) = kind.documented();
    format!(
        "[`{code}`](json-output.md#{}) ({})",
        kinds::anchor(table),
        kind.exit_code()
    )
}

/// The kinds any method can reply with, linked, as `dispatch` replies with them.
fn dispatch_errors() -> String {
    DISPATCH_ERRORS
        .iter()
        .map(|code| kind_link(code))
        .collect::<Vec<_>>()
        .join(", ")
}

/// One method's section.
fn method_section(method: &Method) -> String {
    let mut text = format!("### `{}`\n\n{}\n\n", method.name, escaped(method.summary));
    text += "**Parameters**\n\n";
    text += &fields_table(&(method.input)());
    text += "\n**Result**\n\n";
    text += &fields_table(&(method.output)());
    text += "\n**Errors**: ";
    let own: Vec<String> = method
        .errors
        .iter()
        .filter(|code| !DISPATCH_ERRORS.contains(code))
        .map(|code| kind_link(code))
        .collect();
    if !own.is_empty() {
        text += &own.join(", ");
        text += ", and ";
    }
    text += &format!("{}, which any method can return", dispatch_errors());
    text += ".\n\n**Example**\n\n```sh\n";
    let params = (method.params_example)();
    text += &format!(
        "workroom api call {} {}\n```\n\n",
        method.name,
        quoted(&serde_json::to_string(&params).expect("JSON"))
    );
    if let Some(Some(cli)) = CLI
        .iter()
        .find(|(name, _)| *name == method.name)
        .map(|(_, cli)| cli)
    {
        text += &format!("The same request as a command:\n\n```sh\n{cli}\n```\n\n");
    }
    let mut result = (method.result_example)();
    if method.name == "api.describe" {
        // The schemas it holds are this page's sections, so they are left out here.
        text += "Its `result`, with the schemas it holds left out (`…`): they are what this \
                 page shows for each method, for the error and for a request.\n\n";
        for key in ["error_schema", "request"] {
            result[key] = Value::from("…");
        }
        for each in result["methods"].as_array_mut().into_iter().flatten() {
            for key in ["input", "output"] {
                each[key] = Value::from("…");
            }
        }
    } else {
        text += "Its `result`:\n\n";
    }
    text += &json_block(&result);
    text += "\n";
    text
}

/// The events' section: each kind of event and what it carries, then every field.
fn events_section() -> String {
    let output = (method("events.subscribe").output)();
    let mut text = String::from(
        "## Events\n\n`events.subscribe` streams the daemon's events, one per reply, each \
         reply's `more` true: the sessions as they are (a `session` event each, then \
         `snapshot-complete`), or `resumed` when its `since` names a place the daemon still \
         holds, then live events as they happen. `types` keeps to some live events. Every \
         event has `event`, `boot` and `revision`. Ignore an `event` you don't know: later \
         revisions add more.\n\n### Event types\n\n| `event` | Live | What it says | \
         Fields |\n| ------- | ---- | ------------ | ------ |\n",
    );
    for event in EVENTS {
        let live = if name::LIVE.contains(&event.name) {
            "yes"
        } else {
            ""
        };
        let fields: Vec<String> = event
            .fields
            .iter()
            .map(|field| format!("`{field}`"))
            .collect();
        let fields = if fields.is_empty() {
            "none beside the three".to_string()
        } else {
            fields.join(", ")
        };
        text += &format!(
            "| `{}` | {live} | {} | {fields} |\n",
            event.name,
            cell(event.says)
        );
    }
    text += "\n### Event fields\n\n";
    text += &fields_table(&output);
    text += "\nSome events, as the daemon's schema gives them:\n\n";
    let mut examples = vec![(method("events.subscribe").result_example)()];
    if let Some(Value::Array(more)) = output.get("examples") {
        examples.extend(more.iter().cloned());
    }
    for example in &examples {
        text += &format!(
            "```json\n{}\n```\n\n",
            serde_json::to_string(example).expect("JSON")
        );
    }
    text += "### Resuming, gaps and lagging\n\n\
             Each live event takes the next `revision` of the daemon's events under its `boot`, \
             which a hand-off keeps and a daemon started afresh replaces. Keep the `boot` and \
             `revision` of the last event you read (a live event's, a `place`'s, or a snapshot's \
             end) and subscribe again with `since: {boot, revision}`. When the daemon still holds \
             every event after it, it answers `resumed` and sends them: nothing missed, nothing \
             twice. When it can't, because it is another boot or the place is older than it \
             keeps, it sends the sessions afresh, with `snapshot-complete`'s `reason` `gap`. A \
             subscriber that falls further behind than the daemon keeps is sent the sessions \
             afresh too, `reason` `lagged`, and goes on live. After either, the snapshot replaces \
             what you knew.\n\n";
    text
}

/// The whole page.
pub(super) fn page() -> String {
    let described = described();
    let mut text = front_matter(
        "Terminal API",
        "Every method of the terminal API, with its parameters, result, errors and an example, \
         every event it streams, and how its requests and replies are shaped.",
        true,
    );
    text += &format!(
        "The terminal API is the daemon's public JSON service: what the `workroom` commands that \
         drive terminals call, and what a script or coding agent can call itself with \
         `workroom api call`. This page is generated from the methods and schemas the daemon \
         serves, the ones `workroom api describe` shows. It describes revision {REVISION}.\n\n\
         The API is a stable contract: a release only ever adds methods and fields, and never \
         removes, renames or changes the meaning of one. `revision`, in every reply, counts the \
         additions, so check it when you need one. Every method and field on this page arrived \
         in revision 1, the first. The daemon serves the same API on your Mac and on every \
         remote host.\n\n\
         To see how to use it, read [Drive terminals from agents and \
         scripts](../guides/drive-terminals-from-agents-and-scripts.md). For the kinds a failure \
         can have, read [JSON output and exit codes](json-output.md#the-terminal-apis-kinds). \
         The Mac app also uses [internal APIs](internal-apis.md), which carry no such \
         promise.\n\n"
    );
    text += &format!(
        "## Calling it\n\n\
         From a Workroom terminal, `workroom api call METHOD PARAMS` sends one request and \
         prints its replies. PARAMS is a JSON object inline, `@FILE` or `-` for stdin, and \
         `{{}}` when left out. `workroom api list` lists the methods the daemon you reach has, \
         and `workroom api describe METHOD` prints one's schemas, as on this page.\n\n\
         The daemon is the one `WORKROOM_DAEMON` names, which every Workroom terminal sets. \
         On the wire, the API is service `{:#04x}` of the daemon's socket, from protocol \
         {MIN_TERMINAL_API_VERSION}, one request per stream; the [internal \
         APIs](internal-apis.md#the-socket) page shows the framing.\n\n\
         Any method can fail with {}: a request the daemon can't read, a request or a reply \
         over the limit, or a method that broke off.\n\n",
        wr_protocol::envelope::Service::TerminalApi as u8,
        dispatch_errors()
    );
    text += "## Requests and replies\n\nA request:\n\n";
    text += &fields_table(&described["request"]);
    text += "\nA reply is one of:\n\n\
             | Field | Type | Description |\n| ----- | ---- | ----------- |\n\
             | `revision` | integer | The API's revision, in every reply. |\n\
             | `result` | object | What the method answers, as its section below says. Not in a \
             failed reply. |\n\
             | `error` | object | Why it failed, below. Only in a failed reply. |\n\
             | `more` | boolean | `true` when another reply follows on the stream, `false` on the \
             last. A reply without it is the last. |\n\n\
             Read replies until `more` is false, whatever the method: any method may answer in \
             several parts. An error is always a stream's last reply. `workroom api call` prints \
             each reply as it comes, one envelope per line with `--json`.\n\n\
             ### The error\n\n";
    let error = error_schema();
    text += &fields_table(&error);
    text += "\nBranch on `kind`, never on `message`. For example:\n\n";
    if let Some(Value::Array(examples)) = error.get("examples") {
        for example in examples {
            text += &format!(
                "```json\n{}\n```\n\n",
                serde_json::to_string(example).expect("JSON")
            );
        }
    }
    text += "### Targets and the caller\n\n\
             A `target` names one session: by its full id, then an id suffix of at least 4 \
             characters, then its label, then its live title. At the first of those with any \
             match, more than one match is `TargetAmbiguous`, which lists them in `matches`, and \
             nothing happens. `session.close` never takes a live title.\n\n\
             The caller is the session a request comes from: the one whose shell the connecting \
             process descends from, else the session the request's `caller` names. Results that \
             depend on it say which they found, as `caller`. `session.list` and \
             `events.subscribe` keep to the caller's scope (its workroom) by default.\n\n";
    text += "## Methods\n\n";
    for method in METHODS {
        text += &method_section(method);
    }
    text += &events_section();
    text += "## Shared objects\n\n### The session object\n\n\
             How every reply that lists sessions gives one.\n\n";
    text += &fields_table(&session_schema());
    text += "\n### The client object\n\n\
             A client attached to a session, as `session.list` and `session.resolve` give it \
             with `clients: true`.\n\n";
    text += &fields_table(&client_schema());
    text
}

#[cfg(test)]
mod tests {
    use super::super::super::Command;
    use super::*;

    /// Every method has an entry in [`CLI`], once, and each command it names is a public command
    /// whose flags it uses are its own: the examples run.
    #[test]
    fn every_methods_command_is_a_real_one() {
        for method in METHODS {
            assert_eq!(
                CLI.iter().filter(|(name, _)| *name == method.name).count(),
                1,
                "{} needs one entry in CLI",
                method.name
            );
        }
        for (name, cli) in CLI {
            assert!(METHODS.iter().any(|method| method.name == *name), "{name}");
            let Some(cli) = cli else { continue };
            let words: Vec<&str> = cli.split_whitespace().collect();
            assert_eq!(words[0], "workroom", "{cli}");
            let mut command: &Command = COMMANDS
                .iter()
                .find(|command| command.name == words[1])
                .unwrap_or_else(|| panic!("{cli}: no command {}", words[1]));
            if let Some(sub) = words
                .get(2)
                .and_then(|word| command.subcommands.iter().find(|sub| sub.name == *word))
            {
                command = sub;
            }
            assert!(!command.hidden, "{cli}");
            for word in words.iter().take_while(|word| **word != "--") {
                if let Some(flag) = word.strip_prefix("--") {
                    assert!(
                        command.flags.iter().any(|known| known.name == flag),
                        "{cli}: `{}` has no --{flag}",
                        command.name
                    );
                }
            }
        }
    }

    /// Where a method's parameter comes from on its command's line.
    enum From {
        /// The nth word that is no flag.
        Word(usize),
        /// The words from the nth on, joined with spaces (`command`'s COMMAND).
        Rest(usize),
        /// A flag's value, as the parameter's type reads it.
        Flag(&'static str),
        /// A duration flag, in milliseconds (`timeout_ms`).
        Millis(&'static str),
        /// A comma-separated flag, as a list (`events --type`).
        List(&'static str),
    }

    /// How each command in [`CLI`] makes its method's parameters, for the test that holds each
    /// example to the request it shows.
    const PARAMS: &[(&str, &[(&str, From)])] = &[
        ("api.describe", &[("method", From::Word(0))]),
        (
            "session.list",
            &[
                ("all", From::Flag("all")),
                ("clients", From::Flag("clients")),
            ],
        ),
        ("session.resolve", &[("target", From::Word(0))]),
        (
            "terminal.capture",
            &[
                ("target", From::Word(0)),
                ("lines", From::Flag("lines")),
                ("unwrap", From::Flag("unwrap")),
            ],
        ),
        (
            "terminal.send",
            &[
                ("target", From::Word(0)),
                ("text", From::Word(1)),
                ("enter", From::Flag("enter")),
            ],
        ),
        (
            "terminal.command",
            &[
                ("target", From::Word(0)),
                ("command", From::Rest(1)),
                ("timeout_ms", From::Millis("timeout")),
            ],
        ),
        (
            "terminal.wait",
            &[
                ("target", From::Word(0)),
                ("regex", From::Flag("regex")),
                ("timeout_ms", From::Millis("timeout")),
            ],
        ),
        (
            "terminal.prompt",
            &[
                ("target", From::Word(0)),
                ("text", From::Word(1)),
                ("wait", From::Flag("wait")),
                ("timeout_ms", From::Millis("timeout")),
            ],
        ),
        (
            "session.new",
            &[
                ("title", From::Flag("title")),
                ("run", From::Flag("run")),
                ("split", From::Flag("split")),
            ],
        ),
        (
            "session.run_control",
            &[("target", From::Word(0)), ("action", From::Word(1))],
        ),
        ("session.close", &[("target", From::Word(0))]),
        ("events.subscribe", &[("types", From::List("type"))]),
    ];

    /// Each example's command, read as the CLI reads it, sends the parameters the `api call`
    /// beside it shows: the two are one request.
    #[test]
    fn every_command_example_sends_its_methods_params() {
        use super::super::super::{find_in, parse, wait::parse_duration};
        use super::super::source::shell_words;
        for (method_name, cli) in CLI {
            let Some(cli) = cli else { continue };
            let words = shell_words(cli);
            let mut command = find_in(COMMANDS, &words[1]).expect("a command");
            let mut rest = &words[2..];
            if let Some(sub) = rest
                .first()
                .and_then(|word| find_in(command.subcommands, word))
            {
                command = sub;
                rest = &rest[1..];
            }
            let (parsed, error) = parse(rest, command.flags);
            assert_eq!(error, None, "{cli}");
            let flag = |name: &str| {
                parsed
                    .values
                    .iter()
                    .find(|(flag, _)| *flag == name)
                    .map(|(_, value)| value.clone())
            };
            let example = (method(method_name).params_example)();
            let (_, map) = PARAMS
                .iter()
                .find(|(name, _)| name == method_name)
                .unwrap_or_else(|| panic!("{method_name} needs its PARAMS"));
            let mut sent = serde_json::Map::new();
            for (param, from) in *map {
                let text = match from {
                    From::Word(at) => parsed.positional.get(*at).cloned(),
                    From::Rest(at) => {
                        (parsed.positional.len() > *at).then(|| parsed.positional[*at..].join(" "))
                    }
                    From::Flag(name) | From::Millis(name) | From::List(name) => flag(name),
                };
                let Some(text) = text else { continue };
                let value = match (from, &example[*param]) {
                    (From::Millis(_), _) => {
                        Value::from(parse_duration(&text).expect("a duration").as_millis() as u64)
                    }
                    (From::List(_), _) => {
                        Value::from(text.split(',').map(str::to_string).collect::<Vec<_>>())
                    }
                    (_, Value::Bool(_)) => Value::from(text == "true"),
                    (_, Value::Number(_)) => Value::from(text.parse::<u64>().expect("a number")),
                    _ => Value::from(text),
                };
                sent.insert(param.to_string(), value);
            }
            let mut asked = example.as_object().expect("params").clone();
            // A false boolean is what leaving its flag out sends.
            asked.retain(|_, value| *value != Value::Bool(false));
            assert_eq!(
                Value::Object(sent),
                Value::Object(asked),
                "{method_name}: `{cli}` and its `api call` example ask different things"
            );
        }
    }

    /// The source each method's handler is, for the test that holds its kinds to its declared
    /// list: functions of a module, or all of it.
    const HANDLERS: &[(&str, &str, &[&str])] = &[
        ("api.describe", API_SOURCE, &["describe", "description"]),
        ("session.list", API_SOURCE, &["listing", "in_scope_of"]),
        ("session.resolve", API_SOURCE, &["resolve"]),
        ("terminal.capture", API_SOURCE, &["capture"]),
        (
            "terminal.send",
            include_str!("../../terminal/api/send.rs"),
            &[],
        ),
        (
            "terminal.command",
            include_str!("../../terminal/api/command.rs"),
            &[],
        ),
        (
            "terminal.wait",
            include_str!("../../terminal/api/wait.rs"),
            &[],
        ),
        (
            "terminal.prompt",
            include_str!("../../terminal/api/prompt.rs"),
            &[],
        ),
        ("session.new", LIFECYCLE_SOURCE, &["create"]),
        ("session.run_control", LIFECYCLE_SOURCE, &["run_control"]),
        ("session.close", LIFECYCLE_SOURCE, &["close"]),
        ("session.label", LIFECYCLE_SOURCE, &["label"]),
        ("events.subscribe", EVENTS_SOURCE, &[]),
        ("events.unsubscribe", EVENTS_SOURCE, &["unsubscribe"]),
    ];

    const API_SOURCE: &str = include_str!("../../terminal/api.rs");
    const LIFECYCLE_SOURCE: &str = include_str!("../../terminal/api/lifecycle.rs");
    const EVENTS_SOURCE: &str = include_str!("../../terminal/api/events.rs");

    /// The kinds `source` names, in `functions` of it or all of it.
    fn kinds_of(source: &str, functions: &[&str]) -> Vec<String> {
        use super::super::source::{function, kinds_in};
        if functions.is_empty() {
            return kinds_in(source);
        }
        functions
            .iter()
            .flat_map(|name| kinds_in(function(source, name)))
            .collect()
    }

    /// Every kind a method's handler replies with is one it declares, or one any method can: so
    /// `api.describe`, and this page, never leave out a kind it can return. A module that serves
    /// several methods is held, as a whole, to what they declare together.
    #[test]
    fn every_kind_a_handler_replies_with_is_declared() {
        let declared = |name: &str| -> Vec<&str> {
            method(name)
                .errors
                .iter()
                .chain(DISPATCH_ERRORS)
                .copied()
                .collect()
        };
        for method_entry in METHODS {
            assert!(
                HANDLERS
                    .iter()
                    .any(|(name, _, _)| *name == method_entry.name),
                "{} needs its HANDLERS entry",
                method_entry.name
            );
        }
        for (name, source, functions) in HANDLERS {
            for code in kinds_of(source, functions) {
                kind(&code);
                assert!(
                    declared(name).contains(&code.as_str()),
                    "{name}'s handler replies with {code}, which its errors don't list"
                );
            }
        }
        for module in [LIFECYCLE_SOURCE, EVENTS_SOURCE] {
            let together: Vec<&str> = HANDLERS
                .iter()
                .filter(|(_, source, _)| *source == module)
                .flat_map(|(name, _, _)| declared(name))
                .collect();
            for code in kinds_of(module, &[]) {
                assert!(together.contains(&code.as_str()), "{code}");
            }
        }
        assert!(method("session.new").errors.contains(&"SessionEnded"));
    }

    /// What `dispatch` itself replies with, whatever the method, is `DISPATCH_ERRORS`.
    #[test]
    fn the_kinds_any_method_can_return_are_dispatchs() {
        let found = kinds_of(API_SOURCE, &["dispatch", "send", "stream"]);
        assert!(found.contains(&"TooLarge".to_string()));
        for code in found {
            assert!(DISPATCH_ERRORS.contains(&code.as_str()), "{code}");
        }
    }

    /// Every kind the page links goes to the table of `json-output.md` that has its row.
    #[test]
    fn every_kind_link_reaches_its_row() {
        let path = super::super::site_pages_dir().join(kinds::PAGE);
        let Ok(json_output) = std::fs::read_to_string(&path) else {
            eprintln!(
                "no {}, so the kind links aren't checked here",
                path.display()
            );
            return;
        };
        let json_output = kinds::spliced(&json_output).expect("its markers");
        let anchor = |heading: &str| -> String {
            heading
                .trim_start_matches('#')
                .trim()
                .trim_end_matches(" {nightly}")
                .to_lowercase()
                .chars()
                .filter(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '_'))
                .collect::<String>()
                .replace(' ', "-")
        };
        let link = regex::Regex::new(r"\[`([A-Za-z]+)`\]\(json-output\.md#([a-z-]+)\)").unwrap();
        let page = page();
        let mut seen = 0;
        for found in link.captures_iter(&page) {
            seen += 1;
            let (code, target) = (&found[1], &found[2]);
            let lines: Vec<&str> = json_output.lines().collect();
            let start = lines
                .iter()
                .position(|line| line.starts_with('#') && anchor(line) == target)
                .unwrap_or_else(|| panic!("json-output.md has no #{target}"));
            // Up to the next heading of any level: the table directly under the one linked.
            let section: Vec<&str> = lines[start + 1..]
                .iter()
                .take_while(|line| !line.starts_with('#'))
                .copied()
                .collect();
            assert!(
                section
                    .iter()
                    .any(|line| line.starts_with(&format!("| `{code}` |"))),
                "{code}'s link goes to #{target}, which has no row for it"
            );
        }
        assert!(seen > 20);
    }

    /// Every event the schema names has a row, once, and every field a row lists is one the
    /// schema has; every field of the schema is some event's.
    #[test]
    fn every_event_is_described_with_its_fields() {
        let output = (method("events.subscribe").output)();
        let named: Vec<&str> = output["properties"]["event"]["enum"]
            .as_array()
            .expect("the events' names")
            .iter()
            .filter_map(Value::as_str)
            .collect();
        let mut listed: Vec<&str> = EVENTS.iter().map(|event| event.name).collect();
        let mut sorted = named.clone();
        sorted.sort_unstable();
        listed.sort_unstable();
        assert_eq!(
            listed, sorted,
            "EVENTS must list every event the schema names, once"
        );
        let fields = output["properties"].as_object().expect("fields");
        for event in EVENTS {
            for field in event.fields {
                assert!(
                    fields.contains_key(*field),
                    "{}: the schema has no {field}",
                    event.name
                );
            }
        }
        for field in fields.keys() {
            assert!(
                EVERY_EVENT.contains(&field.as_str())
                    || EVENTS
                        .iter()
                        .any(|event| event.fields.contains(&field.as_str())),
                "no event carries {field}"
            );
        }
        for live in name::LIVE {
            assert!(named.contains(&live), "{live}");
        }
    }

    /// Each event's fields, as the code that sends it writes it: every live one through the hub
    /// that publishes it, a snapshot's `session` through `session_event`, and the three the
    /// subscription writes itself read from its `json!`. Each is exactly `EVERY_EVENT` and the
    /// fields its row lists.
    #[test]
    fn every_event_carries_the_fields_its_row_lists() {
        use crate::terminal::events::{Cursor, Hub, Next, Start, session_event};
        use crate::terminal::session::SessionId;
        use std::collections::BTreeSet;

        let id = SessionId([7; 16]);
        let listing = serde_json::json!({
            "id": id.to_hyphenated(),
            "label": "server",
            "title": null,
            "scope": {"kind": "workroom", "id": "wr-1"},
            "run": true,
            "cwd": "/tmp",
            "coding_agent": null,
        });
        let client = serde_json::json!({
            "id": 1, "kind": "pane", "hostname": "mac", "attached_at_ms": 1,
        });
        let hub = Hub::default();
        let mut cursor = Cursor::new(Start::Fresh);
        let Next::Snapshot { .. } = hub.next(&mut cursor, &|| false) else {
            panic!("a snapshot first");
        };
        hub.created(id, listing.clone());
        hub.client_attached(id, client);
        hub.client_detached(1);
        hub.program_status(
            id,
            serde_json::json!({"state": "working", "app": "claude", "message": "m",
                               "waiting_on_user": false}),
        );
        hub.run(id, "running", None);
        hub.rescoped(id, serde_json::json!({"kind": "workroom", "id": "wr-2"}));
        hub.labelled(id, Some("web"));
        assert!(hub.input(id, Value::Null, None, 3));
        hub.ended(id, Some(0));

        let mut sent: Vec<Value> = Vec::new();
        match hub.next(&mut cursor, &|| false) {
            Next::Events(events) => sent.extend(events.iter().map(|event| event.json.clone())),
            other => panic!("not events: {other:?}"),
        }
        // A snapshot's session, with the hub's place stamped on it as the subscription does.
        let snapshot_hub = Hub::default();
        snapshot_hub.created(id, listing);
        let mut cursor = Cursor::new(Start::Fresh);
        let Next::Snapshot { sessions, .. } = snapshot_hub.next(&mut cursor, &|| false) else {
            panic!("a snapshot");
        };
        let mut session = session_event(name::SESSION, id, &sessions[&id]);
        session["boot"] = Value::Null;
        session["revision"] = Value::Null;
        sent.push(session);

        let mut keys: Vec<(String, BTreeSet<String>)> = sent
            .iter()
            .map(|event| {
                let keys = event
                    .as_object()
                    .expect("an object")
                    .keys()
                    .cloned()
                    .collect();
                (event["event"].as_str().expect("a name").to_string(), keys)
            })
            .collect();
        // The subscription writes these itself: `snapshot-complete` where it sends a snapshot,
        // `resumed` and `place` where it streams.
        let subscription = include_str!("../../terminal/api/events.rs");
        use super::super::source::{function, json_keys};
        for (written, writer, constant) in [
            (name::SNAPSHOT_COMPLETE, "snapshot", "SNAPSHOT_COMPLETE"),
            (name::RESUMED, "start", "RESUMED"),
            (name::PLACE, "start", "PLACE"),
        ] {
            let found = json_keys(
                function(subscription, writer),
                &format!("\"event\": name::{constant},"),
            );
            keys.push((written.to_string(), found.into_iter().collect()));
        }
        for event in EVENTS {
            let want: BTreeSet<String> = EVERY_EVENT
                .iter()
                .chain(event.fields)
                .map(|field| field.to_string())
                .collect();
            let have = keys
                .iter()
                .find(|(name, _)| name == event.name)
                .unwrap_or_else(|| panic!("no {} was sent", event.name));
            assert_eq!(
                have.1, want,
                "{}: its fields as sent, and as EVENTS lists them",
                event.name
            );
        }
    }

    /// The page says every method and field arrived in revision 1, which is true only while the
    /// API is at it. A release that raises the revision records, beside each addition here, the
    /// revision it arrived in.
    #[test]
    fn every_method_arrived_in_the_first_revision() {
        assert_eq!(
            REVISION, 1,
            "the terminal API's reference says every method and field arrived in revision 1: \
             say on the page which revision each addition arrived in"
        );
    }

    /// The commands of the terminal API run anywhere a daemon does, as the page says.
    #[test]
    fn no_terminal_api_command_is_mac_only() {
        for (_, cli) in CLI {
            let Some(cli) = cli else { continue };
            let word = cli.split_whitespace().nth(1).expect("a command");
            let command = COMMANDS
                .iter()
                .find(|command| command.name == word)
                .expect("a command");
            assert!(!command.mac_only, "{word}");
        }
    }

    /// Each method has its section, with its errors and example, and the page has the envelope,
    /// the events and the shared objects.
    #[test]
    fn the_page_describes_every_method() {
        let page = page();
        assert!(page.contains(HEADER));
        assert!(page.contains("\nnightly: true\n"));
        for method in METHODS {
            assert!(
                page.contains(&format!("\n### `{}`\n", method.name)),
                "{}",
                method.name
            );
            assert!(
                page.contains(&format!("workroom api call {} '", method.name)),
                "{}",
                method.name
            );
            for code in method.errors {
                assert!(page.contains(&format!("[`{code}`]")), "{code}");
            }
        }
        for event in EVENTS {
            assert!(
                page.contains(&format!("| `{}` |", event.name)),
                "{}",
                event.name
            );
        }
        assert!(page.contains("| `since.boot` |"), "nested fields get rows");
        assert!(page.contains("\n### The session object\n"));
        assert!(page.contains("| `caller` |"));
    }

    #[test]
    fn type_names_link_the_shared_objects() {
        let sessions = serde_json::json!({"type": "array", "items": session_schema()});
        assert_eq!(
            type_of(&sessions),
            "array of [session](#the-session-object)"
        );
        assert_eq!(
            type_of(&serde_json::json!({"type": ["string", "null"]})),
            "string or null"
        );
        assert_eq!(quoted("it's"), r"'it'\''s'");
    }
}
