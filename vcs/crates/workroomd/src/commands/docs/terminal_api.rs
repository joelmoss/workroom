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
use super::{HEADER, cell, escaped, front_matter};
use crate::terminal::api::{
    METHODS, Method, REVISION, client_schema, error_schema, session_schema,
};
use crate::terminal::events::name;

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

/// A kind, with its exit code, linked to its row.
fn kind_link(code: &str) -> String {
    format!(
        "[`{code}`](json-output.md#the-terminal-apis-kinds) ({})",
        kind(code).exit_code()
    )
}

/// One method's section.
fn method_section(method: &Method) -> String {
    let mut text = format!("### `{}`\n\n{}\n\n", method.name, escaped(method.summary));
    text += "**Parameters**\n\n";
    text += &fields_table(&(method.input)());
    text += "\n**Result**\n\n";
    text += &fields_table(&(method.output)());
    text += "\n**Errors**: ";
    let mut errors: Vec<String> = method.errors.iter().map(|code| kind_link(code)).collect();
    errors.push(format!(
        "{}, which any method can return",
        kind_link("InvalidRequest")
    ));
    text += &errors.join(", ");
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
    text += "## Calling it\n\n\
             From a Workroom terminal, `workroom api call METHOD PARAMS` sends one request and \
             prints its replies. PARAMS is a JSON object inline, `@FILE` or `-` for stdin, and \
             `{}` when left out. `workroom api list` lists the methods the daemon you reach has, \
             and `workroom api describe METHOD` prints one's schemas, as on this page.\n\n\
             The daemon is the one `WORKROOM_DAEMON` names, which every Workroom terminal sets. \
             On the wire, the API is service `0x08` of the daemon's socket, from protocol 12, one \
             request per stream; the [internal APIs](internal-apis.md#the-socket) page shows the \
             framing.\n\n";
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

    /// Every event the schema names has a row, once, and every field a row lists is one the
    /// schema has and says that event carries; every field of the schema is some event's.
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
        // Every event about a session carries these, which their descriptions say so.
        let about_a_session = ["session", "scope"];
        for event in EVENTS {
            for field in event.fields {
                let schema = fields
                    .get(*field)
                    .unwrap_or_else(|| panic!("{}: the schema has no {field}", event.name));
                if about_a_session.contains(field) {
                    continue;
                }
                let says = schema["description"].as_str().unwrap_or_default();
                assert!(
                    says.contains(&format!("`{}`", event.name)),
                    "{}'s {field}: its description doesn't say the event carries it: {says}",
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
