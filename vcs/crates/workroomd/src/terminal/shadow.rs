//! One name for the shadow terminal whether or not it is compiled in.
//!
//! `terminal-state` is off by default because it pulls a pinned Zig toolchain and a Ghostty
//! checkout into the build. Rather than scatter `#[cfg]` through the session layer — where it
//! would obscure the actual logic and rot the moment someone edits the wrong arm — the feature is
//! resolved exactly once, here. `session.rs` calls the same methods either way; without the
//! feature they do nothing and `replay()` returns no bytes, which is precisely the behaviour
//! before the shadow existed.

use crate::terminal::images::{ImageRef, Placement};
use crate::terminal::program_status::Store;
use crate::terminal::pty::Size;
#[cfg(feature = "terminal-state")]
use crate::terminal::vt::{Disturbed, Pixels};

/// No shadow, so no images to encode.
#[cfg(not(feature = "terminal-state"))]
pub struct Pixels;

#[cfg(not(feature = "terminal-state"))]
impl Pixels {
    pub fn to_png(&self) -> Option<Vec<u8>> {
        None
    }
}

/// No shadow, so nothing to disturb.
#[cfg(not(feature = "terminal-state"))]
pub struct Disturbed {
    pub abort_at: Option<usize>,
    pub only_if_loading: bool,
}

/// The longest live title a session reports, cut at a character boundary: the label's cap
/// (`dispatch::MAX_TITLE_BYTES`), so one program's title cannot fill a session listing.
#[cfg(feature = "terminal-state")]
const MAX_TITLE_BYTES: usize = 256;

/// The OSC 2 that gives a terminal `title`, for a hand-off's screen (`SessionStore::frozen`):
/// libghostty's formatter has no title extra, so without it the next program would forget the
/// title until the program set it again. Control characters are dropped, so it cannot end early.
pub fn title_sequence(title: &str) -> Vec<u8> {
    let mut out = b"\x1b]2;".to_vec();
    out.extend(
        title
            .chars()
            .filter(|c| !c.is_control())
            .collect::<String>()
            .bytes(),
    );
    out.push(0x07);
    out
}

/// Which rows a capture reads (#686).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rows {
    /// The visible screen.
    Screen,
    /// The visible screen and the newest this many rows of history above it.
    WithHistory(u32),
    /// The whole scrollback and the screen.
    All,
}

/// What the terminal API's `terminal.capture` asks of a screen.
#[derive(Clone, Copy, Debug)]
pub struct Capture {
    pub rows: Rows,
    /// Join the rows of a line the pane soft-wrapped.
    pub unwrap: bool,
    /// Keep the escape codes (colours, styles) rather than plain text.
    pub vt: bool,
}

/// A screen as a capture read it: its text, and the facts beside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Captured {
    pub text: String,
    /// The cursor's row and column on the visible screen, from 0 at its top left.
    pub cursor: (u16, u16),
    /// Columns and rows.
    pub size: (u16, u16),
    /// Whether a full-screen program has the alternate screen up.
    pub alternate: bool,
    /// The live title (OSC 0 or 2).
    pub title: Option<String>,
}

/// The most text one capture reply holds, JSON-escaped: a reply's 16 MiB less room for the rest
/// of it.
pub const CAPTURE_REPLY_TEXT_MAX: usize = 16 * 1024 * 1024 - 64 * 1024;

/// A capture's text in pieces, made one at a time as they are asked for: joined, they are the
/// text. A `None` piece is one the formatter could not read.
pub type Pieces = Box<dyn Iterator<Item = Option<String>> + Send>;

/// A capture under way: the facts read under the shadow's lock, and the text, which a copy
/// formats once the lock is released, so the session's output never waits on it.
pub struct CaptureJob {
    /// The screen's facts, `text` empty.
    pub facts: Captured,
    pub pieces: Pieces,
}

/// Why a screen can't be captured.
#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// No shadow terminal: a build without terminal-state, or one that failed.
    NoScreen,
    /// The screen, or a copy of it, could not be read.
    Unreadable,
    /// `lines` covers more rows than one reply holds at the pane's width, even at a byte a cell.
    TooManyRows { rows: u64, columns: u16 },
    /// As many captures from a copy as the daemon runs at once are running.
    Busy,
}

/// What a capture from a copy holds for as long as it runs: its place among the daemon's
/// captures, given back when it is dropped.
pub type Admitted = Box<dyn Send>;

/// What a write from the pty asks of the session: bytes to answer the program with (a program
/// status probe's reply), and `Some(blocked)` when its program status changed (#358).
pub type Written = (Vec<u8>, Option<bool>);

/// The budget `replay_for_within` takes for a replay of at most `bytes` in all, and never more
/// than a repaint's.
#[cfg(feature = "terminal-state")]
pub fn record_budget(bytes: usize) -> usize {
    use crate::terminal::vt::{REPAINT_MAX_BYTES, REPLAY_OVERHEAD};
    bytes.min(REPAINT_MAX_BYTES).saturating_sub(REPLAY_OVERHEAD)
}

/// No shadow, no replay.
#[cfg(not(feature = "terminal-state"))]
pub fn record_budget(_bytes: usize) -> usize {
    0
}

#[cfg(feature = "terminal-state")]
pub struct Shadow {
    terminal: Option<crate::terminal::vt::ShadowTerminal>,
    /// The pty's foreground process group when the current progress report arrived: the program
    /// that sent it. Once another group owns the pty, that program is gone (#359).
    progress_owner: Option<libc::pid_t>,
    /// The session's program status records (#358).
    status: Store,
    /// Whether a transfer is running (`watch_for_transfers`).
    watching: bool,
    /// What the last write did to it.
    disturbed: Option<Disturbed>,
    /// The shell's OSC 133 marks so far, for the terminal API's waits (#690).
    marks: Marks,
    /// The coding agent's states the last pty write's events left it in, in order, when it had
    /// several (`Store::apply_read`), for the waits that hear about that write.
    passed: Vec<crate::terminal::program_status::State>,
}

/// How many commands a session's shell has ended through its OSC 133 marks since this program
/// started it. Whether it sends marks at all is the program status store's, which a hand-off
/// carries (`Store::shell_marks`).
#[cfg(feature = "terminal-state")]
#[derive(Default)]
struct Marks {
    commands: u64,
    /// The last commands' exit codes, oldest first, at most `RECENT_EXITS`: every one that ended
    /// in a read, in order, so a wait hears of the first, not only the last. `None` for one that
    /// ended with no code.
    exits: std::collections::VecDeque<Option<i32>>,
}

/// The most recent commands' exit codes the shadow keeps for the waits (`wait::Seen::exits`):
/// more than end within one read, unless a shell prints that many prompts in one.
#[cfg(feature = "terminal-state")]
const RECENT_EXITS: usize = 64;

#[cfg(feature = "terminal-state")]
impl Marks {
    /// Counts one write's marks. Most writes have no events, and this looks at nothing else.
    fn count(&mut self, events: &[crate::terminal::program_status::Event]) {
        use crate::terminal::program_status::Event;
        for event in events {
            if let Event::Command { exit_code, .. } = event {
                self.commands += 1;
                if self.exits.len() == RECENT_EXITS {
                    self.exits.pop_front();
                }
                self.exits.push_back(*exit_code);
            }
        }
    }
}

#[cfg(not(feature = "terminal-state"))]
pub struct Shadow;

#[cfg(feature = "terminal-state")]
impl Shadow {
    pub fn new(columns: u16, rows: u16) -> Shadow {
        Shadow {
            terminal: crate::terminal::vt::ShadowTerminal::new(columns, rows),
            progress_owner: None,
            status: Store::default(),
            watching: false,
            disturbed: None,
            marks: Marks::default(),
            passed: Vec::new(),
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
    /// recorded as the shell, and its report stays until a REMOVE, or the shell's OSC 133 D where
    /// it sends one. A per-report pgid needs the pty to tag its bytes; add if stale busy is ever
    /// seen in practice from a shell without OSC 133.
    pub fn write_from_pty(
        &mut self,
        bytes: &[u8],
        foreground: impl FnOnce() -> Option<libc::pid_t>,
    ) -> Written {
        let Some(terminal) = self.terminal.as_mut() else {
            return (Vec::new(), None);
        };
        if self.watching {
            self.disturbed = terminal.write_watched(bytes);
        } else {
            terminal.write(bytes);
        }
        let (events, replies) = terminal.take_program_status();
        self.marks.count(&events);
        let fresh = terminal.take_fresh_report();
        let sender = (fresh || !events.is_empty()).then(foreground).flatten();
        if fresh {
            self.progress_owner = terminal.progress().and(sender);
        }
        self.passed =
            self.status
                .apply_read(events, sender.unwrap_or(0), std::time::Instant::now());
        // At most once per read, and only while a running program's record could outlive it.
        if self.status.has_live() {
            self.status
                .drop_dead_owners(crate::terminal::program_status::group_alive);
        }
        (replies, self.status.commit())
    }

    /// The session's program status records; `None` in a build that keeps none.
    pub fn status(&mut self) -> Option<&mut Store> {
        Some(&mut self.status)
    }

    /// Makes the next `write_from_pty` report what would disturb an image transfer, for
    /// `take_disturbed`. Off whenever no transfer is running, so output pays nothing.
    pub fn watch_for_transfers(&mut self, on: bool) {
        self.watching = on;
    }

    /// What disturbed a transfer in the last write, if anything did.
    pub fn take_disturbed(&mut self) -> Option<Disturbed> {
        self.disturbed.take()
    }

    pub fn at_ground(&mut self) -> bool {
        self.terminal
            .as_mut()
            .is_some_and(|terminal| terminal.at_ground())
    }

    /// When the output so far ends inside a sequence, so the next bytes are its rest, not text:
    /// the sequence's start, as the parser continuation has it, for a regex wait starting now to
    /// pick up where it is (#690); empty when the parser keeps none (a string too long to keep).
    /// `None` at ground, and with no terminal, where nothing is known to be mid-sequence.
    pub fn open_sequence(&mut self) -> Option<Vec<u8>> {
        let terminal = self.terminal.as_mut()?;
        (!terminal.at_ground()).then(|| terminal.continuation())
    }

    pub fn visible_images(&self) -> Vec<ImageRef> {
        self.terminal
            .as_ref()
            .map(|terminal| terminal.visible_images())
            .unwrap_or_default()
    }

    pub fn pixels(&self, image: ImageRef) -> Option<Pixels> {
        self.terminal.as_ref()?.pixels(image)
    }

    pub fn placement(&self, image: u32, force: bool) -> Placement {
        self.terminal
            .as_ref()
            .map_or(Placement::Ready(Vec::new()), |terminal| {
                terminal.placement(image, force)
            })
    }

    /// `image`'s bytes in full, for a screen nothing can interleave with: what a hand-off carries,
    /// ahead of the parser continuation.
    pub fn hand_off_image(&self, image: ImageRef) -> Option<Vec<u8>> {
        let png = self.pixels(image)?.to_png()?;
        let mut out = crate::terminal::images::transmit_bytes(image.id, &png);
        if let Placement::Ready(bytes) = self.placement(image.id, true) {
            out.extend_from_slice(&bytes);
        }
        Some(out)
    }

    /// How many bytes at the end of a replay are the parser continuation.
    pub fn continuation_len(&self) -> usize {
        self.terminal
            .as_ref()
            .map_or(0, |terminal| terminal.continuation_len())
    }

    pub fn resize(&mut self, size: Size) {
        if let Some(terminal) = self.terminal.as_mut() {
            let cell = |pixels: u16, cells: u16| u32::from(pixels) / u32::from(cells.max(1));
            terminal.set_cell_pixels(
                cell(size.x_pixels, size.columns),
                cell(size.y_pixels, size.rows),
            );
            terminal.resize(size.columns, size.rows);
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
    /// replay says idle: the fallback for a shell that sends no OSC 133 D (`crate::terminal::vt`
    /// says what clears a report). The report is kept, so where no D cleared it, a program stopped
    /// and resumed (^Z, `fg`) is busy again to clients that attach once it is back; a client that
    /// attached while it was away stays idle until the program's next report.
    pub fn replay_for(&self, foreground: Option<libc::pid_t>) -> Vec<u8> {
        self.replay_for_within(foreground, crate::terminal::vt::REPAINT_MAX_BYTES, None)
    }

    /// `replay_for` with its record held to `budget` bytes, and its screen alone past `until`
    /// (`ShadowTerminal::record_within`): for a hand-off, which shares one total between sessions.
    pub fn replay_for_within(
        &self,
        foreground: Option<libc::pid_t>,
        budget: usize,
        until: Option<std::time::Instant>,
    ) -> Vec<u8> {
        let Some(terminal) = self.terminal.as_ref() else {
            return Vec::new();
        };
        let report = !matches!(
            (self.progress_owner, foreground),
            (Some(owner), Some(now)) if owner != now
        );
        terminal.replay_within(report, budget, until)
    }

    /// What to keep on disk for this screen (`crate::terminal::screens`): `replay()` without the
    /// progress report or the parser continuation, held to `vt::RECORD_MAX_BYTES`.
    pub fn record(&self) -> Vec<u8> {
        self.terminal
            .as_ref()
            .map(|t| t.record_within(crate::terminal::vt::RECORD_MAX_BYTES, None))
            .unwrap_or_default()
    }

    /// Compresses the history nothing has touched since it was last compressed (#463).
    pub fn compress(&mut self) {
        if let Some(terminal) = self.terminal.as_mut() {
            terminal.compress();
        }
    }

    /// Whether compressing history frees memory in this build, on this target. True when there is
    /// no terminal, which keeps no history to compress.
    pub fn compression_supported(&self) -> bool {
        self.terminal
            .as_ref()
            .is_none_or(|t| t.compression_supported())
    }

    /// The session's live title (OSC 0 and 2, #683), at most `MAX_TITLE_BYTES`; `None` until its
    /// program sets one.
    pub fn title(&self) -> Option<String> {
        let mut title = self.terminal.as_ref()?.title()?;
        if title.len() > MAX_TITLE_BYTES {
            let mut end = MAX_TITLE_BYTES;
            while !title.is_char_boundary(end) {
                end -= 1;
            }
            title.truncate(end);
        }
        Some(title)
    }

    /// A capture of this screen (#686). Called under the shadow's lock, which only the screen and
    /// up to `LIVE_HISTORY_ROWS` of history are formatted under; anything more is a copy of the
    /// terminal, taken here once `admit` gives it a place, and formatted window by window as the
    /// job's pieces are asked for, after the lock is released (`ShadowTerminal::capture`).
    pub fn capture(
        &self,
        capture: Capture,
        admit: &mut dyn FnMut() -> Option<Admitted>,
    ) -> Result<CaptureJob, Refused> {
        let terminal = self.terminal.as_ref().ok_or(Refused::NoScreen)?;
        let facts = terminal.screen_facts().ok_or(Refused::Unreadable)?;
        let pieces = terminal.capture(capture, admit)?;
        Ok(CaptureJob {
            facts: Captured {
                title: self.title(),
                ..facts
            },
            pieces,
        })
    }

    #[cfg(test)]
    pub fn memory(&self) -> Option<crate::terminal::vt::MemoryUsage> {
        self.terminal.as_ref().and_then(|t| t.memory())
    }

    /// What a wait looks at now (#690): the coding agent's state, as `sessions` reports it, and
    /// the commands the shell has ended.
    pub fn seen(&self) -> crate::terminal::wait::Seen {
        crate::terminal::wait::Seen {
            agent: self.status.coding_agent().map(|agent| agent.state),
            passed: Vec::new(),
            shell_marks: self.status.shell_marks(),
            commands: self.marks.commands,
            exits: self.marks.exits.iter().copied().collect(),
            alternate: self.alternate_screen(),
        }
    }

    /// `seen`, with the states the last pty write passed through: for the reader, right after
    /// that write, to tell the waits that hear about it.
    pub fn seen_after_read(&self) -> crate::terminal::wait::Seen {
        crate::terminal::wait::Seen {
            passed: self.passed.clone(),
            ..self.seen()
        }
    }

    /// Whether the shell has sent an OSC 133 mark, to this program or to one before a hand-off.
    pub fn has_shell_marks(&self) -> bool {
        self.status.shell_marks()
    }

    /// Whether the shell is running a command by its marks (`ShadowTerminal::command_open`): what
    /// `terminal.command` (#691) won't type into. `None` when the marks can't say: no prompt seen
    /// since this program started (a hand-off's next one), or no screen.
    pub fn command_open(&self) -> Option<bool> {
        self.terminal
            .as_ref()
            .and_then(crate::terminal::vt::ShadowTerminal::command_open)
    }

    /// Whether a full-screen program has the alternate screen up; false when it can't be read.
    pub fn alternate_screen(&self) -> bool {
        self.terminal
            .as_ref()
            .is_some_and(crate::terminal::vt::ShadowTerminal::alternate_screen)
    }

    /// Whether the shell's input line already holds text (`ShadowTerminal::input_typed`), which
    /// `terminal.command` (#691) won't type after.
    pub fn input_typed(&self) -> bool {
        self.terminal
            .as_ref()
            .is_some_and(crate::terminal::vt::ShadowTerminal::input_typed)
    }

    /// The input modes the session's program has turned on, which what `terminal.send` types is
    /// encoded for (#689); `None` when the screen can't be read.
    pub fn input_modes(&self) -> Option<crate::terminal::keys::Modes> {
        self.terminal
            .as_ref()
            .and_then(|terminal| terminal.input_modes())
    }

    /// The visible screen as plain text, no history, its soft-wrapped lines joined: what
    /// `wait --include-screen` (#690) matches, so a line the pane wrapped matches as the program
    /// printed it. Bounded by the screen's size, so read under the session's locks, and matched
    /// after. Empty when the screen can't be read.
    pub fn screen_text(&self) -> String {
        self.terminal
            .as_ref()
            .and_then(|terminal| {
                terminal.capture_text(Capture {
                    rows: Rows::Screen,
                    unwrap: true,
                    vt: false,
                })
            })
            .unwrap_or_default()
    }

    #[cfg(any(test, feature = "test-support"))]
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
    /// No terminal, so no title is ever seen.
    pub fn title(&self) -> Option<String> {
        None
    }
    /// No terminal, so the modes a program turned on are never known.
    pub fn input_modes(&self) -> Option<crate::terminal::keys::Modes> {
        None
    }
    /// No terminal, so no screen to capture, whatever was asked.
    pub fn capture(
        &self,
        _capture: Capture,
        _admit: &mut dyn FnMut() -> Option<Admitted>,
    ) -> Result<CaptureJob, Refused> {
        Err(Refused::NoScreen)
    }
    pub fn resize(&mut self, _size: Size) {}
    pub fn watch_for_transfers(&mut self, _on: bool) {}
    pub fn take_disturbed(&mut self) -> Option<Disturbed> {
        None
    }
    pub fn at_ground(&mut self) -> bool {
        false
    }
    /// No parser, so a regex wait starts at ground, as the stream most often is.
    pub fn open_sequence(&mut self) -> Option<Vec<u8>> {
        None
    }
    pub fn visible_images(&self) -> Vec<ImageRef> {
        Vec::new()
    }
    pub fn pixels(&self, _image: ImageRef) -> Option<Pixels> {
        None
    }
    pub fn placement(&self, _image: u32, _force: bool) -> Placement {
        Placement::Ready(Vec::new())
    }
    pub fn hand_off_image(&self, _image: ImageRef) -> Option<Vec<u8>> {
        None
    }
    pub fn continuation_len(&self) -> usize {
        0
    }
    /// No shadow, so nothing to repaint: a reattaching client resumes the live stream, which is
    /// how the daemon behaved before terminal state existed.
    pub fn replay(&self) -> Vec<u8> {
        Vec::new()
    }
    pub fn replay_for(&self, _foreground: Option<libc::pid_t>) -> Vec<u8> {
        Vec::new()
    }
    pub fn replay_for_within(
        &self,
        _foreground: Option<libc::pid_t>,
        _budget: usize,
        _until: Option<std::time::Instant>,
    ) -> Vec<u8> {
        Vec::new()
    }
    pub fn record(&self) -> Vec<u8> {
        Vec::new()
    }
    /// No history kept, so none to compress.
    pub fn compress(&mut self) {}
    pub fn compression_supported(&self) -> bool {
        true
    }
    /// No terminal, so no program status and no marks.
    pub fn seen(&self) -> crate::terminal::wait::Seen {
        crate::terminal::wait::Seen::default()
    }
    pub fn seen_after_read(&self) -> crate::terminal::wait::Seen {
        crate::terminal::wait::Seen::default()
    }
    pub fn has_shell_marks(&self) -> bool {
        false
    }
    pub fn command_open(&self) -> Option<bool> {
        None
    }
    pub fn alternate_screen(&self) -> bool {
        false
    }
    pub fn input_typed(&self) -> bool {
        false
    }
    /// No terminal, so no screen; `terminal.wait` refuses `include_screen` before asking.
    pub fn screen_text(&self) -> String {
        String::new()
    }
    #[cfg(any(test, feature = "test-support"))]
    pub fn visible_text(&self) -> String {
        String::new()
    }
}

#[cfg(all(test, feature = "terminal-state"))]
mod tests;
