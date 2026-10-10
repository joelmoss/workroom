//! `wr-agent hand-off` and `wr-agent handoff-check`: replacing a running agent with a new build.
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use super::{DAEMON_UNAVAILABLE, flag, handshake};
use crate::handoff;
use crate::serve;
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, MIN_HANDOFF_VERSION, Service};
use wr_protocol::frame::{Frame, FrameDecoder, FrameKind};

/// `hand-off`'s exit status when the agent was never asked, because it predates the request. It
/// keeps running, and a client talks to it over the versioned envelope.
const PREDATES_HAND_OFF: u8 = 3;

pub fn run_hand_off(args: &[String]) -> ExitCode {
    let (Some(socket), Some(binary)) = (
        flag(args, "--socket").map(PathBuf::from),
        flag(args, "--binary").map(PathBuf::from),
    ) else {
        eprintln!("error: hand-off needs --socket <path> and --binary <path>");
        return ExitCode::FAILURE;
    };
    let Some(mut stream) = serve::connect(&socket) else {
        eprintln!("error: no agent listening on {}", socket.display());
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let Ok(version) = handshake(&mut stream) else {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    if version < MIN_HANDOFF_VERSION {
        eprintln!("the agent predates hand-off (protocol {version}), so it keeps running");
        return ExitCode::from(PREDATES_HAND_OFF);
    }
    let mut payload = vec![u8::from(args.iter().any(|a| a == "--force"))];
    payload.extend_from_slice(std::os::unix::ffi::OsStrExt::as_bytes(binary.as_os_str()));
    let request = Frame::new(FrameKind::HandOff, payload);
    if stream
        .write_all(&Envelope::new(Service::Control, 0, request.encode()).encode())
        .is_err()
    {
        return ExitCode::FAILURE;
    }
    // Longer than `list`: the agent answers once the new binary has checked every session, and it
    // may first wait out a running repository command (`handoff::QUIET_TIMEOUT`).
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut handing_off = false;
    loop {
        while let Ok(Some(envelope)) = decoder.next_envelope() {
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Ok(Some(frame)) = frames.next_frame() {
                match frame.kind {
                    FrameKind::Acknowledged if frame.payload == b"current" => {
                        println!("current");
                        return ExitCode::SUCCESS;
                    }
                    FrameKind::Acknowledged => handing_off = true,
                    FrameKind::Failure => {
                        eprintln!("error: {}", String::from_utf8_lossy(&frame.payload));
                        return ExitCode::FAILURE;
                    }
                    _ => {}
                }
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => decoder.push(&buffer[..n]),
        }
    }
    if !handing_off {
        eprintln!("error: the agent closed without answering");
        return ExitCode::FAILURE;
    }
    // The exec closed that connection. The socket was never unbound, so this connects at once and
    // the new program greets it as soon as it has adopted every session.
    let answered = serve::connect(&socket).is_some_and(|mut stream| {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        handshake(&mut stream).is_ok()
    });
    if !answered {
        eprintln!("error: the new agent did not answer, so its sessions may be lost");
        return ExitCode::FAILURE;
    }
    println!("handed off");
    ExitCode::SUCCESS
}

/// `wr-agent handoff-check <table>`: whether a hand-off table parses, and how many entries it has.
pub fn run_handoff_check(args: &[String]) -> ExitCode {
    match args.get(1) {
        Some(table) => match handoff::check_table(std::path::Path::new(table)) {
            Ok(count) => {
                println!("ok {count}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::FAILURE
            }
        },
        None => {
            eprintln!("error: handoff-check needs <table>");
            ExitCode::FAILURE
        }
    }
}
