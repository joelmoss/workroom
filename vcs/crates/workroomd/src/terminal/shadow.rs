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
        let fresh = terminal.take_fresh_report();
        let sender = (fresh || !events.is_empty()).then(foreground).flatten();
        if fresh {
            self.progress_owner = terminal.progress().and(sender);
        }
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

    #[cfg(test)]
    pub fn memory(&self) -> Option<crate::terminal::vt::MemoryUsage> {
        self.terminal.as_ref().and_then(|t| t.memory())
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
    pub fn resize(&mut self, _size: Size) {}
    pub fn watch_for_transfers(&mut self, _on: bool) {}
    pub fn take_disturbed(&mut self) -> Option<Disturbed> {
        None
    }
    pub fn at_ground(&mut self) -> bool {
        false
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
    #[cfg(any(test, feature = "test-support"))]
    pub fn visible_text(&self) -> String {
        String::new()
    }
}

#[cfg(all(test, feature = "terminal-state"))]
mod tests;
