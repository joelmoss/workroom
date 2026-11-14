use super::*;
use wr_protocol::terminal::decode_descriptor_list;

/// The descriptor list must match what `SessionDescriptor.decodeList` expects, byte for byte,
/// or the app silently sees no sessions on the Rust backend.
#[test]
fn descriptor_list_round_trips_through_our_own_decoder() {
    use crate::terminal::session::SessionInfo;
    let sessions = vec![
        SessionInfo {
            id: SessionId([3u8; 16]),
            pid: 4242,
            attached: true,
            foreground: Some("nvim".into()),
            cwd: Some("/work/room".into()),
            claude_profile: None,
            metadata: Vec::new(),
        },
        SessionInfo {
            id: SessionId([9u8; 16]),
            pid: 77,
            attached: false,
            foreground: None,
            cwd: None,
            claude_profile: None,
            metadata: Vec::new(),
        },
    ];
    let decoded = decode_descriptor_list(&encode_descriptor_list(&sessions));
    assert_eq!(decoded.len(), 2);
    assert_eq!(decoded[0].0, SessionId([3u8; 16]).to_hyphenated());
    assert!(decoded[0].1);
    assert_eq!(decoded[0].2, "nvim");
    assert!(!decoded[1].1);
    assert_eq!(decoded[1].2, "-");
}

/// The Claude profile entry is sent for a confirmed `claude`, empty when it has none, and not at
/// all otherwise, so the app shows no account rather than guessing one (#480).
#[test]
fn descriptor_list_carries_the_claude_profile_of_a_claude_only() {
    use crate::terminal::session::SessionInfo;
    let entry = |key: &str, value: &str| {
        let mut out = Vec::new();
        out.extend_from_slice(&(key.len() as u32).to_be_bytes());
        out.extend_from_slice(key.as_bytes());
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
        out
    };
    let contains = |haystack: &[u8], needle: &[u8]| {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    };
    let session = |claude_profile: Option<&str>| SessionInfo {
        id: SessionId([5u8; 16]),
        pid: 9,
        attached: false,
        foreground: Some("claude".into()),
        cwd: None,
        claude_profile: claude_profile.map(str::to_string),
        metadata: Vec::new(),
    };

    let set = encode_descriptor_list(&[session(Some("/p/sessions/2-u_example.com"))]);
    assert!(contains(
        &set,
        &entry("claude_profile", "/p/sessions/2-u_example.com")
    ));
    let unset = encode_descriptor_list(&[session(Some(""))]);
    assert!(contains(&unset, &entry("claude_profile", "")));
    // And the entry count covers it, so the app's decoder reads past it to the end.
    let decoded = decode_descriptor_list(&unset);
    assert_eq!(decoded.len(), 1);
    assert_eq!(decoded[0].2, "claude");
    let unknown = encode_descriptor_list(&[session(None)]);
    assert!(!contains(&unknown, b"claude_profile"));
    assert_eq!(decode_descriptor_list(&unknown)[0].2, "claude");
}

/// The header the Swift decoder reads first, pinned explicitly: a count, then a 16-byte id.
/// `SessionDescriptor.minimumEncodedSize` is 37, and `decodeList` rejects a count larger than
/// `payload.count / 37` — so an encoder that disagreed here would be rejected wholesale rather
/// than producing a visible error.
#[test]
fn descriptor_list_layout_matches_the_swift_decoder() {
    use crate::terminal::session::SessionInfo;
    let bytes = encode_descriptor_list(&[SessionInfo {
        id: SessionId([1u8; 16]),
        pid: 1,
        attached: true,
        foreground: None,
        cwd: None,
        claude_profile: None,
        metadata: Vec::new(),
    }]);
    assert_eq!(&bytes[..4], &[0, 0, 0, 1], "count is a big-endian u32");
    assert_eq!(&bytes[4..20], &[1u8; 16], "then the 16-byte identifier");
    // 4 (count) + 16 + 4 (pid) + 8 (tty) + 4 (empty cwd) + 1 (attached) + 4 (no metadata)
    assert_eq!(bytes.len(), 41);
    assert!(
        1 <= bytes.len() / 37,
        "a single descriptor must satisfy Swift's minimumEncodedSize guard"
    );
}

/// A `Sessions` reply is one frame, and `Frame::encode` panics rather than truncating past the
/// cap. Reply with a failure instead — which the app already renders — rather than killing the
/// connection thread and leaving the client waiting for a frame that will never come.
#[test]
fn an_oversized_session_list_is_refused_rather_than_panicking() {
    // What `dispatch` sends: the reply frame inside an envelope. Encoding the frame alone
    // passed at exactly `MAX_PAYLOAD_SIZE`, which then panicked `Envelope::encode` (#246).
    let sent = |payload: Vec<u8>| {
        let frame = list_reply(payload);
        let _ = Envelope::new(Service::Control, 0, frame.encode()).encode();
        frame.kind
    };

    // The biggest list that fits is the smaller of the frame cap and what the envelope leaves
    // after the frame's five-byte header, whichever way round the two caps are.
    let fits = MAX_PAYLOAD_SIZE.min(MAX_ENVELOPE_PAYLOAD - HEADER_SIZE);

    assert_eq!(sent(encode_descriptor_list(&[])), FrameKind::Sessions);
    assert_eq!(sent(vec![0u8; fits]), FrameKind::Sessions);
    // And the refusal must itself be sendable, which is the whole point.
    assert_eq!(sent(vec![0u8; fits + 1]), FrameKind::Failure);
    // Exactly `MAX_PAYLOAD_SIZE` is what panicked before the fix (#246).
    assert_eq!(
        sent(vec![0u8; MAX_PAYLOAD_SIZE]) == FrameKind::Failure,
        MAX_PAYLOAD_SIZE > fits
    );
    assert_eq!(sent(vec![0u8; MAX_PAYLOAD_SIZE + 1]), FrameKind::Failure);
}

fn env(entries: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
    entries
        .iter()
        .map(|(key, value)| (OsString::from(key), OsString::from(value)))
        .collect()
}

/// The app's metadata variables become the session's metadata, under the keys the app reads
/// them back by (`SessionMetadataKey`); everything else in the client's environment, the app's
/// unread `project` included, is not metadata (#255).
#[test]
fn a_sessions_metadata_comes_from_the_apps_variables() {
    let metadata = session_metadata(&env(&[
        ("PATH", "/bin"),
        ("WORKROOM_SESSION_ID", "ignored"),
        ("WORKROOM_SESSION_PROJECT", "/Users/me/dev/app"),
        (
            "WORKROOM_SESSION_WORKROOM",
            "wr|/Users/me/dev/app|cyan-brush",
        ),
        ("WORKROOM_SESSION_TITLE", "Terminal 2"),
        ("WORKROOM_SESSION_TAB", "dead"),
    ]));
    assert_eq!(
        metadata,
        vec![
            (
                "workroom".to_string(),
                "wr|/Users/me/dev/app|cyan-brush".to_string()
            ),
            ("title".to_string(), "Terminal 2".to_string()),
        ]
    );
    assert!(session_metadata(&env(&[("WORKROOM_SESSION_WORKROOM", "")])).is_empty());
}

/// A local workroom id holds the whole project path, so it can be long and must still be kept;
/// one past the bound drops the metadata whole rather than keep a cut id (D8).
#[test]
fn a_long_workroom_id_is_kept_and_one_past_the_bound_drops_the_metadata() {
    let long = format!("wr|/{}|cyan", "p".repeat(1100));
    let kept = session_metadata(&env(&[
        ("WORKROOM_SESSION_WORKROOM", &long),
        ("WORKROOM_SESSION_TITLE", "Terminal 1"),
    ]));
    assert_eq!(kept[0], ("workroom".to_string(), long));

    let over = "w".repeat(MAX_WORKROOM_BYTES + 1);
    assert!(
        session_metadata(&env(&[
            ("WORKROOM_SESSION_WORKROOM", &over),
            ("WORKROOM_SESSION_TITLE", "Terminal 1"),
        ]))
        .is_empty()
    );
}

/// A title is cut to `MAX_TITLE_BYTES` at a character boundary, never mid-character.
#[test]
fn a_long_title_is_cut_at_a_character_boundary() {
    // Three bytes each, so 256 falls inside one.
    let title = "€".repeat(10 * 1024);
    let metadata = session_metadata(&env(&[("WORKROOM_SESSION_TITLE", &title)]));
    let (key, cut) = &metadata[0];
    assert_eq!(key, "title");
    assert!(cut.len() <= MAX_TITLE_BYTES && cut.len() > MAX_TITLE_BYTES - 3);
    assert!(cut.chars().all(|c| c == '€'));
}

/// With every field at its bound, hundreds of sessions still fit one list reply, so no title or
/// workroom id can turn the whole list into a `Failure` (D8).
#[test]
fn many_sessions_at_the_metadata_bounds_still_list() {
    use crate::terminal::session::SessionInfo;
    let metadata = vec![
        ("workroom".to_string(), "w".repeat(MAX_WORKROOM_BYTES)),
        ("title".to_string(), "t".repeat(MAX_TITLE_BYTES)),
        ("created".to_string(), u64::MAX.to_string()),
    ];
    let sessions: Vec<SessionInfo> = (0..250u8)
        .map(|n| SessionInfo {
            id: SessionId([n; 16]),
            pid: 1,
            attached: false,
            foreground: Some("nvim".into()),
            cwd: Some("c".repeat(1024)),
            claude_profile: None,
            metadata: metadata.clone(),
        })
        .collect();
    assert_eq!(
        list_reply(encode_descriptor_list(&sessions)).kind,
        FrameKind::Sessions
    );
}

#[test]
fn a_truncated_descriptor_list_decodes_to_what_survived() {
    use crate::terminal::session::SessionInfo;
    let full = encode_descriptor_list(&[SessionInfo {
        id: SessionId([5u8; 16]),
        pid: 1,
        attached: true,
        foreground: None,
        cwd: None,
        claude_profile: None,
        metadata: Vec::new(),
    }]);
    // Cut mid-descriptor: no panic, no phantom entry.
    assert!(decode_descriptor_list(&full[..20]).is_empty());
}

/// A `Peer` frame as `relay` sends it: NUL-terminated `KEY=VALUE` entries, on Control.
fn peer_envelope(entries: &[(&str, &str)]) -> Envelope {
    let mut payload = Vec::new();
    for (key, value) in entries {
        payload.extend_from_slice(format!("{key}={value}").as_bytes());
        payload.push(0);
    }
    Envelope::new(
        Service::Control,
        0,
        Frame::new(FrameKind::Peer, payload).encode(),
    )
}

/// Hands `envelopes` to one connection's dispatch, and returns what it kept of the peer.
fn dispatched_peer(envelopes: &[Envelope]) -> Option<Vec<(OsString, OsString)>> {
    let sessions = SessionStore::new();
    let mut attachment = Attachment::new(Arc::new(|| {}));
    let writer: SharedWriter = Arc::new(std::sync::Mutex::new(Box::new(std::io::sink())));
    for envelope in envelopes {
        let reply = dispatch(envelope, &sessions, &mut attachment, "test", &writer, &|_| true);
        assert!(reply.is_none(), "a Peer frame is never answered");
    }
    attachment.peer
}

/// Only a connection's first `Peer` frame counts: the relay sends one, right after the greeting,
/// and a later one (anything the client itself put on the stream) changes nothing.
#[test]
fn only_the_first_peer_frame_on_a_connection_is_taken() {
    let peer = dispatched_peer(&[
        peer_envelope(&[("SSH_CONNECTION", "10.0.0.1 1 10.0.0.2 22")]),
        peer_envelope(&[("SSH_CONNECTION", "192.0.2.9 2 192.0.2.10 22")]),
    ]);
    assert_eq!(
        peer,
        Some(env(&[("SSH_CONNECTION", "10.0.0.1 1 10.0.0.2 22")]))
    );
}

/// The daemon holds a `Peer` frame to the login environment itself, whatever a relay sends: the
/// Mac's terminal, the ssh terminal and the session's metadata never come from it, and neither does
/// an entry that is no variable at all.
#[test]
fn a_peer_frame_lets_only_the_login_environment_through() {
    let peer = dispatched_peer(&[peer_envelope(&[
        ("PATH", "/login/bin:/usr/bin"),
        ("HOME", "/home/login"),
        ("SHELL", "/bin/bash"),
        ("USER", "login"),
        ("SSH_CONNECTION", "10.0.0.1 1 10.0.0.2 22"),
        ("SSH_TTY", "/dev/pts/3"),
        ("WORKROOM_SESSION_ID", "6B9B968D-0BD7-4172-850A-A373DA73BC70"),
        ("WORKROOM_SESSION_COMMAND", "rm -rf ~"),
        ("TERM", "dumb"),
        ("COLORTERM", "no"),
        ("TERM_PROGRAM", "tmux"),
        ("TERM_PROGRAM_VERSION", "3"),
        ("TERMINFO", "/elsewhere"),
        ("GHOSTTY_RESOURCES_DIR", "/elsewhere"),
        ("", "no-name"),
        ("PWD", "/home/login"),
    ])]);
    assert_eq!(
        peer,
        Some(env(&[
            ("PATH", "/login/bin:/usr/bin"),
            ("HOME", "/home/login"),
            ("SHELL", "/bin/bash"),
            ("USER", "login"),
            ("SSH_CONNECTION", "10.0.0.1 1 10.0.0.2 22"),
        ]))
    );
}

/// A `Peer` frame over the bound is not taken at all, and nor is one after it: the session falls
/// back to the account entry rather than to a cut environment.
#[test]
fn an_oversized_peer_frame_is_not_taken() {
    let big = "x".repeat(crate::terminal::host_session::MAX_PEER_ENVIRONMENT);
    let peer = dispatched_peer(&[
        peer_envelope(&[("HOME", "/home/login"), ("BIG", &big)]),
        peer_envelope(&[("HOME", "/home/second")]),
    ]);
    assert_eq!(peer, None);
}
