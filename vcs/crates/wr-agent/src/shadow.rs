//! One name for the shadow terminal whether or not it is compiled in.
//!
//! `terminal-state` is off by default because it pulls a pinned Zig toolchain and a Ghostty
//! checkout into the build. Rather than scatter `#[cfg]` through the session layer — where it
//! would obscure the actual logic and rot the moment someone edits the wrong arm — the feature is
//! resolved exactly once, here. `session.rs` calls the same methods either way; without the
//! feature they do nothing and `replay()` returns no bytes, which is precisely the behaviour
//! before the shadow existed.

use crate::program_status::Store;

/// What a write from the pty asks of the session: bytes to answer the program with (a program
/// status probe's reply), and `Some(blocked)` when its program status changed (#358).
pub type Written = (Vec<u8>, Option<bool>);

#[cfg(feature = "terminal-state")]
pub struct Shadow {
    terminal: Option<crate::terminal::ShadowTerminal>,
    /// The pty's foreground process group when the current progress report arrived: the program
    /// that sent it. Once another group owns the pty, that program is gone (#359).
    progress_owner: Option<libc::pid_t>,
    /// The session's program status records (#358).
    status: Store,
}

#[cfg(not(feature = "terminal-state"))]
pub struct Shadow;

#[cfg(feature = "terminal-state")]
impl Shadow {
    pub fn new(columns: u16, rows: u16) -> Shadow {
        Shadow {
            terminal: crate::terminal::ShadowTerminal::new(columns, rows),
            progress_owner: None,
            status: Store::default(),
        }
    }

    /// Every byte the client receives also goes here. Cheap enough to do inline on the output
    /// path: it is the same parse the client's own terminal is doing anyway. Bytes that are not
    /// the live pty's (a screen being checked or restored) answer nothing and report nothing.
    pub fn write(&mut self, bytes: &[u8]) {
        if let Some(terminal) = self.terminal.as_mut() {
            terminal.write(bytes);
            terminal.take_program_status();
        }
    }

    /// `write` for bytes from the live pty, whose `foreground` process group is then the sender
    /// of any progress or program status report in them, and the prober of any probe. Asked only
    /// when one arrived, so the output path pays for it once per report, not per read.
    ///
    /// ponytail: sampled after the read, so a reporter that exits within the same read chunk is
    /// recorded as the shell, and its report stays until a REMOVE. A per-report pgid needs the
    /// pty to tag its bytes; add if stale busy is ever seen in practice.
    pub fn write_from_pty(
        &mut self,
        bytes: &[u8],
        foreground: impl FnOnce() -> Option<libc::pid_t>,
    ) -> Written {
        let Some(terminal) = self.terminal.as_mut() else {
            return (Vec::new(), None);
        };
        terminal.write(bytes);
        let (events, replies) = terminal.take_program_status();
        let fresh = terminal.take_fresh_report();
        let sender = (fresh || !events.is_empty()).then(foreground).flatten();
        if fresh {
            self.progress_owner = terminal.progress().and(sender);
        }
        self.status.apply_read(events, sender.unwrap_or(0));
        // At most once per read, and only while a running program's record could outlive it.
        if self.status.has_live() {
            self.status
                .drop_dead_owners(crate::program_status::group_alive);
        }
        (replies, self.status.commit())
    }

    /// The session's program status records; `None` in a build that keeps none.
    pub fn status(&mut self) -> Option<&mut Store> {
        Some(&mut self.status)
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
    /// No terminal to answer a probe or parse a report: a program sees the protocol as
    /// unsupported, as it did before.
    pub fn write_from_pty(
        &mut self,
        _bytes: &[u8],
        _foreground: impl FnOnce() -> Option<libc::pid_t>,
    ) -> Written {
        (Vec::new(), None)
    }
    pub fn status(&mut self) -> Option<&mut Store> {
        None
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

    /// What libghostty answers `OSC 7501 ; ?` with, before the probe's own terminator.
    const ANSWER: &[u8] =
        b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth";

    /// Every probe is answered, each with its own terminator: Claude Code probes with BEL, and
    /// again on every full redraw (Step 0).
    #[test]
    fn a_probe_is_answered_with_its_own_terminator() {
        let mut shadow = Shadow::new(80, 24);
        for terminator in [b"\x07".as_slice(), b"\x1b\\"] {
            let probe = [b"\x1b]7501;?".as_slice(), terminator].concat();
            let (replies, _) = shadow.write_from_pty(&probe, || Some(1));
            assert_eq!(replies, [ANSWER, terminator].concat());
        }
    }

    /// Value: protects=only the 7501 answer reaches the pty, never a DA1, DSR or colour answer the attached client also gives; fails_when=the WRITE_PTY filter is dropped or loosened; why_new=two answers to one query corrupt the program's input; seam=none
    #[test]
    fn only_the_program_status_answer_is_queued() {
        let mut shadow = Shadow::new(80, 24);
        let (replies, _) = shadow
            .write_from_pty(b"\x1b]7501;?\x07\x1b[c\x1b[6n\x1b[5n\x1b]11;?\x07", || {
                Some(1)
            });
        assert_eq!(replies, [ANSWER, b"\x07"].concat());
    }

    /// A probe cut across reads is answered once, when it completes.
    #[test]
    fn a_split_probe_is_answered_once() {
        let mut shadow = Shadow::new(80, 24);
        let probe = b"\x1b]7501;?\x1b\\";
        let mut replies = Vec::new();
        for byte in probe {
            replies.extend(shadow.write_from_pty(&[*byte], || Some(1)).0);
        }
        assert_eq!(replies, [ANSWER, b"\x1b\\"].concat());
    }

    /// `write` is for screens that are not the live pty's: it answers nothing, and leaves nothing
    /// behind for the next live write to answer.
    #[test]
    fn write_answers_nothing() {
        let mut shadow = Shadow::new(80, 24);
        shadow.write(b"\x1b]7501;?\x07\x1b]7501;state=blocked\x07");
        let (replies, changed) = shadow.write_from_pty(b"x", || Some(1));
        assert!(replies.is_empty());
        assert_eq!(changed, None);
    }

    /// A report reaches the store with the foreground group as its sender, and a prompt ends it.
    #[test]
    fn reports_reach_the_store_and_a_prompt_ends_them() {
        let mut shadow = Shadow::new(80, 24);
        shadow.write_from_pty(b"\x1b]7501;?\x07", || Some(0));
        let (_, changed) = shadow.write_from_pty(
            b"\x1b]7501;state=blocked:kind=permission:app=claude-code:msg=QXBwbHk/\x07",
            || Some(0),
        );
        assert_eq!(changed, Some(true), "a record entered blocked");
        let event = |shadow: &mut Shadow| -> serde_json::Value {
            let id = crate::session::SessionId([0; 16]);
            serde_json::from_slice(&shadow.status().unwrap().event(id, id)).unwrap()
        };
        let status = event(&mut shadow);
        assert_eq!(status["reporting"], true);
        assert_eq!(status["records"][0]["message"], "Apply?");
        assert_eq!(status["records"][0]["notify"], true, "the prober reported");
        let (_, changed) = shadow.write_from_pty(b"\x1b]133;A\x07$ ", || Some(0));
        assert_eq!(changed, Some(false));
        let status = event(&mut shadow);
        assert_eq!(status["records"], serde_json::json!([]));
        assert_eq!(status["reporting"], false);
    }
}
