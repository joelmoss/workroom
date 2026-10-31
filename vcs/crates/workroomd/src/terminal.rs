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
//! 2. **The cursor**, by hand. `GhosttyFormatterTerminalExtra` covers modes, scrolling region,
//!    tabstops, pwd, keyboard and charsets — but has no cursor field. The formatter homes
//!    the cursor, paints, and leaves it wherever the last cell landed, so without an explicit CUP
//!    the next byte lands in the wrong place.
//! 3. **Kitty keyboard flags**, by hand. `extra.keyboard` covers ModifyOtherKeys and not the kitty
//!    stack. The snapshot carries the flags correctly, so nothing is lost across persistence; they
//!    simply are not emitted.
//!
//! The palette goes by hand too, and only the colours a program set (`palette_overrides`).
//!
//! Then **the last OSC 9;4 progress report**, or an explicit REMOVE when there is none (#359). A
//! program reports busy once, at the start of its work, so a client attaching mid-turn learns it
//! only from here. Never in the on-disk record, which outlives the program. Two things clear it:
//! the program's own REMOVE, and the shell's next command end (OSC 133 D, #464). The app clears
//! its spinner at a D too, but only one that closes a command it saw start (OSC 133 C); the shadow
//! clears at any D, so a report held at an idle prompt (a background job's) reads idle on a
//! reattach after the D that zsh and bash send at a prompt with no command, as on an empty Enter,
//! while the live pane still spins. A false D inside a command (a TUI printing one, a nested
//! shell) clears it in both, and a job resumed with `fg` reads idle until it reports again.
//! Separately, and for every session, `Shadow::replay_for` leaves the report out of a replay while
//! a known group other than its sender owns the pty, without clearing it. For a shell that sends
//! no OSC 133 (a run command under `/bin/sh`, a shell without Ghostty's integration) that is all
//! that hides a crashed program's spinner.
//!
//! And **the parser continuation last**, because a byte stream cut mid-sequence leaves the VT
//! parser or UTF-8 decoder unfinished and nothing in the grid expresses that. Without it the tail
//! of a split escape renders as literal text and a cut codepoint as U+FFFD.
//!
//! **Scrollback comes back too, and needs no help.** An earlier reading of this concluded the
//! formatter was screen-scoped and history was lost — it is not. With a NULL selection the
//! formatter emits the *entire* screen in Ghostty's sense, scrollback included: a terminal holding
//! 37 history rows and 24 visible ones emits 60 newlines, and a client fed that ends up with the
//! same 37 rows of history and the right visible screen. A hand-rolled history emission on top of
//! it only double-counts.
//!
//! **Only the newest history that fits is sent.** The shadow keeps as much as the app's pane
//! (50 MB), and a paint of all of it can run to tens of MiB, so every repaint, record and hand-off
//! screen formats a selection of the screen and the newest rows that fit its budget
//! (`format_tail`, ADR 0051).
//!
//! **It answers one query: the program status probe** (`OSC 7501 ; ?`, #358). Every other answer
//! stays the attached client's; this one no client gives, and a program that gets none reports
//! nothing. The reports themselves go to `crate::program_status`, which keeps them.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]

use std::ptr;
use std::time::Instant;

use crate::images::{ImageRef, Placement};
use crate::program_status::{Event, Kind, Report, State};

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
/// unavailable. The daemon can never know where a chunk boundary will fall, so it is on from
/// creation. 4 KiB is far beyond any real escape sequence; the cap exists so a hostile stream
/// cannot grow it without bound.
const CONTINUATION_MAX_BYTES: usize = 4096;

/// What the shadow keeps is what the app's own pane keeps (#462): both run the same Ghostty
/// commit, whose `scrollback-limit-bytes` default is 50 MB with no line limit, so a reattached
/// pane can show what it would have had without the daemon. libghostty's own default is 10 KB,
/// about one page. What is kept is not what is sent: every repaint, record and hand-off sends the
/// newest history that fits its budget (`format_tail`), so the size of the history never decides
/// whether a screen can be sent. The history is kept compressed while idle (`compress`, #463).
const SCROLLBACK_MAX_BYTES: usize = 50_000_000;

/// The most a repaint (`replay`) is: `screens::MAX_RECORD` less room for what `replay` adds after
/// the record and for slack in the fixed parts' estimate.
pub(crate) const REPAINT_MAX_BYTES: usize = crate::screens::MAX_RECORD - (64 << 10);

/// What a screen kept on disk is held to (`Shadow::record`, `crate::screens`). Smaller than a
/// repaint: a busy session's record is rewritten and synced every 2 s, and only a pane coming back
/// after its host restarted reads it. 1 MiB is about 1,700 rows of coloured history at 200 columns,
/// and about 11,000 plain.
pub(crate) const RECORD_MAX_BYTES: usize = 1 << 20;

/// What `replay` adds after `record`: the progress report (under 32 bytes) and the parser
/// continuation (`CONTINUATION_MAX_BYTES`). A hand-off budgets a session's whole replay, so it
/// gives `record` its share less this.
pub(crate) const REPLAY_OVERHEAD: usize = 32 + CONTINUATION_MAX_BYTES;

/// How many of the newest rows `format_tail` formats first, to measure the history's density
/// before guessing how many rows fit.
const TAIL_SAMPLE_ROWS: u32 = 64;

/// How many formats `format_tail` runs before it only halves: the sample and three guesses.
const TAIL_GUESSES: u32 = 4;

/// How many times the rows of `format_tail`'s last format a guess may grow to. The newest rows can
/// be far sparser than the history behind them (prompts after a truecolour dump), where an unbounded
/// guess formatted 118 MB once to send 4 MiB. Three steps of 8 still reach 32,768 rows, more than
/// a full plain history holds at 200 columns.
const TAIL_GROWTH: u32 = 8;

/// `ghostty_mode_new` is a `static inline` in modes.h, so bindgen does not emit it.
/// modes.h: `(value & 0x7FFF) | ((uint16_t)ansi << 15)`.
const fn mode_new(value: u16, ansi: bool) -> GhosttyMode {
    (value & 0x7FFF) | ((ansi as u16) << 15)
}

/// The last OSC 9;4 a session reported, as (state, percent); percent is -1 when omitted.
pub type Progress = Option<(GhosttyTerminalProgressState, i8)>;

/// The image data the shadow keeps per screen, in decoded bytes (#551). libghostty-vt's own default
/// is 10 MB, which refuses a single full-size Retina screenshot outright (2880x1800 RGBA is 20.7).
/// The app keeps 320 MB; this bounds a daemon holding many sessions.
pub(crate) const IMAGE_STORAGE_LIMIT: u64 = 32_000_000;

/// The pixels of one stored image, copied out so it can be encoded without the shadow's lock.
pub struct Pixels {
    width: u32,
    height: u32,
    color: png::ColorType,
    data: Vec<u8>,
}

impl Pixels {
    /// As a PNG, at the encoder's fastest: about 3 ms a MB, smaller than zlib at level 1 and about
    /// four times as fast on one fast core (measured for #551).
    pub fn to_png(&self) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, self.width, self.height);
        encoder.set_color(self.color);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(&self.data).ok()?;
        writer.finish().ok()?;
        Some(out)
    }
}

/// `bytes` as 8-bit RGBA, or `None` for anything that is not a PNG this shadow could store. The
/// size is checked from the header, before anything is allocated for the pixels: a program can
/// claim any dimensions it likes in a few bytes.
fn decode_png_rgba(bytes: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let (width, height) = {
        let info = reader.info();
        (info.width, info.height)
    };
    if u64::from(width) * u64::from(height) * 4 > IMAGE_STORAGE_LIMIT {
        return None;
    }
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buffer).ok()?;
    buffer.truncate(frame.buffer_size());
    let rgba = match frame.color_type {
        png::ColorType::Rgba => buffer,
        png::ColorType::Rgb => buffer
            .chunks_exact(3)
            .flat_map(|pixel| [pixel[0], pixel[1], pixel[2], 255])
            .collect(),
        png::ColorType::GrayscaleAlpha => buffer
            .chunks_exact(2)
            .flat_map(|pixel| [pixel[0], pixel[0], pixel[0], pixel[1]])
            .collect(),
        png::ColorType::Grayscale => buffer
            .iter()
            .flat_map(|gray| [*gray, *gray, *gray, 255])
            .collect(),
        png::ColorType::Indexed => return None,
    };
    Some((width, height, rgba))
}

/// `GHOSTTY_SYS_OPT_DECODE_PNG`. Without a decoder the shadow rejects every PNG, which is what
/// `kitten icat` sends.
unsafe extern "C" fn decode_png(
    _userdata: *mut std::ffi::c_void,
    allocator: *const GhosttyAllocator,
    data: *const u8,
    data_len: usize,
    out: *mut GhosttySysImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: libghostty passes `data_len` bytes at `data`, valid for this call.
    let bytes = unsafe { std::slice::from_raw_parts(data, data_len) };
    // These bytes are whatever a program printed, and a panic cannot cross this C boundary: it
    // would abort the daemon, and every session with it, over one image.
    let Ok(Some((width, height, rgba))) = std::panic::catch_unwind(|| decode_png_rgba(bytes))
    else {
        return false;
    };
    // SAFETY: the allocator is the one this call was given, which is the one libghostty frees with.
    let pixels = unsafe { ghostty_alloc(allocator, rgba.len()) };
    if pixels.is_null() {
        return false;
    }
    // SAFETY: `pixels` has room for `rgba.len()` bytes and cannot overlap a live `Vec`, and `out`
    // is the live struct libghostty gave this call.
    unsafe {
        ptr::copy_nonoverlapping(rgba.as_ptr(), pixels, rgba.len());
        *out = GhosttySysImage {
            width,
            height,
            data: pixels,
            data_len: rgba.len(),
        };
    }
    true
}

/// Sets the process's PNG decoder, once, before any terminal needs it.
fn install_png_decoder() {
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        let decode: GhosttySysDecodePngFn = Some(decode_png);
        // SAFETY: a function pointer option is passed directly, and `decode_png` matches it.
        unsafe {
            ghostty_sys_set(
                GhosttySysOption_GHOSTTY_SYS_OPT_DECODE_PNG,
                decode.map_or(ptr::null(), |function| function as *const std::ffi::c_void),
            );
        }
    });
}

/// A terminal's memory as libghostty counts it (`ShadowTerminal::memory`).
pub type MemoryUsage = GhosttyTerminalMemoryUsage;

#[cfg(test)]
thread_local! {
    /// The size of every format `format_tail` has run on this thread, for the tests that bound
    /// its search.
    static ATTEMPTS: std::cell::RefCell<Vec<usize>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Where the progress callback and a command end write: the held report, and whether it changed
/// since `take_fresh_report` last asked.
#[derive(Default)]
struct ProgressSlot {
    report: Progress,
    fresh: bool,
}

/// The command the shell is running, from its OSC 133 marks, for its command result (#473).
#[derive(Default)]
struct CommandSlot {
    /// When its C arrived. `None` between commands, so a D with no C before it closes nothing:
    /// bash sends `D;<last status>` at every prompt, an empty Enter included.
    started: Option<Instant>,
    /// The title the shell gave it. No shell sends the command line with C, but zsh and bash set
    /// the title to it when the integration's title feature is on: bash just before C, after its
    /// prompt has set the directory, zsh just after C. So the last title since the prompt, or
    /// else the first after C, and never a program's later one.
    line: Option<String>,
}

/// Where the callbacks write: the progress slot, and what a write produced for program status
/// (#358) until `take_program_status` collects it. The records themselves are kept by
/// `crate::program_status::Store`, outside the terminal.
#[derive(Default)]
struct Effects {
    progress: ProgressSlot,
    command: CommandSlot,
    program: Vec<Event>,
    /// A RIS since `write_watched` last looked, which a transfer must not outlive.
    reset: bool,
    /// Bytes for the pty: only the answer to a program status probe.
    replies: Vec<u8>,
}

/// What `OSC 7501 ; ?` is answered with, up to the states and kinds that follow it.
const PROBE_REPLY: &[u8] = b"\x1b]7501;";

/// What disturbed a transfer (`write_watched`).
#[derive(Debug, PartialEq, Eq)]
pub struct Disturbed {
    /// Where in the bytes an `images::ABORT` can go, ahead of whatever disturbed it: an abort must
    /// reach the screen whose storage holds the load, and must not land inside a sequence.
    /// `None` when there is no such place, as after a reset, which clears the load itself.
    pub abort_at: Option<usize>,
    /// Nothing happened yet, but the read ended on an ESC at ground. If `_` follows, the next read
    /// starts a string with no place left for an abort ahead of it, so an open load has to end
    /// now. With no load open, the transfer just waits for ground as usual.
    pub only_if_loading: bool,
}

/// One placement, as `each_placement` reads it.
struct Placed {
    image: u32,
    generation: u64,
    id: u32,
    is_virtual: bool,
    x_offset: u32,
    y_offset: u32,
    columns: u32,
    rows: u32,
    z: i32,
    info: GhosttyKittyGraphicsPlacementRenderInfo,
}

impl Placed {
    fn read(
        graphics: GhosttyKittyGraphics,
        iterator: GhosttyKittyGraphicsPlacementIterator,
        terminal: GhosttyTerminal,
    ) -> Option<Placed> {
        /// # Safety
        /// `T` must be the output type of `data`, and `iterator` positioned on a placement.
        unsafe fn get<T: Default>(
            iterator: GhosttyKittyGraphicsPlacementIterator,
            data: GhosttyKittyGraphicsPlacementData,
        ) -> Option<T> {
            let mut value = T::default();
            // SAFETY: the caller's contract, and `value` is live.
            let rc = unsafe {
                ghostty_kitty_graphics_placement_get(iterator, data, (&raw mut value).cast())
            };
            (rc == OK).then_some(value)
        }
        // SAFETY: each `T` is that data kind's documented output type, and the caller has
        // positioned `iterator` on a placement.
        unsafe {
            let id: u32 = get(
                iterator,
                GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
            )?;
            let image = ghostty_kitty_graphics_image(graphics, id);
            if image.is_null() {
                return None;
            }
            let mut generation = 0u64;
            let rc = ghostty_kitty_graphics_image_get(
                image,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
                (&raw mut generation).cast(),
            );
            if rc != OK {
                return None;
            }
            let mut info: GhosttyKittyGraphicsPlacementRenderInfo = std::mem::zeroed();
            info.size = std::mem::size_of::<GhosttyKittyGraphicsPlacementRenderInfo>();
            // A virtual placement has no position, and says so in `info`.
            let _ =
                ghostty_kitty_graphics_placement_render_info(iterator, image, terminal, &mut info);
            Some(Placed {
                image: id,
                generation,
                id: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
                )?,
                is_virtual: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
                )?,
                x_offset: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
                )?,
                y_offset: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,
                )?,
                columns: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS,
                )?,
                rows: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS,
                )?,
                z: get(
                    iterator,
                    GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
                )?,
                info,
            })
        }
    }

    /// Appends the sequence for this placement. One whose top has scrolled away is cropped to what
    /// is left, at the top row; one that has gone altogether adds nothing.
    fn write(&self, out: &mut Vec<u8>, cell_height: u32) {
        let id = self.image;
        let placement = if self.id == 0 {
            String::new()
        } else {
            format!(",p={}", self.id)
        };
        if self.is_virtual {
            let (columns, rows) = (self.columns, self.rows);
            out.extend_from_slice(
                format!(
                    "\x1b_Ga=p,U=1,i={id}{placement},c={columns},r={rows},z={z},q=2\x1b\\",
                    z = self.z
                )
                .as_bytes(),
            );
            return;
        }
        let info = &self.info;
        if !info.viewport_visible || info.grid_rows == 0 {
            return;
        }
        let above = info.viewport_row.min(0).unsigned_abs();
        let rows = info.grid_rows.saturating_sub(above);
        if rows == 0 {
            return;
        }
        // In pixels, not a share of the rows: an image rarely ends on a row's edge.
        let gone =
            (u64::from(above) * u64::from(cell_height)).saturating_sub(u64::from(self.y_offset));
        let drawn = u64::from(info.pixel_height.max(1));
        let cut = (u64::from(info.source_height) * gone / drawn).min(u64::from(info.source_height));
        let cut = cut as u32;
        let (y, h) = (info.source_y + cut, info.source_height - cut);
        // The offset is into a top row that has gone.
        let y_offset = if above == 0 { self.y_offset } else { 0 };
        let (row, column) = (info.viewport_row.max(0) + 1, info.viewport_col.max(0) + 1);
        let (x, w, x_offset, z) = (info.source_x, info.source_width, self.x_offset, self.z);
        // Only the size the program asked for. Grid sizes are rounded up to whole cells, so
        // asking for those would stretch an image drawn at its natural size.
        let mut size = String::new();
        if self.columns > 0 {
            size.push_str(&format!(",c={}", self.columns));
        }
        if self.rows > 0 {
            size.push_str(&format!(",r={}", self.rows.saturating_sub(above)));
        }
        out.extend_from_slice(
            format!(
                "\x1b[{row};{column}H\x1b_Ga=p,i={id}{placement},C=1{size},\
                 x={x},y={y},w={w},h={h},X={x_offset},Y={y_offset},z={z},q=2\x1b\\"
            )
            .as_bytes(),
        );
    }
}

/// A terminal shadowing one session.
pub struct ShadowTerminal {
    inner: GhosttyTerminal,
    /// The callbacks' userdata. A raw allocation rather than a `Box` field: moving a `Box`
    /// asserts unique access to its contents, which the pointer the terminal holds would then
    /// alias. Freed in `Drop`, after the terminal that writes to it.
    effects: *mut Effects,
    /// The primary screen's last paint and the budget it was made for, kept while the alternate
    /// screen is active (`primary_screen`): reaching the primary takes a copy of the terminal, up
    /// to ~100 ms on 50 MB of history that compresses poorly, and a full-screen program's every
    /// redraw is recorded every 2 s. The primary does not change while the program runs, so the
    /// paint is dropped when output switches screens or resets the terminal (`write`) and on a
    /// resize.
    primary_paint: std::cell::RefCell<Option<(usize, Vec<u8>)>>,
    /// One cell's size in pixels, zero until a client says. An image's height in rows comes from
    /// it, so at zero the screen drifts from the client's under every image (#551).
    cell_pixels: (u32, u32),
}

/// The callbacks' userdata.
///
/// # Safety
/// `userdata` must be the one `register_effects` set, and the call must come from inside
/// `ghostty_terminal_vt_write`, which `write(&mut self)` makes, so nothing else holds a reference
/// to it meanwhile.
unsafe fn effects<'a>(userdata: *mut std::ffi::c_void) -> Option<&'a mut Effects> {
    // SAFETY: per this function's contract, a live `Effects` reached by no other reference.
    unsafe { (userdata as *mut Effects).as_mut() }
}

/// A copy of a string libghostty lent for the current callback.
///
/// # Safety
/// `text` must be a string the current callback was passed, so `len` bytes at `ptr` are live.
unsafe fn copied(text: &GhosttyString) -> String {
    if text.ptr.is_null() || text.len == 0 {
        return String::new();
    }
    // SAFETY: per this function's contract, `len` live bytes at a non-null `ptr`.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(text.ptr, text.len) }).into_owned()
}

/// `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT`: keep the last report; REMOVE clears it.
unsafe extern "C" fn on_progress_report(
    _terminal: GhosttyTerminal,
    userdata: *mut std::ffi::c_void,
    report: *const GhosttyTerminalProgressReport,
) {
    let (Some(effects), Some(report)) = (
        // SAFETY: libghostty passes the userdata `register_effects` set, from inside a write.
        unsafe { effects(userdata) },
        // SAFETY: libghostty passes a report that is valid for the duration of the call.
        unsafe { report.as_ref() },
    ) else {
        return;
    };
    let slot = &mut effects.progress;
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

/// `GHOSTTY_TERMINAL_OPT_WRITE_PTY`: keep only the program status probe's answer. A device
/// attributes, cursor or colour query is the attached client's to answer, as it always was; the
/// shadow answering too would put two replies on the pty.
unsafe extern "C" fn on_write_pty(
    _terminal: GhosttyTerminal,
    userdata: *mut std::ffi::c_void,
    data: *const u8,
    len: usize,
) {
    // SAFETY: libghostty passes the userdata `register_effects` set, from inside a write.
    let Some(effects) = (unsafe { effects(userdata) }) else {
        return;
    };
    if data.is_null() {
        return;
    }
    // SAFETY: libghostty passes `len` bytes at `data`, valid for the duration of the call.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    if bytes.starts_with(PROBE_REPLY) {
        effects.replies.extend_from_slice(bytes);
        effects.program.push(Event::Probed);
    }
}

/// `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`: a report or a CLEAR, queued for the store.
unsafe extern "C" fn on_program_status(
    _terminal: GhosttyTerminal,
    userdata: *mut std::ffi::c_void,
    report: *const GhosttyTerminalProgramStatus,
) {
    let (Some(effects), Some(report)) = (
        // SAFETY: libghostty passes the userdata `register_effects` set, from inside a write.
        unsafe { effects(userdata) },
        // SAFETY: libghostty passes a report that is valid for the duration of the call.
        unsafe { report.as_ref() },
    ) else {
        return;
    };
    // A sized struct whose every field has been there since it was introduced, so one too short
    // for `message` is not this struct at all.
    if report.size
        < std::mem::offset_of!(GhosttyTerminalProgramStatus, message)
            + std::mem::size_of::<GhosttyString>()
    {
        return;
    }
    // SAFETY: each string is one this callback was passed.
    let text = |s: &GhosttyString| unsafe { copied(s) };
    let state = match report.state {
        GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_IDLE => State::Idle,
        GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_WORKING => State::Working,
        GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_DONE => State::Done,
        GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED => State::Blocked,
        GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_ERROR => State::Error,
        GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_CLEAR => {
            effects.program.push(Event::Clear(text(&report.id)));
            return;
        }
        // A state a later library added, which no consumer here could show.
        _ => return,
    };
    let kind = match report.kind {
        GhosttyProgramStatusKind_GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION => Kind::Permission,
        GhosttyProgramStatusKind_GHOSTTY_PROGRAM_STATUS_KIND_QUESTION => Kind::Question,
        GhosttyProgramStatusKind_GHOSTTY_PROGRAM_STATUS_KIND_AUTH => Kind::Auth,
        _ => Kind::None,
    };
    effects.program.push(Event::Report(Report {
        id: text(&report.id),
        state,
        kind,
        progress: report.progress,
        app: text(&report.app),
        title: text(&report.title),
        message: text(&report.message),
    }));
}

/// `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`: the title the shell gives the command it is running.
unsafe extern "C" fn on_title_changed(terminal: GhosttyTerminal, userdata: *mut std::ffi::c_void) {
    // SAFETY: libghostty passes the userdata `register_effects` set, from inside a write.
    let Some(effects) = (unsafe { effects(userdata) }) else {
        return;
    };
    let slot = &mut effects.command;
    if slot.started.is_some() && slot.line.is_some() {
        return;
    }
    let mut title = GhosttyString {
        ptr: ptr::null(),
        len: 0,
    };
    // SAFETY: `terminal` is the live terminal this callback runs for, which has already stored
    // the new title, and `title` is a live out-pointer of the type DATA_TITLE writes.
    let rc = unsafe {
        ghostty_terminal_get(
            terminal,
            GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_TITLE,
            (&mut title as *mut GhosttyString).cast(),
        )
    };
    if rc == OK {
        // SAFETY: the title is borrowed until the next mutating call, and this copies it now.
        slot.line = Some(unsafe { copied(&title) });
    }
}

/// `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT`: a new prompt ends the program run that reported, and a
/// command end clears the progress report, as a REMOVE does, and closes the command C started.
unsafe extern "C" fn on_semantic_prompt(
    _terminal: GhosttyTerminal,
    userdata: *mut std::ffi::c_void,
    event: *const GhosttyTerminalSemanticPrompt,
) {
    let (Some(effects), Some(event)) = (
        // SAFETY: libghostty passes the userdata `register_effects` set, from inside a write.
        unsafe { effects(userdata) },
        // SAFETY: libghostty passes an event that is valid for the duration of the call.
        unsafe { event.as_ref() },
    ) else {
        return;
    };
    let has_kind = event.size
        >= std::mem::offset_of!(GhosttyTerminalSemanticPrompt, kind)
            + std::mem::size_of::<GhosttySemanticPromptKind>();
    if !has_kind {
        return;
    }
    match event.kind {
        GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => {
            effects.command = CommandSlot::default();
            effects.program.push(Event::Prompt);
        }
        GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_INPUT_START => {
            effects.command = CommandSlot::default();
        }
        GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => {
            effects.command.started = Some(Instant::now());
        }
        GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => {
            // Only a held report: a fresh one makes the next read ask the pty for its foreground.
            if effects.progress.report.is_some() {
                effects.progress = ProgressSlot {
                    report: None,
                    fresh: true,
                };
            }
            let command = std::mem::take(&mut effects.command);
            let has_exit_code = event.size
                >= std::mem::offset_of!(GhosttyTerminalSemanticPrompt, exit_code)
                    + std::mem::size_of::<i32>();
            if let Some(started) = command.started
                && has_exit_code
                && event.has_exit_code
            {
                effects.program.push(Event::Command {
                    exit_code: event.exit_code,
                    ran: started.elapsed(),
                    line: command.line.unwrap_or_default(),
                });
            }
        }
        _ => {}
    }
}

/// `GHOSTTY_TERMINAL_OPT_RESET`: RIS, after the CLEAR libghostty sends for it.
unsafe extern "C" fn on_reset(_terminal: GhosttyTerminal, userdata: *mut std::ffi::c_void) {
    // SAFETY: libghostty passes the userdata `register_effects` set, from inside a write.
    if let Some(effects) = unsafe { effects(userdata) } {
        effects.program.push(Event::Reset);
        effects.reset = true;
    }
}

// SAFETY: the handle and the callbacks' userdata are owned exclusively, so moving them to another
// thread moves the only way to reach them. libghostty-vt requires the caller to serialise access,
// and it is: `ShadowTerminal` is not `Sync`, so only the thread holding it can call in, and
// `&mut self` orders the writes that run the callbacks.
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
        install_png_decoder();
        let terminal = ShadowTerminal {
            inner,
            effects: Box::into_raw(Box::default()),
            primary_paint: Default::default(),
            cell_pixels: (0, 0),
        };
        terminal.enable_continuation_tracking();
        terminal.limit_scrollback();
        terminal.limit_images();
        terminal.register_effects();
        Some(terminal)
    }

    /// A program reports busy with OSC 9;4 once, at the start of its work, so a client that
    /// attaches later can only learn it from here (#359). It says what it is doing with OSC 7501
    /// only once something answers its probe, and the attached client never does (#358).
    /// Pointer-typed options are passed directly, not by address (`ghostty_terminal_set`'s doc).
    fn register_effects(&self) {
        let callbacks: [(GhosttyTerminalOption, *const std::ffi::c_void); 6] = [
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT,
                on_progress_report as *const std::ffi::c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                on_write_pty as *const std::ffi::c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
                on_program_status as *const std::ffi::c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
                on_semantic_prompt as *const std::ffi::c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_RESET,
                on_reset as *const std::ffi::c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                on_title_changed as *const std::ffi::c_void,
            ),
        ];
        // SAFETY: `inner` is a live terminal. The userdata is `effects`, which `Drop` frees only
        // after the terminal, and each callback matches its option's signature.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_USERDATA,
                self.effects as *const std::ffi::c_void,
            );
            for (option, callback) in callbacks {
                ghostty_terminal_set(self.inner, option, callback);
            }
        }
    }

    /// The last progress report the program sent, or `None` once it cleared it.
    pub fn progress(&self) -> Progress {
        // SAFETY: `effects` is a live allocation until `Drop`, and the callbacks that write it
        // only run inside `write(&mut self)`, never during this `&self` read.
        unsafe { (*self.effects).progress.report }
    }

    /// Whether the held report changed since this was last asked: a report arrived (a REMOVE
    /// included), or a command end (OSC 133 D) cleared one.
    pub fn take_fresh_report(&mut self) -> bool {
        // SAFETY: as in `progress`; `&mut self` also rules out the callbacks running meanwhile.
        unsafe { std::mem::take(&mut (*self.effects).progress.fresh) }
    }

    /// The program status events and the probe replies the writes since the last call produced.
    pub fn take_program_status(&mut self) -> (Vec<Event>, Vec<u8>) {
        // SAFETY: as in `take_fresh_report`.
        let effects = unsafe { &mut *self.effects };
        (
            std::mem::take(&mut effects.program),
            std::mem::take(&mut effects.replies),
        )
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

    /// `IMAGE_STORAGE_LIMIT`. Direct transfers only stays libghostty's default: a temp file or
    /// shared memory is deleted by whoever reads it first, and that must be the app.
    fn limit_images(&self) {
        let limit = IMAGE_STORAGE_LIMIT;
        // SAFETY: `inner` is a live terminal, and the option reads a `uint64_t` before returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                (&raw const limit).cast(),
            );
        }
    }

    /// A byte limit and no line limit, as the app's pane has.
    fn limit_scrollback(&self) {
        let bytes: usize = SCROLLBACK_MAX_BYTES;
        // SAFETY: `inner` is a live terminal. Both options take a `size_t*`: a NULL one removes
        // the line limit (terminal.h), and `bytes` is a live `usize` the call reads before
        // returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                ptr::null(),
            );
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                &bytes as *const usize as *const std::ffi::c_void,
            );
        }
    }

    /// Feed the emulator the same bytes the client is getting.
    ///
    /// The kept primary paint goes when a write leaves the terminal off the alternate screen, and
    /// when one holds a screen switch or a reset at all (`switches_screens`): a program leaving, the
    /// shell clearing and another program starting can all arrive in one read, which ends back on
    /// the alternate screen.
    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: `inner` is a live terminal, and the pointer and length come from one live slice.
        unsafe { ghostty_terminal_vt_write(self.inner, bytes.as_ptr(), bytes.len()) }
        if self.primary_paint.get_mut().is_some()
            && (self.mode(modes::ALT_SCREEN) != Some(true) || switches_screens(bytes))
        {
            *self.primary_paint.get_mut() = None;
        }
    }

    /// `write` for output a transfer is running through. Returns what disturbed the transfer, if
    /// anything did: a program's own string (its image, most likely), a switch of screen, or a
    /// reset. Any of them ends the transfer, since a chunk after a program's image start would land
    /// in its load, and one after a switch in the wrong screen's storage.
    pub fn write_watched(&mut self, bytes: &[u8]) -> Option<Disturbed> {
        let was_alternate = self.mode(modes::ALT_SCREEN);
        // SAFETY: `effects` is live for `self`'s life and nothing else holds it between writes.
        unsafe { (*self.effects).reset = false };
        let mut abort_at = None;
        let mut disturbed = false;
        let (mut rest, trailing_escape) = match bytes.split_last() {
            Some((0x1b, body)) => (body, true),
            _ => (bytes, false),
        };
        let body_length = rest.len();
        loop {
            // SAFETY: all zeroes is valid for this C struct of integers.
            let mut stop: GhosttyTerminalWriteStop = unsafe { std::mem::zeroed() };
            stop.size = std::mem::size_of::<GhosttyTerminalWriteStop>();
            // SAFETY: `inner` is live, the pointer and length come from one live slice, and `stop`
            // is live with its `size` set.
            let rc = unsafe {
                ghostty_terminal_vt_write_until(
                    self.inner,
                    rest.as_ptr(),
                    rest.len(),
                    GhosttyTerminalBoundary_GHOSTTY_TERMINAL_BOUNDARY_APC_START as u32,
                    &mut stop,
                )
            };
            if rc != OK {
                break;
            }
            let end = body_length - rest.len() + stop.consumed;
            disturbed = true;
            // The ESC can be in an earlier read, which has gone: then the stream is not between
            // sequences anywhere in this one before the string starts.
            if abort_at.is_none() {
                abort_at = match stop.introducer {
                    GhosttyTerminalStringIntroducer_GHOSTTY_TERMINAL_STRING_INTRODUCER_C1 => {
                        end.checked_sub(1)
                    }
                    _ => end
                        .checked_sub(2)
                        .filter(|at| bytes.get(*at) == Some(&0x1b)),
                };
            }
            rest = &rest[stop.consumed..];
            if rest.is_empty() {
                break;
            }
        }
        let escape_at_ground = trailing_escape && self.at_ground();
        if trailing_escape {
            // SAFETY: `inner` is a live terminal, and the byte is a live local.
            unsafe { ghostty_terminal_vt_write(self.inner, [0x1bu8].as_ptr(), 1) }
        }
        let switch = screen_switch_at(bytes);
        let switched = switch.is_some() || self.mode(modes::ALT_SCREEN) != was_alternate;
        // SAFETY: as above.
        let reset = unsafe { (*self.effects).reset };
        if self.primary_paint.get_mut().is_some()
            && (self.mode(modes::ALT_SCREEN) != Some(true) || switch.is_some())
        {
            *self.primary_paint.get_mut() = None;
        }
        if disturbed || switched || reset {
            return Some(Disturbed {
                abort_at: [abort_at, switch].into_iter().flatten().min(),
                only_if_loading: false,
            });
        }
        escape_at_ground.then(|| Disturbed {
            abort_at: Some(bytes.len() - 1),
            only_if_loading: true,
        })
    }

    /// Whether the parser is between sequences, where a client's stream can take other bytes. Not
    /// `continuation()`, which is capped: an unfinished 8 KB OSC 52 reports nothing.
    pub fn at_ground(&mut self) -> bool {
        // SAFETY: all zeroes is valid for this C struct of integers.
        let mut stop: GhosttyTerminalWriteStop = unsafe { std::mem::zeroed() };
        stop.size = std::mem::size_of::<GhosttyTerminalWriteStop>();
        // SAFETY: `inner` is live, a NULL pointer is allowed at length zero, and `stop` is live
        // with its `size` set. Asking for ground with no input consumes nothing.
        let rc = unsafe {
            ghostty_terminal_vt_write_until(
                self.inner,
                ptr::null(),
                0,
                GhosttyTerminalBoundary_GHOSTTY_TERMINAL_BOUNDARY_GROUND as u32,
                &mut stop,
            )
        };
        rc == OK
    }

    /// Calls `f` for each placement on the active screen. The storage is borrowed until the next
    /// write, which `&self` rules out here.
    fn each_placement(&self, mut f: impl FnMut(&Placed)) {
        let mut graphics: GhosttyKittyGraphics = ptr::null_mut();
        // SAFETY: DATA_KITTY_GRAPHICS's output type is `GhosttyKittyGraphics *`.
        let rc = unsafe {
            ghostty_terminal_get(
                self.inner,
                GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                (&raw mut graphics).cast(),
            )
        };
        if rc != OK || graphics.is_null() {
            return;
        }
        let mut iterator: GhosttyKittyGraphicsPlacementIterator = ptr::null_mut();
        // SAFETY: a null allocator selects the default one, and `iterator` is a live out-pointer.
        if unsafe { ghostty_kitty_graphics_placement_iterator_new(ptr::null(), &mut iterator) }
            != OK
        {
            return;
        }
        // SAFETY: the data kind's output is the iterator to fill, which is live.
        let filled = unsafe {
            ghostty_kitty_graphics_get(
                graphics,
                GhosttyKittyGraphicsData_GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
                (&raw mut iterator).cast(),
            )
        };
        // SAFETY: `iterator` is live, and is only advanced here.
        while filled == OK && unsafe { ghostty_kitty_graphics_placement_next(iterator) } {
            if let Some(placed) = Placed::read(graphics, iterator, self.inner) {
                f(&placed);
            }
        }
        // SAFETY: `iterator` came from `iterator_new`, and is freed exactly once, here.
        unsafe { ghostty_kitty_graphics_placement_iterator_free(iterator) };
    }

    /// The images a client should be sent: those with a placement on the active screen, in part
    /// or whole, or through Unicode placeholders. Newest first.
    pub fn visible_images(&self) -> Vec<ImageRef> {
        let mut images: Vec<ImageRef> = Vec::new();
        self.each_placement(|placed| {
            if (placed.is_virtual || placed.info.viewport_visible)
                && !images.iter().any(|image| image.id == placed.image)
            {
                images.push(ImageRef {
                    id: placed.image,
                    generation: placed.generation,
                });
            }
        });
        images.sort_by_key(|image| std::cmp::Reverse(image.generation));
        images
    }

    /// A copy of `image`'s pixels, or `None` if a program has replaced or deleted it since.
    pub fn pixels(&self, image: ImageRef) -> Option<Pixels> {
        let mut graphics: GhosttyKittyGraphics = ptr::null_mut();
        // SAFETY: DATA_KITTY_GRAPHICS's output type is `GhosttyKittyGraphics *`.
        let rc = unsafe {
            ghostty_terminal_get(
                self.inner,
                GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                (&raw mut graphics).cast(),
            )
        };
        if rc != OK || graphics.is_null() {
            return None;
        }
        // SAFETY: `graphics` is live until the next write, which `&self` rules out.
        let handle = unsafe { ghostty_kitty_graphics_image(graphics, image.id) };
        if handle.is_null() {
            return None;
        }
        /// # Safety
        /// `T` must be the output type of `data`.
        unsafe fn get<T: Default>(
            image: GhosttyKittyGraphicsImage,
            data: GhosttyKittyGraphicsImageData,
        ) -> Option<T> {
            let mut value = T::default();
            // SAFETY: the caller's contract, and `value` is live.
            let rc =
                unsafe { ghostty_kitty_graphics_image_get(image, data, (&raw mut value).cast()) };
            (rc == OK).then_some(value)
        }
        // SAFETY: each `T` is that data kind's documented output type.
        unsafe {
            let generation: u64 = get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
            )?;
            if generation != image.generation {
                return None;
            }
            let width: u32 = get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
            )?;
            let height: u32 = get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
            )?;
            let format: GhosttyKittyImageFormat = get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
            )?;
            let length: usize = get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
            )?;
            let mut pointer: *const u8 = ptr::null();
            let rc = ghostty_kitty_graphics_image_get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
                (&raw mut pointer).cast(),
            );
            if rc != OK || pointer.is_null() {
                return None;
            }
            let color = match format {
                GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_RGB => png::ColorType::Rgb,
                GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => png::ColorType::Rgba,
                GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => {
                    png::ColorType::Grayscale
                }
                GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => {
                    png::ColorType::GrayscaleAlpha
                }
                _ => return None,
            };
            Some(Pixels {
                width,
                height,
                color,
                // The storage holds `length` bytes at `pointer` until the next write.
                data: std::slice::from_raw_parts(pointer, length).to_vec(),
            })
        }
    }

    /// The bytes that put `image` where its placements are now.
    ///
    /// A plain cursor move there and back, as the repaint restores the cursor, never ESC 7 and
    /// ESC 8: a terminal has one saved cursor, and it is the program's. Live output waits for a
    /// moment that costs nothing (`force` is for a hand-off, whose screen ends in its own CUP): a
    /// CUP clears a pending wrap, so the next character would overwrite the last column, and origin
    /// mode changes what a CUP means.
    pub fn placement(&self, image: u32, force: bool) -> Placement {
        let wrapping = self
            .get_bool(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP)
            .unwrap_or(false);
        if !force && (wrapping || self.mode(modes::ORIGIN) == Some(true)) {
            return Placement::Hold;
        }
        let mut out = Vec::new();
        self.each_placement(|placed| {
            if placed.image == image {
                placed.write(&mut out, self.cell_pixels.1);
            }
        });
        if !out.is_empty() {
            out.extend_from_slice(&self.cursor_position());
        }
        Placement::Ready(out)
    }

    /// The pixels of one cell, applied at the next `resize`. Images use them; the shadow draws
    /// nothing, and a size report is still the client's to answer.
    pub fn set_cell_pixels(&mut self, width: u32, height: u32) {
        self.cell_pixels = (width, height);
    }

    /// A width change reflows, which decompresses the whole history (1.33 to 40 MB measured at 200
    /// to 160 columns), so it is compressed again before this returns rather than at the next
    /// tick. A height change touches no history.
    pub fn resize(&mut self, columns: u16, rows: u16) {
        let width = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS);
        let (cell_width, cell_height) = self.cell_pixels;
        // SAFETY: `inner` is a live terminal, and both dimensions are at least 1, as required.
        unsafe {
            ghostty_terminal_resize(
                self.inner,
                columns.max(1),
                rows.max(1),
                cell_width,
                cell_height,
            );
        }
        *self.primary_paint.get_mut() = None;
        if width != Some(u32::from(columns.max(1))) {
            self.compress();
        }
    }

    /// Compresses the history pages nothing has touched since they were last compressed (#463).
    /// A read (`format`) re-inflates the pages it reads and output writes new ones, so this runs
    /// after them, every screens tick (`SessionStore::compress_shadows`). An already compressed
    /// terminal costs about 0.001 ms. A failure, or a target without support, leaves the history
    /// as it is, which is all that not compressing costs; `compression_supported` is what is
    /// reported, once, at startup.
    pub fn compress(&mut self) {
        loop {
            let mut result: GhosttyTerminalCompressionResult = 0;
            // SAFETY: `inner` is a live terminal, `&mut self` serialises this with every other
            // call into it, and `result` is a live out-pointer.
            let rc = unsafe {
                ghostty_terminal_compress(
                    self.inner,
                    GhosttyTerminalCompressionMode_GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
                    &mut result,
                )
            };
            if rc != OK
                || result
                    != GhosttyTerminalCompressionResult_GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
            {
                return;
            }
        }
    }

    /// The terminal's memory, as libghostty counts it.
    pub fn memory(&self) -> Option<MemoryUsage> {
        // SAFETY: a C struct of integers and a bool, for which all zeroes is a valid value.
        let mut usage: GhosttyTerminalMemoryUsage = unsafe { std::mem::zeroed() };
        // `GHOSTTY_INIT_SIZED` is a macro, which bindgen does not emit.
        usage.size = std::mem::size_of::<GhosttyTerminalMemoryUsage>();
        // SAFETY: DATA_MEMORY_USAGE's output type is `GhosttyTerminalMemoryUsage`, and `usage` is
        // a live one with its `size` set, as the call requires.
        let rc = unsafe {
            ghostty_terminal_get(
                self.inner,
                GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_MEMORY_USAGE,
                (&raw mut usage).cast(),
            )
        };
        (rc == OK).then_some(usage)
    }

    /// The 256 colours of `data`, one of the two `COLOR_PALETTE` kinds.
    fn palette(&self, data: GhosttyTerminalData) -> Option<[[u8; 3]; 256]> {
        let mut colours = [GhosttyColorRgb { r: 0, g: 0, b: 0 }; 256];
        // SAFETY: both palette kinds write a `GhosttyColorRgb[256]`, and `colours` is a live one.
        let rc = unsafe { ghostty_terminal_get(self.inner, data, colours.as_mut_ptr().cast()) };
        (rc == OK).then(|| colours.map(|colour| [colour.r, colour.g, colour.b]))
    }

    /// Whether `compress` can free memory on this target. Where it cannot, each session's history
    /// stays uncompressed, up to `SCROLLBACK_MAX_BYTES`.
    pub fn compression_supported(&self) -> bool {
        self.memory()
            .is_some_and(|usage| usage.compression_supported)
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
    fn get_bool(&self, data: GhosttyTerminalData) -> Option<bool> {
        let mut value = false;
        // SAFETY: the data kinds passed here have `bool *` as their output type.
        let rc = unsafe { ghostty_terminal_get(self.inner, data, (&raw mut value).cast()) };
        (rc == OK).then_some(value)
    }

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

    /// How many bytes `replay` ends with for the parser continuation.
    pub fn continuation_len(&self) -> usize {
        self.continuation().len()
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

    /// A selection from the `rows_back`th history row from the bottom to the active area's last
    /// cell: the screen and the newest `rows_back` history rows. `rows_back` 0 is the screen alone.
    /// None when a point cannot be resolved.
    fn tail_selection(&self, rows_back: u32) -> Option<GhosttySelection> {
        let history = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)?;
        let columns = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS)?;
        let rows = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS)?;
        let point = |tag, x: u32, y: u32| -> Option<GhosttyGridRef> {
            // SAFETY: plain C structs of integers and pointers, for which all zeroes is valid.
            let mut point: GhosttyPoint = unsafe { std::mem::zeroed() };
            point.tag = tag;
            point.value.coordinate = GhosttyPointCoordinate {
                x: u16::try_from(x).ok()?,
                y,
            };
            // SAFETY: as above.
            let mut grid: GhosttyGridRef = unsafe { std::mem::zeroed() };
            grid.size = std::mem::size_of::<GhosttyGridRef>();
            // SAFETY: `inner` is a live terminal and `grid` a live out-pointer with its size set.
            let rc = unsafe { ghostty_terminal_grid_ref(self.inner, point, &mut grid) };
            (rc == OK).then_some(grid)
        };
        Some(GhosttySelection {
            size: std::mem::size_of::<GhosttySelection>(),
            start: point(
                GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN,
                0,
                history - rows_back.min(history),
            )?,
            end: point(
                GhosttyPointTag_GHOSTTY_POINT_TAG_ACTIVE,
                columns.saturating_sub(1),
                rows.saturating_sub(1),
            )?,
            rectangle: false,
        })
    }

    /// `format`, of the screen and the newest `rows_back` history rows when given, or of everything
    /// when not. A selection the terminal cannot resolve gives no bytes, as a failed format does.
    fn format_rows(&self, extras: bool, rows_back: Option<u32>) -> Vec<u8> {
        let selection = match rows_back {
            Some(rows_back) => match self.tail_selection(rows_back) {
                Some(selection) => Some(selection),
                None => return Vec::new(),
            },
            None => None,
        };
        let mut formatter: GhosttyFormatter = ptr::null_mut();
        // SAFETY: the options are a C struct of integers, bools and sized sub-structs, for which
        // all zeroes is a valid value; the fields that matter are set below.
        let mut options: GhosttyFormatterTerminalOptions = unsafe { std::mem::zeroed() };
        options.size = std::mem::size_of::<GhosttyFormatterTerminalOptions>();
        options.emit = GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_VT;
        // `trim` stays false: untrimmed VT output keeps the blank rows at the end of the screen, so
        // a client scrolls as far as the producer did and the next write lands below the last line.
        options.extra.size = std::mem::size_of::<GhosttyFormatterTerminalExtra>();
        if extras {
            options.extra.modes = true;
            options.extra.scrolling_region = true;
            options.extra.tabstops = true;
            options.extra.pwd = true;
            options.extra.keyboard = true;
            options.extra.screen.size = std::mem::size_of::<GhosttyFormatterScreenExtra>();
            options.extra.screen.charsets = true;
        }
        if let Some(selection) = selection.as_ref() {
            options.selection = selection;
        }
        // SAFETY: `inner` is a live terminal that outlives the formatter, which is freed before
        // this method returns; `formatter` is a live out-pointer. The selection, when set, lives
        // until this method returns and was taken with no write since.
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
        if extras && !bytes.is_empty() {
            let mut painted = self.palette_overrides();
            painted.extend_from_slice(&bytes);
            return painted;
        }
        bytes
    }

    /// The colours a program set, for a repaint. Not `extra.palette`, which sends all 256: each is
    /// a message in the app's 64-slot mailbox, so every attach filled it, and a pane freed before
    /// the next tick deadlocked (#547). They also replaced the client's theme with this terminal's
    /// built-in colours. The reset first is for a pane that reconnects and still holds colours the
    /// program has since reset; a fresh pane holds none, so it costs no messages.
    ///
    /// shortcut: a colour set to its built-in value counts as unset, so a client with another theme
    /// shows the theme's. Upgrade if the C API ever exposes the terminal's override mask.
    fn palette_overrides(&self) -> Vec<u8> {
        let (Some(current), Some(default)) = (
            self.palette(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_PALETTE),
            self.palette(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT),
        ) else {
            return Vec::new();
        };
        let mut out = b"\x1b]104\x1b\\".to_vec();
        for (index, ([r, g, b], default)) in current.iter().zip(&default).enumerate() {
            if [*r, *g, *b] != *default {
                let set = format!("\x1b]4;{index};rgb:{r:02x}/{g:02x}/{b:02x}\x1b\\");
                out.extend_from_slice(set.as_bytes());
            }
        }
        out
    }

    /// A byte-for-byte copy of this terminal, via the snapshot format.
    ///
    /// Used to read state the formatter cannot reach on the live terminal without destroying it —
    /// see `primary_screen`. The snapshot carries BOTH screens, which is exactly why it is the way
    /// in: the formatter only ever sees the active one.
    ///
    /// The copy registers no callbacks: it is a scratch read, never replayed.
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
        // The copy's history compressed as it is decoded: uncompressed it is the whole 50 MB the
        // source keeps compressed (measured 49.97 MB against 1.33 MB).
        let compress: bool = true;
        // SAFETY: `decoder` is live and has not started decoding, and a non-pointer option is
        // passed by address: `compress` is a live `bool` (the option's type) read before the call
        // returns.
        unsafe {
            ghostty_snapshot_decoder_set(
                decoder,
                GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY,
                &compress as *const bool as *const std::ffi::c_void,
            );
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
            effects: Box::into_raw(Box::default()),
            primary_paint: Default::default(),
            cell_pixels: self.cell_pixels,
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
    ///
    /// The copy is the only way in and costs a snapshot each time (about 27 ms on 50 MB of
    /// compressed history), so a hand-off past its deadline skips it (`record`).
    ///
    /// The paint is kept (`primary_paint`) with the `budget` it was made for, what the alternate
    /// screen's paint left it, and reused while it fits and the budget has not grown by more than a
    /// quarter: a paint made for more holds at least the history a fresh one for less would, and
    /// the search only fills to 80% anyway, so the program's ordinary redraws reuse it while a
    /// screen that gets much lighter gets a fresh paint with the history that now fits. One made
    /// against a deadline, which may have cut it short, is not kept.
    fn primary_screen(&self, budget: usize, until: Option<Instant>) -> Option<Vec<u8>> {
        if let Some((kept, paint)) = self.primary_paint.borrow().as_ref()
            && paint.len() <= budget
            && budget <= kept.saturating_add(kept / 4)
        {
            return Some(paint.clone());
        }
        let mut copy = self.clone_via_snapshot()?;
        copy.write(b"\x1b[?1049l");
        let mut out = copy.format_tail(budget, until);
        // Each screen has its own kitty flags, so the primary's go before `DECSET 1049` too, or a
        // client gets them back only from the alternate screen's, which are usually clear.
        out.extend_from_slice(&copy.kitty_flags());
        // The primary's cursor, explicitly, for the same reason `replay` emits one: the formatter
        // homes the cursor and leaves it at the end of the paint. Here it matters twice over,
        // because `DECSET 1049` SAVES the cursor as it switches — so without this the position the
        // client restores when the program exits is wherever the paint ended, and the shell's next
        // line is written onto the end of the last history line instead of below it.
        out.extend_from_slice(&copy.cursor_position());
        if until.is_none() {
            *self.primary_paint.borrow_mut() = Some((budget, out.clone()));
        }
        Some(out)
    }

    /// The screen and the newest history rows whose paint fits `budget` bytes.
    ///
    /// **Why a search.** A row's bytes depend on how often its style changes from cell to cell,
    /// not on its length: the same 10,000 lines at 200 columns measured 1.9 MiB plain and 75 MiB
    /// in truecolour. So the only measure of what fits is the formatter's own output. The newest
    /// `TAIL_SAMPLE_ROWS` rows go first, to measure the history's density; a first guess from the
    /// budget alone (`budget / columns` rows) is ~20,000 rows at 200 columns, which on dense
    /// history would format ~160 MB once before being rejected. Each later guess scales the last by
    /// `budget / bytes` at 90%, growing at most `TAIL_GROWTH` times, since the newest rows can be far
    /// sparser than older ones, and the search stops once a paint fits within 80% of the budget:
    /// `TAIL_GUESSES` formats, plus the fitting steps the growth cap held back (up to `log8(history)`
    /// after each counted one, so a few dozen at most for history whose density swings back and
    /// forth, and `until` still bounds the time), then halvings (at most `log2(history) + 1`).
    /// A bisection would take about 12, at up to ~27 ms each for a full 4 MiB tail, with every
    /// session frozen during a hand-off.
    ///
    /// The largest fitting count found is kept. The screen alone (0 rows) is always returned, even
    /// when it does not fit a budget smaller than itself: a caller is sent the screen, never
    /// nothing. Past `until`, no more guesses are made: the best fit so far, or the screen alone,
    /// and a call that starts past it formats the screen alone.
    fn format_tail(&self, budget: usize, until: Option<Instant>) -> Vec<u8> {
        let history = self
            .get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
            .unwrap_or(0);
        let late = || until.is_some_and(|until| Instant::now() >= until);
        let format = |rows: u32| {
            // The whole history is formatted with no selection.
            let bytes = self.format_rows(true, (rows < history).then_some(rows));
            #[cfg(test)]
            ATTEMPTS.with(|attempts| attempts.borrow_mut().push(bytes.len()));
            bytes
        };
        // The next count to try after `rows` rows came to `len` bytes, and whether the growth cap
        // held it back.
        let guess = |rows: u32, len: usize| -> (u32, bool) {
            let scaled = u64::from(rows).saturating_mul(budget as u64) / len.max(1) as u64 / 10 * 9;
            let wanted = u32::try_from(scaled).unwrap_or(u32::MAX).min(history);
            let most = rows.saturating_mul(TAIL_GROWTH);
            (wanted.min(most), wanted > most)
        };

        if late() {
            return format(0);
        }
        let mut best: Option<(u32, Vec<u8>)> = None;
        let mut rows = history.min(TAIL_SAMPLE_ROWS);
        let sample = format(rows);
        let (mut next, mut held_back) = guess(rows, sample.len());
        if sample.len() <= budget {
            if rows == history {
                return sample;
            }
            best = Some((rows, sample));
        }
        let mut guesses = 1;
        while guesses < TAIL_GUESSES {
            if next == rows || late() {
                break;
            }
            rows = next;
            let bytes = format(rows);
            let len = bytes.len();
            // A step the growth cap held back that still fitted was a step towards the answer,
            // not a guess at it, so a long plain history is not cut short by the cap.
            if !(held_back && len <= budget) {
                guesses += 1;
            }
            (next, held_back) = guess(rows, len);
            if len <= budget {
                if best.as_ref().is_none_or(|(kept, _)| rows > *kept) {
                    best = Some((rows, bytes));
                }
                if rows == history || len >= budget / 10 * 8 {
                    break;
                }
            }
        }
        match best {
            Some((_, bytes)) => bytes,
            // Only after every guess overshot, or the time ran out first.
            None => loop {
                rows = if late() { 0 } else { rows / 2 };
                let bytes = format(rows);
                if bytes.len() <= budget || rows == 0 {
                    break bytes;
                }
            },
        }
    }

    /// The active screen's kitty keyboard flags, which the formatter does not emit (module doc), or
    /// nothing when they are clear.
    fn kitty_flags(&self) -> Vec<u8> {
        match self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS) {
            Some(flags) if flags != 0 => format!("\x1b[>{flags}u").into_bytes(),
            _ => Vec::new(),
        }
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
        self.replay_within(true, REPAINT_MAX_BYTES, None)
    }

    /// `replay()` with its record held to `budget` (`record_within`), saying idle unless `report`:
    /// for a program that is gone. The whole replay is at most `budget + REPLAY_OVERHEAD`.
    pub fn replay_within(&self, report: bool, budget: usize, until: Option<Instant>) -> Vec<u8> {
        let mut out = self.record_within(budget, until);
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

    /// `record_within` a repaint's budget.
    #[cfg(test)]
    pub fn record(&self) -> Vec<u8> {
        self.record_within(REPAINT_MAX_BYTES, None)
    }

    /// `replay()` without the progress report or the parser continuation: the record kept on disk
    /// (`crate::screens`), and the start of every replay. A record outlives the program, so a
    /// report in it would only pin the client's spinner on; and nothing will ever complete a
    /// continuation in a record, while the notice written after one would.
    ///
    /// It is at most `budget` bytes, unless the screens alone are larger: the history it carries
    /// is the newest that fits (`format_tail`).
    ///
    /// The parts whose size the history does not change are sized first, and the history gets what
    /// is left: the leading erase, the kitty flags, the cursor and, on the alternate screen, that
    /// screen's paint, which has no history. The output keeps the order a real session produced it in:
    /// primary, `DECSET 1049`, alternate.
    ///
    /// Past `until` (a hand-off out of time) a session sends its screen alone, and on the alternate
    /// screen skips the primary's paint, which costs a copy of the terminal (`primary_screen`).
    pub fn record_within(&self, budget: usize, until: Option<Instant>) -> Vec<u8> {
        const ERASE: &[u8] = b"\x1b[2J\x1b[3J";
        const ALTERNATE: &[u8] = b"\x1b[?1049h";
        // The longest CUP `cursor_position` writes, and the longest `kitty_flags`.
        const CURSOR: usize = b"\x1b[65535;65535H".len();
        const KITTY: usize = b"\x1b[>255u".len();
        let kitty = self.kitty_flags();
        let cursor = self.cursor_position();
        let fixed = ERASE.len() + kitty.len() + cursor.len();
        let late = until.is_some_and(|until| Instant::now() >= until);

        let mut out = if self.mode(modes::ALT_SCREEN) == Some(true) {
            let alternate = self.format_tail(budget.saturating_sub(fixed + ALTERNATE.len()), None);
            let left = budget.saturating_sub(fixed + alternate.len() + ALTERNATE.len());
            // The primary screen first, then re-entering the alt screen, then the alt screen's own
            // paint below — the order a real session produced them in.
            let primary = if late {
                None
            } else {
                self.primary_screen(left.saturating_sub(CURSOR + KITTY), until)
            };
            // The switch whether or not the primary was painted. The formatter's mode extras set
            // it again within the paint (measured), but the screen switch is what separates the
            // two paints, so it is written here rather than left to them.
            let mut out = primary.unwrap_or_default();
            out.extend_from_slice(ALTERNATE);
            out.extend_from_slice(&alternate);
            out
        } else {
            self.format_tail(budget.saturating_sub(fixed), until)
        };
        out.extend_from_slice(&kitty);
        out.extend_from_slice(&cursor);
        if out.is_empty() {
            // Nothing could be read, which callers tell from an empty record.
            return out;
        }
        // Ahead of it all, a blank screen and no scrollback: the paint erases nothing, and a
        // client rarely starts blank — the app's panes run under macOS `login`, which prints its
        // `Last login` banner first. Erasing the screen before the scrollback matters: Ghostty's
        // ED 2 pushes the screen into the scrollback when its last rows are a shell prompt.
        [ERASE, &out].concat()
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
        // SAFETY: `effects` came from `Box::into_raw` and is freed exactly once, here, after the
        // terminal that held a copy of it is gone.
        drop(unsafe { Box::from_raw(self.effects) });
    }
}

/// Whether `bytes` hold a reset (`ESC c`) or a DECSET/DECRST of an alternate screen mode (47, 1047
/// or 1049), as any parameter of a `CSI ?` sequence. Only escape sequences count: a pid or a size in
/// a program's output is not a switch. A sequence cut across two writes is not seen; the leave half
/// of a switch is still caught, as a write that ends off the alternate screen.
fn switches_screens(bytes: &[u8]) -> bool {
    screen_switch_at(bytes).is_some()
}

/// Where in `bytes` the first screen switch or reset starts, which is `switches_screens`' answer.
fn screen_switch_at(bytes: &[u8]) -> Option<usize> {
    let mut rest = bytes;
    while let Some(at) = rest.iter().position(|byte| *byte == 0x1b) {
        let start = bytes.len() - rest.len() + at;
        rest = &rest[at + 1..];
        if rest.first() == Some(&b'c') {
            return Some(start);
        }
        if let Some(params) = rest.strip_prefix(b"[?") {
            let end = params
                .iter()
                .position(|byte| !(byte.is_ascii_digit() || *byte == b';'))
                .unwrap_or(params.len());
            if matches!(params.get(end), Some(b'h' | b'l'))
                && params[..end]
                    .split(|byte| *byte == b';')
                    .any(|param| matches!(param, b"47" | b"1047" | b"1049"))
            {
                return Some(start);
            }
        }
    }
    None
}

/// Modes worth naming, for tests and for anything that needs to reason about what survived.
pub mod modes {
    use super::{GhosttyMode, mode_new};
    #[cfg(test)]
    pub const APP_CURSOR_KEYS: GhosttyMode = mode_new(1, false);
    #[cfg(test)]
    pub const MOUSE_BUTTON: GhosttyMode = mode_new(1002, false);
    #[cfg(test)]
    pub const MOUSE_SGR: GhosttyMode = mode_new(1006, false);
    #[cfg(test)]
    pub const FOCUS_EVENTS: GhosttyMode = mode_new(1004, false);
    #[cfg(test)]
    pub const BRACKETED_PASTE: GhosttyMode = mode_new(2004, false);
    pub const ALT_SCREEN: GhosttyMode = mode_new(1049, false);
    pub const ORIGIN: GhosttyMode = mode_new(6, false);
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

    fn colour_sets(bytes: &[u8]) -> usize {
        bytes.windows(3).filter(|bytes| *bytes == b"]4;").count()
    }

    fn colours(terminal: &ShadowTerminal) -> [[u8; 3]; 256] {
        terminal
            .palette(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)
            .expect("palette")
    }

    /// Each colour set is one message in the app's 64-slot mailbox. 256 of them fill it, and a
    /// pane freed before the next tick then deadlocks (#547).
    ///
    /// Value: protects=an attach sends no colours nobody set; fails_when=the formatter's palette
    /// comes back; why_new=the formatter sent all 256 unnoticed; seam=none; no_claim=the deadlock
    /// itself (needs a real surface)
    #[test]
    fn a_default_palette_repaints_no_colours() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"hello\r\n");
        assert_eq!(colour_sets(&producer.replay()), 0);
    }

    /// Value: protects=a program's colours survive a reattach; fails_when=overrides are dropped or
    /// the whole palette is sent; why_new=only a default palette was covered; seam=none;
    /// no_claim=none beyond protects
    #[test]
    fn only_the_colours_a_program_set_are_repainted() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"\x1b]4;1;rgb:12/34/56\x1b\\\x1b]4;200;rgb:ab/cd/ef\x1b\\hello");
        let replay = producer.replay();
        assert_eq!(colour_sets(&replay), 2);

        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&replay);
        assert_eq!(colours(&client)[1], [0x12, 0x34, 0x56]);
        assert_eq!(colours(&client), colours(&producer));
    }

    /// A pane that reconnects keeps its surface, so it still holds what the program set before.
    ///
    /// Value: protects=a colour the program reset while detached does not linger; fails_when=the
    /// repaint stops resetting; why_new=sending every colour used to cover this; seam=none;
    /// no_claim=none beyond protects
    #[test]
    fn a_repaint_clears_colours_the_session_no_longer_has() {
        let producer = ShadowTerminal::new(80, 24).expect("producer");
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(b"\x1b]4;1;rgb:12/34/56\x1b\\");
        assert_ne!(colours(&client), colours(&producer));

        client.write(&producer.replay());
        assert_eq!(colours(&client), colours(&producer));
    }

    /// Value: protects=a reattached pane keeps the app's theme; fails_when=a repaint sends colours
    /// nobody set; why_new=a client with the same default palette cannot show this; seam=none;
    /// no_claim=the app's own theme handling (a shadow terminal stands in for the client)
    #[test]
    fn a_repaint_keeps_the_clients_theme() {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"hello\r\n");
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        let theme = [GhosttyColorRgb { r: 1, g: 2, b: 3 }; 256];
        // SAFETY: COLOR_PALETTE reads a `GhosttyColorRgb[256]`, and `theme` is a live one.
        let rc = unsafe {
            ghostty_terminal_set(
                client.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
                theme.as_ptr().cast(),
            )
        };
        assert_eq!(rc, OK);

        client.write(&producer.replay());
        assert_eq!(colours(&client)[1], [1, 2, 3]);
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
        naive.write(&producer.format_rows(false, None));

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

        // Exactly the producer's depth. This was once asserted as "within one row", but a missing
        // row is not a rounding difference: it is a dropped line of output on the next write, so
        // the bound is an equality and the old one must not come back.
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

    fn history_rows(terminal: &ShadowTerminal) -> u32 {
        terminal
            .get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
            .unwrap_or(0)
    }

    /// The sizes of the formats `format_tail` ran on this thread since the last call.
    fn attempts() -> Vec<usize> {
        ATTEMPTS.with(|attempts| std::mem::take(&mut *attempts.borrow_mut()))
    }

    /// `line {n}` and then plain cells to the pane's width.
    fn plain_line(columns: u16, n: usize) -> String {
        format!("line {n:<6} {}\r\n", "x".repeat(usize::from(columns) - 13))
    }

    /// `line {n}` and then cells alternating between two of the 16 colours.
    fn sixteen_colour_line(columns: u16, n: usize) -> String {
        let cells: String = (13..columns)
            .map(|c| format!("\x1b[3{}mx", 1 + c % 2))
            .collect();
        format!("\x1b[mline {n:<6} {cells}\x1b[m\r\n")
    }

    /// `line {n}` and then cells alternating between two truecolour styles: the densest history,
    /// 75 MiB for 10,000 lines at 200 columns.
    fn truecolour_line(columns: u16, n: usize) -> String {
        let cells: String = (13..columns)
            .map(|c| {
                if c % 2 == 0 {
                    "\x1b[38;2;255;128;0mx"
                } else {
                    "\x1b[38;2;0;128;255mx"
                }
            })
            .collect();
        format!("\x1b[mline {n:<6} {cells}\x1b[m\r\n")
    }

    /// What the app's own pane keeps, the shadow keeps (#462): libghostty's 10 KB default kept
    /// about one page, #469's 4 MiB cap 5,450 rows at 80 columns, and its line cap 10,000.
    ///
    /// Value: protects=the shadow keeps the app's 50 MB of history with no line cap; fails_when=the
    /// byte cap shrinks or a line cap comes back; why_new=the 10 KB default was never tested;
    /// seam=none
    #[test]
    fn the_shadow_keeps_what_the_app_keeps() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        for n in 0..60_000 {
            terminal.write(format!("line {n}\r\n").as_bytes());
        }
        let rows = history_rows(&terminal);
        assert!(rows > 20_000, "{rows} history rows kept of 60,000 lines");
        // And a repaint carries all of it: 60,000 short lines paint in well under the budget, so
        // the search must reach the whole history however many steps that takes.
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&terminal.replay());
        assert_eq!(history_rows(&client), rows, "the repaint left history out");
    }

    /// A record's size follows how densely its history is styled, not how much of it there is, and
    /// one over `MAX_RECORD` is deleted: a pane would come back from a host restart with nothing.
    /// So a record carries the newest history that fits, on the primary screen and under a
    /// full-screen program.
    ///
    /// Value: protects=record() and replay() stay within their budgets whatever the history;
    /// fails_when=format_tail is bypassed or the fixed parts are not sized first; why_new=#469's
    /// test passed at the 10 KB default; seam=none
    #[test]
    fn a_densely_styled_history_is_cut_to_fit() {
        let columns = 200;
        let mut producer = ShadowTerminal::new(columns, 24).expect("producer");
        for n in 0..3_000 {
            producer.write(truecolour_line(columns, n).as_bytes());
        }
        for alternate in [false, true] {
            if alternate {
                producer.write(b"\x1b[?1049h\x1b[H");
                for n in 0..23 {
                    producer.write(truecolour_line(columns, n).as_bytes());
                }
            }
            let record = producer.record();
            assert!(
                record.len() <= REPAINT_MAX_BYTES,
                "alternate {alternate}: a {} byte record, over {REPAINT_MAX_BYTES}",
                record.len()
            );
            assert!(
                producer.replay().len() < crate::screens::MAX_RECORD,
                "alternate {alternate}: the replay is over MAX_RECORD"
            );
            let mut client = ShadowTerminal::new(columns, 24).expect("client");
            client.write(&record);
            if alternate {
                client.write(b"\x1b[?1049l");
            }
            let rows = history_rows(&client);
            assert!(
                rows > 100,
                "alternate {alternate}: {rows} history rows sent"
            );
            assert!(
                client.visible_text().contains("line 2999"),
                "alternate {alternate}: the newest line is missing"
            );
        }
    }

    /// A kept primary paint made while the program's own screen was dense, and so left little of
    /// the budget, is made again once that screen gets lighter: the record then carries the shell
    /// history that now fits, not the old paint's share.
    ///
    /// Value: protects=the kept paint is reused only for a budget it was made for; fails_when=the
    /// paint is keyed by the record's budget rather than what the alternate screen left it;
    /// why_new=the other cache tests keep the program's screen the same size; seam=none
    #[test]
    fn a_lighter_program_screen_lets_the_primary_carry_more_history() {
        let budget = 256 << 10;
        let mut terminal = ShadowTerminal::new(200, 24).expect("terminal");
        for n in 0..20_000 {
            terminal.write(plain_line(200, n).as_bytes());
        }
        terminal.write(b"\x1b[?1049h\x1b[H");
        for n in 0..23 {
            terminal.write(truecolour_line(200, n).as_bytes());
        }
        let primary_rows = |record: &[u8]| {
            let mut client = ShadowTerminal::new(200, 24).expect("client");
            client.write(record);
            client.write(b"\x1b[?1049l");
            history_rows(&client)
        };
        let dense = primary_rows(&terminal.record_within(budget, None));
        terminal.write(b"\x1b[2J\x1b[Hhelp");
        let light = primary_rows(&terminal.record_within(budget, None));
        assert!(
            light > dense * 3 / 2,
            "the primary kept {dense} rows under a dense screen and {light} under a light one"
        );
    }

    /// Under a full-screen program the primary's paint is made once and kept, since reaching it
    /// takes a copy of the terminal; it is made again once the program has left the alternate
    /// screen, so a second program shows what the shell printed in between.
    ///
    /// Value: protects=the primary paint is reused while a program runs and never outlives it;
    /// fails_when=the paint is never kept (a copy every record) or kept past the program;
    /// why_new=the primary was always copied; seam=none
    #[test]
    fn the_primary_paint_is_kept_only_while_a_program_runs() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        for n in 0..100 {
            terminal.write(format!("line {n}\r\n").as_bytes());
        }
        terminal.write(b"\x1b[?1049h\x1b[Hfirst program");
        let first = terminal.record();
        attempts();
        // A switch's digits in the program's own output (a pid, a size) are not a switch.
        terminal.write(b"\x1b[Hfirst program, redrawn, pid 1049 size 1047 ?47");
        let redrawn = terminal.record();
        assert_eq!(
            attempts().len(),
            1,
            "the primary was painted again while the program ran"
        );
        assert!(String::from_utf8_lossy(&redrawn).contains("redrawn"));
        assert_ne!(first, redrawn);

        terminal.write(b"\x1b[?1049lprinted between\r\n");
        terminal.write(b"\x1b[?1049h\x1b[Hsecond program");
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&terminal.record());
        client.write(b"\x1b[?1049l");
        assert!(
            client.visible_text().contains("printed between"),
            "the second program was shown the first's primary"
        );
    }

    /// The same when the first program leaving, the shell clearing and the second program starting
    /// all arrive in one read (`vim; clear; vim` in a script), and when a program resets the
    /// terminal: the kept paint never shows a primary the shell has since cleared.
    ///
    /// Value: protects=a cleared or reset shell is never repainted from the kept primary paint;
    /// fails_when=the paint is dropped only when a write ends off the alternate screen;
    /// why_new=the other test splits the switch across writes; seam=none
    #[test]
    fn a_screen_switch_within_one_write_drops_the_kept_paint() {
        for switch in [
            b"\x1b[?1049l\x1b[2J\x1b[3J\x1b[Hcleared\r\n\x1b[?1049h\x1b[Hsecond".as_slice(),
            b"\x1bc\x1b[?1049h\x1b[Hsecond",
            b"\x1b[?25;1049l\x1b[2J\x1b[3J\x1b[Hcleared\r\n\x1b[?1;1049h\x1b[Hsecond",
        ] {
            let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
            for n in 0..100 {
                terminal.write(format!("secret {n}\r\n").as_bytes());
            }
            terminal.write(b"\x1b[?1049h\x1b[Hfirst program");
            terminal.record();
            terminal.write(switch);
            let mut client = ShadowTerminal::new(80, 24).expect("client");
            client.write(&terminal.record());
            client.write(b"\x1b[?1049l");
            assert!(
                !client.visible_text().contains("secret"),
                "{:?}: a cleared primary was repainted from the kept paint",
                String::from_utf8_lossy(switch)
            );
        }
    }

    /// The row guesses grow at most `TAIL_GROWTH` times a step, so a plain tail over much denser
    /// history (prompts after a truecolour dump) never formats most of the history at once.
    ///
    /// Value: protects=no single format approaches the whole history's paint; fails_when=a guess
    /// may jump from the sample straight to the whole history; why_new=the bounds test has uniform
    /// density, where the sample predicts the rest; seam=none
    #[test]
    fn a_sparse_tail_over_dense_history_does_not_format_it_all() {
        let mut terminal = ShadowTerminal::new(200, 24).expect("terminal");
        for n in 0..6_000 {
            terminal.write(truecolour_line(200, n).as_bytes());
        }
        for n in 0..200 {
            terminal.write(format!("$ ls {n}\r\n").as_bytes());
        }
        let whole = terminal.format_rows(true, None).len();
        attempts();
        let tail = terminal.format_tail(1 << 20, None);
        let sizes = attempts();
        assert!(tail.len() <= 1 << 20, "{} bytes", tail.len());
        assert!(
            sizes.iter().all(|size| *size < whole / 8),
            "a format approached the whole history ({whole} bytes): {sizes:?}"
        );
    }

    /// A screen larger than its budget is still sent, alone: a client gets the screen, never
    /// nothing. Many sessions sharing a hand-off can each have a share smaller than a dense screen.
    ///
    /// Value: protects=format_tail always returns the screen; fails_when=an over-budget screen
    /// yields no bytes or keeps history; why_new=no budget was smaller than a screen; seam=none
    #[test]
    fn a_screen_larger_than_its_budget_is_sent_alone() {
        let mut producer = ShadowTerminal::new(200, 24).expect("producer");
        for n in 0..300 {
            producer.write(truecolour_line(200, n).as_bytes());
        }
        let mut client = ShadowTerminal::new(200, 24).expect("client");
        client.write(&producer.record_within(1 << 10, None));
        assert_eq!(history_rows(&client), 0, "history sent over the budget");
        assert!(
            client.visible_text().contains("line 299"),
            "the screen was not sent"
        );
    }

    /// A record made past its deadline (a hand-off out of time) is the screen alone, and under a
    /// full-screen program still switches to the alternate screen, so the program's exit brings
    /// the client back to its primary rather than leaving the program's screen there.
    ///
    /// Value: protects=a late record carries no history and keeps the screen switch;
    /// fails_when=the switch is written only with the primary's paint, or a late call still
    /// formats history; why_new=a record never skipped the primary before; seam=none
    #[test]
    fn a_record_past_its_deadline_is_the_screen_alone() {
        for alternate in [false, true] {
            let mut producer = ShadowTerminal::new(80, 24).expect("producer");
            for n in 0..200 {
                producer.write(format!("line {n}\r\n").as_bytes());
            }
            if alternate {
                producer.write(b"\x1b[?1049h\x1b[Hprogram");
            }
            let mut client = ShadowTerminal::new(80, 24).expect("client");
            client.write(&producer.record_within(REPAINT_MAX_BYTES, Some(Instant::now())));
            assert_eq!(
                history_rows(&client),
                0,
                "alternate {alternate}: history sent past the deadline"
            );
            assert_eq!(
                client.mode(modes::ALT_SCREEN),
                Some(alternate),
                "alternate {alternate}: the screen switch was lost"
            );
            if alternate {
                client.write(b"\x1b[?1049l");
                assert!(
                    !client.visible_text().contains("program"),
                    "the program's screen stayed after it left"
                );
            }
        }
    }

    /// The cut fixtures: modes set before the history, so they are older than any cut, then
    /// `lines` of history, some wide and soft-wrapped, so a cut can land inside a wrapped line.
    fn cut_fixture(lines: usize) -> ShadowTerminal {
        let mut producer = ShadowTerminal::new(80, 24).expect("producer");
        producer.write(b"\x1b[?2004h\x1b[>5u");
        for n in 0..lines {
            if n % 7 == 0 {
                producer.write(format!("wide {n} {}\r\n", "漢字".repeat(30)).as_bytes());
            } else {
                producer.write(format!("line {n}\r\n").as_bytes());
            }
        }
        producer
    }

    /// A client fed a cut record holds the newest part of the producer's terminal, rows and modes,
    /// and the next output lands where the producer's does. A cut can start inside a soft-wrapped
    /// line, whose first row then arrives as a line of its own, which is still the end of the
    /// producer's line.
    fn assert_lands(producer: &mut ShadowTerminal, client: &mut ShadowTerminal, label: &str) {
        let (want, got) = (producer.visible_text(), client.visible_text());
        assert!(
            want.ends_with(&got),
            "{label}: the client is not the end of the producer: {:?}",
            &got[..got.len().min(200)]
        );
        producer.write(b"after the cut\r\n");
        client.write(b"after the cut\r\n");
        assert!(
            producer.visible_text().ends_with(&client.visible_text()),
            "{label}: the next line landed elsewhere"
        );
        assert_eq!(
            client.mode(modes::BRACKETED_PASTE),
            Some(true),
            "{label}: bracketed paste did not survive the cut"
        );
        assert_eq!(
            client.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS),
            Some(5),
            "{label}: the kitty flags did not survive the cut"
        );
    }

    /// Value: protects=a cut record's client holds the newest rows, its modes and the producer's
    /// cursor row, at every cut point; fails_when=the paint drops the blank rows at the end of
    /// the screen, or modes are cut with the history; why_new=no record was ever cut; seam=none
    #[test]
    fn a_cut_history_lands_where_the_producer_has_it() {
        // Budgets from tiny to the whole, so cuts land on plain rows, wide rows and wrapped rows.
        for budget in [8 << 10, 20 << 10, 33 << 10, 64 << 10, 100 << 10] {
            let mut producer = cut_fixture(5_000);
            let mut client = ShadowTerminal::new(80, 24).expect("client");
            client.write(&producer.record_within(budget, None));
            let rows = history_rows(&client);
            assert!(
                rows > 0 && rows < history_rows(&producer),
                "budget {budget}: the fixture was not cut ({rows} rows)"
            );
            assert_lands(&mut producer, &mut client, &format!("budget {budget}"));
        }
    }

    /// The same under a full-screen program: the primary's paint is cut on its own,
    /// so quitting the program brings back the shell's newest history and its cursor row.
    ///
    /// Value: protects=the primary's cut paint under the alternate screen; fails_when=the primary's
    /// paint drops its blank rows or the alternate screen's budget is not taken first; why_new=the
    /// primary was always painted whole; seam=none
    #[test]
    fn quitting_a_program_after_a_cut_brings_back_the_shell() {
        let mut producer = cut_fixture(5_000);
        producer.write(b"\x1b[?1049h\x1b[H");
        producer.write("~\r\n".repeat(23).as_bytes());
        let mut client = ShadowTerminal::new(80, 24).expect("client");
        client.write(&producer.record_within(32 << 10, None));
        assert_eq!(client.mode(modes::ALT_SCREEN), Some(true));
        producer.write(b"\x1b[?1049l");
        client.write(b"\x1b[?1049l");
        let rows = history_rows(&client);
        assert!(
            rows > 0 && rows < history_rows(&producer),
            "the primary was not cut ({rows} rows)"
        );
        assert_lands(&mut producer, &mut client, "after the program");
    }

    /// The search's bounds, across widths and densities: within the budget unless it sent the
    /// screen alone, never more history than there is, no more formats than its bound, and every
    /// format after the sample near the budget, never a large overshoot.
    ///
    /// Value: protects=format_tail's bounds; fails_when=the seed goes back to budget / columns
    /// (which formats ~10 MB here for a 256 KiB budget) or the halvings run away; why_new=no
    /// search existed; seam=none
    #[test]
    fn the_tail_search_keeps_its_bounds() {
        let budget = 256 << 10;
        type Line = fn(u16, usize) -> String;
        let densities: [(&str, Line); 3] = [
            ("plain", plain_line),
            ("16-colour", sixteen_colour_line),
            ("truecolour", truecolour_line),
        ];
        for columns in [80u16, 200, 400] {
            for (density, line) in densities {
                let label = format!("{density} at {columns} columns");
                let mut terminal = ShadowTerminal::new(columns, 24).expect("terminal");
                for n in 0..2_000 {
                    terminal.write(line(columns, n).as_bytes());
                }
                attempts();
                let tail = terminal.format_tail(budget, None);
                let sizes = attempts();
                let history = history_rows(&terminal);
                let mut client = ShadowTerminal::new(columns, 24).expect("client");
                client.write(&tail);
                let sent = history_rows(&client);
                assert!(sent <= history, "{label}");
                assert!(
                    tail.len() <= budget || sent == 0,
                    "{label}: {} bytes",
                    tail.len()
                );
                let bits = u32::BITS - history.leading_zeros();
                let bound = TAIL_GUESSES + bits / 3 + 1 + bits + 1;
                assert!(
                    sizes.len() as u32 <= bound,
                    "{label}: {} formats, bound {bound}",
                    sizes.len()
                );
                assert_eq!(
                    sizes.first().copied(),
                    Some(terminal.format_rows(true, Some(TAIL_SAMPLE_ROWS)).len()),
                    "{label}: the first format is not the sample: {sizes:?}"
                );
                assert!(
                    sizes.iter().skip(1).all(|size| *size <= 2 * budget),
                    "{label}: a format overshot: {sizes:?}"
                );
            }
        }
    }

    /// A paint that fits within 80% of the budget is scaled up once more. Fixed-length rows make
    /// the landing deterministic: the sample (the newest rows, with the screen) comes to more bytes
    /// a row than the history behind it, so the first guess comes in at about three fifths of the
    /// budget.
    ///
    /// Value: protects=the 80% stop; fails_when=the search stops at a lower fill; why_new=no
    /// search existed; seam=none
    #[test]
    fn the_tail_search_fills_its_budget() {
        let mut terminal = ShadowTerminal::new(200, 24).expect("terminal");
        for _ in 0..20_000 {
            terminal.write(format!("{}\r\n", "y".repeat(199)).as_bytes());
        }
        for _ in 0..200 {
            terminal.write(format!("{}\r\n", "x".repeat(139)).as_bytes());
        }
        let budget = 1 << 20;
        attempts();
        let tail = terminal.format_tail(budget, None);
        let sizes = attempts();
        assert!(
            sizes
                .iter()
                .any(|size| (budget / 2..budget / 10 * 8).contains(size)),
            "fixture: no format landed between 50% and 80% of the budget: {sizes:?}"
        );
        assert!(
            (budget / 10 * 8..=budget).contains(&tail.len()),
            "the search stopped at {} of {budget} bytes: {sizes:?}",
            tail.len()
        );
    }

    /// Several pages of history, with wide characters, a combining mark and OSC 8 links, so a page
    /// compressed and read back has every kind of cell content.
    fn compression_fixture() -> ShadowTerminal {
        let mut terminal = ShadowTerminal::new(200, 50).expect("terminal");
        for n in 0..20_000 {
            terminal.write(
                format!(
                    "line {n} 漢字 e\u{301} \x1b]8;;https://example.com/{n}\x1b\\link\x1b]8;;\x1b\\ {}\r\n",
                    "z".repeat(100)
                )
                .as_bytes(),
            );
        }
        terminal
    }

    /// Compressing frees memory and changes nothing a client is shown: the same replay, with a
    /// continuation left open, and the same record under a full-screen program. A read inflates
    /// what it reads, and the next compress undoes it (#463).
    ///
    /// Value: protects=compress() frees history memory losslessly, and runs where the daemon
    /// ships; fails_when=compress is not called, loses cell content, or the target cannot
    /// compress; why_new=nothing compressed before; seam=none
    #[test]
    fn compressing_changes_nothing_a_client_is_shown() {
        let mut terminal = compression_fixture();
        terminal.write(b"\x1b[31mpartly \x1b[3");
        let full = terminal.memory().expect("memory");
        assert!(
            full.compression_supported,
            "this target cannot compress: each session would keep its history uncompressed"
        );
        let before = terminal.replay();
        terminal.compress();
        let compressed = terminal.memory().expect("memory");
        assert!(
            compressed.primary_compressed_pages > 0,
            "nothing compressed"
        );
        assert!(
            compressed.primary_resident_bytes * 2 < full.primary_resident_bytes,
            "{} bytes resident after compressing {}",
            compressed.primary_resident_bytes,
            full.primary_resident_bytes
        );
        assert_eq!(terminal.replay(), before, "compressing changed the replay");
        let read = terminal.memory().expect("memory");
        assert!(
            read.primary_resident_bytes > compressed.primary_resident_bytes,
            "a read inflated nothing"
        );
        terminal.compress();
        assert!(
            terminal.memory().expect("memory").primary_resident_bytes < read.primary_resident_bytes,
            "the next compress did not undo the read"
        );

        terminal.write(b"m\x1b[?1049h\x1b[Hvim");
        let before = terminal.record();
        terminal.compress();
        assert_eq!(
            terminal.record(),
            before,
            "compressing changed the alternate screen's record"
        );
    }

    /// A width change reflows, which inflates the whole history, so `resize` compresses it again
    /// before it returns rather than leaving it to the next tick.
    ///
    /// Value: protects=a resize leaves the history compressed; fails_when=resize stops compressing
    /// on a width change; why_new=resizing never touched memory before; seam=none
    #[test]
    fn a_width_change_leaves_the_history_compressed() {
        let mut terminal = compression_fixture();
        let full = terminal.memory().expect("memory").primary_resident_bytes;
        terminal.compress();
        terminal.resize(160, 50);
        let after = terminal.memory().expect("memory");
        assert!(after.primary_compressed_pages > 0, "nothing compressed");
        assert!(
            after.primary_resident_bytes * 2 < full,
            "{} bytes resident after the resize, {full} uncompressed",
            after.primary_resident_bytes
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
    /// This is the case that finds a paint ending short of the producer's last row: every split
    /// from the moment the session first scrolled, which is every realistic mid-stream attach,
    /// would drop a line.
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
    /// Worth its own case because the paint keeps every blank row and the alternate screen has no
    /// scrollback: one newline too many would scroll a TUI's screen out from under it. Measured: it
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

    /// Not a test: prints the numbers ADR 0051 quotes, so they can be measured again after an
    /// engine bump. Run it in release:
    /// `WORKROOMD_HAS_TERMINAL_STATE=1 cargo test --manifest-path vcs/Cargo.toml -p workroomd
    /// --features terminal-state --release --lib measure_shadow_history -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, run by hand in release"]
    fn measure_shadow_history() {
        fn mib(bytes: u64) -> f64 {
            bytes as f64 / f64::from(1 << 20)
        }
        let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
        let mut random_line = move || -> String {
            const ALPHABET: &[u8] =
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            (0..199)
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    char::from(ALPHABET[(seed % 64) as usize])
                })
                .collect::<String>()
                + "\r\n"
        };
        // The fixtures: 200 by 50, history up to the 50 MB the shadow keeps.
        let moderate = |n: usize| {
            format!(
                "\x1b[3{}mline {n}\x1b[0m {}\r\n",
                n % 8,
                "x".repeat(n % 120)
            )
        };
        type Fixture<'a> = (&'a str, Box<dyn FnMut(usize) -> String + 'a>);
        let fixtures: [Fixture; 3] = [
            ("moderate (16 colours, short lines)", Box::new(moderate)),
            (
                "dense (truecolour alternating per cell)",
                Box::new(|n| truecolour_line(200, n)),
            ),
            ("high-entropy (random base64)", Box::new(|_| random_line())),
        ];
        for (name, mut line) in fixtures {
            let mut terminal = ShadowTerminal::new(200, 50).expect("terminal");
            for n in 0..150_000 {
                terminal.write(line(n).as_bytes());
            }
            let full = terminal.memory().expect("memory");
            println!(
                "\n{name}: {} history rows, {:.2} MiB resident",
                history_rows(&terminal),
                mib(full.primary_resident_bytes)
            );

            let started = Instant::now();
            let fresh = terminal.clone_via_snapshot().expect("clone");
            println!(
                "  clone of the uncompressed history: {:?}, copy {:.2} MiB resident",
                started.elapsed(),
                mib(fresh.memory().expect("memory").primary_resident_bytes)
            );
            drop(fresh);

            let started = Instant::now();
            terminal.compress();
            println!(
                "  compress: {:?}, {:.2} MiB resident",
                started.elapsed(),
                mib(terminal.memory().expect("memory").primary_resident_bytes)
            );

            for (budget_name, budget) in [
                ("repaint", REPAINT_MAX_BYTES),
                ("record", RECORD_MAX_BYTES),
                ("hand-off share of 16", (16 << 20) / 16),
            ] {
                attempts();
                let started = Instant::now();
                let record = terminal.record_within(budget, None);
                let took = started.elapsed();
                let sizes = attempts();
                let mut client = ShadowTerminal::new(200, 50).expect("client");
                client.write(&record);
                println!(
                    "  {budget_name} ({:.2} MiB): {:.2} MiB, {} rows, {took:?} (the shadow-lock \
                     hold), formats {:?}, peak format {:.2} MiB, {:.2} MiB resident after",
                    mib(budget as u64),
                    mib(record.len() as u64),
                    history_rows(&client),
                    sizes,
                    mib(sizes.iter().copied().max().unwrap_or(0) as u64),
                    mib(terminal.memory().expect("memory").primary_resident_bytes)
                );
                terminal.compress();
            }

            terminal.write(b"\x1b[?1049h\x1b[H");
            for n in 0..49 {
                terminal.write(truecolour_line(200, n).as_bytes());
            }
            terminal.compress();
            let started = Instant::now();
            let copy = terminal.clone_via_snapshot().expect("clone");
            println!(
                "  alternate screen: clone {:?} (compressed source), copy {:.2} MiB resident",
                started.elapsed(),
                mib(copy.memory().expect("memory").primary_resident_bytes)
            );
            let started = Instant::now();
            let record = terminal.record();
            println!(
                "  alternate screen: record {:.2} MiB in {:?}",
                mib(record.len() as u64),
                started.elapsed()
            );
        }
    }

    /// The command ends one write produced, as (exit code, command line).
    fn commands(bytes: &[u8]) -> Vec<(i32, String)> {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        terminal.write(bytes);
        let (events, _) = terminal.take_program_status();
        events
            .into_iter()
            .filter_map(|event| match event {
                Event::Command {
                    exit_code, line, ..
                } => Some((exit_code, line)),
                _ => None,
            })
            .collect()
    }

    /// zsh's integration with the title feature, byte for byte: the title is set to the directory
    /// before the prompt, and to the command just after C.
    const ZSH: &[u8] = b"\x1b]2;~/app\x07\x1b]133;A;cl=line\x07$ \x1b]133;B\x07\
        \x1b]133;C\x07\x1b]2;npm test\x07FAIL\r\n\x1b]133;D;1\x07\x1b]2;~/app\x07";
    /// bash's: the prompt sets the directory as title after B, and preexec sets the command just
    /// before C. Its next prompt sends `D` with the last status again, empty Enter or not.
    const BASH: &[u8] = b"\x1b]133;A;redraw=last;cl=line;aid=9\x07\x1b]133;P;k=i\x07$ \
        \x1b]133;B\x07\x1b[5 q\x1b]2;~/app\x07\x1b]2;npm test\x07\x1b]133;C;\x07FAIL\r\n\
        \x1b]133;D;1;aid=9\x07\x1b]133;A;redraw=last;cl=line;aid=9\x07\x1b]133;P;k=i\x07$ \
        \x1b]133;B\x07\x1b]2;~/app\x07\r\n\x1b]133;D;1;aid=9\x07";

    /// Value: protects=a command end becomes a result only after its own C, named by the title the shell gave it (#473); fails_when=a D with no C counts (bash repeats its status every prompt), or the line is the directory or a program's title; why_new=the pairing and the title timing differ per shell and nothing else pins them; seam=none
    #[test]
    fn a_command_end_closes_only_a_command_the_shell_started() {
        assert_eq!(commands(ZSH), [(1, "npm test".to_string())]);
        assert_eq!(
            commands(BASH),
            [(1, "npm test".to_string())],
            "one, not two"
        );
        let program_titles = [
            (
                ZSH,
                "\x1b]2;npm test\x07",
                "\x1b]2;npm test\x07\x1b]2;vim\x07",
            ),
            (BASH, "\x1b]133;C;\x07", "\x1b]133;C;\x07\x1b]2;vim\x07"),
        ];
        for (shell, mark, renamed) in program_titles {
            let bytes = String::from_utf8_lossy(shell).replacen(mark, renamed, 1);
            assert_eq!(
                commands(bytes.as_bytes())[0].1,
                "npm test",
                "a program's own title"
            );
        }
        let untitled = b"\x1b]133;A\x07$ \x1b]133;B\x07\x1b]133;C\x07ok\r\n\x1b]133;D;0\x07";
        assert_eq!(commands(untitled), [(0, String::new())], "no title feature");
        assert_eq!(
            commands(b"\x1b]133;C\x07\x1b]133;D\x07"),
            [],
            "a D with no exit code"
        );
        assert_eq!(commands(b"\x1b]133;D;0\x07"), [], "a D with no C");
    }

    /// A terminal whose cells are 10x20 pixels, as a client's are.
    fn sized_terminal(columns: u16, rows: u16) -> ShadowTerminal {
        let mut terminal = ShadowTerminal::new(columns, rows).expect("terminal");
        terminal.set_cell_pixels(10, 20);
        terminal.resize(columns, rows);
        terminal
    }

    /// Black RGB pixels sent as a raw image.
    fn raw_image(id: u32, width: u32, height: u32) -> Vec<u8> {
        let mut out = format!("\x1b_Ga=T,f=24,s={width},v={height},i={id},q=2;").into_bytes();
        out.extend(std::iter::repeat_n(b'A', (width * height * 4) as usize));
        out.extend_from_slice(b"\x1b\\");
        out
    }

    fn png_bytes(width: u32, height: u32) -> Vec<u8> {
        Pixels {
            width,
            height,
            color: png::ColorType::Rgb,
            data: vec![0; (width * height * 3) as usize],
        }
        .to_png()
        .expect("png")
    }

    fn sent_as_png(id: u32, width: u32, height: u32) -> Vec<u8> {
        let mut out = format!("\x1b_Ga=T,f=100,i={id},q=2;").into_bytes();
        out.extend_from_slice(crate::file::base64(&png_bytes(width, height)).as_bytes());
        out.extend_from_slice(b"\x1b\\");
        out
    }

    fn image_bytes(terminal: &ShadowTerminal) -> u64 {
        terminal.memory().expect("memory").primary_image_bytes
    }

    fn has(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|window| window == needle)
    }

    fn ready(placement: Placement) -> Vec<u8> {
        match placement {
            Placement::Ready(bytes) => bytes,
            Placement::Hold => panic!("held"),
        }
    }

    /// Value: protects=what `kitten icat` sends reaches the shadow (#551); fails_when=the PNG
    /// decoder is not installed; why_new=no test stored an image; seam=none; no_claim=a real
    /// program's PNG, which the app check covers
    #[test]
    fn a_png_is_stored_decoded() {
        let mut terminal = sized_terminal(80, 24);
        terminal.write(&sent_as_png(7, 3, 2));
        assert_eq!(image_bytes(&terminal), 3 * 2 * 4);
    }

    /// Value: protects=a full-size Retina screenshot can come back; fails_when=the limit is left
    /// at libghostty's 10 MB; why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn a_retina_sized_image_fits_the_limit() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        // 2880x1800 RGBA in chunks: the size that libghostty's default limit refuses.
        let bytes = 2880 * 1800 * 4 / 3 * 4;
        let chunk = 1 << 16;
        let mut sent = 0;
        while sent < bytes {
            let length = chunk.min(bytes - sent);
            sent += length;
            let more = u8::from(sent < bytes);
            let head = if sent == length {
                "a=T,f=32,s=2880,v=1800,i=7,"
            } else {
                ""
            };
            let mut out = format!("\x1b_G{head}q=2,m={more};").into_bytes();
            out.extend(std::iter::repeat_n(b'A', length));
            out.extend_from_slice(b"\x1b\\");
            terminal.write(&out);
        }
        assert_eq!(image_bytes(&terminal), 2880 * 1800 * 4);
    }

    /// Value: protects=a small file cannot make the daemon hold an image past the limit;
    /// fails_when=the size check goes; why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn a_valid_png_over_the_limit_is_refused() {
        let over = png_bytes(4000, 2048);
        assert!(over.len() < 1 << 20, "a few bytes of file: {}", over.len());
        assert!(decode_png_rgba(&over).is_none());
        assert!(decode_png_rgba(&png_bytes(3, 2)).is_some(), "fixture");
    }

    /// Value: protects=image data is only inserted between sequences; fails_when=at_ground reads
    /// continuation(); why_new=the 8 KB case is past continuation's cap; seam=none;
    /// no_claim=none beyond protects
    #[test]
    fn ground_is_false_inside_any_unfinished_sequence() {
        let mut long = b"\x1b]52;c;".to_vec();
        long.extend(std::iter::repeat_n(b'A', 8192));
        let cases: [(&[u8], bool); 6] = [
            (b"plain", true),
            (b"\x1b[31m", true),
            (b"\x1b[3", false),
            (b"\xe2\x82", false),
            (b"\x1b", false),
            (&long, false),
        ];
        for (bytes, ground) in cases {
            let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
            terminal.write(bytes);
            assert_eq!(
                terminal.at_ground(),
                ground,
                "{:?}",
                &bytes[..bytes.len().min(8)]
            );
        }
    }

    /// The regression contract for ADR 0010: output renders the same with image data going in
    /// wherever `at_ground` allows, at every place a read could end.
    ///
    /// Value: protects=program output is never corrupted by a transfer (#551); fails_when=a chunk
    /// goes in mid-sequence; why_new=new; seam=none; no_claim=real Ghostty, which the shadow's
    /// engine stands in for at the same revision
    #[test]
    fn output_renders_the_same_at_every_split_with_chunks_at_ground() {
        const STREAM: &[u8] =
            b"plain \x1b[31mred\x1b[0m caf\xc3\xa9 \xe2\x82\xac \x1b]0;title\x07 end\r\nnext";
        const CHUNK: &[u8] = b"\x1b_Ga=t,f=24,s=2,v=1,i=7,q=2,m=1;AAAA\x1b\\";
        let mut control = ShadowTerminal::new(80, 24).expect("control");
        control.write(STREAM);
        let expected = (control.visible_text(), control.replay());
        let mut injected = 0;
        for split in 1..STREAM.len() {
            let (first, second) = STREAM.split_at(split);
            let mut producer = ShadowTerminal::new(80, 24).expect("producer");
            let mut client = ShadowTerminal::new(80, 24).expect("client");
            producer.write(first);
            client.write(first);
            if producer.at_ground() {
                client.write(CHUNK);
                injected += 1;
            }
            producer.write(second);
            client.write(second);
            assert_eq!(client.visible_text(), expected.0, "split at {split}");
            assert_eq!(client.replay(), expected.1, "split at {split}");
        }
        assert!(
            injected > 10,
            "the fixture must exercise injection: {injected}"
        );
    }

    /// Value: protects=a transfer stops for a program's image, and an abort goes ahead of it;
    /// fails_when=write_watched misses the APC or its offset; why_new=new; seam=none;
    /// no_claim=the reader's use of it, which session.rs covers
    #[test]
    fn a_program_image_disturbs_a_transfer_at_its_start() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        assert_eq!(terminal.write_watched(b"hello"), None);
        let disturbed = terminal.write_watched(b"ab\x1b_Ga=T,s=1,v=1,f=24;AAAA\x1b\\");
        assert_eq!(disturbed.map(|d| d.abort_at), Some(Some(2)));
    }

    /// Value: protects=a load is closed before a string that starts across two reads, the last
    /// chance there is; fails_when=the trailing ESC is not seen; why_new=the offset test has the
    /// ESC in the same read; seam=none; no_claim=the reader's use of it, which session.rs covers
    #[test]
    fn a_read_ending_on_an_escape_warns_an_open_load() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        let disturbed = terminal.write_watched(b"ab\x1b").expect("warned");
        assert_eq!(disturbed.abort_at, Some(2));
        assert!(disturbed.only_if_loading);
        assert!(!terminal.at_ground(), "the ESC is in the parser");
        let disturbed = terminal.write_watched(b"_Ga=T,s=1,v=1,f=24;AAAA\x1b\\");
        assert_eq!(disturbed.map(|d| d.abort_at), Some(None));
    }

    /// Value: protects=the abort still lands ahead of a program's string when the read also ends
    /// on an ESC; fails_when=the offset counts that held-back byte; why_new=found in review, the
    /// other tests have one or the other; seam=none; no_claim=none beyond protects
    #[test]
    fn an_abort_lands_ahead_of_a_string_in_a_read_ending_on_an_escape() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        let disturbed = terminal.write_watched(b"ab\x1b_Ga=T,s=1,v=1,f=24;AAAA\x1b");
        assert_eq!(disturbed.map(|d| d.abort_at), Some(Some(2)));
    }

    /// A string's own terminator is not at ground, and an abort there would land inside it.
    #[test]
    fn an_escape_ending_a_string_warns_nothing() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        assert_eq!(terminal.write_watched(b"\x1b]0;title\x1b"), None);
    }

    /// Value: protects=a transfer does not outlive the screen it was for; fails_when=the switch or
    /// reset is not seen; why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn a_screen_switch_or_a_reset_disturbs_a_transfer() {
        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        let disturbed = terminal.write_watched(b"ab\x1b[?1049h");
        assert_eq!(disturbed.map(|d| d.abort_at), Some(Some(2)));

        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        assert!(terminal.write_watched(b"\x1bc").is_some());

        let mut terminal = ShadowTerminal::new(80, 24).expect("terminal");
        assert_eq!(terminal.write_watched(b"\x1b[?10"), None);
        assert!(
            terminal.write_watched(b"49h").is_some(),
            "a switch cut across reads is still seen"
        );
    }

    /// Value: protects=only what is on screen is sent; fails_when=visible_images ignores the
    /// viewport; why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn only_images_on_the_active_screen_are_visible() {
        let mut terminal = sized_terminal(80, 10);
        assert_eq!(terminal.visible_images(), []);
        terminal.write(&raw_image(7, 20, 40));
        let images = terminal.visible_images();
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].id, 7);

        terminal.write(b"\x1b[?1049h");
        assert_eq!(
            terminal.visible_images(),
            [],
            "behind a full-screen program"
        );
        terminal.write(b"\x1b[?1049l");
        terminal.write(&b"\r\n".repeat(20));
        assert_eq!(terminal.visible_images(), [], "scrolled off");
    }

    /// Value: protects=a replaced image is not sent; fails_when=the generation is ignored;
    /// why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn pixels_are_refused_once_a_program_has_replaced_the_image() {
        let mut terminal = sized_terminal(80, 24);
        terminal.write(&raw_image(7, 2, 2));
        let image = terminal.visible_images()[0];
        assert!(terminal.pixels(image).is_some());
        terminal.write(&raw_image(7, 2, 2));
        assert!(terminal.pixels(image).is_none());
    }

    /// Value: protects=a restored image lands where it was, cursor unmoved; fails_when=the
    /// sequence changes shape; why_new=new; seam=none; no_claim=the app's drawing
    #[test]
    fn a_placement_goes_to_its_cell_and_back() {
        let mut producer = sized_terminal(80, 24);
        producer.write(b"\r\n\r\n");
        producer.write(&raw_image(7, 20, 40));
        producer.write(b"\r\nBELOW");
        let image = producer.visible_images()[0];
        let png = producer
            .pixels(image)
            .and_then(|p| p.to_png())
            .expect("png");

        let mut client = sized_terminal(80, 24);
        client.write(&producer.replay());
        client.write(&crate::images::transmit_bytes(7, &png));
        client.write(&ready(producer.placement(7, false)));
        assert_eq!(client.visible_images().len(), 1);
        assert_eq!(
            ready(client.placement(7, false)),
            ready(producer.placement(7, false)),
            "the same cell, cursor and size"
        );
        client.write(b"X");
        producer.write(b"X");
        assert_eq!(client.visible_text(), producer.visible_text());
    }

    /// Value: protects=the program's saved cursor; fails_when=placement uses ESC 7 or ESC 8;
    /// why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn a_placement_leaves_the_saved_cursor_alone() {
        let mut terminal = sized_terminal(80, 24);
        terminal.write(&raw_image(7, 20, 40));
        let bytes = ready(terminal.placement(7, false));
        assert!(
            !has(&bytes, b"\x1b7") && !has(&bytes, b"\x1b8"),
            "{bytes:?}"
        );
    }

    /// Value: protects=the top of a tall image scrolling away crops it, as agreed for #551;
    /// fails_when=the crop arithmetic changes; why_new=new; seam=none; no_claim=the app's crop,
    /// checked by hand on 2026-10-31
    #[test]
    fn an_image_partly_above_the_top_is_cropped_to_what_is_left() {
        let mut terminal = sized_terminal(80, 10);
        // 5 rows tall from the top row: its cursor ends on the last of them.
        terminal.write(&raw_image(7, 20, 100));
        // Seven more lines take the cursor to the bottom and two rows off the top.
        terminal.write(&b"\r\n".repeat(7));
        let text = String::from_utf8_lossy(&ready(terminal.placement(7, false))).into_owned();
        assert!(text.starts_with("\x1b[1;1H\x1b_Ga=p,i=7,"), "{text:?}");
        assert!(!text.contains(",r="), "it had no size of its own: {text:?}");
        assert!(text.contains("x=0,y=40,w=20,h=60"), "{text:?}");

        // 90 pixels ends part-way through its fifth row, and two rows are still 40 pixels.
        let mut terminal = sized_terminal(80, 10);
        terminal.write(&raw_image(7, 20, 90));
        terminal.write(&b"\r\n".repeat(7));
        let text = String::from_utf8_lossy(&ready(terminal.placement(7, false))).into_owned();
        assert!(text.contains("x=0,y=40,w=20,h=50"), "{text:?}");

        // An offset of 10 into the first row: two rows gone hide 30 of its pixels, not 40.
        let mut terminal = sized_terminal(80, 10);
        let mut image = b"\x1b_Ga=T,f=24,s=20,v=100,i=7,Y=10,q=2;".to_vec();
        image.extend(std::iter::repeat_n(b'A', 20 * 100 * 4));
        image.extend_from_slice(b"\x1b\\");
        terminal.write(&image);
        terminal.write(&b"\r\n".repeat(6));
        let text = String::from_utf8_lossy(&ready(terminal.placement(7, false))).into_owned();
        assert!(text.contains("x=0,y=30,w=20,h=70"), "{text:?}");
    }

    /// Value: protects=a restored image keeps its size: natural stays natural, and an asked-for
    /// size stays, less what is cropped; fails_when=the grid size is sent; why_new=seen in the app,
    /// 1% stretched; seam=none; no_claim=the app's drawing
    #[test]
    fn a_placement_keeps_the_size_the_program_asked_for() {
        let mut terminal = sized_terminal(80, 10);
        let mut image = b"\x1b_Ga=T,f=24,s=20,v=100,i=7,c=4,r=5,q=2;".to_vec();
        image.extend(std::iter::repeat_n(b'A', 20 * 100 * 4));
        image.extend_from_slice(b"\x1b\\");
        terminal.write(&image);
        let text = String::from_utf8_lossy(&ready(terminal.placement(7, false))).into_owned();
        assert!(text.contains("C=1,c=4,r=5,"), "{text:?}");

        terminal.write(&b"\r\n".repeat(7));
        let text = String::from_utf8_lossy(&ready(terminal.placement(7, false))).into_owned();
        assert!(text.contains("C=1,c=4,r=3,"), "{text:?}");
    }

    #[test]
    fn a_placement_scrolled_away_adds_nothing() {
        let mut terminal = sized_terminal(80, 10);
        terminal.write(&raw_image(7, 20, 40));
        terminal.write(&b"\r\n".repeat(20));
        assert_eq!(ready(terminal.placement(7, false)), b"");
    }

    /// Value: protects=a character at the last column still wraps, and CUP means what it says;
    /// fails_when=placement stops holding; why_new=new; seam=none; no_claim=none beyond protects
    #[test]
    fn a_placement_waits_out_a_pending_wrap_and_origin_mode() {
        let mut terminal = sized_terminal(20, 10);
        terminal.write(&raw_image(7, 20, 40));
        terminal.write(b"\r\n");
        terminal.write(&[b'x'; 20]);
        assert_eq!(terminal.placement(7, false), Placement::Hold);
        assert!(matches!(terminal.placement(7, true), Placement::Ready(_)));
        terminal.write(b"y");
        assert!(matches!(terminal.placement(7, false), Placement::Ready(_)));

        terminal.write(b"\x1b[?6h");
        assert_eq!(terminal.placement(7, false), Placement::Hold);
    }

    /// Value: protects=images drawn through placeholders come back; fails_when=virtual placements
    /// are dropped; why_new=new; seam=none; no_claim=the placeholder cells, which are text
    #[test]
    fn a_virtual_placement_comes_back_without_moving_the_cursor() {
        let mut terminal = sized_terminal(80, 24);
        let mut image = b"\x1b_Ga=T,f=24,s=2,v=2,i=7,U=1,c=4,r=2,q=2;".to_vec();
        image.extend(std::iter::repeat_n(b'A', 16));
        image.extend_from_slice(b"\x1b\\");
        terminal.write(&image);
        assert_eq!(terminal.visible_images().len(), 1);
        let text = String::from_utf8_lossy(&ready(terminal.placement(7, false))).into_owned();
        assert!(text.contains("a=p,U=1,i=7"), "{text:?}");
        assert!(text.contains("c=4,r=2,z=0"), "{text:?}");
    }
}
