//! The terminal API's client (ADR 0079): one request to the daemon's `Service::TerminalApi` and its
//! reply, for the commands that wrap it. The daemon is the one `WORKROOM_DAEMON` names, the socket
//! path #684 gives every pane's shell. Finding one without it (the caller's peer pid, `new`
//! starting one) is #684's and #693's; until then no other daemon is ever reached.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

use super::Context;
use super::kind::{CliError, Kind};
use wr_protocol::envelope::{
    Envelope, EnvelopeDecoder, MAX_ENVELOPE_PAYLOAD, MIN_TERMINAL_API_VERSION, Service,
};

/// How long the daemon gets to greet and to answer.
const TIMEOUT: Duration = Duration::from_secs(10);

/// The variable naming the daemon's socket.
pub(super) const DAEMON_VARIABLE: &str = "WORKROOM_DAEMON";

/// The request's stream: one request per connection.
const STREAM: u32 = 1;

/// Calls `method` with `params` and returns its `result`, or the daemon's error as the command's.
pub(super) fn call(context: &Context, method: &str, params: Value) -> Result<Value, CliError> {
    let unreachable = |message: String| CliError::new(Kind::DaemonUnreachable, message);
    let Some(socket) = context.env(DAEMON_VARIABLE).filter(|path| !path.is_empty()) else {
        return Err(unreachable(format!(
            "no daemon to ask: {DAEMON_VARIABLE} names none (it is set in every Workroom pane)"
        )));
    };
    let mut stream = UnixStream::connect(&socket)
        .map_err(|error| unreachable(format!("no daemon is listening on {socket}: {error}")))?;
    let _ = stream.set_read_timeout(Some(TIMEOUT));
    let _ = stream.set_write_timeout(Some(TIMEOUT));
    let version = crate::cli::handshake(&mut stream)
        .map_err(|_| unreachable(format!("the process on {socket} is not a Workroom daemon")))?;
    // An older daemon's decoder fails the whole connection on a service byte it doesn't know, so
    // nothing is sent to one. It is running, so the caller is told to update it, not start one.
    if version < MIN_TERMINAL_API_VERSION {
        return Err(CliError::new(
            Kind::DaemonTooOld,
            format!(
                "the daemon on {socket} speaks protocol {version}, which predates the terminal \
                 API (protocol {MIN_TERMINAL_API_VERSION}); it needs updating, which updating \
                 the app does"
            ),
        ));
    }
    let request = serde_json::to_vec(&json!({"method": method, "params": params}))
        .expect("a request serializes");
    if request.len() > MAX_ENVELOPE_PAYLOAD {
        return Err(CliError::new(
            Kind::TooLarge,
            format!("the request is over {MAX_ENVELOPE_PAYLOAD} bytes"),
        ));
    }
    stream
        .write_all(&Envelope::new(Service::TerminalApi, STREAM, request).encode())
        .map_err(|error| unreachable(format!("the daemon on {socket} hung up: {error}")))?;
    let reply = read_reply(&mut stream)
        .ok_or_else(|| unreachable(format!("the daemon on {socket} did not answer")))?;
    let reply: Value = serde_json::from_slice(&reply)
        .map_err(|_| CliError::internal("the daemon's reply is not JSON"))?;
    if let Some(error) = reply.get("error") {
        let mut failure = CliError::new(
            Kind::from_code(error["kind"].as_str().unwrap_or_default()),
            error["message"].as_str().unwrap_or("the daemon refused"),
        );
        failure.matches = error["matches"].as_array().cloned().unwrap_or_default();
        return Err(failure);
    }
    Ok(reply.get("result").cloned().unwrap_or(Value::Null))
}

/// The reply on `STREAM`, its chunks joined (`rpc::send`: each payload's first byte says whether
/// it is the last), or `None` when the daemon hangs up or goes quiet first.
fn read_reply(stream: &mut UnixStream) -> Option<Vec<u8>> {
    let mut decoder = EnvelopeDecoder::new();
    let mut reply = Vec::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        while let Some(envelope) = decoder.next_envelope().ok()? {
            if envelope.service != Service::TerminalApi || envelope.stream != STREAM {
                continue;
            }
            let (last, body) = envelope.payload.split_first()?;
            reply.extend_from_slice(body);
            if *last == 1 {
                return Some(reply);
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => return None,
            Ok(n) => decoder.push(&buffer[..n]),
        }
    }
}
