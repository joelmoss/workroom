//! The multiplex envelope: stream id, service kind, payload — versioned from the first commit.
//!
//! **Why the version lives in a handshake and not in every envelope.** The design doc asks for a
//! "versioned multiplex envelope" and then says what makes that versioning *real rather than
//! ceremonial*: an agent on a suspended VM can be older than the app reconnecting to it, and the
//! open question is whether reconnecting **replaces** the running agent — killing the pty children
//! the whole feature exists to preserve — or **negotiates** with the old one. Only negotiation
//! preserves the children, and negotiation needs one exchange at connect time, not a version tag
//! repeated on every frame. A per-envelope version field would cost 2 bytes on every chunk of
//! terminal output and still not tell either side what the other supports.
//!
//! So: [`Hello`] is exchanged once, both sides take the **lower** of the two protocol versions,
//! and every envelope after that is untagged. An agent that cannot satisfy the client's minimum
//! says so and keeps running, rather than being replaced.
//!
//! Wire shape, all integers big-endian to match the frame codec:
//!
//! ```text
//! Hello:     "WRA1" | protocol_version: u16 | build_len: u8 | build: [u8]
//! Envelope:  service: u8 | stream: u32 | length: u32 | payload: [u8]
//! ```

use std::collections::VecDeque;

/// Bumped when the wire changes in a way an older peer cannot parse, OR when a new service is
/// added that an older agent would silently drop rather than answer (`Service::Vcs`, added at 2 —
/// an older agent has no `vcs::dispatch` at all, so an unversioned capability probe would just
/// hang until its own timeout; `Service::File`, added at 3, for the same reason — `serve.rs`'s
/// dispatch returns silently for a service byte it does not handle). `MIN_SUPPORTED` stays untouched by such bumps: negotiation still
/// takes the lower of the two sides' versions for the services both already understand (Terminal,
/// Control), so a newer app still drives an older agent left running rather than replacing it —
/// only a version-gated service (checked against the peer's raw `Hello.protocol_version`, not the
/// negotiated minimum) refuses to talk to a peer that predates it.
pub const PROTOCOL_VERSION: u16 = 4;
pub const MIN_SUPPORTED_VERSION: u16 = 1;
/// The minimum peer version that understands `Service::Vcs`. Checked directly against a peer's
/// `Hello.protocol_version` by VCS clients — never folded into `negotiate`'s minimum, which would
/// incorrectly refuse Terminal/Control traffic with a pre-VCS agent too.
pub const MIN_VCS_VERSION: u16 = 2;
/// The minimum peer version that understands `Service::File`. Same rule as `MIN_VCS_VERSION`: a
/// File client checks the peer's raw `Hello.protocol_version` against this BEFORE sending anything,
/// because a protocol-2 agent drops a File envelope without answering it and the request would
/// otherwise wait out its own timeout. Never folded into `negotiate`.
pub const MIN_FILE_VERSION: u16 = 3;
/// The minimum peer version that understands `Service::Status`. Same rule again: a protocol-3
/// agent drops a Status envelope without answering it.
pub const MIN_STATUS_VERSION: u16 = 4;

/// Sent first by both sides. The magic is here so a peer that is not an agent at all — a login
/// banner, an MOTD, an ssh warning printed onto the stream — fails immediately and legibly
/// instead of being parsed as a service byte and a length.
pub const MAGIC: [u8; 4] = *b"WRA1";

pub const ENVELOPE_HEADER_SIZE: usize = 9;
/// Matches the frame codec's cap: an envelope carries one frame and nothing larger.
pub const MAX_ENVELOPE_PAYLOAD: usize = 1 << 20;

/// Which service a stream belongs to. Terminal and Control shipped in Phase 1, Vcs and File in
/// Phase 2, Status (the wakefulness service, protocol 4) after them. The envelope is the thing that
/// had to be right from the first commit: adding Status later was not a wire change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Service {
    /// Session control that is not attached to any one stream: list, kill, hello.
    Control = 0x00,
    Terminal = 0x01,
    Vcs = 0x02,
    File = 0x03,
    Status = 0x04,
}

impl Service {
    pub fn from_u8(raw: u8) -> Option<Self> {
        Some(match raw {
            0x00 => Self::Control,
            0x01 => Self::Terminal,
            0x02 => Self::Vcs,
            0x03 => Self::File,
            0x04 => Self::Status,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub protocol_version: u16,
    /// Free-form build identifier, for logs and crash reports. Never parsed for behaviour —
    /// behaviour comes from `protocol_version` alone, so that a build string that drifts or gets
    /// truncated can never change what the two sides do.
    pub build: String,
}

impl Hello {
    pub fn current(build: impl Into<String>) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            build: build.into(),
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let build = self.build.as_bytes();
        let build = &build[..build.len().min(u8::MAX as usize)];
        let mut out = Vec::with_capacity(MAGIC.len() + 3 + build.len());
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&self.protocol_version.to_be_bytes());
        out.push(build.len() as u8);
        out.extend_from_slice(build);
        out
    }

    /// `Ok(None)` means the greeting has not arrived in full yet.
    pub fn decode(bytes: &[u8]) -> Result<Option<(Hello, usize)>, ProtocolError> {
        if bytes.len() < MAGIC.len() + 3 {
            // Fail fast on a prefix that already cannot be the magic, rather than waiting for
            // bytes that will never make it valid — otherwise an ssh banner stalls the connection
            // instead of reporting it.
            let seen = bytes.len().min(MAGIC.len());
            if bytes[..seen] != MAGIC[..seen] {
                return Err(ProtocolError::NotAnAgent);
            }
            return Ok(None);
        }
        if bytes[..MAGIC.len()] != MAGIC {
            return Err(ProtocolError::NotAnAgent);
        }
        let version = u16::from_be_bytes([bytes[4], bytes[5]]);
        let build_len = bytes[6] as usize;
        let end = MAGIC.len() + 3 + build_len;
        if bytes.len() < end {
            return Ok(None);
        }
        let build = String::from_utf8_lossy(&bytes[MAGIC.len() + 3..end]).into_owned();
        Ok(Some((
            Hello {
                protocol_version: version,
                build,
            },
            end,
        )))
    }
}

/// The negotiated result: the lower of the two versions, provided both sides can still speak it.
///
/// Taking the lower version is what keeps a long-lived agent alive across an app upgrade. The
/// failure case is deliberately *not* "replace the agent": it is an error the caller surfaces, so
/// that killing a workroom's running processes is always a decision someone made rather than a
/// side effect of reconnecting.
pub fn negotiate(local: &Hello, remote: &Hello) -> Result<u16, ProtocolError> {
    let agreed = local.protocol_version.min(remote.protocol_version);
    if agreed < MIN_SUPPORTED_VERSION {
        return Err(ProtocolError::VersionTooOld {
            theirs: remote.protocol_version,
            minimum: MIN_SUPPORTED_VERSION,
        });
    }
    Ok(agreed)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Envelope {
    pub service: Service,
    /// Identifies one logical stream within the connection. Stream 0 is reserved for
    /// service-level messages that belong to no particular stream.
    pub stream: u32,
    pub payload: Vec<u8>,
}

impl Envelope {
    pub fn new(service: Service, stream: u32, payload: Vec<u8>) -> Self {
        Self {
            service,
            stream,
            payload,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        assert!(
            self.payload.len() <= MAX_ENVELOPE_PAYLOAD,
            "envelope payload {} exceeds the {MAX_ENVELOPE_PAYLOAD}-byte cap",
            self.payload.len()
        );
        let mut out = Vec::with_capacity(ENVELOPE_HEADER_SIZE + self.payload.len());
        out.push(self.service as u8);
        out.extend_from_slice(&self.stream.to_be_bytes());
        out.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.payload);
        out
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("peer did not send the agent greeting (got something else on the stream)")]
    NotAnAgent,
    #[error(
        "peer speaks protocol {theirs}, which is below the minimum {minimum} this build supports"
    )]
    VersionTooOld { theirs: u16, minimum: u16 },
    #[error("envelope payload of {0} bytes exceeds the {MAX_ENVELOPE_PAYLOAD}-byte cap")]
    EnvelopeTooLarge(usize),
    #[error("unknown service {0:#04x}")]
    UnknownService(u8),
    #[error("decoder already failed on an earlier envelope")]
    DecoderFailed,
}

/// Same sticky-failure contract as the frame decoder: a desynchronised multiplex cannot be
/// resynchronised by guessing, and pretending otherwise delivers one stream's bytes to another.
#[derive(Debug, Default)]
pub struct EnvelopeDecoder {
    buffer: VecDeque<u8>,
    failed: bool,
}

impl EnvelopeDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn buffered_len(&self) -> usize {
        self.buffer.len()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        if self.failed {
            return;
        }
        self.buffer.extend(bytes);
    }

    pub fn next_envelope(&mut self) -> Result<Option<Envelope>, ProtocolError> {
        if self.failed {
            return Err(ProtocolError::DecoderFailed);
        }
        if self.buffer.len() < ENVELOPE_HEADER_SIZE {
            return Ok(None);
        }
        let raw_service = self.buffer[0];
        let stream = u32::from_be_bytes([
            self.buffer[1],
            self.buffer[2],
            self.buffer[3],
            self.buffer[4],
        ]);
        let length = u32::from_be_bytes([
            self.buffer[5],
            self.buffer[6],
            self.buffer[7],
            self.buffer[8],
        ]) as usize;

        // Length before service, for the same reason the frame codec checks length before kind.
        if length > MAX_ENVELOPE_PAYLOAD {
            self.failed = true;
            return Err(ProtocolError::EnvelopeTooLarge(length));
        }
        if self.buffer.len() - ENVELOPE_HEADER_SIZE < length {
            return Ok(None);
        }
        let Some(service) = Service::from_u8(raw_service) else {
            self.failed = true;
            return Err(ProtocolError::UnknownService(raw_service));
        };

        self.buffer.drain(..ENVELOPE_HEADER_SIZE);
        let payload: Vec<u8> = self.buffer.drain(..length).collect();
        Ok(Some(Envelope {
            service,
            stream,
            payload,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::frame::{Frame, FrameDecoder, FrameKind};

    #[test]
    fn hello_round_trips() {
        let hello = Hello::current("wr-agent 0.1.0 (test)");
        let bytes = hello.encode();
        let (decoded, consumed) = Hello::decode(&bytes).unwrap().expect("complete");
        assert_eq!(decoded, hello);
        assert_eq!(consumed, bytes.len());
    }

    #[test]
    fn hello_needs_more_bytes_rather_than_failing() {
        let bytes = Hello::current("build").encode();
        for cut in 0..bytes.len() {
            assert_eq!(Hello::decode(&bytes[..cut]).unwrap(), None, "cut at {cut}");
        }
    }

    /// An ssh banner or MOTD on the stream must fail immediately and legibly, not stall waiting
    /// for bytes that can never make the greeting valid.
    #[test]
    fn rejects_a_peer_that_is_not_an_agent() {
        assert_eq!(
            Hello::decode(b"Welcome to Ubuntu 24.04 LTS\r\n"),
            Err(ProtocolError::NotAnAgent)
        );
        assert_eq!(Hello::decode(b"X"), Err(ProtocolError::NotAnAgent));
        // But a genuine PREFIX of the magic is not yet a failure — the rest may still arrive.
        // "Welcome" above is caught at its second byte, which is why the banner fails fast.
        assert_eq!(Hello::decode(b"W").unwrap(), None);
        assert_eq!(Hello::decode(b"WRA").unwrap(), None);
    }

    #[test]
    fn negotiation_takes_the_lower_version() {
        let newer = Hello {
            protocol_version: 7,
            build: "app".into(),
        };
        let older = Hello {
            protocol_version: 1,
            build: "agent asleep since last release".into(),
        };
        assert_eq!(negotiate(&newer, &older).unwrap(), 1);
        assert_eq!(negotiate(&older, &newer).unwrap(), 1);
    }

    #[test]
    fn negotiation_refuses_a_peer_below_the_minimum() {
        let ours = Hello::current("app");
        let ancient = Hello {
            protocol_version: 0,
            build: "prehistoric".into(),
        };
        assert_eq!(
            negotiate(&ours, &ancient),
            Err(ProtocolError::VersionTooOld {
                theirs: 0,
                minimum: MIN_SUPPORTED_VERSION
            })
        );
    }

    #[test]
    fn envelope_round_trips_and_preserves_stream_identity() {
        let envelope = Envelope::new(Service::Terminal, 0xDEAD_BEEF, b"payload".to_vec());
        let mut decoder = EnvelopeDecoder::new();
        decoder.push(&envelope.encode());
        assert_eq!(decoder.next_envelope().unwrap(), Some(envelope));
    }

    #[test]
    fn interleaved_streams_stay_separate() {
        let mut bytes = Vec::new();
        for (stream, body) in [(1u32, &b"one"[..]), (2, b"two"), (1, b"one again")] {
            bytes.extend(Envelope::new(Service::Terminal, stream, body.to_vec()).encode());
        }
        let mut decoder = EnvelopeDecoder::new();
        decoder.push(&bytes);
        let got: Vec<(u32, Vec<u8>)> = std::iter::from_fn(|| decoder.next_envelope().unwrap())
            .map(|e| (e.stream, e.payload))
            .collect();
        assert_eq!(
            got,
            vec![
                (1, b"one".to_vec()),
                (2, b"two".to_vec()),
                (1, b"one again".to_vec())
            ]
        );
    }

    #[test]
    fn reassembles_an_envelope_split_across_pushes() {
        let envelope = Envelope::new(Service::Vcs, 9, vec![3; 5000]);
        let encoded = envelope.encode();
        let mut decoder = EnvelopeDecoder::new();
        for chunk in encoded.chunks(97) {
            decoder.push(chunk);
        }
        assert_eq!(decoder.next_envelope().unwrap(), Some(envelope));
    }

    #[test]
    fn rejects_an_unknown_service_and_stays_failed() {
        let mut decoder = EnvelopeDecoder::new();
        decoder.push(&[0xEE, 0, 0, 0, 1, 0, 0, 0, 0]);
        assert_eq!(
            decoder.next_envelope(),
            Err(ProtocolError::UnknownService(0xEE))
        );
        decoder.push(&Envelope::new(Service::Control, 0, vec![]).encode());
        assert_eq!(decoder.next_envelope(), Err(ProtocolError::DecoderFailed));
    }

    #[test]
    fn rejects_an_oversized_envelope() {
        let mut header = vec![Service::Terminal as u8, 0, 0, 0, 1];
        header.extend_from_slice(&((MAX_ENVELOPE_PAYLOAD + 1) as u32).to_be_bytes());
        let mut decoder = EnvelopeDecoder::new();
        decoder.push(&header);
        assert_eq!(
            decoder.next_envelope(),
            Err(ProtocolError::EnvelopeTooLarge(MAX_ENVELOPE_PAYLOAD + 1))
        );
    }

    /// The layering the whole design rests on: a terminal frame travels inside an envelope, and
    /// comes back out byte-identical after crossing a stream that chunks arbitrarily.
    #[test]
    fn a_terminal_frame_survives_the_envelope_over_a_chunking_transport() {
        let frame = Frame::new(FrameKind::Output, b"\x1b[1;31mred\x1b[0m".to_vec());
        let envelope = Envelope::new(Service::Terminal, 42, frame.encode());
        let wire = envelope.encode();

        let mut envelopes = EnvelopeDecoder::new();
        for chunk in wire.chunks(3) {
            envelopes.push(chunk);
        }
        let received = envelopes.next_envelope().unwrap().expect("envelope");
        assert_eq!(received.stream, 42);
        assert_eq!(received.service, Service::Terminal);

        let mut frames = FrameDecoder::new();
        frames.push(&received.payload);
        assert_eq!(frames.next_frame().unwrap(), Some(frame));
    }
}
