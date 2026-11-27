//! `workroomd program-status`: what each session's program says it is doing, as the app is told it
//! (#358). Subscribes like the app, prints the snapshot, and exits at `snapshot-complete`.
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{DAEMON_UNAVAILABLE, flag, handshake};
use crate::daemon::serve;
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, MIN_PROGRAM_STATUS_VERSION, Service};

/// The `--json` output's shape; bumped when a field changes meaning or goes.
const SCHEMA_VERSION: u32 = 1;

pub fn run_program_status(args: &[String]) -> ExitCode {
    let Some(socket) = flag(args, "--socket").map(PathBuf::from) else {
        eprintln!("error: program-status needs --socket <path>");
        return ExitCode::FAILURE;
    };
    let as_json = args.iter().any(|a| a == "--json");
    let Some(mut stream) = serve::connect(&socket) else {
        eprintln!("error: no daemon listening on {}", socket.display());
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    let Ok(version) = handshake(&mut stream) else {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    // An older daemon would drop the request unanswered.
    if version < MIN_PROGRAM_STATUS_VERSION {
        let reason = format!(
            "the daemon speaks protocol {version}; program status needs {MIN_PROGRAM_STATUS_VERSION}"
        );
        print(as_json, &json!({"available": false, "reason": reason}), &[]);
        return ExitCode::SUCCESS;
    }
    let request = serde_json::to_vec(&json!({"version": 1, "method": "subscribe"}))
        .expect("a request serializes");
    if stream
        .write_all(&Envelope::new(Service::ProgramStatus, 1, request).encode())
        .is_err()
    {
        return ExitCode::FAILURE;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut result = None;
    let mut sessions = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        while let Ok(Some(envelope)) = decoder.next_envelope() {
            // Every reply and event here is one final envelope: `[1] + json`.
            let Some((_, body)) = envelope.payload.split_first() else {
                continue;
            };
            let Ok(value) = serde_json::from_slice::<Value>(body) else {
                continue;
            };
            if envelope.service != Service::ProgramStatus {
                continue;
            }
            if envelope.stream == 1 {
                let available = value["result"]["available"] == true;
                result = Some(value["result"].clone());
                if !available {
                    print(as_json, &value["result"], &[]);
                    return ExitCode::SUCCESS;
                }
            } else if value["event"] == "status" {
                sessions.push(shown(value));
            } else if value["event"] == "snapshot-complete" {
                print(as_json, &result.unwrap_or_default(), &sessions);
                return ExitCode::SUCCESS;
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => decoder.push(&buffer[..n]),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => break,
        }
    }
    eprintln!("error: the daemon on {} did not answer", socket.display());
    ExitCode::from(DAEMON_UNAVAILABLE)
}

/// A `status` event as this command prints it: a resume record's arguments can hold secrets
/// (#824), and this output gets pasted into bug reports, so the app alone is told them.
fn shown(mut status: Value) -> Value {
    if let Some(resume) = status.get_mut("resume").and_then(Value::as_object_mut) {
        resume.remove("argv");
    }
    status
}

/// The `--json` output, for `result` and `sessions` as `print` takes them.
fn json_output(result: &Value, sessions: &[Value]) -> Value {
    let mut out = json!({
        "schema_version": SCHEMA_VERSION,
        "available": result["available"] == true,
        "droppedReplies": result["droppedReplies"],
        "sessions": sessions,
    });
    if let Some(reason) = result.get("reason") {
        out["reason"] = reason.clone();
    }
    out
}

/// `result` is the subscribe reply's (or the reason it was not made); `sessions` the snapshot.
fn print(as_json: bool, result: &Value, sessions: &[Value]) {
    if as_json {
        println!("{}", json_output(result, sessions));
        return;
    }
    if result["available"] != true {
        println!(
            "program status: unavailable ({})",
            result["reason"].as_str().unwrap_or("no reason given")
        );
        return;
    }
    println!("program status: available (terminal-state)");
    println!("dropped replies: {}", result["droppedReplies"]);
    for status in sessions {
        println!(
            "{} {}, revision {}",
            status["session"].as_str().unwrap_or("?"),
            if status["reporting"] == true {
                "reporting"
            } else {
                "not reporting"
            },
            status["revision"]
        );
        for record in status["records"].as_array().into_iter().flatten() {
            let id = record["id"].as_str().unwrap_or_default();
            println!(
                "  {} {} kind={} progress={} app={} episode={} notify={} title={} message={}",
                if id.is_empty() { "(root)" } else { id },
                record["state"].as_str().unwrap_or("?"),
                record["kind"].as_str().unwrap_or("?"),
                record["progress"],
                record["app"],
                record["episode"],
                record["notify"],
                record["title"],
                record["message"],
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Value: protects=the hidden command's `--json` output, which gets pasted into bug reports,
    /// never carrying a resume record's arguments, which can hold secrets (#824); fails_when=a
    /// status event's `resume.argv` reaches the output, or the record goes with it; why_new=the
    /// redaction was untested (#824's review); seam=the status event the app's decoder tests share
    #[test]
    fn the_json_output_never_carries_a_resume_records_arguments() {
        let status: Value = serde_json::from_str(include_str!(
            "../../../../../testdata/program-status/status.json"
        ))
        .unwrap();
        assert_eq!(status["resume"]["argv"][2], "a-session", "the fixture has arguments");
        let out = json_output(&json!({"available": true}), &[shown(status)]).to_string();
        assert!(!out.contains("argv"), "{out}");
        assert!(!out.contains("a-session"), "{out}");
        let out: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(out["sessions"][0]["resume"]["cwd"], "/work", "{out}");
    }
}
