//! `workroom sessions [TARGET] [--all]`: the daemon's sessions, from the terminal API's
//! `session.list`, or the one `TARGET` names (`session.resolve`). The listing keeps to the
//! caller's scope (its workroom) unless `--all` widens it to every session; from no pane, or from
//! one with no scope, it is every session. A target resolves across every session either way.
//! With `--json`, one envelope with `sessions`, each in the API's own shape, and `caller`, the id
//! of the pane it ran in (null for none); without, a table. `--clients` adds each session's
//! attached clients (#688): `clients` in each session with `--json`, and in the table, a row for
//! each under its session's. A daemon too old to list them is `DaemonTooOld`.

use serde::Serialize;
use serde_json::{Value, json};

use super::kind::CliError;
use super::{Args, Context, Outcome, terminal_api};

#[derive(Serialize)]
struct Payload {
    sessions: Vec<Value>,
    caller: Value,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let all = args.is_set("all");
    // Asked for only when wanted, so a daemon's reply to a plain `sessions` keeps its shape.
    let with_clients = |mut params: Value| {
        if args.is_set("clients") {
            params["clients"] = json!(true);
        }
        params
    };
    let reply = match args.positional.as_slice() {
        [] => terminal_api::call(context, "session.list", with_clients(json!({"all": all}))).map(
            |result| {
                let sessions = result["sessions"].as_array().cloned().unwrap_or_default();
                (sessions, result["caller"].clone())
            },
        ),
        [target] => terminal_api::call(
            context,
            "session.resolve",
            with_clients(json!({"target": target})),
        )
        .map(|result| (vec![result["session"].clone()], result["caller"].clone())),
        // One TARGET at most. Go checks that before the command runs, so the envelope names no
        // command.
        [_, extra, ..] => {
            return Outcome::Usage(CliError::internal(format!(
                "unknown command {extra:?} for \"workroom sessions\""
            )));
        }
    };
    let reply = reply.and_then(|(sessions, caller)| {
        if args.is_set("clients") {
            listed_clients(&sessions)?;
        }
        Ok((sessions, caller))
    });
    match reply {
        Err(error) => Outcome::Failed(error),
        Ok((sessions, caller)) if context.json => Outcome::Success(super::envelope::success(
            "sessions",
            &Payload { sessions, caller },
        )),
        Ok((sessions, _)) => {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |since| since.as_millis());
            Outcome::Printed(table(&sessions, u64::try_from(now).unwrap_or(u64::MAX)))
        }
    }
}

/// Whether a reply asked for `clients` has them: a daemon that knows the parameter lists them for
/// every session, `[]` for none, so a session without is from a daemon from before them, which
/// ignored it. That is `DaemonTooOld` (7): it needs updating, and saying "no clients" would be
/// wrong.
fn listed_clients(sessions: &[Value]) -> Result<(), CliError> {
    if sessions.iter().all(|session| session["clients"].is_array()) {
        return Ok(());
    }
    Err(CliError::new(
        super::kind::Kind::DaemonTooOld,
        "the daemon is too old for --clients: it doesn't list a session's clients; it needs \
         updating, which updating the app does",
    ))
}

/// One client as a row under its session, for a person (#688): its kind, its machine, how long
/// ago it attached as of `now` (milliseconds since the epoch), its size, whether it owns the size
/// and its keepalive. What a client didn't say is `-`.
fn client_row(client: &Value, now: u64) -> Vec<String> {
    let or_dash = |value: &Value| value.as_str().unwrap_or("-").to_string();
    let size = &client["size"];
    let size = match (size["columns"].as_u64(), size["rows"].as_u64()) {
        (Some(columns), Some(rows)) if columns > 0 && rows > 0 => format!("{columns}×{rows}"),
        _ => "no size".to_string(),
    };
    vec![
        or_dash(&client["kind"]),
        or_dash(&client["hostname"]),
        client["attached_at_ms"]
            .as_u64()
            .map(|at| format!("attached {}", ago(now.saturating_sub(at))))
            .unwrap_or_default(),
        size,
        if client["owns_size"] == true {
            "owns size"
        } else {
            ""
        }
        .to_string(),
        format!("keepalive {}", or_dash(&client["keepalive"])),
    ]
}

/// `millis` as a person reads an age: the largest whole unit, `42s ago` to `3d ago`.
fn ago(millis: u64) -> String {
    let seconds = millis / 1000;
    let (amount, unit) = match seconds {
        0..60 => (seconds, "s"),
        60..3600 => (seconds / 60, "m"),
        3600..86_400 => (seconds / 3600, "h"),
        _ => (seconds / 86_400, "d"),
    };
    format!("{amount}{unit} ago")
}

/// How many of an id's last characters the table shows: enough to tell sessions apart, and a
/// suffix a target resolves by.
const SHORT_ID: usize = 8;

/// A session's id as the table shows it.
pub(super) fn short_id(session: &Value) -> String {
    let id = session["id"].as_str().unwrap_or_default();
    id.get(id.len().saturating_sub(SHORT_ID)..)
        .unwrap_or(id)
        .to_string()
}

/// What starts each client's row, under its session's.
const CLIENT_PREFIX: &str = "  └ ";

/// The sessions as aligned columns, for a person, each session's clients (`--clients`) under its
/// row, indented, in columns of their own that line up across every session's clients.
fn table(sessions: &[Value], now: u64) -> String {
    if sessions.is_empty() {
        return "No sessions.\n".to_string();
    }
    let session_lines = aligned(&session_rows(sessions));
    let client_rows: Vec<Vec<String>> = sessions
        .iter()
        .flat_map(|session| session["clients"].as_array().into_iter().flatten())
        .map(|client| client_row(client, now))
        .collect();
    let mut client_lines = aligned(&client_rows).into_iter();
    // The header, then each session and its clients.
    let mut lines = session_lines.into_iter();
    let mut out = lines.next().unwrap_or_default() + "\n";
    for (session, line) in sessions.iter().zip(lines) {
        out += &line;
        out.push('\n');
        let count = session["clients"].as_array().map_or(0, Vec::len);
        for line in client_lines.by_ref().take(count) {
            out += CLIENT_PREFIX;
            out += &line;
            out.push('\n');
        }
    }
    out
}

/// The sessions' rows, a header first.
fn session_rows(sessions: &[Value]) -> Vec<Vec<String>> {
    let text = |value: &Value| value.as_str().unwrap_or("").to_string();
    let mut rows = vec![
        ["ID", "LABEL", "TITLE", "STATUS", "RUN", "SCOPE", "CWD"]
            .map(str::to_string)
            .to_vec(),
    ];
    for session in sessions {
        let agent = &session["coding_agent"];
        let status = match (agent["state"].as_str(), agent["waiting_on_user"].as_bool()) {
            (Some(_), Some(true)) => "waiting".to_string(),
            (Some(state), _) => state.to_string(),
            (None, _) => String::new(),
        };
        rows.push(vec![
            short_id(session),
            text(&session["label"]),
            text(&session["title"]),
            status,
            if session["run"] == true { "yes" } else { "" }.to_string(),
            text(&session["scope"]["id"]),
            text(&session["cwd"]),
        ]);
    }
    rows
}

/// `rows` as lines of columns two spaces apart, each as wide as its widest cell (counted in
/// characters, so `×` and `└` are one), trailing spaces trimmed.
fn aligned(rows: &[Vec<String>]) -> Vec<String> {
    let columns = rows.first().map_or(0, Vec::len);
    let widths: Vec<usize> = (0..columns)
        .map(|column| {
            rows.iter()
                .map(|row| row[column].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    rows.iter()
        .map(|row| {
            let line: Vec<String> = row
                .iter()
                .zip(&widths)
                .map(|(cell, width)| format!("{cell:width$}"))
                .collect();
            line.join("  ").trim_end().to_string()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::kind::Kind;

    fn session(id: &str, label: &str, clients: Option<Value>) -> Value {
        let mut session = json!({
            "id": id, "label": label, "title": null, "scope": {"kind": "workroom", "id": "wr-1"},
            "run": false, "cwd": "/w", "coding_agent": null,
        });
        if let Some(clients) = clients {
            session["clients"] = clients;
        }
        session
    }

    /// A reply asked for `clients` that has none is from a daemon from before them, which needs
    /// updating: `DaemonTooOld` (7), never an empty list. `[]` is a session with none.
    #[test]
    fn a_reply_without_clients_is_a_daemon_too_old_for_them() {
        let older = [session("a-1111", "x", None)];
        let error = listed_clients(&older).expect_err("too old");
        assert_eq!(error.kind, Kind::DaemonTooOld);
        assert_eq!(error.kind.exit_code(), 7);
        assert!(error.message.contains("too old for --clients"), "{error:?}");
        assert_eq!(
            listed_clients(&[session("a-1111", "x", Some(json!([])))]),
            Ok(())
        );
        assert_eq!(listed_clients(&[]), Ok(()));
    }

    /// Each session's clients are rows under its own, indented, their columns lined up across
    /// every session's clients: what each is, where, how long ago it attached, its size, whether
    /// it owns the size and its keepalive, `-` for what a client didn't say.
    #[test]
    fn a_sessions_clients_are_rows_under_it_lined_up_across_sessions() {
        let now: u64 = 1_763_700_000_000;
        let sessions = [
            session(
                "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
                "server",
                Some(json!([
                    {"id": 1, "kind": "pane", "hostname": "joels-mbp", "attached_at_ms": now - 12_000,
                     "size": {"columns": 120, "rows": 40}, "owns_size": true, "keepalive": "off"},
                    {"id": 2, "kind": "cli", "hostname": "build-box.local",
                     "attached_at_ms": now - 3_600_000, "size": {"columns": 0, "rows": 0},
                     "owns_size": false, "keepalive": "off"},
                ])),
            ),
            session(
                "c0ffee00-1111-4222-8333-44445555beef",
                "dev",
                Some(json!([])),
            ),
            session(
                "0b9d33c1-7a44-4e1b-8f00-6c2a1d0abeef",
                "tests",
                Some(json!([
                    {"id": 3, "kind": null, "hostname": null, "attached_at_ms": now - 90_000,
                     "size": {"columns": 80, "rows": 24}, "owns_size": true,
                     "keepalive": "answering"},
                ])),
            ),
        ];
        assert_eq!(
            table(&sessions, now),
            "ID        LABEL   TITLE  STATUS  RUN  SCOPE  CWD\n\
             1d0a8e11  server                      wr-1   /w\n  \
             └ pane  joels-mbp        attached 12s ago  120×40   owns size  keepalive off\n  \
             └ cli   build-box.local  attached 1h ago   no size             keepalive off\n\
             5555beef  dev                         wr-1   /w\n\
             1d0abeef  tests                       wr-1   /w\n  \
             └ -     -                attached 1m ago   80×24    owns size  keepalive answering\n"
        );
        // Without `--clients`, the sessions alone, as ever.
        let plain: Vec<Value> = sessions
            .iter()
            .map(|session| {
                let mut session = session.clone();
                session.as_object_mut().unwrap().remove("clients");
                session
            })
            .collect();
        assert_eq!(table(&plain, now).lines().count(), 4);
    }
}
