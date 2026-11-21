//! What a command printed, for `terminal.command` (#691): the session's output between the shell's
//! OSC 133 C (the command's output starts) and the D that ends it, kept as it arrives and rendered
//! as `terminal.capture` renders a screen once the command has ended.
//!
//! **Between the marks.** The bytes after the C's terminator and before the D's `ESC ]`. So not
//! the command line the shell echoed as it was typed, which comes before the C, nor the prompt
//! after the D. A transcript starts looking for its C once its wait is registered, which is
//! before the command is typed, and takes the first: the session is refused as `Busy` while a
//! command is open, so the first C to come is the command's own (`api::command`).
//!
//! **Kept as it arrives.** The session's reader hands each read to its waiters with the session's
//! locks released (`Waiter::output`), and a transcript's share of that is a scan for `ESC ] 133 ;`
//! and a copy: never a format, so the reader pays about what a regex wait's queue costs it. Nothing
//! is dropped for falling behind, since nothing is queued. Past [`RAW_MAX`] the oldest bytes go,
//! so a command that prints without end holds a bounded tail.
//!
//! **Rendered** in a terminal of the session's size, its own, fed the bytes kept and read back as
//! plain text with soft-wrapped lines joined and the trailing blanks trimmed, as
//! `terminal.capture --unwrap` reads a screen: colours and other escape codes gone, a line a
//! progress bar redrew with `\r` as it last stood, a line the pane wrapped one line, and no final
//! newline. At most [`OUTPUT_MAX`] bytes of it, its last, from a line's start.

/// The most of a command's output a transcript keeps as it arrives, its last bytes: past it the
/// oldest go, and the output is `truncated`.
pub const RAW_MAX: usize = 1024 * 1024;

/// The most text `terminal.command` replies with, its last: past it the oldest lines go, and the
/// output is `truncated`. JSON-escaped, the text of a rendered screen is at most twice this (a
/// tab, a newline, a quote or a backslash), far under a reply's 16 MiB.
pub const OUTPUT_MAX: usize = 1024 * 1024;

/// An OSC 133 mark's start, which the mark's letter follows.
const PREFIX: &[u8] = b"\x1b]133;";

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
/// C1's string terminator, which a terminal reading C1 controls takes as ST.
const ST: u8 = 0x9c;

/// Where a transcript is in the command's life.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum Phase {
    /// Waiting for the command's C.
    #[default]
    Before,
    /// Inside the C, until its terminator: its options are no output.
    Opening,
    /// Inside the C, after an ESC that may be its ST.
    OpeningEscape,
    /// Between the C and the D: every byte is the command's.
    Running,
    /// The D came: nothing after it is the command's.
    Ended,
}

/// One command's output as the session's reader hands it over ([`Transcript::feed`]).
#[derive(Debug, Default)]
pub struct Transcript {
    phase: Phase,
    /// How much of `PREFIX` and a letter the bytes just fed end with: 0 to `PREFIX.len()` for the
    /// prefix, one more once a letter followed it.
    matched: usize,
    /// The letter after the prefix, once `matched` is past it.
    letter: u8,
    /// The command's bytes since its C, the last `RAW_MAX` of them (and up to as many more, till
    /// the next trim).
    raw: Vec<u8>,
    /// Whether bytes were dropped from `raw`'s front.
    dropped: bool,
}

/// What a command printed, rendered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub text: String,
    /// Whether the output was longer than what is kept, so `text` is its end.
    pub truncated: bool,
}

impl Transcript {
    /// Whether the command's D has come.
    #[cfg(test)]
    fn ended(&self) -> bool {
        self.phase == Phase::Ended
    }

    /// The session's next output.
    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            match self.phase {
                Phase::Ended => return,
                Phase::Before => {
                    if let Some(delimiter) = self.mark(byte)
                        && self.letter == b'C'
                    {
                        self.phase = match delimiter {
                            BEL | ST => Phase::Running,
                            ESC => Phase::OpeningEscape,
                            _ => Phase::Opening,
                        };
                    }
                }
                Phase::Opening => {
                    self.phase = match byte {
                        BEL | ST => Phase::Running,
                        ESC => Phase::OpeningEscape,
                        _ => Phase::Opening,
                    };
                }
                Phase::OpeningEscape => {
                    // Any ESC ends a string; one that is no ST starts what follows it, which is
                    // the command's.
                    self.phase = Phase::Running;
                    if byte != b'\\' {
                        self.raw.extend_from_slice(&[ESC, byte]);
                    }
                }
                Phase::Running => {
                    self.raw.push(byte);
                    // The D, or a prompt with none before it (`exec zsh`: a shell that replaced
                    // the one that ran the command), which ends it as the shadow does.
                    if self.mark(byte).is_some() && matches!(self.letter, b'D' | b'A' | b'P' | b'B')
                    {
                        // The mark's prefix, letter and delimiter are no output.
                        let mark = PREFIX.len() + 2;
                        self.raw.truncate(self.raw.len().saturating_sub(mark));
                        self.phase = Phase::Ended;
                        return;
                    }
                }
            }
        }
        if self.raw.len() > 2 * RAW_MAX {
            self.raw.drain(..self.raw.len() - RAW_MAX);
            self.dropped = true;
        }
    }

    /// Steps the mark matcher over `byte`: the delimiter after `ESC ] 133 ; <letter>` (`;`, BEL,
    /// ESC or ST) when `byte` is it, with the letter in `self.letter`.
    fn mark(&mut self, byte: u8) -> Option<u8> {
        if self.matched == PREFIX.len() + 1 {
            self.matched = 0;
            if matches!(byte, b';' | BEL | ESC | ST) {
                return Some(byte);
            }
        } else if self.matched == PREFIX.len() {
            self.letter = byte;
            self.matched += 1;
            return None;
        }
        if byte == PREFIX[self.matched] {
            self.matched += 1;
        } else {
            self.matched = usize::from(byte == ESC);
        }
        None
    }

    /// The command's bytes, as they will be rendered: its last `RAW_MAX`, from after a line's end
    /// when its start was dropped, so the text starts at a line's start, not inside a sequence or a
    /// character. Whether any were dropped.
    fn kept(&self) -> (&[u8], bool) {
        let mut kept = &self.raw[..];
        let mut dropped = self.dropped;
        if kept.len() > RAW_MAX {
            kept = &kept[kept.len() - RAW_MAX..];
            dropped = true;
        }
        if dropped && let Some(newline) = kept.iter().position(|&byte| byte == b'\n') {
            kept = &kept[newline + 1..];
        }
        (kept, dropped)
    }

    /// What the command printed, rendered at `columns` by `rows`, the session's size, so what moved
    /// the cursor lands where it did there; or with `vt`, as it printed it, escape codes and all
    /// (lossy where it isn't UTF-8). zsh's PROMPT_SP mark at its end is not the command's, and
    /// goes from either.
    pub fn output(&self, columns: u16, rows: u16, vt: bool) -> Output {
        let (kept, dropped) = self.kept();
        let kept = without_prompt_sp(kept, columns);
        if vt {
            return Output {
                text: String::from_utf8_lossy(kept).into_owned(),
                truncated: dropped,
            };
        }
        let text = render(kept, columns.max(1), rows.max(1));
        let (text, cut) = last(&text, OUTPUT_MAX);
        Output {
            text: text.to_string(),
            truncated: dropped || cut,
        }
    }
}

/// `raw` without zsh's PROMPT_SP at its end, which zsh prints before its prompt when output
/// didn't end with a line's end, and which comes before the integration's D: its end-of-line
/// mark (`%`, or `#` for root, in reverse video, bold or plain as the terminal has them), then
/// spaces to the pane's last column or the one before it, then `\r`, and with some terminals
/// ` \r` more. The spaces are what tell it from a command's own `50%\r`: nearly a whole line of
/// them, at the session's `columns`.
fn without_prompt_sp(raw: &[u8], columns: u16) -> &[u8] {
    let mut end = raw.len();
    let mut returns = 0;
    while end > 0 && raw[end - 1] == b'\r' {
        returns += 1;
        end -= 1;
        // A space between two returns is the ` \r` some terminals are sent.
        if end > 1 && raw[end - 1] == b' ' && raw[end - 2] == b'\r' {
            end -= 1;
        }
    }
    let spaces = raw[..end]
        .iter()
        .rev()
        .take_while(|&&byte| byte == b' ')
        .count();
    end -= spaces;
    let columns = usize::from(columns);
    if returns == 0 || spaces + 3 < columns || spaces > columns {
        return raw;
    }
    end = before_sgr(raw, end);
    if end == 0 || !matches!(raw[end - 1], b'%' | b'#') {
        return raw;
    }
    &raw[..before_sgr(raw, end - 1)]
}

/// Where the SGR sequences (`ESC [ … m`) that `raw[..end]` ends with start.
fn before_sgr(raw: &[u8], mut end: usize) -> usize {
    while end > 0 && raw[end - 1] == b'm' {
        let body = raw[..end - 1]
            .iter()
            .rev()
            .take_while(|byte| byte.is_ascii_digit() || **byte == b';')
            .count();
        let start = end - 1 - body;
        if start >= 2 && raw[start - 2..start] == [ESC, b'['] {
            end = start - 2;
        } else {
            break;
        }
    }
    end
}

/// The last `max` bytes of `text`, from a line's start when it is cut; whether it was.
fn last(text: &str, max: usize) -> (&str, bool) {
    if text.len() <= max {
        return (text, false);
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    let tail = &text[start..];
    let tail = tail.find('\n').map_or(tail, |newline| &tail[newline + 1..]);
    (tail, true)
}

/// `bytes` as a terminal of `columns` by `rows` shows them, read back as plain text, soft-wrapped
/// lines joined and trailing blanks trimmed, as `terminal.capture --all --unwrap` reads a screen.
#[cfg(feature = "terminal-state")]
fn render(bytes: &[u8], columns: u16, rows: u16) -> String {
    use crate::terminal::shadow::{Capture, Rows};
    let Some(mut terminal) = crate::terminal::vt::ShadowTerminal::new(columns, rows) else {
        return String::from_utf8_lossy(bytes).into_owned();
    };
    terminal.write(bytes);
    terminal
        .capture_text(Capture {
            rows: Rows::All,
            unwrap: true,
            vt: false,
        })
        .unwrap_or_default()
}

/// No terminal to render with: `terminal.command` is refused without terminal-state, as a wait for
/// a command's end is, so this is never reached but for its tests.
#[cfg(not(feature = "terminal-state"))]
fn render(bytes: &[u8], _columns: u16, _rows: u16) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fed(pieces: &[&[u8]]) -> Transcript {
        let mut transcript = Transcript::default();
        for piece in pieces {
            transcript.feed(piece);
        }
        transcript
    }

    /// The bytes between the C's terminator and the D, however the reads split them, and nothing
    /// before the C or after the D: the echoed command line and the prompts.
    #[test]
    fn keeps_the_bytes_between_the_c_and_the_d_however_they_are_split() {
        let stream: &[u8] = b"$ ls\r\n\x1b]133;C\x07one\r\ntwo\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ";
        for split in 0..=stream.len() {
            let (a, b) = stream.split_at(split);
            let transcript = fed(&[a, b]);
            assert!(transcript.ended(), "split at {split}");
            assert_eq!(transcript.raw, b"one\r\ntwo\r\n", "split at {split}");
        }
        let one_at_a_time: Vec<&[u8]> = stream.chunks(1).collect();
        assert_eq!(fed(&one_at_a_time).raw, b"one\r\ntwo\r\n");
    }

    /// A C's options and either terminator are no output; a D before any C (bash's at every
    /// prompt) is no end, and nothing after the end is kept.
    #[test]
    fn a_cs_options_and_terminators_and_a_d_before_it_are_no_output() {
        let transcript =
            fed(&[b"\x1b]133;D;0\x1b\\x\x1b]133;C;cmdline=ls\x1b\\out\x1b]133;D;1\x1b\\after"]);
        assert!(transcript.ended());
        assert_eq!(transcript.raw, b"out");
        let transcript = fed(&[b"\x1b]133;C\x9cout\x1b]133;D\x07"]);
        assert_eq!(transcript.raw, b"out");
        let open = fed(&[b"\x1b]133;Cxyz\x1b]133;C\x07still"]);
        assert!(!open.ended());
        assert_eq!(open.raw, b"still", "`133;Cx` is no mark");
    }

    /// Escape codes are the command's output too: kept, and rendered away.
    #[test]
    fn escape_codes_between_the_marks_are_kept_for_the_render() {
        let transcript =
            fed(&[b"\x1b]133;C\x07\x1b[31mred\x1b[0m \x1b]0;title\x07\x1b\x1b]133;D;0\x07"]);
        assert_eq!(transcript.raw, b"\x1b[31mred\x1b[0m \x1b]0;title\x07\x1b");
    }

    /// Past `RAW_MAX` the oldest bytes go, from a line's start, and the output says it is cut.
    #[test]
    fn a_long_output_keeps_its_last_bytes_from_a_lines_start() {
        let mut transcript = fed(&[b"\x1b]133;C\x07"]);
        let line = b"0123456789abcde\n";
        for _ in 0..(3 * RAW_MAX / line.len()) {
            transcript.feed(line);
        }
        transcript.feed(b"last\x1b]133;D;0\x07");
        let (kept, dropped) = transcript.kept();
        assert!(dropped);
        assert!(kept.len() <= RAW_MAX);
        assert!(kept.starts_with(line), "from a line's start");
        assert!(kept.ends_with(b"\nlast"));
        assert!(transcript.raw.len() <= 2 * RAW_MAX);
    }

    #[test]
    fn the_text_past_its_bound_is_its_last_lines() {
        assert_eq!(last("ab\ncd\nef", 100), ("ab\ncd\nef", false));
        assert_eq!(last("ab\ncd\nef", 4), ("ef", true));
        assert_eq!(last("ab\ncd\nef", 5), ("ef", true), "never a line's middle");
        assert_eq!(last("é\né", 3), ("é", true), "never a character's middle");
    }

    /// Rendered as a screen reads: colours gone, a line redrawn after `\r` as it last stood, no
    /// final newline.
    #[cfg(feature = "terminal-state")]
    #[test]
    fn the_output_is_rendered_as_capture_reads_a_screen() {
        let transcript =
            fed(&[b"\x1b]133;C\x07\x1b[32mok\x1b[0m\r\n10%\r50%\r100%\r\n\x1b]133;D;0\x07"]);
        assert_eq!(
            transcript.output(80, 24, false),
            Output {
                text: "ok\n100%".into(),
                truncated: false,
            }
        );
        assert_eq!(
            fed(&[b"\x1b]133;C\x07\x1b]133;D;0\x07"])
                .output(80, 24, false)
                .text,
            ""
        );
        let wrapped = format!("\x1b]133;C\x07{}\x1b]133;D;0\x07", "x".repeat(30));
        assert_eq!(
            fed(&[wrapped.as_bytes()]).output(10, 5, false).text,
            "x".repeat(30),
            "a line the pane wrapped is one line"
        );
    }

    /// With `vt`, the bytes as the command printed them, escape codes and all.
    #[test]
    fn vt_is_the_bytes_as_printed() {
        let transcript = fed(&[b"\x1b]133;C\x07\x1b[32mok\x1b[0m\r\n\x1b]133;D;0\x07"]);
        assert_eq!(
            transcript.output(80, 24, true),
            Output {
                text: "\x1b[32mok\x1b[0m\r\n".into(),
                truncated: false,
            }
        );
    }

    /// A prompt that comes with no D before it (`exec zsh`) ends the command, as a D does.
    #[test]
    fn a_prompt_with_no_d_ends_the_command() {
        for prompt in ["A;cl=line", "P;k=i", "B"] {
            let bytes = format!("\x1b]133;C\x07replaced\r\n\x1b]133;{prompt}\x07% ");
            let transcript = fed(&[bytes.as_bytes()]);
            assert!(transcript.ended(), "{prompt}");
            assert_eq!(transcript.raw, b"replaced\r\n", "{prompt}");
        }
    }

    /// zsh's PROMPT_SP at the output's end, in reverse video or plain, with `\r` or ` \r` after
    /// it, goes; a command's own `%` with no line of spaces after it stays.
    #[test]
    fn zshs_prompt_sp_is_not_the_commands() {
        let spaces = " ".repeat(79);
        for mark in [
            format!("foo\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m{spaces}\r \r"),
            format!("foo\x1b[7m%\x1b[27m{spaces}\r"),
            format!("foo%{}\r", " ".repeat(78)),
            format!("foo#{spaces}\r \r"),
        ] {
            assert_eq!(without_prompt_sp(mark.as_bytes(), 80), b"foo", "{mark:?}");
        }
        for own in ["50%\r", "50%", "a % b", "100% done\r\n"] {
            assert_eq!(
                without_prompt_sp(own.as_bytes(), 80),
                own.as_bytes(),
                "{own:?}"
            );
        }
    }
}
