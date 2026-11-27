//! The Program Resume Protocol's wire format (OSC 7577): finding reports in a pty's raw output,
//! checking their `mac` and `time`, and parsing what they ask for. Pure functions, with no session
//! or process state; `super::Resume` decides what an accepted report does.
//!
//! Ported from herdr-core (herdrdev/herdr-core#429, `crates/herdr-core/src/resume/protocol.rs` at
//! `0cb50d57832f3ebb69157ce7f023fbbc520181a8`), Licensed under the Apache License, Version 2.0
//! (`LICENSE` beside this file). Changed from the original for Workroom: SHA-256 and base64 come
//! from this crate's `util` instead of herdr-core's; the reasons a report is ignored are returned
//! (`super::Reason`, shared with every other reason a report doesn't count) so the daemon can log
//! them; the scanner's stream offset is its caller's (`Stream::feed`), which a hand-off
//! carries; Windows path rules are dropped; the tests moved to
//! `protocol/tests.rs`; and `workroom_exit` and `workroom_hook` read Workroom's own keys.

use std::collections::HashSet;
use std::path::Path;

use super::Reason;

/// What opens a report: `ESC ] 7577 ;`.
pub(super) const OPEN: &[u8] = b"\x1b]7577;";
/// The most a whole frame may be, opener and terminator included. Longer is dropped unread.
pub(super) const LIMIT: usize = 8192;

/// A scanner over one session's raw pty output, carried across reads, so a report split at any
/// byte is still found. The offset it is fed with counts every byte of the stream; a report is
/// returned with the offset just past its terminator, which `Resume` uses to refuse a replayed
/// report. The offset is the caller's, which a hand-off carries; the scanner's place inside a
/// report it has not finished is not.
#[derive(Clone, Default, PartialEq)]
pub(super) struct Stream {
    frame: Frame,
    body: Vec<u8>,
}

#[derive(Clone, Copy, Default, PartialEq)]
enum Frame {
    #[default]
    Ground,
    Escape {
        report: bool,
    },
    Osc(usize),
    Body,
    Discard {
        bel: bool,
    },
}

impl Stream {
    /// Every report `bytes` completes, each with the stream offset just past it. `offset` is the
    /// stream's before `bytes`, and is moved on past them.
    pub(super) fn feed(&mut self, offset: &mut u64, mut bytes: &[u8]) -> Vec<(u64, Vec<u8>)> {
        let mut reports = Vec::new();
        loop {
            if matches!(self.frame, Frame::Ground) {
                let skip = bytes
                    .iter()
                    .position(|&byte| byte == 0x1b)
                    .unwrap_or(bytes.len());
                *offset += skip as u64;
                bytes = &bytes[skip..];
            }
            let Some((&byte, rest)) = bytes.split_first() else {
                break;
            };
            bytes = rest;
            *offset += 1;
            let frame = self.frame;
            if matches!(
                (frame, byte),
                (Frame::Escape { report: true }, b'\\') | (Frame::Body, 7)
            ) {
                let terminator_len = if byte == 7 { 1 } else { 2 };
                if OPEN.len() + self.body.len() + terminator_len <= LIMIT {
                    reports.push((*offset, std::mem::take(&mut self.body)));
                }
                self.body.clear();
                self.frame = Frame::Ground;
                continue;
            }
            if matches!(frame, Frame::Escape { .. }) || matches!(byte, 7 | 0x18 | 0x1a) {
                self.body.clear();
            }
            self.frame = match (frame, byte) {
                (_, 0x1b) => Frame::Escape {
                    report: matches!(frame, Frame::Body),
                },
                (Frame::Escape { .. }, b']') => Frame::Osc(2),
                (Frame::Escape { .. }, b'P' | b'X' | b'^' | b'_') => Frame::Discard { bel: false },
                (Frame::Ground | Frame::Escape { .. }, _) | (_, 0x18 | 0x1a) => Frame::Ground,
                (Frame::Discard { bel: false }, _) => frame,
                (_, 7) => Frame::Ground,
                (Frame::Osc(i), byte) if byte == OPEN[i] && i + 1 == OPEN.len() => Frame::Body,
                (Frame::Osc(i), byte) if byte == OPEN[i] => Frame::Osc(i + 1),
                (Frame::Body, byte) if OPEN.len() + self.body.len() + 1 < LIMIT => {
                    self.body.push(byte);
                    Frame::Body
                }
                _ => Frame::Discard { bel: true },
            };
        }
        reports
    }
}

/// What an authenticated, well-formed report asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Action {
    /// `clear=1`: the owner should no longer be resumed.
    Clear,
    /// `argv` (and maybe `cwd`): the command that brings the owner back.
    Set {
        argv: Vec<String>,
        cwd: Option<String>,
    },
}

/// A report whose `mac` and `time` checked out. `action` is `None` when its body is malformed or
/// asks for something this terminal does not support: the spec calls that rejected.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Report {
    pub pid: u32,
    pub time: u64,
    pub action: Option<Action>,
}

/// How far a report's `time` may be from the daemon's clock, either way (the spec's suggestion).
pub(super) const WINDOW_SECONDS: u64 = 60;

/// The `mac` a body is sent with: SHA-256 of the body before `:mac=`, a `:` and the token, in
/// lowercase hex.
pub(super) fn mac(body: &[u8], token: &str) -> String {
    let mut input = Vec::with_capacity(body.len() + 1 + token.len());
    input.extend_from_slice(body);
    input.push(b':');
    input.extend_from_slice(token.as_bytes());
    crate::util::sha256_hex(&input)
}

fn number<T: std::str::FromStr>(s: &[u8]) -> Option<T> {
    if s.first().is_none_or(|b| !matches!(b, b'1'..=b'9')) || !s.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(s).ok()?.parse().ok()
}

/// The value of an envelope key (`pid`, `time`), when every copy of it agrees.
fn envelope<'a>(body: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let mut values = body
        .split(|b| *b == b':')
        .filter_map(|pair| pair.strip_prefix(key));
    let first = values.next()?;
    values.all(|value| value == first).then_some(first)
}

/// Checks a report body's `mac` against `token` and its `time` against `now` (Unix seconds), then
/// parses it. A report that fails is ignored (`Reason::BadMac`, `StaleTime` or `NoPid`): it
/// changes nothing, since nobody who knows the token can be shown to have sent it.
pub(super) fn authenticate(body: &[u8], token: &str, now: u64) -> Result<Report, Reason> {
    let end = body
        .len()
        .checked_sub(b":mac=".len() + 64)
        .ok_or(Reason::BadMac)?;
    let (body, suffix) = body.split_at(end);
    let sent = suffix.strip_prefix(b":mac=").ok_or(Reason::BadMac)?;
    let expected = mac(body, token);
    // Compared in constant time, so a timing difference says nothing about the token.
    if sent
        .iter()
        .zip(expected.bytes())
        .fold(0, |diff, (a, b)| diff | (a ^ b))
        != 0
    {
        return Err(Reason::BadMac);
    }
    let time: u64 = envelope(body, b"time=")
        .and_then(number)
        .ok_or(Reason::StaleTime)?;
    if now.abs_diff(time) > WINDOW_SECONDS {
        return Err(Reason::StaleTime);
    }
    let pid = envelope(body, b"pid=")
        .and_then(number)
        .ok_or(Reason::NoPid)?;
    Ok(Report {
        pid,
        time,
        action: std::str::from_utf8(body).ok().and_then(parse),
    })
}

/// The status a resumed program exited with, in an authenticated `clear=1` report's Workroom key
/// `workroomexit` (`launch::run_launch`, #825). Unknown lowercase keys are the spec's to ignore,
/// so any other terminal reads the report as a plain clear.
pub(super) fn workroom_exit(body: &[u8]) -> Option<i32> {
    envelope(body, b"workroomexit=").and_then(number)
}

/// Whether an authenticated `clear=1` report carries Workroom's key `workroomhook=1`: the
/// session's shell saying, as its Workroom hook loads (`launch::run_hook`, #825), that the hook
/// runs in it. Any other terminal reads it as a plain clear of the shell's records, which a shell
/// that has only just started has none of.
pub(super) fn workroom_hook(body: &[u8]) -> bool {
    envelope(body, b"workroomhook=") == Some(b"1".as_slice())
}

/// One base64 field as text: canonical (with or without its padding), valid UTF-8, and with no
/// control characters.
fn decode(text: &str) -> Option<String> {
    let bytes = crate::util::base64_decode(text)?;
    let canonical = crate::util::base64(&bytes);
    if text != canonical && text != canonical.trim_end_matches('=') {
        return None;
    }
    let text = String::from_utf8(bytes).ok()?;
    (!text.chars().any(char::is_control)).then_some(text)
}

/// Whether `argv[0]` is a command the spec allows: an absolute path, or a bare name to look up on
/// PATH (no separator, not an option).
fn command(text: &str) -> bool {
    let path = Path::new(text);
    path.is_absolute()
        || (!text.starts_with('-')
            && !text.chars().any(std::path::is_separator)
            && matches!(
                path.components().next(),
                Some(std::path::Component::Normal(_))
            ))
}

/// Parses an authenticated body strictly; `None` rejects it.
fn parse(body: &str) -> Option<Action> {
    const KEYS: &[&str] = &["pid", "time", "mac", "argv", "cwd", "clear", "need"];
    let mut keys = HashSet::from(["mac"]);
    let (mut argv, mut cwd, mut clear) = (None, None, false);
    for pair in body.split(':') {
        let (key, value) = pair.split_once('=')?;
        if key.is_empty()
            || !key.bytes().all(|b| b.is_ascii_lowercase())
            || !keys.insert(key)
            || !value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b))
        {
            return None;
        }
        match key {
            "argv" => {
                let args = value
                    .split(',')
                    .take(65)
                    .map(decode)
                    .collect::<Option<Vec<_>>>()?;
                if args.len() > 64 || !command(&args[0]) {
                    return None;
                }
                argv = Some(args);
            }
            "cwd" => {
                let dir = decode(value)?;
                if !Path::new(&dir).is_absolute() {
                    return None;
                }
                cwd = Some(dir);
            }
            "clear" if value == "1" => clear = true,
            "clear" => return None,
            "need" if !value.split(',').all(|key| KEYS.contains(&key)) => return None,
            _ => {}
        }
    }
    match (clear, argv) {
        (true, None) => Some(Action::Clear),
        (false, Some(argv)) => Some(Action::Set { argv, cwd }),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
