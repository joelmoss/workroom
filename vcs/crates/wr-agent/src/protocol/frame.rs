//! The terminal service's wire frame, ported from `macapp/WorkroomSessionProtocol/SessionFrame.swift`.
//!
//! The shape is fixed and already shipped: **1-byte kind, 4-byte big-endian length, payload**,
//! capped at 1 MiB. Swift keeps its copy — a client has to speak the wire — so this is a
//! deliberate, accepted duplication, and these tests are what keep the two honest.
//!
//! Three behaviours of the Swift decoder are load-bearing and reproduced exactly, because a
//! client on the other end depends on them:
//!
//!   * **Failure is sticky.** Once the decoder rejects a frame, every later call fails too. A
//!     stream whose framing has desynchronised cannot be resynchronised by guessing.
//!   * **Length is validated before kind.** An oversized frame carrying an unknown kind reports
//!     `FrameTooLarge`, not `UnknownKind`. Swapping the order would change what a peer is told
//!     about a malformed stream.
//!   * **Partial frames are kept, not consumed.** `next_frame()` returning `None` means "need more
//!     bytes", and the buffer is left ready for them.

use std::collections::VecDeque;

/// Frame kinds, matching `SessionFrameKind`'s raw values exactly. The numbering is grouped
/// deliberately — `0x0*` client→agent, `0x1*` agent→client, `0x2*` control, `0x3*` control
/// replies — and the gaps are room to grow within a group without renumbering.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameKind {
    Attach = 0x01,
    Input = 0x02,
    Resize = 0x03,

    Attached = 0x11,
    Output = 0x12,
    Exited = 0x13,
    Failure = 0x14,

    List = 0x21,
    Info = 0x22,
    Kill = 0x23,
    KillAll = 0x24,
    /// Replace this agent's program with another binary, keeping every session (#230). Payload:
    /// `force:u8`, then the binary's absolute path. See `crate::handoff`.
    HandOff = 0x25,

    Sessions = 0x31,
    Acknowledged = 0x32,
}

impl FrameKind {
    pub fn from_u8(raw: u8) -> Option<Self> {
        Some(match raw {
            0x01 => Self::Attach,
            0x02 => Self::Input,
            0x03 => Self::Resize,
            0x11 => Self::Attached,
            0x12 => Self::Output,
            0x13 => Self::Exited,
            0x14 => Self::Failure,
            0x21 => Self::List,
            0x22 => Self::Info,
            0x23 => Self::Kill,
            0x24 => Self::KillAll,
            0x25 => Self::HandOff,
            0x31 => Self::Sessions,
            0x32 => Self::Acknowledged,
            _ => return None,
        })
    }
}

pub const HEADER_SIZE: usize = 5;
pub const MAX_PAYLOAD_SIZE: usize = 1 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: FrameKind,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: FrameKind, payload: Vec<u8>) -> Self {
        Self { kind, payload }
    }

    pub fn control(kind: FrameKind) -> Self {
        Self {
            kind,
            payload: Vec::new(),
        }
    }

    /// Panics on an oversized payload rather than truncating: a caller building a frame bigger
    /// than the cap has a bug the peer cannot diagnose, and silently sending a short frame turns
    /// it into a desynchronised stream several frames later.
    pub fn encode(&self) -> Vec<u8> {
        assert!(
            self.payload.len() <= MAX_PAYLOAD_SIZE,
            "frame payload {} exceeds the {MAX_PAYLOAD_SIZE}-byte cap",
            self.payload.len()
        );
        let mut out = Vec::with_capacity(HEADER_SIZE + self.payload.len());
        out.push(self.kind as u8);
        out.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.payload);
        out
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FrameError {
    #[error("frame payload of {0} bytes exceeds the {MAX_PAYLOAD_SIZE}-byte cap")]
    FrameTooLarge(usize),
    #[error("unknown frame kind {0:#04x}")]
    UnknownKind(u8),
    #[error("decoder already failed on an earlier frame")]
    DecoderFailed,
}

#[derive(Debug, Default)]
pub struct FrameDecoder {
    buffer: VecDeque<u8>,
    failed: bool,
}

impl FrameDecoder {
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

    /// `Ok(None)` means "need more bytes", and leaves the buffer untouched so the caller can
    /// simply push more. Any `Err` is terminal.
    pub fn next_frame(&mut self) -> Result<Option<Frame>, FrameError> {
        if self.failed {
            return Err(FrameError::DecoderFailed);
        }
        if self.buffer.len() < HEADER_SIZE {
            return Ok(None);
        }

        let raw_kind = self.buffer[0];
        let mut length = 0usize;
        for i in 1..HEADER_SIZE {
            length = (length << 8) | self.buffer[i] as usize;
        }

        // Length first, then kind — see the module doc. Swapping these changes what a peer is
        // told about a malformed stream, and the Swift decoder is the one already deployed.
        if length > MAX_PAYLOAD_SIZE {
            self.failed = true;
            return Err(FrameError::FrameTooLarge(length));
        }
        if self.buffer.len() - HEADER_SIZE < length {
            return Ok(None);
        }
        let Some(kind) = FrameKind::from_u8(raw_kind) else {
            self.failed = true;
            return Err(FrameError::UnknownKind(raw_kind));
        };

        self.buffer.drain(..HEADER_SIZE);
        let payload: Vec<u8> = self.buffer.drain(..length).collect();
        Ok(Some(Frame { kind, payload }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(kind: FrameKind, payload: Vec<u8>) {
        let frame = Frame::new(kind, payload);
        let mut decoder = FrameDecoder::new();
        decoder.push(&frame.encode());
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
    }

    #[test]
    fn round_trips_every_kind() {
        for raw in [
            0x01, 0x02, 0x03, 0x11, 0x12, 0x13, 0x14, 0x21, 0x22, 0x23, 0x24, 0x31, 0x32,
        ] {
            let kind = FrameKind::from_u8(raw).expect("known kind");
            roundtrip(kind, b"payload".to_vec());
            roundtrip(kind, Vec::new());
        }
    }

    #[test]
    fn header_is_one_byte_kind_then_big_endian_length() {
        let encoded = Frame::new(FrameKind::Output, vec![0xAA; 0x0102]).encode();
        assert_eq!(encoded[0], 0x12);
        assert_eq!(&encoded[1..5], &[0x00, 0x00, 0x01, 0x02]);
    }

    /// The case a pipe produces and a socket hides: a header arriving in pieces.
    #[test]
    fn reassembles_a_header_split_across_pushes() {
        let frame = Frame::new(FrameKind::Input, b"hello".to_vec());
        let encoded = frame.encode();
        let mut decoder = FrameDecoder::new();
        for chunk in encoded.chunks(2) {
            let before = decoder.next_frame().unwrap();
            assert!(before.is_none() || chunk.len() < 2);
            decoder.push(chunk);
        }
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
    }

    #[test]
    fn returns_none_without_consuming_a_partial_frame() {
        let encoded = Frame::new(FrameKind::Output, b"abcdef".to_vec()).encode();
        let mut decoder = FrameDecoder::new();
        decoder.push(&encoded[..7]);
        assert_eq!(decoder.next_frame().unwrap(), None);
        assert_eq!(decoder.buffered_len(), 7, "partial frame must be kept");
        decoder.push(&encoded[7..]);
        assert!(decoder.next_frame().unwrap().is_some());
    }

    #[test]
    fn decodes_several_frames_from_one_push() {
        let mut bytes = Frame::new(FrameKind::Input, b"a".to_vec()).encode();
        bytes.extend(Frame::control(FrameKind::List).encode());
        bytes.extend(Frame::new(FrameKind::Output, b"ccc".to_vec()).encode());
        let mut decoder = FrameDecoder::new();
        decoder.push(&bytes);
        let kinds: Vec<FrameKind> = std::iter::from_fn(|| decoder.next_frame().unwrap())
            .map(|f| f.kind)
            .collect();
        assert_eq!(
            kinds,
            vec![FrameKind::Input, FrameKind::List, FrameKind::Output]
        );
        assert_eq!(decoder.buffered_len(), 0);
    }

    #[test]
    fn rejects_an_oversized_frame() {
        let mut decoder = FrameDecoder::new();
        let mut header = vec![FrameKind::Output as u8];
        header.extend_from_slice(&((MAX_PAYLOAD_SIZE + 1) as u32).to_be_bytes());
        decoder.push(&header);
        assert_eq!(
            decoder.next_frame(),
            Err(FrameError::FrameTooLarge(MAX_PAYLOAD_SIZE + 1))
        );
    }

    #[test]
    fn accepts_a_frame_exactly_at_the_cap() {
        let frame = Frame::new(FrameKind::Output, vec![7; MAX_PAYLOAD_SIZE]);
        let mut decoder = FrameDecoder::new();
        decoder.push(&frame.encode());
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
    }

    #[test]
    fn rejects_an_unknown_kind() {
        let mut decoder = FrameDecoder::new();
        decoder.push(&[0x7f, 0, 0, 0, 0]);
        assert_eq!(decoder.next_frame(), Err(FrameError::UnknownKind(0x7f)));
    }

    /// Order matters: the Swift decoder checks length first, so an oversized frame with an
    /// unknown kind reports the size, not the kind. A peer diagnosing a desync sees the same
    /// reason from either implementation.
    #[test]
    fn reports_length_before_kind_when_both_are_wrong() {
        let mut decoder = FrameDecoder::new();
        let mut header = vec![0x7f];
        header.extend_from_slice(&((MAX_PAYLOAD_SIZE + 1) as u32).to_be_bytes());
        decoder.push(&header);
        assert_eq!(
            decoder.next_frame(),
            Err(FrameError::FrameTooLarge(MAX_PAYLOAD_SIZE + 1))
        );
    }

    #[test]
    fn failure_is_sticky_and_later_pushes_are_ignored() {
        let mut decoder = FrameDecoder::new();
        decoder.push(&[0x7f, 0, 0, 0, 0]);
        assert!(decoder.next_frame().is_err());
        decoder.push(&Frame::control(FrameKind::List).encode());
        assert_eq!(decoder.next_frame(), Err(FrameError::DecoderFailed));
    }
}
