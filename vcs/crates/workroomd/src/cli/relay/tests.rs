use super::*;
use std::ffi::OsString;
use wr_protocol::envelope::EnvelopeDecoder;

fn environment(entries: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    entries
        .iter()
        .map(|(key, value)| (OsString::from(key), OsString::from(value)))
        .collect()
}

/// The envelopes `bytes` holds, which must be nothing else.
fn envelopes(bytes: &[u8]) -> Vec<Envelope> {
    let mut decoder = EnvelopeDecoder::new();
    decoder.push(bytes);
    let mut out = Vec::new();
    while let Some(envelope) = decoder.next_envelope().expect("envelopes") {
        out.push(envelope);
    }
    out
}

/// The `Peer` frame in `envelope`, as `NAME=value` strings.
fn peer_entries(envelope: &Envelope) -> Vec<String> {
    assert_eq!(envelope.service, Service::Control);
    let mut frames = wr_protocol::frame::FrameDecoder::new();
    frames.push(&envelope.payload);
    let frame = frames.next_frame().expect("frame").expect("one frame");
    assert_eq!(frame.kind, FrameKind::Peer);
    frame
        .payload
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
        .map(|entry| String::from_utf8_lossy(entry).into_owned())
        .collect()
}

/// A stream that is no greeting (a client that is not one of ours) reaches the daemon exactly as
/// it came, with no `Peer` frame in it.
#[test]
fn a_stream_that_is_no_greeting_passes_through_unchanged_with_no_peer() {
    let input = b"GET / HTTP/1.1\r\nHost: example\r\n\r\n".to_vec();
    let peer = peer_frame(environment(&[("HOME", "/home/login")]));
    let mut from = std::io::Cursor::new(input.clone());
    let mut to = Vec::new();
    forward_greeting(&mut from, &mut to, peer.as_deref()).expect("forwarded");
    std::io::copy(&mut from, &mut to).unwrap();
    assert_eq!(to, input);
}

/// A client that hangs up mid-greeting: what it sent goes on, then the stream ends, with no
/// `Peer` frame after it.
#[test]
fn a_greeting_cut_short_by_eof_is_passed_on_with_no_peer() {
    let greeting = Hello::current("test-client").encode();
    let cut = &greeting[..greeting.len() - 1];
    let peer = peer_frame(environment(&[("HOME", "/home/login")]));
    let mut to = Vec::new();
    let result = forward_greeting(&mut std::io::Cursor::new(cut), &mut to, peer.as_deref());
    assert_eq!(
        result.unwrap_err().kind(),
        std::io::ErrorKind::UnexpectedEof
    );
    assert_eq!(to, cut);
}

/// A greeting is followed by exactly one `Peer` frame, before anything the client sends after it,
/// which is left for the copy that follows.
#[test]
fn a_greeting_is_followed_by_exactly_one_peer_frame() {
    let greeting = Hello::current("test-client").encode();
    let after = Envelope::new(Service::Control, 1, b"next".to_vec()).encode();
    let mut input = greeting.clone();
    input.extend_from_slice(&after);
    let peer = peer_frame(environment(&[
        ("HOME", "/home/login"),
        ("PATH", "/login/bin"),
    ]));
    let mut from = std::io::Cursor::new(input);
    let mut to = Vec::new();
    forward_greeting(&mut from, &mut to, peer.as_deref()).expect("forwarded");

    assert_eq!(&to[..greeting.len()], greeting.as_slice());
    let sent = envelopes(&to[greeting.len()..]);
    assert_eq!(sent.len(), 1, "one Peer frame");
    assert_eq!(
        peer_entries(&sent[0]),
        ["HOME=/home/login", "PATH=/login/bin"]
    );
    let mut rest = Vec::new();
    from.read_to_end(&mut rest).unwrap();
    assert_eq!(
        rest, after,
        "the client's next envelope is left to the copy"
    );
}

/// A login with nothing to pass on sends no `Peer` frame: no environment, or one of only what a
/// session must not take from it.
#[test]
fn there_is_no_peer_frame_without_a_login_environment_to_send() {
    assert_eq!(peer_frame(Vec::new()), None);
    assert_eq!(
        peer_frame(environment(&[
            ("TERM", "xterm-256color"),
            ("SSH_TTY", "/dev/pts/3"),
            ("WORKROOM_SESSION_ID", "x"),
        ])),
        None
    );
    let greeting = Hello::current("test-client").encode();
    let mut to = Vec::new();
    forward_greeting(&mut std::io::Cursor::new(greeting.clone()), &mut to, None)
        .expect("forwarded");
    assert_eq!(to, greeting);
}

/// The frame drops the login's terminal, ssh terminal and session metadata, and stays within its
/// bound however big the environment, keeping the account's own variables first.
#[test]
fn the_peer_frame_holds_the_login_environment_within_its_bound() {
    let big = "x".repeat(crate::terminal::host_session::MAX_PEER_ENVIRONMENT);
    let frame = peer_frame(environment(&[
        ("BIG", &big),
        ("TERM", "xterm-256color"),
        ("SSH_TTY", "/dev/pts/3"),
        ("WORKROOM_SESSION_TITLE", "t"),
        ("EDITOR", "vi"),
        ("HOME", "/home/login"),
        ("SSH_CONNECTION", "10.0.0.1 1 10.0.0.2 22"),
    ]))
    .expect("a frame");
    let sent = envelopes(&frame);
    assert_eq!(sent.len(), 1);
    assert_eq!(
        peer_entries(&sent[0]),
        [
            "HOME=/home/login",
            "SSH_CONNECTION=10.0.0.1 1 10.0.0.2 22",
            "EDITOR=vi"
        ]
    );
}
