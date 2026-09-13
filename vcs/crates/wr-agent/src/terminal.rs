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

/// A terminal shadowing one session.
pub struct ShadowTerminal {
    inner: GhosttyTerminal,
}

// The handle is owned exclusively and every method takes `&mut self`, so the terminal is never
// touched from two threads at once. libghostty-vt requires the caller to serialise access, which
// is exactly what `&mut` expresses.
unsafe impl Send for ShadowTerminal {}

impl ShadowTerminal {
    pub fn new(columns: u16, rows: u16) -> Option<ShadowTerminal> {
        let mut inner: GhosttyTerminal = ptr::null_mut();
        let rc =
            unsafe { ghostty_terminal_new(ptr::null(), &mut inner, columns.max(1), rows.max(1)) };
        if rc != OK || inner.is_null() {
            return None;
        }
        let terminal = ShadowTerminal { inner };
        terminal.enable_continuation_tracking();
        Some(terminal)
    }

    fn enable_continuation_tracking(&self) {
        let limit: usize = CONTINUATION_MAX_BYTES;
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
        unsafe { ghostty_terminal_vt_write(self.inner, bytes.as_ptr(), bytes.len()) }
    }

    /// Cell pixel dimensions are zero: they feed image protocols and size reports, and the shadow
    /// renders nothing — the real client owns the pixels and reports its own.
    pub fn resize(&mut self, columns: u16, rows: u16) {
        unsafe {
            ghostty_terminal_resize(self.inner, columns.max(1), rows.max(1), 0, 0);
        }
    }

    fn get_u32(&self, data: GhosttyTerminalData) -> Option<u32> {
        let mut out: u32 = 0;
        let rc = unsafe {
            ghostty_terminal_get(
                self.inner,
                data,
                &mut out as *mut u32 as *mut std::ffi::c_void,
            )
        };
        (rc == OK).then_some(out)
    }

    pub fn mode(&self, mode: GhosttyMode) -> Option<bool> {
        let mut config = GhosttyTerminalModeConfig { mode, value: false };
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
        let rc = unsafe {
            ghostty_terminal_continuation_alloc(self.inner, ptr::null(), &mut ptr_out, &mut len)
        };
        if rc != OK || ptr_out.is_null() || len == 0 {
            return Vec::new();
        }
        let bytes = unsafe { std::slice::from_raw_parts(ptr_out, len) }.to_vec();
        unsafe { ghostty_free(ptr::null(), ptr_out, len) };
        bytes
    }

    fn format(&self, extras: bool) -> Vec<u8> {
        let mut formatter: GhosttyFormatter = ptr::null_mut();
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
        let rc = unsafe {
            ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.inner, options)
        };
        if rc != OK || formatter.is_null() {
            return Vec::new();
        }
        let mut out: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        let rc =
            unsafe { ghostty_formatter_format_alloc(formatter, ptr::null(), &mut out, &mut len) };
        let bytes = if rc == OK && !out.is_null() {
            let copied = unsafe { std::slice::from_raw_parts(out, len) }.to_vec();
            unsafe { ghostty_free(ptr::null(), out, len) };
            copied
        } else {
            Vec::new()
        };
        unsafe { ghostty_formatter_free(formatter) };
        bytes
    }

    /// A byte-for-byte copy of this terminal, via the snapshot format.
    ///
    /// Used to read state the formatter cannot reach on the live terminal without destroying it —
    /// see `primary_screen`. The snapshot carries BOTH screens, which is exactly why it is the way
    /// in: the formatter only ever sees the active one.
    fn clone_via_snapshot(&self) -> Option<ShadowTerminal> {
        let mut bytes: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        let rc =
            unsafe { ghostty_snapshot_encode_alloc(self.inner, ptr::null(), &mut bytes, &mut len) };
        if rc != OK || bytes.is_null() {
            return None;
        }
        let encoded = unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec();
        unsafe { ghostty_free(ptr::null(), bytes, len) };

        let mut decoder: GhosttySnapshotDecoder = ptr::null_mut();
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
        let rc = unsafe { ghostty_snapshot_decoder_decode(decoder, &mut inner) };
        unsafe { ghostty_snapshot_decoder_free(decoder) };
        if rc != OK || inner.is_null() {
            return None;
        }
        Some(ShadowTerminal { inner })
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
    /// instead of a blank screen. See the module doc for why this is four pieces and not one.
    pub fn replay(&self) -> Vec<u8> {
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

        // Last: the continuation leaves the client's parser mid-sequence, exactly as the
        // producer's is, so the bytes that arrive next complete it instead of printing as text.
        out.extend_from_slice(&self.continuation());
        out
    }

    /// Plain-text screen contents. Used by tests and by the session list's preview; never sent to
    /// a client, which gets `replay()`.
    pub fn visible_text(&self) -> String {
        let mut formatter: GhosttyFormatter = ptr::null_mut();
        let mut options: GhosttyFormatterTerminalOptions = unsafe { std::mem::zeroed() };
        options.size = std::mem::size_of::<GhosttyFormatterTerminalOptions>();
        options.emit = GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_PLAIN;
        options.extra.size = std::mem::size_of::<GhosttyFormatterTerminalExtra>();
        let rc = unsafe {
            ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.inner, options)
        };
        if rc != OK || formatter.is_null() {
            return String::new();
        }
        let mut out: *mut u8 = ptr::null_mut();
        let mut len: usize = 0;
        let rc =
            unsafe { ghostty_formatter_format_alloc(formatter, ptr::null(), &mut out, &mut len) };
        let text = if rc == OK && !out.is_null() {
            let copied = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(out, len) })
                .into_owned();
            unsafe { ghostty_free(ptr::null(), out, len) };
            copied
        } else {
            String::new()
        };
        unsafe { ghostty_formatter_free(formatter) };
        text
    }
}

impl Drop for ShadowTerminal {
    fn drop(&mut self) {
        if !self.inner.is_null() {
            unsafe { ghostty_terminal_free(self.inner) };
        }
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
    #[test]
    fn kitty_keyboard_flags_survive() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"\x1b[>13u");
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.replay());
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
        // The oldest line must be there, not just some rows.
        assert!(
            client.visible_text().contains("line 59"),
            "screen lost its last line"
        );
        // The visible screen must still be the recent lines, not the replayed history.
        assert!(
            client.visible_text().contains("line 59"),
            "screen lost its last line: {:?}",
            client.visible_text()
        );
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

    #[test]
    fn resize_is_reflected() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        terminal.resize(100, 30);
        assert_eq!(
            terminal.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS),
            Some(100)
        );
        assert_eq!(
            terminal.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS),
            Some(30)
        );
    }
}
