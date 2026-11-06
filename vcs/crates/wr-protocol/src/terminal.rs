//! The Terminal service's payloads, inside its frames: the session id, the window size, what an
//! Attach asks for, a Resize, a Retag, and the session list a `Sessions` reply carries.
//!
//! Byte layouts the app's Swift side already reads (`SessionDescriptor.decodeList`,
//! `SessionAttachClient`), so each is fixed: an encoder that disagreed would leave the app seeing
//! no sessions, or a relay that attaches to the wrong one.

use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::{OsStrExt, OsStringExt};

/// The client-minted session id: 16 bytes, matching `SessionIdentifier`'s UUID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(pub [u8; 16]);

impl SessionId {
    pub fn from_slice(bytes: &[u8]) -> Option<SessionId> {
        (bytes.len() == 16).then(|| {
            let mut id = [0u8; 16];
            id.copy_from_slice(bytes);
            SessionId(id)
        })
    }

    /// Lowercase hyphenated UUID, so daemon logs and the app's own logs can be grepped together.
    pub fn to_hyphenated(self) -> String {
        let h: Vec<String> = self.0.iter().map(|b| format!("{b:02x}")).collect();
        format!(
            "{}-{}-{}-{}-{}",
            h[0..4].concat(),
            h[4..6].concat(),
            h[6..8].concat(),
            h[8..10].concat(),
            h[10..16].concat()
        )
    }
}

/// Parses the app's `uuidString` form — uppercase and hyphenated — tolerantly: hex digits only,
/// exactly 32 of them. Tolerant because the id is a stored-data contract with Swift's `UUID`
/// description, and a formatting difference should not silently orphan a live session.
pub fn parse_session_id(value: &OsStr) -> Option<SessionId> {
    let text = String::from_utf8(value.as_bytes().to_vec()).ok()?;
    let hex: String = text.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for (i, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(SessionId(bytes))
}

/// A terminal's size. Zero pixels means nobody has said: a client with no terminal, or one older
/// than pixel sizes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Size {
    pub columns: u16,
    pub rows: u16,
    pub x_pixels: u16,
    pub y_pixels: u16,
}

impl Size {
    /// A size with no pixels.
    pub fn cells(columns: u16, rows: u16) -> Size {
        Size {
            columns,
            rows,
            ..Size::default()
        }
    }
}

/// A Resize frame's payload: columns and rows, then the pixels. An older daemon reads the first
/// two and ignores the rest.
pub fn encode_resize(size: Size) -> Vec<u8> {
    [size.columns, size.rows, size.x_pixels, size.y_pixels]
        .iter()
        .flat_map(|value| value.to_be_bytes())
        .collect()
}

/// The size in a Resize frame's payload. An older client sends no pixels.
pub fn decode_resize(payload: &[u8]) -> Option<Size> {
    let value = |at: usize| {
        Some(u16::from_be_bytes([
            *payload.get(at)?,
            *payload.get(at + 1)?,
        ]))
    };
    Some(Size {
        columns: value(0)?,
        rows: value(2)?,
        x_pixels: value(4).unwrap_or(0),
        y_pixels: value(6).unwrap_or(0),
    })
}

/// The longest workroom id a session keeps (#255). A local workroom's id is `wr|<project>|<name>`,
/// and a macOS path is at most 1024 bytes, so every real one fits. One past it drops the session's
/// metadata rather than cutting an id that would then match the wrong workroom, or none.
pub const MAX_WORKROOM_BYTES: usize = 2048;

/// A Retag frame's payload: the 16-byte session id, then the new workroom as UTF-8. Held to the
/// rule the daemon applies to a session's workroom metadata: non-empty, and no longer than
/// `MAX_WORKROOM_BYTES` (refused, never cut, since a cut id could match the wrong workroom).
pub fn decode_retag(payload: &[u8]) -> Result<(SessionId, &str), &'static str> {
    let id = payload.get(..16).and_then(SessionId::from_slice);
    let workroom = payload.get(16..).map(std::str::from_utf8);
    match (id, workroom) {
        (Some(id), Some(Ok(workroom))) if !workroom.is_empty() => {
            if workroom.len() > MAX_WORKROOM_BYTES {
                Err("a retag's workroom is too long")
            } else {
                Ok((id, workroom))
            }
        }
        _ => Err("a retag names one 16-byte session id and a non-empty UTF-8 workroom"),
    }
}

/// One session in a `Sessions` reply, as the wire carries it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionDescriptor<'a> {
    pub id: SessionId,
    pub pid: i32,
    /// Empty when unknown.
    pub cwd: &'a str,
    pub attached: bool,
    /// Key and value pairs, in order.
    pub metadata: Vec<(&'a str, &'a str)>,
}

/// The session list, in the wire format `SessionDescriptor.decodeList` already reads.
///
/// Matching the shipped Swift encoding rather than inventing a second one: the app's decoder,
/// its `SessionDescriptor` type and every caller of `liveSessions()` then work against either
/// backend with no branching. The format is
/// `count:u32`, then per session `id:[16]`, `pid:i32`, `tty:u64`, `cwd:string`,
/// `attached:u8`, `metadata:entries` — all big-endian, strings length-prefixed.
///
/// `tty` is zero: the Swift helper reports the pty's device number, and nothing in the app reads
/// it (verified by grep). Reporting a fabricated value would be worse than reporting none.
pub fn encode_descriptor_list(sessions: &[SessionDescriptor<'_>]) -> Vec<u8> {
    fn put_string(out: &mut Vec<u8>, value: &str) {
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
    }

    let mut out = Vec::new();
    out.extend_from_slice(&(sessions.len() as u32).to_be_bytes());
    for session in sessions {
        out.extend_from_slice(&session.id.0);
        out.extend_from_slice(&session.pid.to_be_bytes());
        out.extend_from_slice(&0u64.to_be_bytes());
        put_string(&mut out, session.cwd);
        out.push(u8::from(session.attached));
        out.extend_from_slice(&(session.metadata.len() as u32).to_be_bytes());
        for (key, value) in &session.metadata {
            put_string(&mut out, key);
            put_string(&mut out, value);
        }
    }
    out
}

/// Decodes what `encode_descriptor_list` produced, for `workroomd list`'s own output: each
/// session's id, whether it is attached, and its `command` entry, `-` without one.
pub fn decode_descriptor_list(payload: &[u8]) -> Vec<(String, bool, String)> {
    let mut out = Vec::new();
    let mut at = 0usize;
    let take = |at: &mut usize, n: usize| -> Option<&[u8]> {
        let slice = payload.get(*at..*at + n)?;
        *at += n;
        Some(slice)
    };
    let Some(count) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap())) else {
        return out;
    };
    for _ in 0..count {
        let Some(id) = take(&mut at, 16).and_then(SessionId::from_slice) else {
            break;
        };
        if take(&mut at, 4).is_none() || take(&mut at, 8).is_none() {
            break;
        }
        let Some(cwd_len) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
        else {
            break;
        };
        if take(&mut at, cwd_len as usize).is_none() {
            break;
        }
        let Some(attached) = take(&mut at, 1).map(|b| b[0] == 1) else {
            break;
        };
        let Some(entries) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
        else {
            break;
        };
        let mut command = String::from("-");
        for _ in 0..entries {
            let Some(key_len) = take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
            else {
                break;
            };
            let key = take(&mut at, key_len as usize)
                .map(|b| String::from_utf8_lossy(b).into_owned())
                .unwrap_or_default();
            let Some(value_len) =
                take(&mut at, 4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
            else {
                break;
            };
            let value = take(&mut at, value_len as usize)
                .map(|b| String::from_utf8_lossy(b).into_owned())
                .unwrap_or_default();
            if key == "command" {
                command = value;
            }
        }
        out.push((id.to_hyphenated(), attached, command));
    }
    out
}

/// How a client asks for a session to exist: the id, plus what to run if it does not yet.
///
/// These travel in the Attach frame rather than being read from the daemon's own environment,
/// because the daemon is long-lived and shared — its environment is whatever it happened to be
/// spawned with, which may be minutes or days older than the client's, and belongs to a different
/// workroom. The client knows the shell, the directory and the metadata; the daemon must be told.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AttachRequest {
    pub id: Option<SessionId>,
    pub shell: Option<OsString>,
    pub command: Option<OsString>,
    pub cwd: Option<OsString>,
    /// Ghostty's bundled resources, whose `shell-integration` subtree the shell is pointed at.
    /// Without it the shell loads the user's own config directly and the app loses OSC 2/7 —
    /// which is what a pane's title and working directory are read from.
    pub resources: Option<OsString>,
    pub columns: u16,
    pub rows: u16,
    pub x_pixels: u16,
    pub y_pixels: u16,
    /// Passed to the child verbatim. The client's environment, not the daemon's.
    pub env: Vec<(OsString, OsString)>,
    /// Attach only if the session exists; never create it (`CREATE=0`). A restored pane sends it,
    /// because creating would hand back a fresh shell that looks like the one that was running
    /// there. A local relay that is refused attaches again without it, after saying so (#459).
    /// Every daemon-owned restored pane, local or remote, sends it, so one request cannot
    /// race the answer; the app asks first (`confirmBeforeAttach`) only about a session the
    /// retired Swift helper held, whose client has no such flag. Inverted so the default,
    /// and an older client that never sends it, keeps create-on-attach.
    pub existing_only: bool,
}

impl AttachRequest {
    /// 16-byte id, then NUL-terminated `KEY=VALUE` entries. Deliberately not a serialisation
    /// format: the envelope already carries the version, the fields are all strings, and a
    /// dependency-free encoding keeps the daemon linkable into anything.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.id.map(|i| i.0).unwrap_or([0u8; 16]));
        let mut put = |key: &str, value: &[u8]| {
            out.extend_from_slice(key.as_bytes());
            out.push(b'=');
            out.extend_from_slice(value);
            out.push(0);
        };
        if let Some(shell) = &self.shell {
            put("SHELL", shell.as_bytes());
        }
        if let Some(command) = &self.command {
            put("COMMAND", command.as_bytes());
        }
        if let Some(cwd) = &self.cwd {
            put("CWD", cwd.as_bytes());
        }
        if let Some(resources) = &self.resources {
            put("RESOURCES", resources.as_bytes());
        }
        put("COLS", self.columns.to_string().as_bytes());
        put("ROWS", self.rows.to_string().as_bytes());
        put("XPIXELS", self.x_pixels.to_string().as_bytes());
        put("YPIXELS", self.y_pixels.to_string().as_bytes());
        if self.existing_only {
            put("CREATE", b"0");
        }
        for (key, value) in &self.env {
            let mut entry = b"ENV:".to_vec();
            entry.extend_from_slice(key.as_bytes());
            out.extend_from_slice(&entry);
            out.push(b'=');
            out.extend_from_slice(value.as_bytes());
            out.push(0);
        }
        out
    }

    pub fn decode(payload: &[u8]) -> Option<AttachRequest> {
        let id = SessionId::from_slice(payload.get(..16)?)?;
        let mut request = AttachRequest {
            id: Some(id),
            ..Default::default()
        };
        for entry in payload[16..].split(|b| *b == 0) {
            if entry.is_empty() {
                continue;
            }
            let Some(split) = entry.iter().position(|b| *b == b'=') else {
                continue;
            };
            let (key, value) = (&entry[..split], &entry[split + 1..]);
            let value = OsString::from_vec(value.to_vec());
            match key {
                b"SHELL" => request.shell = Some(value),
                b"COMMAND" => request.command = Some(value),
                b"CWD" => request.cwd = Some(value),
                b"RESOURCES" => request.resources = Some(value),
                b"COLS" => {
                    request.columns = value.to_string_lossy().parse().unwrap_or(0);
                }
                b"ROWS" => {
                    request.rows = value.to_string_lossy().parse().unwrap_or(0);
                }
                b"XPIXELS" => {
                    request.x_pixels = value.to_string_lossy().parse().unwrap_or(0);
                }
                b"YPIXELS" => {
                    request.y_pixels = value.to_string_lossy().parse().unwrap_or(0);
                }
                b"CREATE" => request.existing_only = value == "0",
                _ => {
                    if let Some(name) = key.strip_prefix(b"ENV:") {
                        request.env.push((OsString::from_vec(name.to_vec()), value));
                    }
                }
            }
        }
        Some(request)
    }

    /// Built from the variables `PersistentSessionService.launchEnvironment` sets, so the app
    /// needs no new contract: it already exports every one of these. `get` reads one, and `env`
    /// is the whole environment the child is given.
    ///
    /// The environment is passed in, never read here: this crate does no I/O, and `workroomd
    /// attach` reads its own process environment (`cli::attach`). Tests never touch the process
    /// environment either: setting variables in a test is a shared-mutable-state bug waiting to
    /// happen. These tests passed serially and raced each other under cargo's default
    /// parallelism, each clobbering the ids the others had just set.
    pub fn from_vars(
        get: impl Fn(&str) -> Option<OsString>,
        env: Vec<(OsString, OsString)>,
    ) -> AttachRequest {
        let var = |name: &str| get(name).filter(|v| !v.is_empty());
        AttachRequest {
            // An empty COMMAND is the app's "ordinary shell", not a command to run: `sh -c ""`
            // exits instantly and reads as a session that died on creation.
            id: var("WORKROOM_SESSION_ID").and_then(|v| parse_session_id(&v)),
            shell: var("WORKROOM_SESSION_SHELL").or_else(|| var("SHELL")),
            command: var("WORKROOM_SESSION_COMMAND"),
            cwd: var("WORKROOM_SESSION_CWD"),
            resources: var("WORKROOM_SESSION_RESOURCES"),
            columns: 0,
            rows: 0,
            x_pixels: 0,
            y_pixels: 0,
            env,
            existing_only: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_retag_payload_is_an_id_and_a_bounded_non_empty_utf8_workroom() {
        let with = |tail: &[u8]| [&[7u8; 16][..], tail].concat();
        assert_eq!(
            decode_retag(&with(b"/w/x")),
            Ok((SessionId([7; 16]), "/w/x"))
        );
        assert!(decode_retag(&with(b"")).is_err(), "empty workroom");
        assert!(decode_retag(&[7; 15]).is_err(), "short id");
        assert!(decode_retag(&with(&[0xff, 0xfe])).is_err(), "not UTF-8");
        let longest = "a".repeat(MAX_WORKROOM_BYTES);
        assert!(decode_retag(&with(longest.as_bytes())).is_ok());
        let too_long = "a".repeat(MAX_WORKROOM_BYTES + 1);
        assert!(decode_retag(&with(too_long.as_bytes())).is_err());
    }

    #[test]
    fn an_empty_descriptor_list_is_just_a_zero_count() {
        assert_eq!(encode_descriptor_list(&[]), vec![0, 0, 0, 0]);
        assert!(decode_descriptor_list(&[0, 0, 0, 0]).is_empty());
    }

    #[test]
    fn a_resize_round_trips_with_its_pixels() {
        let size = Size {
            columns: 120,
            rows: 40,
            x_pixels: 1200,
            y_pixels: 800,
        };
        assert_eq!(decode_resize(&encode_resize(size)), Some(size));
    }

    /// An older client's resize still works, with no pixels, and a short one is ignored.
    #[test]
    fn a_resize_without_pixels_still_resizes() {
        assert_eq!(decode_resize(&[0, 120, 0, 40]), Some(Size::cells(120, 40)));
        assert_eq!(decode_resize(&[0, 120, 0]), None);
    }

    #[test]
    fn attach_request_round_trips() {
        let request = AttachRequest {
            id: Some(SessionId([7u8; 16])),
            shell: Some(OsString::from("/bin/zsh")),
            command: Some(OsString::from("npm run dev")),
            cwd: Some(OsString::from("/Users/x/dev/workroom")),
            resources: Some(OsString::from(
                "/Applications/Workroom.app/Contents/Resources/ghostty",
            )),
            columns: 120,
            rows: 40,
            x_pixels: 1200,
            y_pixels: 800,
            env: vec![
                (OsString::from("TERM"), OsString::from("xterm-ghostty")),
                (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
            ],
            existing_only: true,
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded, request);
    }

    /// A value containing `=` must survive: PATH-like variables and commands are full of them, and
    /// splitting on the LAST rather than the FIRST separator would quietly corrupt them.
    #[test]
    fn attach_request_keeps_equals_signs_in_values() {
        let request = AttachRequest {
            id: Some(SessionId([1u8; 16])),
            command: Some(OsString::from("FOO=bar make test ARGS=-v")),
            env: vec![(OsString::from("K"), OsString::from("a=b=c"))],
            ..Default::default()
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded.command, request.command);
        assert_eq!(decoded.env, request.env);
    }

    #[test]
    fn attach_request_survives_empty_optional_fields() {
        let request = AttachRequest {
            id: Some(SessionId([2u8; 16])),
            ..Default::default()
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded, request);
    }

    #[test]
    fn attach_request_rejects_a_short_payload() {
        assert!(AttachRequest::decode(&[0u8; 8]).is_none());
    }

    /// The app sets these and passes NO flags, so the environment alone has to be sufficient.
    /// The app sets these and passes NO flags, so the environment alone has to be sufficient.
    #[test]
    fn attach_request_reads_the_app_environment_contract() {
        let vars = [
            (
                "WORKROOM_SESSION_ID",
                "550e8400-e29b-41d4-a716-446655440000",
            ),
            ("WORKROOM_SESSION_SHELL", "/bin/fish"),
            ("WORKROOM_SESSION_CWD", "/work/room"),
            ("WORKROOM_SESSION_COMMAND", ""),
        ];
        let request = AttachRequest::from_vars(
            |name| {
                vars.iter()
                    .find(|(k, _)| *k == name)
                    .map(|(_, v)| OsString::from(*v))
            },
            vec![(OsString::from("TERM"), OsString::from("xterm-ghostty"))],
        );
        assert_eq!(
            request.id.map(|i| i.to_hyphenated()).as_deref(),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
        assert_eq!(request.shell.as_deref(), Some(OsStr::new("/bin/fish")));
        assert_eq!(request.cwd.as_deref(), Some(OsStr::new("/work/room")));
        // An empty COMMAND is "ordinary shell", not a command — `sh -c ""` exits instantly and
        // reads as a session that died on creation.
        assert_eq!(request.command, None);
        assert_eq!(request.env.len(), 1);
    }

    /// Falls back to the plain SHELL when the app did not name one.
    #[test]
    fn attach_request_falls_back_to_the_plain_shell_variable() {
        let request = AttachRequest::from_vars(
            |name| (name == "SHELL").then(|| OsString::from("/bin/zsh")),
            Vec::new(),
        );
        assert_eq!(request.shell.as_deref(), Some(OsStr::new("/bin/zsh")));
    }

    #[test]
    fn parses_the_apps_uuid_format() {
        let id = parse_session_id(OsStr::new("550E8400-E29B-41D4-A716-446655440000")).expect("id");
        assert_eq!(id.to_hyphenated(), "550e8400-e29b-41d4-a716-446655440000");
        // Unhyphenated is the same id: the separators carry no information.
        assert_eq!(
            parse_session_id(OsStr::new("550e8400e29b41d4a716446655440000")),
            Some(id)
        );
    }

    #[test]
    fn rejects_a_malformed_session_id() {
        assert!(parse_session_id(OsStr::new("not-a-uuid")).is_none());
        assert!(parse_session_id(OsStr::new("")).is_none());
        // 31 and 33 hex digits are both wrong, and neither may be silently padded or truncated.
        assert!(parse_session_id(OsStr::new(&"a".repeat(31))).is_none());
        assert!(parse_session_id(OsStr::new(&"a".repeat(33))).is_none());
    }
}
