//! `wr-agent program-status`: what each session's program says it is doing, as the app is told it
//! (#358). Subscribes like the app, prints the snapshot, and exits at `snapshot-complete`.
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{DAEMON_UNAVAILABLE, flag, handshake};
use crate::serve;
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
        eprintln!("error: no agent listening on {}", socket.display());
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    let Ok(version) = handshake(&mut stream) else {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    // An older agent would drop the request unanswered.
    if version < MIN_PROGRAM_STATUS_VERSION {
        let reason = format!(
            "the agent speaks protocol {version}; program status needs {MIN_PROGRAM_STATUS_VERSION}"
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
                sessions.push(value);
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
    eprintln!("error: the agent on {} did not answer", socket.display());
    ExitCode::from(DAEMON_UNAVAILABLE)
}

/// `result` is the subscribe reply's (or the reason it was not made); `sessions` the snapshot.
fn print(as_json: bool, result: &Value, sessions: &[Value]) {
    if as_json {
        let mut out = json!({
            "schema_version": SCHEMA_VERSION,
            "available": result["available"] == true,
            "droppedReplies": result["droppedReplies"],
            "sessions": sessions,
        });
        if let Some(reason) = result.get("reason") {
            out["reason"] = reason.clone();
        }
        println!("{out}");
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
