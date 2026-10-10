//! `wr-agent list`: the sessions a running agent holds.
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use super::{DAEMON_UNAVAILABLE, flag, handshake};
use crate::serve;
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Service};
use wr_protocol::frame::{Frame, FrameDecoder, FrameKind};

pub fn run_list(args: &[String]) -> ExitCode {
    let Some(socket) = flag(args, "--socket").map(PathBuf::from) else {
        eprintln!("error: list needs --socket <path>");
        return ExitCode::FAILURE;
    };
    let Some(mut stream) = serve::connect(&socket) else {
        eprintln!("error: no agent listening on {}", socket.display());
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    // No fallback here, deliberately: `list` is a diagnostic command run by a person at a prompt,
    // not a relay libghostty forked into a pane. Exec'ing a shell would be absurd; an exit code is
    // exactly what the caller wants.
    if handshake(&mut stream).is_err() {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    }
    let request = Frame::control(FrameKind::List);
    if stream
        .write_all(&Envelope::new(Service::Control, 0, request.encode()).encode())
        .is_err()
    {
        return ExitCode::FAILURE;
    }

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => decoder.push(&buffer[..n]),
        }
        while let Ok(Some(envelope)) = decoder.next_envelope() {
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Ok(Some(frame)) = frames.next_frame() {
                if frame.kind == FrameKind::Sessions {
                    for (id, attached, command) in serve::decode_descriptor_list(&frame.payload) {
                        println!(
                            "{id} {} {command}",
                            if attached { "attached" } else { "detached" }
                        );
                    }
                    return ExitCode::SUCCESS;
                }
            }
        }
    }
    // Hung up, failed or timed out without a reply: callers use `list` as the readiness probe, and
    // an agent that never answers is not ready.
    eprintln!("error: the agent on {} did not answer", socket.display());
    ExitCode::from(DAEMON_UNAVAILABLE)
}
