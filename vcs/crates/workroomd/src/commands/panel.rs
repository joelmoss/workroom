//! What a person at the CLI is shown in colour: [`Paint`], Go's `ui` colour helpers, and a
//! script's streamed output in a titled, bordered panel, Go's `ui.LogPanel`. `delete`'s teardown
//! writes to one; `create`'s setup (#677) will too. With `--json` the same output goes to stderr
//! as NDJSON events instead (`log`). `trust`'s approval panel (`prompt`) is drawn to the same
//! width in the same colours.

use std::io::Write;

/// Human output's colours, as Go's `ui` helpers (fatih/color) write them, when stdout takes them.
#[derive(Clone, Copy)]
pub(super) struct Paint(pub(super) bool);

impl Paint {
    fn code(self, code: &str, text: &str) -> String {
        if self.0 {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    pub(super) fn green(self, text: &str) -> String {
        self.code("32", text)
    }

    pub(super) fn red(self, text: &str) -> String {
        self.code("31", text)
    }

    pub(super) fn yellow(self, text: &str) -> String {
        self.code("33", text)
    }

    pub(super) fn dim(self, text: &str) -> String {
        self.code("90", text)
    }

    /// Bold, which fatih/color ends with `\x1b[22m` rather than a full reset, around blue.
    pub(super) fn bold_blue(self, text: &str) -> String {
        let blue = self.code("34", text);
        if self.0 {
            format!("\x1b[1m{blue}\x1b[22m")
        } else {
            blue
        }
    }
}

/// The width of a panel's top and bottom rules, as Go's `ui.LogPanel` draws them.
pub(super) const PANEL_WIDTH: usize = 60;

/// Renders each complete line it is given with a gutter border as it arrives. The header is drawn
/// on the first byte, so a script that prints nothing draws no panel. [`LogPanel::close`] ends it.
pub(super) struct LogPanel<W: Write> {
    out: W,
    title: String,
    paint: Paint,
    started: bool,
    /// Bytes received since the last newline, not yet rendered.
    partial: Vec<u8>,
}

impl<W: Write> LogPanel<W> {
    pub(super) fn new(out: W, title: &str, paint: Paint) -> LogPanel<W> {
        LogPanel {
            out,
            title: title.to_string(),
            paint,
            started: false,
            partial: Vec::new(),
        }
    }

    /// Whether the panel has rendered anything: whether the script printed.
    pub(super) fn shown(&self) -> bool {
        self.started
    }

    fn start(&mut self) {
        if self.started {
            return;
        }
        self.started = true;
        let title = format!(" {} ", self.title);
        let rule = PANEL_WIDTH.saturating_sub(2 + title.chars().count());
        let header = format!(
            "{}{}{}\n",
            self.paint.dim("╭─"),
            self.paint.bold_blue(&title),
            self.paint.dim(&"─".repeat(rule))
        );
        self.emit(header.as_bytes());
    }

    fn line(&mut self, line: &[u8]) {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let mut text = format!("{} ", self.paint.dim("│")).into_bytes();
        text.extend_from_slice(line);
        text.push(b'\n');
        self.emit(&text);
    }

    /// A failed write is ignored, as Go's `fmt.Fprintf` is: the script still runs to its end.
    fn emit(&mut self, bytes: &[u8]) {
        let _ = self.out.write_all(bytes);
        let _ = self.out.flush();
    }

    /// Renders what's left of the last line and the footer, which says whether the script `ok`.
    /// A panel never started renders nothing.
    pub(super) fn close(&mut self, ok: bool) {
        if !self.started {
            return;
        }
        if !self.partial.is_empty() {
            let rest = std::mem::take(&mut self.partial);
            self.line(&rest);
        }
        let footer = if ok {
            self.paint.dim(&format!("╰{}", "─".repeat(PANEL_WIDTH - 1)))
        } else {
            let label = format!(" {} failed ", self.title);
            let rule = PANEL_WIDTH.saturating_sub(2 + label.chars().count());
            format!(
                "{}{}{}",
                self.paint.dim("╰─"),
                self.paint.red(&label),
                self.paint.dim(&"─".repeat(rule))
            )
        };
        self.emit(format!("{footer}\n").as_bytes());
    }
}

impl<W: Write> Write for LogPanel<W> {
    /// Takes any piece of output: bytes wait for their newline, then render as a line.
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.start();
        self.partial.extend_from_slice(bytes);
        while let Some(end) = self.partial.iter().position(|&byte| byte == b'\n') {
            let line: Vec<u8> = self.partial.drain(..=end).collect();
            self.line(&line[..line.len() - 1]);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::{LogPanel, Paint};

    fn rendered(chunks: &[&[u8]], ok: bool, paint: bool) -> String {
        let mut out = Vec::new();
        let mut panel = LogPanel::new(&mut out, "Teardown", Paint(paint));
        for chunk in chunks {
            panel.write_all(chunk).expect("write");
        }
        panel.close(ok);
        String::from_utf8(out).expect("UTF-8")
    }

    /// Lines in any chunks, a CRLF's `\r` and a last line without a newline, then the footer, as
    /// Go's panel renders them.
    #[test]
    fn a_panel_renders_each_line_and_its_footer_as_go_does() {
        let top = format!("╭─ Teardown {}\n", "─".repeat(48));
        assert_eq!(
            rendered(&[b"sto", b"pping\r\nnext\nlast"], true, false),
            format!("{top}│ stopping\n│ next\n│ last\n╰{}\n", "─".repeat(59))
        );
        assert_eq!(
            rendered(&[b"boom\n"], false, false),
            format!("{top}│ boom\n╰─ Teardown failed {}\n", "─".repeat(41))
        );
        // Nothing printed draws nothing, whatever the outcome.
        assert_eq!(rendered(&[], false, false), "");
    }

    /// In colour, with the bytes Go's helpers (fatih/color v1.19) write: bold ends with
    /// `\x1b[22m`, the rest with a full reset.
    #[test]
    fn a_panel_is_painted_as_go_paints_it() {
        assert_eq!(
            rendered(&[b"stopping\n"], true, true),
            format!(
                "\x1b[90m╭─\x1b[0m\x1b[1m\x1b[34m Teardown \x1b[0m\x1b[22m\x1b[90m{}\x1b[0m\n\
                 \x1b[90m│\x1b[0m stopping\n\x1b[90m╰{}\x1b[0m\n",
                "─".repeat(48),
                "─".repeat(59)
            )
        );
    }
}
