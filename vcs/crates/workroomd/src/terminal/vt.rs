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
//! nothing. The reports themselves go to `crate::terminal::program_status`, which keeps them.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]

use std::time::Instant;

use ghostty_vt::sys::*;
use ghostty_vt::{Callbacks, Extras, Placed, Point, ProgramStatus, Selection, Terminal, Title};

use crate::terminal::images::{ImageRef, Placement};
use crate::terminal::program_status::{Event, Kind, Report, State};

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
pub(crate) const REPAINT_MAX_BYTES: usize = crate::terminal::screens::MAX_RECORD - (64 << 10);

/// What a screen kept on disk is held to (`Shadow::record`, `crate::terminal::screens`). Smaller
/// than a repaint: a busy session's record is rewritten and synced every 2 s, and only a pane
/// coming back after its host restarted reads it. 1 MiB is about 1,700 rows of coloured history at
/// 200 columns, and about 11,000 plain.
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
/// claim any dimensions it likes in a few bytes. The process's PNG decoder
/// (`ghostty_vt::set_png_decoder`): without one the shadow rejects every PNG, which is what
/// `kitten icat` sends.
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
/// `crate::terminal::program_status::Store`, outside the terminal.
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

/// What the terminal's callbacks keep, and which of their reports matter here.
impl Callbacks for Effects {
    /// Keep the last report; REMOVE clears it.
    fn progress_report(&mut self, state: GhosttyTerminalProgressState, percent: i8) {
        let slot = &mut self.progress;
        slot.report = (state
            != GhosttyTerminalProgressState_GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE)
            .then_some((state, percent));
        slot.fresh = true;
    }

    /// Keep only the program status probe's answer. A device attributes, cursor or colour query is
    /// the attached client's to answer, as it always was; the shadow answering too would put two
    /// replies on the pty.
    fn write_pty(&mut self, bytes: &[u8]) {
        if bytes.starts_with(PROBE_REPLY) {
            self.replies.extend_from_slice(bytes);
            self.program.push(Event::Probed);
        }
    }

    /// A report or a CLEAR, queued for the store.
    fn program_status(&mut self, report: ProgramStatus<'_>) {
        let state = match report.state() {
            GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_IDLE => State::Idle,
            GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_WORKING => State::Working,
            GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_DONE => State::Done,
            GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED => State::Blocked,
            GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_ERROR => State::Error,
            GhosttyProgramStatusState_GHOSTTY_PROGRAM_STATUS_STATE_CLEAR => {
                self.program.push(Event::Clear(report.id()));
                return;
            }
            // A state a later library added, which no consumer here could show.
            _ => return,
        };
        let kind = match report.kind() {
            GhosttyProgramStatusKind_GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION => Kind::Permission,
            GhosttyProgramStatusKind_GHOSTTY_PROGRAM_STATUS_KIND_QUESTION => Kind::Question,
            GhosttyProgramStatusKind_GHOSTTY_PROGRAM_STATUS_KIND_AUTH => Kind::Auth,
            _ => Kind::None,
        };
        self.program.push(Event::Report(Report {
            id: report.id(),
            state,
            kind,
            progress: report.progress(),
            app: report.app(),
            title: report.title(),
            message: report.message(),
        }));
    }

    /// The title the shell gives the command it is running.
    fn title_changed(&mut self, title: Title<'_>) {
        let slot = &mut self.command;
        if slot.started.is_some() && slot.line.is_some() {
            return;
        }
        if let Some(line) = title.read() {
            slot.line = Some(line);
        }
    }

    /// A new prompt ends the program run that reported, and a command end clears the progress
    /// report, as a REMOVE does, and closes the command C started.
    fn semantic_prompt(&mut self, kind: GhosttySemanticPromptKind, exit_code: Option<i32>) {
        match kind {
            GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => {
                self.command = CommandSlot::default();
                self.program.push(Event::Prompt);
            }
            GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_INPUT_START => {
                self.command = CommandSlot::default();
            }
            GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => {
                self.command.started = Some(Instant::now());
            }
            GhosttySemanticPromptKind_GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => {
                // Only a held report: a fresh one makes the next read ask the pty for its foreground.
                if self.progress.report.is_some() {
                    self.progress = ProgressSlot {
                        report: None,
                        fresh: true,
                    };
                }
                let command = std::mem::take(&mut self.command);
                if let Some(started) = command.started
                    && let Some(exit_code) = exit_code
                {
                    self.program.push(Event::Command {
                        exit_code,
                        ran: started.elapsed(),
                        line: command.line.unwrap_or_default(),
                    });
                }
            }
            _ => {}
        }
    }

    /// RIS, after the CLEAR libghostty sends for it.
    fn reset(&mut self) {
        self.program.push(Event::Reset);
        self.reset = true;
    }
}

/// Appends the sequence for this placement. One whose top has scrolled away is cropped to what is
/// left, at the top row; one that has gone altogether adds nothing.
fn write_placement(placed: &Placed, out: &mut Vec<u8>, cell_height: u32) {
    let id = placed.image;
    let placement = if placed.id == 0 {
        String::new()
    } else {
        format!(",p={}", placed.id)
    };
    if placed.is_virtual {
        let (columns, rows) = (placed.columns, placed.rows);
        out.extend_from_slice(
            format!(
                "\x1b_Ga=p,U=1,i={id}{placement},c={columns},r={rows},z={z},q=2\x1b\\",
                z = placed.z
            )
            .as_bytes(),
        );
        return;
    }
    let info = &placed.info;
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
        (u64::from(above) * u64::from(cell_height)).saturating_sub(u64::from(placed.y_offset));
    let drawn = u64::from(info.pixel_height.max(1));
    let cut = (u64::from(info.source_height) * gone / drawn).min(u64::from(info.source_height));
    let cut = cut as u32;
    let (y, h) = (info.source_y + cut, info.source_height - cut);
    // The offset is into a top row that has gone.
    let y_offset = if above == 0 { placed.y_offset } else { 0 };
    let (row, column) = (info.viewport_row.max(0) + 1, info.viewport_col.max(0) + 1);
    let (x, w, x_offset, z) = (info.source_x, info.source_width, placed.x_offset, placed.z);
    // Only the size the program asked for. Grid sizes are rounded up to whole cells, so
    // asking for those would stretch an image drawn at its natural size.
    let mut size = String::new();
    if placed.columns > 0 {
        size.push_str(&format!(",c={}", placed.columns));
    }
    if placed.rows > 0 {
        size.push_str(&format!(",r={}", placed.rows.saturating_sub(above)));
    }
    out.extend_from_slice(
        format!(
            "\x1b[{row};{column}H\x1b_Ga=p,i={id}{placement},C=1{size},\
             x={x},y={y},w={w},h={h},X={x_offset},Y={y_offset},z={z},q=2\x1b\\"
        )
        .as_bytes(),
    );
}

/// A terminal shadowing one session.
pub struct ShadowTerminal {
    /// The emulator, reporting to the `Effects` its callbacks write.
    terminal: Terminal<Effects>,
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

impl ShadowTerminal {
    /// A program reports busy with OSC 9;4 once, at the start of its work, so a client that
    /// attaches later can only learn it from here (#359). It says what it is doing with OSC 7501
    /// only once something answers its probe, and the attached client never does (#358). Both
    /// reach the `Effects` the terminal's callbacks write.
    pub fn new(columns: u16, rows: u16) -> Option<ShadowTerminal> {
        let terminal = Terminal::new(columns, rows, Effects::default())?;
        ghostty_vt::set_png_decoder(decode_png_rgba);
        let mut terminal = ShadowTerminal {
            terminal,
            primary_paint: Default::default(),
            cell_pixels: (0, 0),
        };
        terminal.enable_continuation_tracking();
        terminal.limit_scrollback();
        terminal.limit_images();
        Some(terminal)
    }

    /// The last progress report the program sent, or `None` once it cleared it.
    pub fn progress(&self) -> Progress {
        self.terminal.callbacks().progress.report
    }

    /// Whether the held report changed since this was last asked: a report arrived (a REMOVE
    /// included), or a command end (OSC 133 D) cleared one.
    pub fn take_fresh_report(&mut self) -> bool {
        std::mem::take(&mut self.terminal.callbacks_mut().progress.fresh)
    }

    /// The program status events and the probe replies the writes since the last call produced.
    pub fn take_program_status(&mut self) -> (Vec<Event>, Vec<u8>) {
        let effects = self.terminal.callbacks_mut();
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

    fn enable_continuation_tracking(&mut self) {
        self.terminal
            .set_continuation_max_bytes(CONTINUATION_MAX_BYTES);
    }

    /// `IMAGE_STORAGE_LIMIT`. Direct transfers only stays libghostty's default: a temp file or
    /// shared memory is deleted by whoever reads it first, and that must be the app.
    fn limit_images(&mut self) {
        self.terminal
            .set_kitty_image_storage_limit(IMAGE_STORAGE_LIMIT);
    }

    /// A byte limit and no line limit, as the app's pane has.
    fn limit_scrollback(&mut self) {
        self.terminal.set_scrollback_max_lines(None);
        self.terminal.set_scrollback_max_bytes(SCROLLBACK_MAX_BYTES);
    }

    /// Feed the emulator the same bytes the client is getting.
    ///
    /// The kept primary paint goes when a write leaves the terminal off the alternate screen, and
    /// when one holds a screen switch or a reset at all (`switches_screens`): a program leaving, the
    /// shell clearing and another program starting can all arrive in one read, which ends back on
    /// the alternate screen.
    pub fn write(&mut self, bytes: &[u8]) {
        self.terminal.write(bytes);
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
        self.terminal.callbacks_mut().reset = false;
        let mut abort_at = None;
        let mut disturbed = false;
        let (mut rest, trailing_escape) = match bytes.split_last() {
            Some((0x1b, body)) => (body, true),
            _ => (bytes, false),
        };
        let body_length = rest.len();
        while let Some(stop) = self.terminal.write_until(
            rest,
            GhosttyTerminalBoundary_GHOSTTY_TERMINAL_BOUNDARY_APC_START,
        ) {
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
            self.terminal.write(&[0x1b]);
        }
        let switch = screen_switch_at(bytes);
        let switched = switch.is_some() || self.mode(modes::ALT_SCREEN) != was_alternate;
        let reset = self.terminal.callbacks().reset;
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
        // Asking for ground with no input consumes nothing.
        self.terminal
            .write_until(
                &[],
                GhosttyTerminalBoundary_GHOSTTY_TERMINAL_BOUNDARY_GROUND,
            )
            .is_some()
    }

    /// The images a client should be sent: those with a placement on the active screen, in part
    /// or whole, or through Unicode placeholders. Newest first.
    pub fn visible_images(&self) -> Vec<ImageRef> {
        let mut images: Vec<ImageRef> = Vec::new();
        self.terminal.each_placement(|placed| {
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
        let pixels = self.terminal.image_pixels(image.id, image.generation)?;
        let color = match pixels.format {
            GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_RGB => png::ColorType::Rgb,
            GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => png::ColorType::Rgba,
            GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => png::ColorType::Grayscale,
            GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => {
                png::ColorType::GrayscaleAlpha
            }
            _ => return None,
        };
        Some(Pixels {
            width: pixels.width,
            height: pixels.height,
            color,
            data: pixels.data,
        })
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
        self.terminal.each_placement(|placed| {
            if placed.image == image {
                write_placement(placed, &mut out, self.cell_pixels.1);
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
        self.terminal.resize(columns, rows, cell_width, cell_height);
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
        self.terminal.compress();
    }

    /// The terminal's memory, as libghostty counts it.
    pub fn memory(&self) -> Option<MemoryUsage> {
        self.terminal.memory()
    }

    /// The 256 colours of `data`, one of the two `COLOR_PALETTE` kinds.
    fn palette(&self, data: GhosttyTerminalData) -> Option<[[u8; 3]; 256]> {
        self.terminal.palette(data)
    }

    /// Whether `compress` can free memory on this target. Where it cannot, each session's history
    /// stays uncompressed, up to `SCROLLBACK_MAX_BYTES`.
    pub fn compression_supported(&self) -> bool {
        self.memory()
            .is_some_and(|usage| usage.compression_supported)
    }

    fn get_bool(&self, data: GhosttyTerminalData) -> Option<bool> {
        self.terminal.get_bool(data)
    }

    /// A count or position, widened to `u32` (`ghostty_vt::Terminal::get_u32`). A kind with no
    /// known width is refused.
    fn get_u32(&self, data: GhosttyTerminalData) -> Option<u32> {
        self.terminal.get_u32(data)
    }

    pub fn mode(&self, mode: GhosttyMode) -> Option<bool> {
        self.terminal.mode(mode)
    }

    /// How many bytes `replay` ends with for the parser continuation.
    pub fn continuation_len(&self) -> usize {
        self.continuation().len()
    }

    fn continuation(&self) -> Vec<u8> {
        self.terminal.continuation()
    }

    /// A selection from the `rows_back`th history row from the bottom to the active area's last
    /// cell: the screen and the newest `rows_back` history rows. `rows_back` 0 is the screen alone.
    /// None when a point cannot be resolved.
    fn tail_selection(&self, rows_back: u32) -> Option<Selection<'_>> {
        let history = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)?;
        let columns = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS)?;
        let rows = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS)?;
        let point = |tag, x: u32, y: u32| -> Option<Point> {
            Some(Point {
                tag,
                x: u16::try_from(x).ok()?,
                y,
            })
        };
        self.terminal.selection(
            point(
                GhosttyPointTag_GHOSTTY_POINT_TAG_SCREEN,
                0,
                history - rows_back.min(history),
            )?,
            point(
                GhosttyPointTag_GHOSTTY_POINT_TAG_ACTIVE,
                columns.saturating_sub(1),
                rows.saturating_sub(1),
            )?,
        )
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
        // The screen's state with it (the module doc), or only its cells.
        let extras_on = Extras {
            modes: extras,
            scrolling_region: extras,
            tabstops: extras,
            pwd: extras,
            keyboard: extras,
            charsets: extras,
        };
        let bytes = self.terminal.format(
            GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_VT,
            extras_on,
            selection.as_ref(),
        );
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
        // The copy's history compressed as it is decoded: uncompressed it is the whole 50 MB the
        // source keeps compressed (measured 49.97 MB against 1.33 MB).
        let terminal = self.terminal.snapshot_copy(true)?;
        Some(ShadowTerminal {
            terminal,
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
    /// (`crate::terminal::screens`), and the start of every replay. A record outlives the program,
    /// so a report in it would only pin the client's spinner on; and nothing will ever complete a
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
    #[cfg(any(test, feature = "test-support"))]
    pub fn visible_text(&self) -> String {
        let text = self.terminal.format(
            GhosttyFormatterFormat_GHOSTTY_FORMATTER_FORMAT_PLAIN,
            Extras::default(),
            None,
        );
        String::from_utf8_lossy(&text).into_owned()
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
mod tests;
