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
    /// A remote pane attached from the Mac (`HOST=1`, ADR 0074): the session is built from the
    /// host's environment and account, and only `host_attach_environment`'s variables come from
    /// `env`. Sent only to a daemon at `MIN_HOST_ATTACH_VERSION` or later.
    pub host_environment: bool,
    /// What kind of client this is (`CLIENT`, #688), which `sessions --clients` reports. A daemon
    /// that knows none of this ignores the key, and an older client sends none, which the daemon
    /// reports as unknown, so neither needs a protocol version.
    pub client: Option<ClientKind>,
    /// The machine the client is on (`HOSTNAME`, #688): for a pane, the Mac showing it. None when
    /// the client could not say, or said something `client_hostname` refuses.
    pub hostname: Option<String>,
    /// The resume record a restored pane's tab saved (ADR 0082, #825), sent only with the attach
    /// that recreates its gone session under the same id: the daemon starts the program it names
    /// in that session's login shell. A daemon that predates it ignores the keys.
    pub resume: Option<ResumeRequest>,
}

/// A resume record as an attach carries it (`RESUME_ARG`, `RESUME_CWD`, `RESUME_AT`): the command
/// whole, which can hold secrets, so it is never printed (`Debug` shows the program alone).
#[derive(Clone, PartialEq, Eq, Default)]
pub struct ResumeRequest {
    /// The command, as its program reported it.
    pub argv: Vec<String>,
    /// The folder it starts in.
    pub cwd: String,
    /// When it reported, in milliseconds since the Unix epoch.
    pub reported_at_ms: u64,
}

impl std::fmt::Debug for ResumeRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let program = self
            .argv
            .first()
            .map_or("", |word| word.rsplit('/').next().unwrap_or(word.as_str()));
        write!(f, "ResumeRequest({program})")
    }
}

/// What kind of client attached to a session (#688): a pane of the app, the app's own service
/// connection, or a `workroom attach` someone ran. Named as `sessions --clients` and the terminal
/// API's events give it; a name this daemon doesn't know is reported as unknown, never kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientKind {
    Pane,
    App,
    Cli,
}

impl ClientKind {
    pub fn name(self) -> &'static str {
        match self {
            ClientKind::Pane => "pane",
            ClientKind::App => "app",
            ClientKind::Cli => "cli",
        }
    }

    pub fn parse(name: &[u8]) -> Option<ClientKind> {
        match name {
            b"pane" => Some(ClientKind::Pane),
            b"app" => Some(ClientKind::App),
            b"cli" => Some(ClientKind::Cli),
            _ => None,
        }
    }
}

/// The longest hostname an attach may name: POSIX's `HOST_NAME_MAX` on Linux, and one short of
/// macOS's `MAXHOSTNAMELEN`. It goes into every listing and event of the client, so it is bounded.
pub const MAX_HOSTNAME_BYTES: usize = 255;

/// A client's hostname as the daemon keeps it: UTF-8, not empty, at most `MAX_HOSTNAME_BYTES`, and
/// no control characters, which a table or a log line would print. Anything else is none, never
/// cut: a cut name could be another machine's.
pub fn client_hostname(name: &[u8]) -> Option<String> {
    let name = std::str::from_utf8(name).ok()?;
    (!name.is_empty() && name.len() <= MAX_HOSTNAME_BYTES && !name.chars().any(char::is_control))
        .then(|| name.to_string())
}

/// Whether a client's variable may reach a host-environment session (ADR 0074): the terminal
/// type, colour support, terminal program, locale and the session's own metadata.
pub fn is_host_attach_variable(name: &OsStr) -> bool {
    let name = name.as_bytes();
    matches!(
        name,
        b"TERM" | b"COLORTERM" | b"TERM_PROGRAM" | b"TERM_PROGRAM_VERSION" | b"LANG"
    ) || name.starts_with(b"LC_")
        || name.starts_with(b"WORKROOM_SESSION_")
}

/// `env` with only what `is_host_attach_variable` allows, in order.
pub fn host_attach_environment(env: Vec<(OsString, OsString)>) -> Vec<(OsString, OsString)> {
    env.into_iter()
        .filter(|(key, _)| is_host_attach_variable(key))
        .collect()
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
        if self.host_environment {
            put("HOST", b"1");
        }
        if let Some(client) = self.client {
            put("CLIENT", client.name().as_bytes());
        }
        if let Some(hostname) = &self.hostname {
            put("HOSTNAME", hostname.as_bytes());
        }
        if let Some(resume) = &self.resume {
            for word in &resume.argv {
                put("RESUME_ARG", word.as_bytes());
            }
            put("RESUME_CWD", resume.cwd.as_bytes());
            put("RESUME_AT", resume.reported_at_ms.to_string().as_bytes());
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
        let mut resume = ResumeRequest::default();
        let mut resume_cwd = None;
        let mut unreadable = false;
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
                b"HOST" => request.host_environment = value == "1",
                b"CLIENT" => request.client = ClientKind::parse(value.as_bytes()),
                b"HOSTNAME" => request.hostname = client_hostname(value.as_bytes()),
                // A word that is not UTF-8 is no word a program reported: the record goes whole.
                b"RESUME_ARG" => match value.into_string() {
                    Ok(word) => resume.argv.push(word),
                    Err(_) => unreadable = true,
                },
                b"RESUME_CWD" => match value.into_string() {
                    Ok(cwd) => resume_cwd = Some(cwd),
                    Err(_) => unreadable = true,
                },
                b"RESUME_AT" => {
                    resume.reported_at_ms = value.to_string_lossy().parse().unwrap_or(0);
                }
                _ => {
                    if let Some(name) = key.strip_prefix(b"ENV:") {
                        request.env.push((OsString::from_vec(name.to_vec()), value));
                    }
                }
            }
        }
        // A record needs its command and its folder; one without either is none.
        if let Some(cwd) = resume_cwd
            && !resume.argv.is_empty()
            && !unreadable
        {
            resume.cwd = cwd;
            request.resume = Some(resume);
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
            host_environment: false,
            client: None,
            hostname: None,
            resume: None,
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
            host_environment: true,
            client: Some(ClientKind::Pane),
            hostname: Some("joels-macbook.local".into()),
            resume: None,
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded, request);
    }

    /// A client says what it is and where it runs (#688), and a daemon keeps only a kind it knows
    /// and a hostname it can show: an unknown kind and an unprintable or oversized name are none.
    /// An attach with neither, an older client's, is the same request it always was.
    #[test]
    fn an_attach_names_its_kind_and_hostname_and_a_bad_one_is_none() {
        let with = |entries: &[u8]| [&[3u8; 16][..], entries].concat();
        let decoded = AttachRequest::decode(&with(b"CLIENT=cli\0HOSTNAME=box\0")).unwrap();
        assert_eq!(decoded.client, Some(ClientKind::Cli));
        assert_eq!(decoded.hostname.as_deref(), Some("box"));
        let decoded = AttachRequest::decode(&with(b"CLIENT=robot\0HOSTNAME=a\x1bb\0")).unwrap();
        assert_eq!((decoded.client, decoded.hostname), (None, None));
        let long = [
            b"HOSTNAME=".as_slice(),
            &[b'a'; MAX_HOSTNAME_BYTES + 1],
            b"\0",
        ]
        .concat();
        assert_eq!(AttachRequest::decode(&with(&long)).unwrap().hostname, None);
        let longest = "a".repeat(MAX_HOSTNAME_BYTES);
        assert_eq!(client_hostname(longest.as_bytes()), Some(longest));
        assert_eq!(client_hostname(b""), None);
        assert_eq!(client_hostname(&[0xff]), None);
        let older = AttachRequest::decode(&with(b"COLS=80\0")).unwrap();
        assert_eq!((older.client, older.hostname), (None, None));
    }

    /// A recreating attach carries its tab's resume record (#825) word for word, in order, with
    /// the words a shell would split or expand kept whole; a record missing its command or its
    /// folder is none, and the record is never printed.
    #[test]
    fn an_attach_carries_a_resume_record_whole_and_never_prints_it() {
        let resume = ResumeRequest {
            argv: vec![
                "/opt/bin/claude".into(),
                "--resume".into(),
                "two words".into(),
                "a=b".into(),
                String::new(),
            ],
            cwd: "/work/a b".into(),
            reported_at_ms: 1_795_543_200_000,
        };
        let request = AttachRequest {
            id: Some(SessionId([5u8; 16])),
            resume: Some(resume.clone()),
            ..Default::default()
        };
        let decoded = AttachRequest::decode(&request.encode()).expect("decode");
        assert_eq!(decoded.resume, Some(resume));
        assert_eq!(
            format!("{:?}", decoded.resume),
            "Some(ResumeRequest(claude))"
        );
        assert!(!format!("{decoded:?}").contains("two words"));

        let with = |entries: &[u8]| [&[3u8; 16][..], entries].concat();
        let decode = |entries: &[u8]| AttachRequest::decode(&with(entries)).unwrap().resume;
        assert_eq!(decode(b"RESUME_ARG=vim\0"), None, "no folder");
        assert_eq!(decode(b"RESUME_CWD=/w\0"), None, "no command");
        assert_eq!(
            decode(b"RESUME_ARG=\xff\0RESUME_CWD=/w\0"),
            None,
            "not UTF-8"
        );
        assert_eq!(decode(b"COLS=80\0"), None, "an attach that never had one");
    }

    /// The client's environment a remote pane may hand its host (ADR 0074), and nothing else.
    #[test]
    fn a_host_attach_keeps_only_the_terminal_locale_and_session_variables() {
        let entry = |key: &str, value: &str| (OsString::from(key), OsString::from(value));
        let kept = host_attach_environment(vec![
            entry("TERM", "xterm-ghostty"),
            entry("COLORTERM", "truecolor"),
            entry("TERM_PROGRAM", "ghostty"),
            entry("TERM_PROGRAM_VERSION", "1.2.3"),
            entry("LANG", "en_GB.UTF-8"),
            entry("LC_ALL", "en_GB.UTF-8"),
            entry("LC_CTYPE", "UTF-8"),
            entry("WORKROOM_SESSION_KEEPALIVE", "1"),
            entry("PATH", "/opt/homebrew/bin"),
            entry("HOME", "/Users/mac"),
            entry("SHELL", "/bin/zsh"),
            entry("USER", "mac"),
            entry("TERMINFO", "/Applications/Workroom.app/terminfo"),
            entry("LCX", "no"),
            entry("SSH_AUTH_SOCK", "/tmp/agent"),
        ]);
        let names: Vec<&str> = kept.iter().map(|(k, _)| k.to_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "TERM",
                "COLORTERM",
                "TERM_PROGRAM",
                "TERM_PROGRAM_VERSION",
                "LANG",
                "LC_ALL",
                "LC_CTYPE",
                "WORKROOM_SESSION_KEEPALIVE",
            ]
        );
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
