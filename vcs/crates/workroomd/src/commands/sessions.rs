//! `workroom sessions [TARGET] [--all]`: the daemon's sessions, from the terminal API's
//! `session.list`, or the one `TARGET` names (`session.resolve`). The listing keeps to the
//! caller's scope (its workroom) unless `--all` widens it to every session; from no pane, or from
//! one with no scope, it is every session. A target resolves across every session either way.
//! With `--json`, one envelope with `sessions`, each in the API's own shape, and `caller`, the id
//! of the pane it ran in (null for none); without, a table. `--clients` adds each session's
//! attached clients (#688), as `clients` in each session with `--json`, and as a second table.

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
    match reply {
        Err(error) => Outcome::Failed(error),
        Ok((sessions, caller)) if context.json => Outcome::Success(super::envelope::success(
            "sessions",
            &Payload { sessions, caller },
        )),
        Ok((sessions, _)) if args.is_set("clients") => {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |since| since.as_millis());
            Outcome::Printed(format!(
                "{}\n{}",
                table(&sessions),
                clients_table(&sessions, u64::try_from(now).unwrap_or(u64::MAX))
            ))
        }
        Ok((sessions, _)) => Outcome::Printed(table(&sessions)),
    }
}

/// Every session's clients as aligned columns, for a person (#688): each by its session's short
/// id, how long ago it attached as of `now` (milliseconds since the epoch), and its size as
/// `COLUMNSxROWS`.
pub(super) fn clients_table(sessions: &[Value], now: u64) -> String {
    let text = |value: &Value| value.as_str().unwrap_or("").to_string();
    let mut rows: Vec<Vec<String>> = vec![
        [
            "SESSION",
            "CLIENT",
            "KIND",
            "HOSTNAME",
            "ATTACHED",
            "SIZE",
            "OWNER",
            "KEEPALIVE",
        ]
        .map(str::to_string)
        .to_vec(),
    ];
    for session in sessions {
        for client in session["clients"].as_array().into_iter().flatten() {
            let size = &client["size"];
            rows.push(vec![
                short_id(session),
                client["id"].to_string(),
                text(&client["kind"]),
                text(&client["hostname"]),
                client["attached_at_ms"]
                    .as_u64()
                    .map(|at| ago(now.saturating_sub(at)))
                    .unwrap_or_default(),
                format!("{}x{}", size["columns"], size["rows"]),
                if client["owns_size"] == true {
                    "yes"
                } else {
                    ""
                }
                .to_string(),
                text(&client["keepalive"]),
            ]);
        }
    }
    if rows.len() == 1 {
        return "No clients.\n".to_string();
    }
    aligned(&rows)
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

/// The sessions as aligned columns, for a person.
pub(super) fn table(sessions: &[Value]) -> String {
    if sessions.is_empty() {
        return "No sessions.\n".to_string();
    }
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
    aligned(&rows)
}

/// `rows` as columns two spaces apart, each as wide as its widest cell, trailing spaces trimmed.
fn aligned(rows: &[Vec<String>]) -> String {
    let columns = rows.first().map_or(0, Vec::len);
    let widths: Vec<usize> = (0..columns)
        .map(|column| {
            rows.iter()
                .map(|row| row[column].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for row in rows {
        let line: Vec<String> = row
            .iter()
            .zip(&widths)
            .map(|(cell, width)| format!("{cell:width$}"))
            .collect();
        out += line.join("  ").trim_end();
        out.push('\n');
    }
    out
}
