//! The NDJSON log stream on stderr (ADR 0013): in `--json` mode a command's progress, a setup or
//! teardown script's output above all, goes to stderr as one JSON object per line, while stdout
//! keeps its one envelope. The app reads it line by line as the script runs.
//!
//! The Rust copy of Go's `jsonLogWriter` and `crSplitter` (`cmd/jsonlog.go`), event for event.
//!
//! `delete-project`'s teardowns (`teardown`) and `add-project --clone`'s progress
//! (`add_project`) write to it; `create` (#677) and `delete` (#678) will too.

use std::io::Write;

use serde::Serialize;

use super::envelope::encode;

/// The most of one line held before it is sent as an event of its own: output that never sends a
/// newline (a hostile git server's endless sideband text) stays bounded, and an event stays under
/// the app's 1 MiB line limit even when every byte needs a six-byte escape.
pub(crate) const MAX_LOG_LINE: usize = 128 << 10;

/// `bytes` as text the way Go turns bytes into a JSON string: each byte that isn't part of valid
/// UTF-8 becomes its own U+FFFD. (`String::from_utf8_lossy` replaces a whole broken sequence with
/// one, so `"\xe2\x80"` would be one U+FFFD here and two in Go.)
pub(crate) fn go_lossy(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len());
    for chunk in bytes.utf8_chunks() {
        text.push_str(chunk.valid());
        for _ in chunk.invalid() {
            text.push('\u{fffd}');
        }
    }
    text
}

/// One event on the stream.
pub(crate) fn write_event<T: Serialize>(out: &mut dyn Write, event: &T) {
    // json.Marshal's encoding, HTML escaped, as Go's writer used.
    let mut line = encode(event, true);
    line.push('\n');
    let _ = out.write_all(line.as_bytes());
}

/// Turns a script's raw output into `{"type":"log","phase":…,"step":…,"text":…}` events, one per
/// line, written to `out` (stderr).
pub(crate) struct LogWriter<W: Write> {
    out: W,
    phase: String,
    /// The create step now running, which tags each event; empty when none.
    pub(crate) step: String,
    /// Bytes received since the last newline, not yet sent.
    pending: Vec<u8>,
}

impl<W: Write> LogWriter<W> {
    pub(crate) fn new(out: W, phase: impl Into<String>) -> LogWriter<W> {
        LogWriter {
            out,
            phase: phase.into(),
            step: String::new(),
            pending: Vec::new(),
        }
    }

    /// Takes the next piece of output, sending each line it completes.
    pub(crate) fn feed(&mut self, bytes: &[u8]) {
        self.pending.extend_from_slice(bytes);
        while let Some(end) = self.pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=end).collect();
            self.emit(&line[..line.len() - 1]);
        }
        while self.pending.len() > MAX_LOG_LINE {
            // Never split a character across two events.
            let mut cut = MAX_LOG_LINE;
            while cut > MAX_LOG_LINE - 4 && is_continuation(self.pending[cut]) {
                cut -= 1;
            }
            let piece: Vec<u8> = self.pending.drain(..cut).collect();
            self.emit(&piece);
        }
    }

    /// Sends what's left without a newline. Call once, after the script ends.
    pub(crate) fn flush(&mut self) {
        if !self.pending.is_empty() {
            let rest = std::mem::take(&mut self.pending);
            self.emit(&rest);
        }
    }

    fn emit(&mut self, line: &[u8]) {
        #[derive(Serialize)]
        struct Event<'a> {
            r#type: &'a str,
            phase: &'a str,
            #[serde(skip_serializing_if = "str::is_empty")]
            step: &'a str,
            text: &'a str,
        }
        let text = go_lossy(line.strip_suffix(b"\r").unwrap_or(line));
        write_event(
            &mut self.out,
            &Event {
                r#type: "log",
                phase: &self.phase,
                step: &self.step,
                text: &text,
            },
        );
    }
}

/// Whether `byte` continues a UTF-8 character rather than starting one (Go's `!utf8.RuneStart`).
fn is_continuation(byte: u8) -> bool {
    byte & 0xC0 == 0x80
}

/// Go's `crSplitter`: a [`LogWriter`] that also ends a line at each lone `\r`, so each redraw of
/// git's progress counter is an event of its own. A `\r\n` stays one line end. Only clone output
/// goes through it: a script's CRLF output must not gain events.
pub(crate) struct CrSplitter<W: Write> {
    log: LogWriter<W>,
    /// The last byte was a `\r`, so a `\n` next is its pair.
    last_cr: bool,
}

impl<W: Write> CrSplitter<W> {
    pub(crate) fn new(log: LogWriter<W>) -> CrSplitter<W> {
        CrSplitter {
            log,
            last_cr: false,
        }
    }

    /// Sends what's left without a line end. Call once, after the clone ends.
    pub(crate) fn flush_log(&mut self) {
        self.log.flush();
    }
}

impl<W: Write> Write for CrSplitter<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let mut out = Vec::with_capacity(bytes.len());
        for &byte in bytes {
            match byte {
                b'\n' if self.last_cr => self.last_cr = false,
                b'\r' => {
                    out.push(b'\n');
                    self.last_cr = true;
                }
                _ => {
                    out.push(byte);
                    self.last_cr = false;
                }
            }
        }
        self.log.feed(&out);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn events(feed: &[&[u8]], step: &str) -> String {
        let mut writer = LogWriter::new(Vec::new(), "setup");
        writer.step = step.to_string();
        for piece in feed {
            writer.feed(piece);
        }
        writer.flush();
        String::from_utf8(writer.out).unwrap()
    }

    #[test]
    fn each_line_is_one_event_and_a_trailing_cr_goes() {
        assert_eq!(
            events(&[b"one\r\ntw", b"o\nthree"], ""),
            concat!(
                "{\"type\":\"log\",\"phase\":\"setup\",\"text\":\"one\"}\n",
                "{\"type\":\"log\",\"phase\":\"setup\",\"text\":\"two\"}\n",
                "{\"type\":\"log\",\"phase\":\"setup\",\"text\":\"three\"}\n",
            )
        );
    }

    #[test]
    fn a_step_tags_each_event_and_html_is_escaped_as_json_marshal_does() {
        assert_eq!(
            events(&[b"<b>&\n"], "fetch"),
            "{\"type\":\"log\",\"phase\":\"setup\",\"step\":\"fetch\",\"text\":\"\\u003cb\\u003e\\u0026\"}\n"
        );
    }

    #[test]
    fn a_lone_cr_ends_a_line_and_a_crlf_split_across_writes_stays_one() {
        let mut splitter = CrSplitter::new(LogWriter::new(Vec::new(), "clone"));
        for piece in [&b"Receiving 1%\rReceiving 2%\r"[..], b"\ndone\r\n", b"tail"] {
            splitter.write_all(piece).unwrap();
        }
        splitter.flush_log();
        let texts: Vec<String> = String::from_utf8(splitter.log.out)
            .unwrap()
            .lines()
            .map(|line| {
                serde_json::from_str::<serde_json::Value>(line).unwrap()["text"].to_string()
            })
            .collect();
        assert_eq!(
            texts,
            [
                "\"Receiving 1%\"",
                "\"Receiving 2%\"",
                "\"done\"",
                "\"tail\""
            ]
        );
    }

    #[test]
    fn invalid_utf8_becomes_one_replacement_per_byte_as_in_go() {
        assert_eq!(go_lossy(b"a\xe2\x80b\xff"), "a\u{fffd}\u{fffd}b\u{fffd}");
    }

    #[test]
    fn a_line_without_a_newline_is_sent_in_bounded_pieces_without_splitting_a_character() {
        // A two-byte character straddles the cut: the piece ends before it.
        let mut long = vec![b'a'; MAX_LOG_LINE - 1];
        long.extend_from_slice("é".as_bytes());
        long.extend_from_slice(b"tail");
        let mut writer = LogWriter::new(Vec::new(), "setup");
        writer.feed(&long);
        let first: Vec<String> = String::from_utf8(writer.out.clone())
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(first.len(), 1, "one piece sent before the flush");
        let event: serde_json::Value = serde_json::from_str(&first[0]).unwrap();
        assert_eq!(event["text"].as_str().unwrap().len(), MAX_LOG_LINE - 1);
        writer.flush();
        let all = String::from_utf8(writer.out).unwrap();
        let last: serde_json::Value = serde_json::from_str(all.lines().last().unwrap()).unwrap();
        assert_eq!(last["text"], "étail");
    }
}
