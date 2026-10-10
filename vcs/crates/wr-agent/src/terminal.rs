//! The shadow terminal: a `libghostty-vt` emulator fed every byte the pty produces, read only
//! when a client attaches.
//!
//! **Raw bytes stay the live path.** This is not a render path — a connected client receives the
//! pty's bytes untouched, exactly as it does today, so it gets full Ghostty fidelity and
//! everything negotiated over a live bidirectional channel: kitty keyboard, OSC 52, synchronised
//! output, mouse handshakes, the bell. Rendering *from* state would push parse → state →
//! re-synthesis between the child and the real client for every session including local ones, and
//! degrade local behaviour to a remote limitation. The emulator runs alongside, and is consulted
//! only to answer "what should a client that just arrived be shown?".
//!
//! **What re-synthesis has to send, and why each piece.** Phase 0 measured all three of these by
//! watching a fresh client get them wrong:
//!
//! 1. **Screen + state** from the formatter, with its `extra` flags on. With the default options
//!    the formatter emits 8 bytes and the client loses *every* negotiated mode — it looks correct
//!    and is completely dead: no mouse, wrong key encoding, not even on the alternate screen.
//! 2. **The cursor**, by hand. `GhosttyFormatterTerminalExtra` covers palette, modes, scrolling
//!    region, tabstops, pwd, keyboard and charsets — but has no cursor field. The formatter homes
//!    the cursor, paints, and leaves it wherever the last cell landed, so without an explicit CUP
//!    the next byte lands in the wrong place.
//! 3. **Kitty keyboard flags**, by hand. `extra.keyboard` covers ModifyOtherKeys and not the kitty
//!    stack. The snapshot carries the flags correctly, so nothing is lost across persistence; they
//!    simply are not emitted.
//!
//! Then **the last OSC 9;4 progress report**, or an explicit REMOVE when there is none (#359). A
//! program reports busy once, at the start of its work, so a client attaching mid-turn learns it
//! only from here. Never in the on-disk record, which outlives the program.
//!
//! And **the parser continuation last**, because a byte stream cut mid-sequence leaves the VT
//! parser or UTF-8 decoder unfinished and nothing in the grid expresses that. Without it the tail
//! of a split escape renders as literal text and a cut codepoint as U+FFFD.
//!
//! **Scrollback comes back too, and needs no help.** An earlier reading of this concluded the
//! formatter was screen-scoped and history was lost — it is not. With a NULL selection the
//! formatter emits the *entire* screen in Ghostty's sense, scrollback included: a terminal holding
//! 37 history rows and 24 visible ones emits 59 newlines, and a client fed that ends up with the
//! history and the right visible screen. A hand-rolled history emission on top of it only
//! double-counts. The one measurable difference is a single row: the emission ends without a
//! trailing newline, so the last line does not scroll, and the client reports 36 history rows
//! where the producer has 37.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]

use std::ptr;

mod sys {
    #![allow(
        non_upper_case_globals,
        non_camel_case_types,
        non_snake_case,
        dead_code
    )]
    include!(concat!(env!("OUT_DIR"), "/ghostty_vt.rs"));
}

use sys::*;

const OK: GhosttyResult = GhosttyResult_GHOSTTY_SUCCESS;

/// Continuation tracking is a byte LIMIT, not a flag, and it must be set before the input that
/// leaves the parser unfinished — enabling it afterwards makes that continuation permanently
/// unavailable. The agent can never know where a chunk boundary will fall, so it is on from
/// creation. 4 KiB is far beyond any real escape sequence; the cap exists so a hostile stream
/// cannot grow it without bound.
const CONTINUATION_MAX_BYTES: usize = 4096;

/// `ghostty_mode_new` is a `static inline` in modes.h, so bindgen does not emit it.
/// modes.h: `(value & 0x7FFF) | ((uint16_t)ansi << 15)`.
const fn mode_new(value: u16, ansi: bool) -> GhosttyMode {
    (value & 0x7FFF) | ((ansi as u16) << 15)
}

/// The last OSC 9;4 a session reported, as (state, percent); percent is -1 when omitted.
pub type Progress = Option<(GhosttyTerminalProgressState, i8)>;

/// Where the progress callback writes: the last report, and whether one has arrived since
/// `take_fresh_report` last asked.
#[derive(Default)]
struct ProgressSlot {
    report: Progress,
    fresh: bool,
}

/// A terminal shadowing one session.
pub struct ShadowTerminal {
    inner: GhosttyTerminal,
    /// The callback's userdata. A raw allocation rather than a `Box` field: moving a `Box`
    /// asserts unique access to its contents, which the pointer the terminal holds would then
    /// alias. Freed in `Drop`, after the terminal that writes to it.
    progress: *mut ProgressSlot,
}

/// `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT`: keep the last report; REMOVE clears it.
unsafe extern "C" fn on_progress_report(
    _terminal: GhosttyTerminal,
    userdata: *mut std::ffi::c_void,
    report: *const GhosttyTerminalProgressReport,
) {
    let (Some(slot), Some(report)) = (
        // SAFETY: the only userdata ever set is `ShadowTerminal::progress`, which outlives the
        // terminal. The callback runs synchronously inside `write(&mut self)`, so nothing else
        // holds a reference to the slot meanwhile.
        unsafe { (userdata as *mut ProgressSlot).as_mut() },
        // SAFETY: libghostty passes a report that is valid for the duration of the call.
        unsafe { report.as_ref() },
    ) else {
        return;
    };
    // A sized struct: only read `progress` if this library's struct has it.
    let has_percent = report.size
        >= std::mem::offset_of!(GhosttyTerminalProgressReport, progress)
            + std::mem::size_of::<i8>();
    let percent = if has_percent { report.progress } else { -1 };
    slot.report = (report.state
        != GhosttyTerminalProgressState_GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE)
        .then_some((report.state, percent));
    slot.fresh = true;
}

// SAFETY: the handle and the progress slot are owned exclusively, so moving them to another thread
// moves the only way to reach them. libghostty-vt requires the caller to serialise access, and it
// is: `ShadowTerminal` is not `Sync`, so only the thread holding it can call in, and `&mut self`
// orders the writes that run the callback.
unsafe impl Send for ShadowTerminal {}

impl ShadowTerminal {
    pub fn new(columns: u16, rows: u16) -> Option<ShadowTerminal> {
        let mut inner: GhosttyTerminal = ptr::null_mut();
        // SAFETY: a null allocator selects the default one, `inner` is a live out-pointer, and
        // both dimensions are at least 1, as the call requires.
        let rc =
            unsafe { ghostty_terminal_new(ptr::null(), &mut inner, columns.max(1), rows.max(1)) };
        if rc != OK || inner.is_null() {
            return None;
        }
        let terminal = ShadowTerminal {
            inner,
            progress: Box::into_raw(Box::default()),
        };
        terminal.enable_continuation_tracking();
        terminal.track_progress_reports();
        Some(terminal)
    }

    /// A program reports busy with OSC 9;4 once, at the start of its work, so a client that
    /// attaches later can only learn it from here (#359). Pointer-typed options are passed
    /// directly, not by address (`ghostty_terminal_set`'s doc).
    fn track_progress_reports(&self) {
        // SAFETY: `inner` is a live terminal. The userdata is the progress slot, which `Drop`
        // frees only after the terminal, and the callback matches the option's signature.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_USERDATA,
                self.progress as *const std::ffi::c_void,
            );
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT,
                on_progress_report as *const std::ffi::c_void,
            );
        }
    }

    /// The last progress report the program sent, or `None` once it cleared it.
    pub fn progress(&self) -> Progress {
        // SAFETY: `progress` is a live allocation until `Drop`, and the callback that writes it
        // only runs inside `write(&mut self)`, never during this `&self` read.
        unsafe { (*self.progress).report }
    }

    /// Whether a report (a REMOVE included) has arrived since this was last asked.
    pub fn take_fresh_report(&mut self) -> bool {
        // SAFETY: as in `progress`; `&mut self` also rules out the callback running meanwhile.
        unsafe { std::mem::take(&mut (*self.progress).fresh) }
    }

    /// The last progress report, re-emitted, or an explicit REMOVE when there is none or
    /// `report` is false. The REMOVE matters to a client that kept its view across a reconnect:
    /// it may still show a busy state the program has since cleared.
    fn progress_report(&self, report: bool) -> Vec<u8> {
        let remove = (
            GhosttyTerminalProgressState_GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE,
            -1,
        );
        let (state, percent) = self.progress().filter(|_| report).unwrap_or(remove);
        let percent = if percent >= 0 {
            format!(";{percent}")
        } else {
            String::new()
        };
        format!("\x1b]9;4;{state}{percent}\x1b\\").into_bytes()
    }

    fn enable_continuation_tracking(&self) {
        let limit: usize = CONTINUATION_MAX_BYTES;
        // SAFETY: a non-pointer option is passed by address, and `limit` is a live `usize` (the
        // option's type) that the call reads before returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
                &limit as *const usize as *const std::ffi::c_void,
            );
        }
    }

    /// Feed the emulator the same bytes the client is getting.
    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: `inner` is a live terminal, and the pointer and length come from one live slice.
        unsafe { ghostty_terminal_vt_write(self.inner, bytes.as_ptr(), bytes.len()) }
    }

    /// Cell pixel dimensions are zero: they feed image protocols and size reports, and the shadow
    /// renders nothing — the real client owns the pixels and reports its own.
    pub fn resize(&mut self, columns: u16, rows: u16) {
        // SAFETY: `inner` is a live terminal, and both dimensions are at least 1, as required.
        unsafe {
            ghostty_terminal_resize(self.inner, columns.max(1), rows.max(1), 0, 0);
        }
    }

    /// How many bytes `ghostty_terminal_get` writes for each kind `get_u32` reads: the size of the
    /// output type terminal.h names, a `size_t` for the scrollback rows, a `uint16_t` for the size
    /// and the cursor, a `uint8_t` for the kitty flags. `None` for any other kind.
    /// `widths_are_what_libghostty_writes` holds this table to the linked library.
    fn width_of(data: GhosttyTerminalData) -> Option<usize> {
        match data {
            GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS => {
                Some(std::mem::size_of::<usize>())
            }
            GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS
            | GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS
            | GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X
            | GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y => {
                Some(std::mem::size_of::<u16>())
            }
            GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS => {
                Some(std::mem::size_of::<u8>())
            }
            _ => None,
        }
    }

    /// A count or position, widened to `u32`, read into a variable exactly `width_of(data)` bytes
    /// wide, because that is how many bytes the library writes. A `u32` for every kind overran
    /// the stack for the scrollback rows. A kind with no known width is refused.
    fn get_u32(&self, data: GhosttyTerminalData) -> Option<u32> {
        /// # Safety
        /// `width` must be how many bytes `ghostty_terminal_get` writes for `data`.
        unsafe fn get<T: Default>(
            terminal: GhosttyTerminal,
            data: GhosttyTerminalData,
            width: usize,
        ) -> Option<T> {
            // A `T` of the wrong width still reads the right number on a little-endian machine,
            // so only this check stops a wrong arm below from overrunning silently.
            assert_eq!(std::mem::size_of::<T>(), width, "kind {data}");
            let mut out = T::default();
            // SAFETY: `terminal` is live, and `out` is exactly the `width` bytes `data` writes.
            let rc = unsafe { ghostty_terminal_get(terminal, data, (&raw mut out).cast()) };
            (rc == OK).then_some(out)
        }
        let width = Self::width_of(data)?;
        // SAFETY: `inner` is live, and `width` comes from `width_of`, which
        // `widths_are_what_libghostty_writes` holds to the linked library.
        unsafe {
            match width {
                1 => get::<u8>(self.inner, data, width).map(u32::from),
                2 => get::<u16>(self.inner, data, width).map(u32::from),
                8 => get::<u64>(self.inner, data, width).and_then(|n| u32::try_from(n).ok()),
                _ => None,
            }
        }
    }

    pub fn mode(&self, mode: GhosttyMode) -> Option<bool> {
        let mut config = GhosttyTerminalModeConfig { mode, value: false };
        // SAFETY: DATA_MODE's input/output type is `GhosttyTerminalModeConfig`, and `config` is a
        // live one with `mode` set first, as the call requires.
        let rc = unsafe {
            ghostty_terminal_get(
                self.inner,
                GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_MODE,
                &mut config as *mut _ as *mut std::ffi::c_void,
            )
        };
        (rc == OK).then_some(config.value)
    }

    fn continuation(&self) -> Vec<u8> {
        let mut ptr_out: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        // SAFETY: `inner` is a live terminal, a null allocator selects the default one, and both
        // out-pointers are live locals.
        let rc = unsafe {
            ghostty_terminal_continuation_alloc(self.inner, ptr::null(), &mut ptr_out, &mut len)
        };
        if rc != OK || ptr_out.is_null() || len == 0 {
            return Vec::new();
        }
        // SAFETY: on success the call returned `len` initialised bytes at `ptr_out`, freed only on
        // the next line, after they are copied.
        let bytes = unsafe { std::slice::from_raw_parts(ptr_out, len) }.to_vec();
        // SAFETY: the same pointer, length and (default) allocator the allocation came from.
        unsafe { ghostty_free(ptr::null(), ptr_out, len) };
        bytes
    }

    fn format(&self, extras: bool) -> Vec<u8> {
        let mut formatter: GhosttyFormatter = ptr::null_mut();
        // SAFETY: the options are a C struct of integers, bools and sized sub-structs, for which
        // all zeroes is a valid value; the fields that matter are set below.
        let mut options: GhosttyFormatterTerminalOptions = unsafe { std::mem::zeroed() };
        options.size = std::mem::size_of::<GhosttyFormatterTerminalOptions>();
        options.emit = GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_VT;
        options.extra.size = std::mem::size_of::<GhosttyFormatterTerminalExtra>();
        if extras {
            options.extra.palette = true;
            options.extra.modes = true;
            options.extra.scrolling_region = true;
            options.extra.tabstops = true;
            options.extra.pwd = true;
            options.extra.keyboard = true;
            options.extra.screen.size = std::mem::size_of::<GhosttyFormatterScreenExtra>();
            options.extra.screen.charsets = true;
        }
        // SAFETY: `inner` is a live terminal that outlives the formatter, which is freed before
        // this method returns; `formatter` is a live out-pointer.
        let rc = unsafe {
            ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.inner, options)
        };
        if rc != OK || formatter.is_null() {
            return Vec::new();
        }
        let mut out: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        // SAFETY: `formatter` is live, and both out-pointers are live locals.
        let rc =
            unsafe { ghostty_formatter_format_alloc(formatter, ptr::null(), &mut out, &mut len) };
        let bytes = if rc == OK && !out.is_null() {
            // SAFETY: on success the call returned `len` initialised bytes at `out`, freed only
            // after they are copied.
            let copied = unsafe { std::slice::from_raw_parts(out, len) }.to_vec();
            // SAFETY: the pointer, length and (default) allocator the allocation came from.
            unsafe { ghostty_free(ptr::null(), out, len) };
            copied
        } else {
            Vec::new()
        };
        // SAFETY: `formatter` is live and freed exactly once, here.
        unsafe { ghostty_formatter_free(formatter) };
        bytes
    }

    /// A byte-for-byte copy of this terminal, via the snapshot format.
    ///
    /// Used to read state the formatter cannot reach on the live terminal without destroying it —
    /// see `primary_screen`. The snapshot carries BOTH screens, which is exactly why it is the way
    /// in: the formatter only ever sees the active one.
    ///
    /// The copy tracks no progress reports: it is a scratch read, never replayed.
    fn clone_via_snapshot(&self) -> Option<ShadowTerminal> {
        let mut bytes: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        // SAFETY: `inner` is a live terminal, and both out-pointers are live locals.
        let rc =
            unsafe { ghostty_snapshot_encode_alloc(self.inner, ptr::null(), &mut bytes, &mut len) };
        if rc != OK || bytes.is_null() {
            return None;
        }
        // SAFETY: on success the call returned `len` initialised bytes at `bytes`, freed only on
        // the next line, after they are copied.
        let encoded = unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec();
        // SAFETY: the pointer, length and (default) allocator the allocation came from.
        unsafe { ghostty_free(ptr::null(), bytes, len) };

        let mut decoder: GhosttySnapshotDecoder = ptr::null_mut();
        // SAFETY: the decoder borrows `encoded`, which is neither changed nor dropped until after
        // the decoder is freed below.
        let rc = unsafe {
            ghostty_snapshot_decoder_new_buf(
                ptr::null(),
                &mut decoder,
                encoded.as_ptr(),
                encoded.len(),
            )
        };
        if rc != OK || decoder.is_null() {
            return None;
        }
        let mut inner: GhosttyTerminal = ptr::null_mut();
        // SAFETY: `decoder` is live and has not started decoding; `inner` is a live out-pointer
        // that receives a terminal this function then owns.
        let rc = unsafe { ghostty_snapshot_decoder_decode(decoder, &mut inner) };
        // SAFETY: `decoder` is live and freed exactly once, here.
        unsafe { ghostty_snapshot_decoder_free(decoder) };
        if rc != OK || inner.is_null() {
            return None;
        }
        Some(ShadowTerminal {
            inner,
            progress: Box::into_raw(Box::default()),
        })
    }

    /// The primary screen's paint, when the alternate screen is the active one.
    ///
    /// **Why this needs a copy of the terminal.** `ghostty_formatter_terminal_new` formats the
    /// terminal's ACTIVE screen and takes no screen argument, so while a full-screen program is
    /// running the formatter can only see the alt screen — the shell's history is invisible to it.
    /// A client repainted from that comes back to a blank primary, so quitting the program loses
    /// every line that came before it. The design doc names the fix: paint the primary first, then
    /// the alt screen.
    ///
    /// Switching THIS terminal to primary and back is not an option — `DECRST 1049` abandons the
    /// alternate buffer and `DECSET 1049` clears it on re-entry, so the round trip would destroy
    /// the very screen being replayed. The snapshot carries both screens, so a decoded copy can be
    /// driven out of the alt screen freely and thrown away.
    fn primary_screen(&self) -> Option<Vec<u8>> {
        if self.mode(modes::ALT_SCREEN) != Some(true) {
            return None;
        }
        let mut copy = self.clone_via_snapshot()?;
        copy.write(b"\x1b[?1049l");
        let mut out = copy.format(true);
        // The primary's cursor, explicitly, for the same reason `replay` emits one: the formatter
        // homes the cursor and leaves it after the last painted cell. Here it matters twice over,
        // because `DECSET 1049` SAVES the cursor as it switches — so without this the position the
        // client restores when the program exits is wherever the paint ended, and the shell's next
        // line is written onto the end of the last history line instead of below it.
        out.extend_from_slice(&copy.cursor_position());
        Some(out)
    }

    /// Newlines to make up rows the formatter did not emit.
    ///
    /// The formatter stops at the last row with something on it, so a session whose cursor sits on
    /// a blank row — every session that has just printed a newline, which is most of them — leaves
    /// the client one or more rows short. That is invisible in the painted screen and wrong the
    /// moment the next byte arrives: the client's cursor is at the same VIEWPORT coordinate over
    /// content that is shifted up, so the next line of output lands on top of the last one instead
    /// of below it. Measured as one dropped line of output per mid-stream attach, on every session
    /// that had scrolled at all.
    ///
    /// The cursor's absolute row is `scrollback + cursor_y`, and the paint leaves the client at
    /// `painted_rows`; the difference is what has to be scrolled through.
    fn scroll_padding(&self, painted_rows: u32) -> Vec<u8> {
        let (Some(history), Some(cursor_y)) = (
            self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS),
            self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y),
        ) else {
            return Vec::new();
        };
        let wanted = history + cursor_y;
        if wanted <= painted_rows {
            return Vec::new();
        }
        // `\r\n` rather than `\n`: the client may have `LNM` unset, where a bare newline moves down
        // without returning to column 0, and the CUP that follows would then be applied from the
        // wrong place on every intermediate row.
        b"\r\n".repeat((wanted - painted_rows) as usize)
    }

    /// A CUP for wherever this terminal's cursor is, or nothing if it cannot be read.
    fn cursor_position(&self) -> Vec<u8> {
        match (
            self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X),
            self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y),
        ) {
            (Some(x), Some(y)) => format!("\x1b[{};{}H", y + 1, x + 1).into_bytes(),
            _ => Vec::new(),
        }
    }

    /// The bytes to send a client that has just attached, so it sees what the session looks like
    /// instead of a blank screen. See the module doc for why this is several pieces and not one.
    pub fn replay(&self) -> Vec<u8> {
        self.replay_reporting(true)
    }

    /// `replay()` saying idle whatever the last report was: for a program that is gone.
    pub fn replay_idle(&self) -> Vec<u8> {
        self.replay_reporting(false)
    }

    fn replay_reporting(&self, report: bool) -> Vec<u8> {
        let mut out = self.record();
        // Not in `record()`: a record outlives the program, and a stale "busy" would pin the
        // client's spinner on. Not with an empty record either, which callers read as "nothing
        // to show".
        if !out.is_empty() {
            out.extend_from_slice(&self.progress_report(report));
        }
        // Last: the continuation leaves the client's parser mid-sequence, exactly as the
        // producer's is, so the bytes that arrive next complete it instead of printing as text.
        out.extend_from_slice(&self.continuation());
        out
    }

    /// `replay()` without the progress report or the parser continuation: the record kept on disk
    /// (`crate::screens`). A record outlives the program, so a report in it would only pin the
    /// client's spinner on; and nothing will ever complete a continuation in a record, while the
    /// notice written after one would.
    pub fn record(&self) -> Vec<u8> {
        // The primary screen first, then re-entering the alt screen, then the alt screen's own
        // paint below — the order a real session produced them in.
        let mut out = match self.primary_screen() {
            Some(mut primary) => {
                primary.extend_from_slice(b"\x1b[?1049h");
                primary
            }
            None => Vec::new(),
        };
        let painted = self.format(true);
        // How far down the client's content the paint leaves it. The formatter emits one line per
        // non-empty row and no trailing newline, so this is where its cursor ends up.
        let painted_rows = painted.iter().filter(|byte| **byte == b'\n').count() as u32;
        out.extend_from_slice(&painted);
        out.extend_from_slice(&self.scroll_padding(painted_rows));

        if let Some(flags) =
            self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS)
        {
            if flags != 0 {
                out.extend_from_slice(format!("\x1b[>{flags}u").as_bytes());
            }
        }

        out.extend_from_slice(&self.cursor_position());
        if out.is_empty() {
            // Nothing could be read, which callers tell from an empty record.
            return out;
        }
        // Ahead of it all, a blank screen and no scrollback: the paint erases nothing, and a
        // client rarely starts blank — the app's panes run under macOS `login`, which prints its
        // `Last login` banner first. Erasing the screen before the scrollback matters: Ghostty's
        // ED 2 pushes the screen into the scrollback when its last rows are a shell prompt.
        [b"\x1b[2J\x1b[3J".as_slice(), &out].concat()
    }

    /// Plain-text screen contents. Used by tests and by the session list's preview; never sent to
    /// a client, which gets `replay()`.
    pub fn visible_text(&self) -> String {
        let mut formatter: GhosttyFormatter = ptr::null_mut();
        // SAFETY: the options are a C struct of integers, bools and sized sub-structs, for which
        // all zeroes is a valid value; the fields that matter are set below.
        let mut options: GhosttyFormatterTerminalOptions = unsafe { std::mem::zeroed() };
        options.size = std::mem::size_of::<GhosttyFormatterTerminalOptions>();
        options.emit = GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_PLAIN;
        options.extra.size = std::mem::size_of::<GhosttyFormatterTerminalExtra>();
        // SAFETY: `inner` is a live terminal that outlives the formatter, which is freed before
        // this method returns; `formatter` is a live out-pointer.
        let rc = unsafe {
            ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.inner, options)
        };
        if rc != OK || formatter.is_null() {
            return String::new();
        }
        let mut out: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        // SAFETY: `formatter` is live, and both out-pointers are live locals.
        let rc =
            unsafe { ghostty_formatter_format_alloc(formatter, ptr::null(), &mut out, &mut len) };
        let text = if rc == OK && !out.is_null() {
            // SAFETY: on success the call returned `len` initialised bytes at `out`, freed only
            // after they are copied.
            let copied = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(out, len) })
                .into_owned();
            // SAFETY: the pointer, length and (default) allocator the allocation came from.
            unsafe { ghostty_free(ptr::null(), out, len) };
            copied
        } else {
            String::new()
        };
        // SAFETY: `formatter` is live and freed exactly once, here.
        unsafe { ghostty_formatter_free(formatter) };
        text
    }
}

impl Drop for ShadowTerminal {
    fn drop(&mut self) {
        if !self.inner.is_null() {
            // SAFETY: `inner` is owned by this value and freed exactly once, here.
            unsafe { ghostty_terminal_free(self.inner) };
        }
        // After the terminal: it is what writes here.
        // SAFETY: `progress` came from `Box::into_raw` and is freed exactly once, here, after the
        // terminal that held a copy of it is gone.
        drop(unsafe { Box::from_raw(self.progress) });
    }
}

/// Modes worth naming, for tests and for anything that needs to reason about what survived.
pub mod modes {
    use super::{mode_new, GhosttyMode};
    pub const APP_CURSOR_KEYS: GhosttyMode = mode_new(1, false);
    pub const MOUSE_BUTTON: GhosttyMode = mode_new(1002, false);
    pub const MOUSE_SGR: GhosttyMode = mode_new(1006, false);
    pub const FOCUS_EVENTS: GhosttyMode = mode_new(1004, false);
    pub const BRACKETED_PASTE: GhosttyMode = mode_new(2004, false);
    pub const ALT_SCREEN: GhosttyMode = mode_new(1049, false);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole point: a client repainted from `replay()` must end up in the same state as one
    /// that watched from byte zero. Anything less is a terminal that looks right and does not work.
    fn assert_equivalent(source_bytes: &[u8], label: &str) {
        let mut watcher = ShadowTerminal::new(80, 24).expect("watcher");
        watcher.write(source_bytes);

        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(source_bytes);

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());

        for (name, mode) in [
            ("app cursor keys", modes::APP_CURSOR_KEYS),
            ("mouse 1002", modes::MOUSE_BUTTON),
            ("mouse 1006", modes::MOUSE_SGR),
            ("focus events", modes::FOCUS_EVENTS),
            ("bracketed paste", modes::BRACKETED_PASTE),
            ("alt screen", modes::ALT_SCREEN),
        ] {
            assert_eq!(
                watcher.mode(mode),
                client.mode(mode),
                "{label}: {name} did not survive re-synthesis"
            );
        }
        assert_eq!(
            watcher.visible_text(),
            client.visible_text(),
            "{label}: screen differs"
        );
    }

    #[test]
    fn plain_output_round_trips() {
        assert_equivalent(b"hello world\r\nsecond line\r\n", "plain");
    }

    #[test]
    fn styles_round_trip() {
        assert_equivalent(
            b"\x1b[1;31mbold red\x1b[0m \x1b[4;32munderline\x1b[0m\r\n\x1b[38;2;10;200;30mtruecolor\x1b[0m\r\n",
            "styles",
        );
    }

    /// The case the design doc singles out: a full-screen program's screen must come back, and
    /// leaving the alternate screen must restore the real shell history rather than a blank buffer.
    #[test]
    fn alternate_screen_round_trips() {
        assert_equivalent(
            b"shell history\r\n\x1b[?1049h\x1b[2J\x1b[HTUI BODY\x1b[5;3Hparked",
            "alt screen",
        );
    }

    #[test]
    fn negotiated_modes_round_trip() {
        assert_equivalent(
            b"\x1b[?1h\x1b[?2004h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[3;20rbody",
            "modes",
        );
    }

    /// A client's pane is rarely blank when the repaint arrives: the app's panes run under macOS
    /// `login`, which prints `Last login: … on ttys019` first. A repaint drawn over that without
    /// erasing it left the tail of the banner after any prompt shorter than it. Scrolled-off rows
    /// count too (`visible_text` includes scrollback), and the client's last rows are a marked
    /// prompt, which makes ED 2 push the screen into the scrollback rather than erase it.
    #[test]
    fn the_repaint_erases_what_the_client_showed_before_it() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"short$ ");

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        for _ in 0..30 {
            client.write(b"Last login: Fri Oct  2 08:21:13 on ttys019\r\n");
        }
        client.write(b"\x1b]133;A\x07old$ ");
        client.write(&producer.replay());

        assert_eq!(producer.visible_text(), client.visible_text());
    }

    /// Without the hand-emitted CUP the client writes the next byte where the last cell landed,
    /// producing "row 0row 1" instead of two rows.
    #[test]
    fn the_cursor_lands_where_the_producer_left_it() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"row 0\r\n");

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());
        client.write(b"row 1");

        let mut watcher = ShadowTerminal::new(80, 24).expect("watcher");
        watcher.write(b"row 0\r\nrow 1");

        assert_eq!(watcher.visible_text(), client.visible_text());
        assert!(
            !client.visible_text().contains("row 0row 1"),
            "the cursor was not restored: {:?}",
            client.visible_text()
        );
    }

    /// A stream cut mid-escape: the tail must complete the sequence, not print as text.
    #[test]
    fn a_split_escape_completes_after_reattach() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"visible\r\n\x1b[1;3");

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());
        client.write(b"1mRED\x1b[0m");

        let text = client.visible_text();
        assert!(text.contains("RED"), "got {text:?}");
        assert!(
            !text.contains("1mRED"),
            "the escape tail printed as text: {text:?}"
        );
    }

    #[test]
    fn a_split_codepoint_completes_after_reattach() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"visible\r\n");
        producer.write(&"\u{65e5}".as_bytes()[..2]);

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());
        client.write(&"\u{65e5}".as_bytes()[2..]);

        let text = client.visible_text();
        assert!(text.contains('\u{65e5}'), "got {text:?}");
        assert!(!text.contains('\u{fffd}'), "replacement char in {text:?}");
    }

    /// The kitty stack is the one thing `extra.keyboard` does not carry, so it is emitted by hand.
    ///
    /// Value: protects=the kitty flags read back as the value pushed, on both ends; fails_when=
    /// get_u32 stops reading KITTY_KEYBOARD_FLAGS, so both ends read None and still compare equal;
    /// why_new=the equality alone passed with that arm removed; seam=none
    #[test]
    fn kitty_keyboard_flags_survive() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"\x1b[>13u");
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());
        assert_eq!(
            producer.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS),
            Some(13)
        );
        assert_eq!(
            producer.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS),
            client.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS)
        );
    }

    /// Proof the assertions are not vacuous: the default formatter output — the obvious
    /// implementation — loses every mode, which is what makes a repainted client look right and
    /// do nothing.
    #[test]
    fn the_naive_formatter_output_would_fail_these_tests() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"\x1b[?1049h\x1b[2J\x1b[H\x1b[?1002h\x1b[?2004hbody");

        let mut naive = ShadowTerminal::new(80, 24).expect("naive");
        naive.write(&producer.format(false));

        assert_eq!(producer.mode(modes::ALT_SCREEN), Some(true));
        assert_eq!(
            naive.mode(modes::ALT_SCREEN),
            Some(false),
            "if this ever passes, the extra flags are no longer load-bearing"
        );
    }

    /// Scrollback is most of what people lose across a detach: the screen is only the last 24
    /// rows, and everything a build or a test run printed before that is above it.
    #[test]
    fn scrollback_survives_re_synthesis() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        // Comfortably more than one screen, so the early lines are genuinely in history.
        for n in 0..60 {
            producer.write(format!("line {n}\r\n").as_bytes());
        }
        assert!(
            producer
                .get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
                .unwrap_or(0)
                > 0,
            "fixture produced no scrollback"
        );

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());

        // Exactly the producer's depth. This was once asserted as "within one row", because the
        // formatter's emission ends without a trailing newline and the final line does not scroll
        // — and that missing row was not a rounding difference, it was a dropped line of output on
        // the next write. `scroll_padding` makes it up, so the bound is now an equality and the
        // old one must not come back.
        let want = producer
            .get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
            .unwrap_or(0);
        let got = client
            .get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
            .unwrap_or(0);
        assert_eq!(got, want, "history depth differs from the producer's");
        assert!(got > 20, "history was not restored at all: {got} rows");
        // History CONTENT, not just depth. Both checks below this were once the same copy-pasted
        // assertion on `line 59`, so the one whose comment promised "the oldest line" tested
        // nothing at all: padding the depth with blank rows would have satisfied every assertion
        // above while silently losing `line 0` through `line 35`.
        //
        // Asserted on the replay bytes as well as the client, because they fail differently — an
        // empty replay and a client that dropped what it was sent both lose the history, and only
        // the pair says which.
        let replay = String::from_utf8_lossy(&producer.replay()).into_owned();
        assert!(
            replay.contains("line 0") && replay.contains("line 35"),
            "the replay carries no scrolled-off history, only the visible screen"
        );

        // Note `visible_text()` is NOT screen-scoped: with a NULL selection the formatter emits the
        // whole terminal in Ghostty's sense, scrollback included (the module doc records the same
        // thing about `format`). So it sees both ends, and both are checked.
        assert!(
            client.visible_text().contains("line 59"),
            "screen lost its last line: {:?}",
            client.visible_text()
        );
        assert!(
            client.visible_text().contains("line 0"),
            "the oldest line did not survive into the client's history"
        );
    }

    /// A record is the replay without its continuation: the screen, both screens when a program
    /// is on the alternate one, and nothing left open for the notice written after it to complete.
    #[test]
    fn a_record_is_the_screen_without_a_continuation() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"shell history\r\n\x1b[?1049h\x1b[HFULL-SCREEN\x1b[3");
        let record = producer.record();
        assert!(
            producer.replay().ends_with(b"\x1b[3"),
            "fixture has no continuation"
        );
        assert!(producer.replay().starts_with(&record));
        assert!(!record.ends_with(b"\x1b[3"), "a continuation was kept");

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&record);
        assert_eq!(client.mode(modes::ALT_SCREEN), Some(true));
        assert!(client.visible_text().contains("FULL-SCREEN"));
        client.write(b"\x1b[?1049l");
        assert!(client.visible_text().contains("shell history"));
    }

    /// The replay re-emits the last progress report, in a form Ghostty parses back to the same
    /// report; the on-disk record never does, since it outlives the program that sent it (#359).
    /// Value: protects=replay() carries the last OSC 9;4 report, a cleared one and record() never; fails_when=replay drops, mis-formats or keeps a cleared report, or record() carries one; why_new=nothing covered the progress report before #359; seam=none
    #[test]
    fn only_the_replay_carries_the_progress_report() {
        for (sent, want) in [
            (b"\x1b]9;4;3\x1b\\".as_slice(), Some((3, -1))),
            (b"\x1b]9;4;1;42\x07".as_slice(), Some((1, 42))),
            (b"\x1b]9;4;1;0\x07".as_slice(), Some((1, 0))),
            (b"\x1b]9;4;3\x1b\\\x1b]9;4;0\x1b\\".as_slice(), None),
        ] {
            let mut producer = ShadowTerminal::new(80, 24).expect("producer");
            producer.write(b"busy\r\n");
            producer.write(sent);
            assert_eq!(producer.progress(), want, "producer for {sent:?}");

            let mut client = ShadowTerminal::new(80, 24).expect("client");
            client.write(&producer.replay());
            assert_eq!(client.progress(), want, "client replayed from {sent:?}");

            // Idle is said out loud, so a client still showing an old busy state drops it.
            let remove = b"\x1b]9;4;0\x1b\\";
            let replay = producer.replay();
            assert_eq!(
                want.is_none(),
                replay.windows(remove.len()).any(|w| w == remove),
                "REMOVE in the replay for {sent:?}: {:?}",
                String::from_utf8_lossy(&replay)
            );

            let record = producer.record();
            let osc = b"\x1b]9;4";
            assert!(
                !record.windows(osc.len()).any(|w| w == osc),
                "the record carries a progress report: {:?}",
                String::from_utf8_lossy(&record)
            );
        }
    }

    /// The progress report goes before the continuation, so a sequence the producer was
    /// mid-way through still completes on the client instead of printing as text (#359).
    /// Value: protects=replay() ends with the continuation even when a progress report is present; fails_when=progress_report() is appended after continuation(), splicing the report into the open CSI; why_new=the progress report is the first piece placed between the record and the continuation; seam=none
    #[test]
    fn the_progress_report_does_not_split_the_continuation() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"busy\r\n\x1b]9;4;3\x1b\\\x1b[3");
        let replay = producer.replay();
        assert!(replay.ends_with(b"\x1b[3"), "{replay:?}");
        assert!(
            replay
                .windows(b"\x1b]9;4;3".len())
                .any(|w| w == b"\x1b]9;4;3"),
            "no progress report in {replay:?}"
        );

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&replay);
        assert_eq!(client.progress(), Some((3, -1)));
        client.write(b"1mRED\x1b[0m");
        let text = client.visible_text();
        assert!(text.contains("RED") && !text.contains("1mRED"), "{text:?}");
    }

    /// A session with nothing scrolled off must not gain phantom history.
    #[test]
    fn a_short_session_gains_no_phantom_history() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"just one line\r\n");
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());
        assert_eq!(
            client.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS),
            Some(0)
        );
    }

    /// The design doc's property, in the stronger form it names: a client attaching mid-stream sees
    /// what a client that watched from byte zero sees — and then **both receive the rest of the
    /// stream**, so a divergence in mode or parser state shows up in what they render afterwards
    /// rather than only at the join.
    ///
    /// `assert_equivalent` above is the `k == len` case of this: it repaints a client and compares,
    /// but never feeds it the tail, so a client left in the wrong parser state looks identical to a
    /// correct one. That is exactly the failure the continuation record exists to prevent.
    ///
    /// **Every split point, not a hand-picked one.** A chosen split tests the boundary its author
    /// thought of; the bugs live at the boundaries they did not — between a CSI's parameter bytes,
    /// between an OSC's introducer and its terminator, in the middle of a UTF-8 sequence. The
    /// corpora below are short precisely so that exhausting their split points is cheap.
    fn assert_equivalent_at_every_split(source: &[u8], label: &str) {
        let mut watcher = ShadowTerminal::new(80, 24).expect("watcher");
        watcher.write(source);
        let want_text = watcher.visible_text();

        for split in 0..=source.len() {
            let mut producer = ShadowTerminal::new(80, 24).expect("producer");
            producer.write(&source[..split]);

            let mut client = ShadowTerminal::new(80, 24).expect("client");
            client.write(&producer.replay());
            client.write(&source[split..]);

            for (name, mode) in [
                ("app cursor keys", modes::APP_CURSOR_KEYS),
                ("mouse 1002", modes::MOUSE_BUTTON),
                ("mouse 1006", modes::MOUSE_SGR),
                ("focus events", modes::FOCUS_EVENTS),
                ("bracketed paste", modes::BRACKETED_PASTE),
                ("alt screen", modes::ALT_SCREEN),
            ] {
                assert_eq!(
                    watcher.mode(mode),
                    client.mode(mode),
                    "{label}: {name} differs after attaching at byte {split} of {}",
                    source.len()
                );
            }
            assert_eq!(
                want_text,
                client.visible_text(),
                "{label}: screen differs after attaching at byte {split} of {}",
                source.len()
            );
        }
    }

    /// Escape sequences that a split can land inside, including a nested style change and a CSI
    /// whose parameters run to several bytes.
    #[test]
    fn every_split_of_a_styled_stream_converges() {
        assert_equivalent_at_every_split(
            b"top\r\n\x1b[1;31mred\x1b[0m \x1b[38;2;10;200;30mtruecolor\x1b[0m\r\n\x1b[5;12Hparked",
            "split escapes",
        );
    }

    /// Entering and leaving the alternate screen. The doc singles this out because a split inside
    /// the transition is what decides whether the client comes back to the shell's history or to a
    /// blank buffer.
    #[test]
    fn every_split_of_an_alt_screen_transition_converges() {
        assert_equivalent_at_every_split(
            b"history one\r\nhistory two\r\n\x1b[?1049h\x1b[2J\x1b[HTUI\x1b[?1049lback home\r\n",
            "alt screen transitions",
        );
    }

    /// Multi-byte characters, so a split lands mid-codepoint. A client that resumed with a fresh
    /// parser would render U+FFFD here and never recover the character.
    #[test]
    fn every_split_of_multibyte_text_converges() {
        assert_equivalent_at_every_split(
            "hello \u{65e5}\u{672c}\u{8a9e} and \u{1f600} done\r\n".as_bytes(),
            "truncated UTF-8",
        );
    }

    /// Queries embedded in the stream. These are the shape that made a reattaching client answer
    /// stale questions into an idle pane as garbage, so what matters is that they do not change the
    /// screen — at any split.
    #[test]
    fn every_split_of_an_embedded_query_stream_converges() {
        assert_equivalent_at_every_split(
            b"before\x1b[6n\x1b[>c\x1b]11;?\x07\x1b[?62;1;4c\x1b[0nafter\r\n",
            "embedded queries",
        );
    }

    /// The named cases plus the one that combines them: negotiated modes over content deep enough
    /// to have scrolled.
    ///
    /// This is the case that found `scroll_padding`'s bug: every split from the moment the session
    /// first scrolled — which is to say every realistic mid-stream attach — dropped a line.
    #[test]
    fn every_split_of_modes_over_scrollback_converges() {
        let mut source = Vec::new();
        source.extend_from_slice(b"\x1b[?1h\x1b[?2004h\x1b[?1002h\x1b[?1006h\x1b[?1004h");
        for n in 0..40 {
            source.extend_from_slice(format!("line {n}\r\n").as_bytes());
        }
        source.extend_from_slice(b"\x1b[1;33mtail\x1b[0m");

        let mut watcher = ShadowTerminal::new(80, 24).expect("watcher");
        watcher.write(&source);

        for split in 0..=source.len() {
            let mut producer = ShadowTerminal::new(80, 24).expect("producer");
            producer.write(&source[..split]);
            let mut client = ShadowTerminal::new(80, 24).expect("client");
            client.write(&producer.replay());
            client.write(&source[split..]);

            assert_eq!(
                watcher.mode(modes::BRACKETED_PASTE),
                client.mode(modes::BRACKETED_PASTE),
                "bracketed paste differs after attaching at byte {split}"
            );
            assert_eq!(
                watcher.visible_text(),
                client.visible_text(),
                "screen differs after attaching at byte {split}"
            );
        }
    }

    /// A TUI that draws a few rows and parks the cursor far below them, on the alternate screen.
    ///
    /// Worth its own case because `scroll_padding` reasons in absolute rows — scrollback plus the
    /// cursor's row — and the alternate screen has no scrollback. Padding that made sense for a
    /// scrolling primary screen could have scrolled a TUI's screen out from under it. Measured: it
    /// does not, at any split.
    #[test]
    fn every_split_of_a_parked_alt_cursor_converges() {
        assert_equivalent_at_every_split(
            b"shell history\r\n\x1b[?1049h\x1b[2JTUI HEADER\r\nbody\x1b[20;3Hparked",
            "parked alt cursor",
        );
    }

    /// Both counts above 255, so reading them a byte too narrow shows.
    #[test]
    fn resize_is_reflected() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        terminal.resize(300, 400);
        assert_eq!(
            terminal.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS),
            Some(300)
        );
        assert_eq!(
            terminal.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS),
            Some(400)
        );
    }

    /// `get_u32` reads only the kinds whose width it knows: a kind it was not told about could
    /// write more than the variable it reads into.
    #[test]
    fn get_u32_refuses_a_kind_of_unknown_width() {
        let terminal = ShadowTerminal::new(80, 24).expect("terminal");
        assert_eq!(
            terminal.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_TOTAL_ROWS),
            None
        );
    }

    /// A read too wide or too narrow still gets the right number on a little-endian machine, so
    /// no value assertion notices one; only counting the bytes the library writes does. This is
    /// what fails if a Ghostty bump widens an output type.
    ///
    /// Value: protects=width_of equals the bytes libghostty writes for every kind get_u32 reads;
    /// fails_when=a Ghostty bump changes an output type, or width_of names the wrong width;
    /// why_new=a u32 read for every kind passed every other test; seam=none
    #[test]
    fn widths_are_what_libghostty_writes() {
        const SENTINEL: u8 = 0xA5;
        let terminal = ShadowTerminal::new(80, 24).expect("terminal");
        // Every kind the table claims, so a kind added to it is checked without being listed
        // here. terminal.h's kinds run from 0 to 39 today.
        let kinds: Vec<_> = (0..256)
            .filter_map(|kind| ShadowTerminal::width_of(kind).map(|width| (kind, width)))
            .collect();
        assert!(!kinds.is_empty(), "width_of claims no kinds");
        for (kind, width) in kinds {
            // Words, not bytes, so the buffer is aligned for the widest type written into it.
            let mut words = [u64::from_ne_bytes([SENTINEL; 8]); 2];
            // SAFETY: `inner` is live, and only kinds the table claims are read. 16 aligned bytes
            // hold all of them, and a table entry off by up to 8 bytes is what this test reports.
            let rc =
                unsafe { ghostty_terminal_get(terminal.inner, kind, words.as_mut_ptr().cast()) };
            assert_eq!(rc, OK, "kind {kind}");
            // Every value here is small, so no byte the library writes equals the sentinel.
            let bytes: Vec<u8> = words.iter().flat_map(|word| word.to_ne_bytes()).collect();
            let written = bytes
                .iter()
                .rposition(|byte| *byte != SENTINEL)
                .map(|i| i + 1);
            assert_eq!(written, Some(width), "kind {kind}");
        }
    }

    /// The precondition behind `attach`'s chunking: a repaint really can exceed the protocol's
    /// 1 MiB frame cap, so this is a reachable state and not a theoretical one.
    ///
    /// `Frame::encode` PANICS above that cap rather than truncating, and `attach` builds the
    /// repaint frame while holding the attachment mutex — so an unchunked oversized replay
    /// poisons that mutex and the session's reader thread dies on its next chunk, leaving the pty
    /// undrained and the shell blocked on write for every client on it.
    ///
    /// Styled rather than plain: the formatter emits an SGR run per colour change, so colour is
    /// what makes a screen expensive. A large window running a heavily-coloured TUI is the real
    /// shape of this.
    #[test]
    fn a_repaint_can_exceed_the_frame_cap() {
        let mut terminal = ShadowTerminal::new(400, 200).expect("terminal");
        // Alternating 256-colour foreground per cell, so no two adjacent cells share a run.
        let mut paint = Vec::new();
        for row in 0..200u32 {
            for column in 0..400u32 {
                let colour = ((row * 400 + column) % 255) + 1;
                paint.extend_from_slice(format!("\x1b[38;5;{colour}mX").as_bytes());
            }
            if row < 199 {
                paint.extend_from_slice(b"\r\n");
            }
        }
        terminal.write(&paint);

        assert!(
            terminal.replay().len() > crate::protocol::frame::MAX_PAYLOAD_SIZE,
            "a 400x200 styled screen replayed in {} bytes, under the {} cap — the fixture no \
             longer reproduces the condition `attach`'s chunking exists for",
            terminal.replay().len(),
            crate::protocol::frame::MAX_PAYLOAD_SIZE
        );
    }
}
