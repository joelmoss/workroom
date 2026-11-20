//! `workroom sessions [TARGET]`: the daemon's sessions, from the terminal API's `session.list`, or
//! the one `TARGET` names (`session.resolve`). With `--json`, one envelope with `sessions`, each
//! in the API's own shape; without, a table.

use serde::Serialize;
use serde_json::{Value, json};

use super::kind::CliError;
use super::{Args, Context, Outcome, terminal_api};

#[derive(Serialize)]
struct Payload {
    sessions: Vec<Value>,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let sessions = match args.positional.as_slice() {
        [] => terminal_api::call(context, "session.list", json!({}))
            .map(|result| result["sessions"].as_array().cloned().unwrap_or_default()),
        [target] => terminal_api::call(context, "session.resolve", json!({"target": target}))
            .map(|result| vec![result["session"].clone()]),
        // One TARGET at most. Go checks that before the command runs, so the envelope names no
        // command.
        [_, extra, ..] => {
            return Outcome::Usage(CliError::internal(format!(
                "unknown command {extra:?} for \"workroom sessions\""
            )));
        }
    };
    match sessions {
        Err(error) => Outcome::Failed(error),
        Ok(sessions) if context.json => {
            Outcome::Success(super::envelope::success("sessions", &Payload { sessions }))
        }
        Ok(sessions) => Outcome::Printed(table(&sessions)),
    }
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
    let mut rows =
        vec![["ID", "LABEL", "TITLE", "STATUS", "RUN", "SCOPE", "CWD"].map(str::to_string)];
    for session in sessions {
        let agent = &session["coding_agent"];
        let status = match (agent["state"].as_str(), agent["waiting_on_user"].as_bool()) {
            (Some(_), Some(true)) => "waiting".to_string(),
            (Some(state), _) => state.to_string(),
            (None, _) => String::new(),
        };
        rows.push([
            short_id(session),
            text(&session["label"]),
            text(&session["title"]),
            status,
            if session["run"] == true { "yes" } else { "" }.to_string(),
            text(&session["scope"]["id"]),
            text(&session["cwd"]),
        ]);
    }
    let widths: Vec<usize> = (0..7)
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
