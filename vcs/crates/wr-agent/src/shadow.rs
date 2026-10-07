//! One name for the shadow terminal whether or not it is compiled in.
//!
//! `terminal-state` is off by default because it pulls a pinned Zig toolchain and a Ghostty
//! checkout into the build. Rather than scatter `#[cfg]` through the session layer — where it
//! would obscure the actual logic and rot the moment someone edits the wrong arm — the feature is
//! resolved exactly once, here. `session.rs` calls the same methods either way; without the
//! feature they do nothing and `replay()` returns no bytes, which is precisely the behaviour
//! before the shadow existed.

#[cfg(feature = "terminal-state")]
pub struct Shadow {
    terminal: Option<crate::terminal::ShadowTerminal>,
    /// The pty's foreground process group when the current progress report arrived: the program
    /// that sent it. Once another group owns the pty, that program is gone (#359).
    progress_owner: Option<libc::pid_t>,
}

#[cfg(not(feature = "terminal-state"))]
pub struct Shadow;

#[cfg(feature = "terminal-state")]
impl Shadow {
    pub fn new(columns: u16, rows: u16) -> Shadow {
        Shadow {
            terminal: crate::terminal::ShadowTerminal::new(columns, rows),
            progress_owner: None,
        }
    }

    /// Every byte the client receives also goes here. Cheap enough to do inline on the output
    /// path: it is the same parse the client's own terminal is doing anyway.
    pub fn write(&mut self, bytes: &[u8]) {
        if let Some(terminal) = self.terminal.as_mut() {
            terminal.write(bytes);
        }
    }

    /// `write` for bytes from the live pty, whose `foreground` process group is then the sender
    /// of any progress report in them. Asked only when a report arrived, so the output path pays
    /// for it once per report, not per read.
    ///
    /// ponytail: sampled after the read, so a reporter that exits within the same read chunk is
    /// recorded as the shell, and its report stays until a REMOVE. A per-report pgid needs the
    /// pty to tag its bytes; add if stale busy is ever seen in practice.
    pub fn write_from_pty(
        &mut self,
        bytes: &[u8],
        foreground: impl FnOnce() -> Option<libc::pid_t>,
    ) {
        let Some(terminal) = self.terminal.as_mut() else {
            return;
        };
        terminal.write(bytes);
        if terminal.take_fresh_report() {
            self.progress_owner = terminal.progress().and_then(|_| foreground());
        }
    }

    pub fn resize(&mut self, columns: u16, rows: u16) {
        if let Some(terminal) = self.terminal.as_mut() {
            terminal.resize(columns, rows);
        }
    }

    /// What to send a client that has just attached, so it sees the session rather than a blank
    /// screen. Empty when there is nothing to show yet.
    pub fn replay(&self) -> Vec<u8> {
        self.terminal
            .as_ref()
            .map(|t| t.replay())
            .unwrap_or_default()
    }

    /// `replay()` for a live session whose pty `foreground` now owns. While the program that sent
    /// the progress report is not in the foreground, killed or crashed without clearing it, the
    /// replay says idle: the app clears its own on the shell's next prompt (OSC 133 D), which the
    /// shadow cannot see. The report is kept, so a program stopped and resumed (^Z, `fg`) is
    /// busy again to clients that attach once it is back; a client that attached while it was
    /// away stays idle until the program's next report.
    pub fn replay_for(&self, foreground: Option<libc::pid_t>) -> Vec<u8> {
        let Some(terminal) = self.terminal.as_ref() else {
            return Vec::new();
        };
        match (self.progress_owner, foreground) {
            (Some(owner), Some(now)) if owner != now => terminal.replay_idle(),
            _ => terminal.replay(),
        }
    }

    /// What to keep on disk for this screen (`crate::screens`): `replay()` without the progress
    /// report or the parser continuation.
    pub fn record(&self) -> Vec<u8> {
        self.terminal
            .as_ref()
            .map(|t| t.record())
            .unwrap_or_default()
    }

    pub fn visible_text(&self) -> String {
        self.terminal
            .as_ref()
            .map(|t| t.visible_text())
            .unwrap_or_default()
    }
}

#[cfg(not(feature = "terminal-state"))]
impl Shadow {
    pub fn new(_columns: u16, _rows: u16) -> Shadow {
        Shadow
    }
    pub fn write(&mut self, _bytes: &[u8]) {}
    pub fn write_from_pty(
        &mut self,
        _bytes: &[u8],
        _foreground: impl FnOnce() -> Option<libc::pid_t>,
    ) {
    }
    pub fn resize(&mut self, _columns: u16, _rows: u16) {}
    /// No shadow, so nothing to repaint: a reattaching client resumes the live stream, which is
    /// how the agent behaved before terminal state existed.
    pub fn replay(&self) -> Vec<u8> {
        Vec::new()
    }
    pub fn replay_for(&self, _foreground: Option<libc::pid_t>) -> Vec<u8> {
        Vec::new()
    }
    pub fn record(&self) -> Vec<u8> {
        Vec::new()
    }
    pub fn visible_text(&self) -> String {
        String::new()
    }
}

#[cfg(all(test, feature = "terminal-state"))]
mod tests {
    use super::*;

    const BUSY: &[u8] = b"\x1b]9;4;3\x1b\\";
    const IDLE: &[u8] = b"\x1b]9;4;0\x1b\\";

    fn has(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    fn busy_from(owner: Option<libc::pid_t>) -> Shadow {
        let mut shadow = Shadow::new(80, 24);
        shadow.write_from_pty(b"working\r\n", || unreachable!("no report, so no question"));
        shadow.write_from_pty(BUSY, || owner);
        shadow
    }

    /// The report follows its sender: busy while it owns the pty, idle while another group does,
    /// busy again when it is back (^Z then `fg`), and kept when nobody can say (#359).
    /// Value: protects=replay_for says busy only while the sender owns the pty, without losing the report; fails_when=the owner comparison inverts, drops the report, or the owner is never noted; why_new=the session test needs job control and timing, this needs neither; seam=none
    #[test]
    fn the_progress_report_follows_the_program_that_sent_it() {
        let shadow = busy_from(Some(10));
        assert!(
            has(&shadow.replay_for(Some(10)), BUSY),
            "the sender owns the pty"
        );
        let elsewhere = shadow.replay_for(Some(20));
        assert!(
            !has(&elsewhere, BUSY) && has(&elsewhere, IDLE),
            "the sender has gone"
        );
        assert!(
            has(&shadow.replay_for(Some(10)), BUSY),
            "the sender came back"
        );
        assert!(
            has(&shadow.replay_for(None), BUSY),
            "unknown foreground keeps the report"
        );
        assert!(
            has(&busy_from(None).replay_for(Some(20)), BUSY),
            "unknown owner keeps the report"
        );
    }

    /// Each report belongs to whoever sent it: a program that reports busy after another one left
    /// without clearing its report owns the new one.
    /// Value: protects=a new report replaces the old sender; fails_when=the owner is noted only once, on the first report; why_new=the other test sends one report; seam=none
    #[test]
    fn a_new_report_belongs_to_its_own_sender() {
        let mut shadow = busy_from(Some(10));
        shadow.write_from_pty(BUSY, || Some(20));
        assert!(
            has(&shadow.replay_for(Some(20)), BUSY),
            "the new sender owns the pty"
        );
        assert!(
            !has(&shadow.replay_for(Some(10)), BUSY),
            "the old sender no longer counts"
        );
    }
}
