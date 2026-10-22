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
//! 37 history rows and 24 visible ones emits 59 newlines, and a client fed that ends up with the
//! history and the right visible screen. A hand-rolled history emission on top of it only
//! double-counts. The one measurable difference is a single row: the emission ends without a
//! trailing newline, so the last line does not scroll, and the client reports 36 history rows
//! where the producer has 37.
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

/// A terminal's memory as libghostty counts it (`ShadowTerminal::memory`).
pub type MemoryUsage = GhosttyTerminalMemoryUsage;

/// What `format_tail` sends: the paint, and how many history rows it carries.
struct Tail {
    bytes: Vec<u8>,
    history_rows: u32,
}

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
    /// Bytes for the pty: only the answer to a program status probe.
    replies: Vec<u8>,
}

/// What `OSC 7501 ; ?` is answered with, up to the states and kinds that follow it.
const PROBE_REPLY: &[u8] = b"\x1b]7501;";

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
        let terminal = ShadowTerminal {
            inner,
            effects: Box::into_raw(Box::default()),
            primary_paint: Default::default(),
        };
        terminal.enable_continuation_tracking();
        terminal.limit_scrollback();
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

    /// Cell pixel dimensions are zero: they feed image protocols and size reports, and the shadow
    /// renders nothing — the real client owns the pixels and reports its own.
    ///
    /// A width change reflows, which decompresses the whole history (1.33 to 40 MB measured at 200
    /// to 160 columns), so it is compressed again before this returns rather than at the next
    /// tick. A height change touches no history.
    pub fn resize(&mut self, columns: u16, rows: u16) {
        let width = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS);
        // SAFETY: `inner` is a live terminal, and both dimensions are at least 1, as required.
        unsafe {
            ghostty_terminal_resize(self.inner, columns.max(1), rows.max(1), 0, 0);
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
        bytes
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
        let mut out = copy.paint(budget, until);
        // Each screen has its own kitty flags, so the primary's go before `DECSET 1049` too, or a
        // client gets them back only from the alternate screen's, which are usually clear.
        out.extend_from_slice(&copy.kitty_flags());
        // The primary's cursor, explicitly, for the same reason `replay` emits one: the formatter
        // homes the cursor and leaves it after the last painted cell. Here it matters twice over,
        // because `DECSET 1049` SAVES the cursor as it switches — so without this the position the
        // client restores when the program exits is wherever the paint ended, and the shell's next
        // line is written onto the end of the last history line instead of below it.
        out.extend_from_slice(&copy.cursor_position());
        if until.is_none() {
            *self.primary_paint.borrow_mut() = Some((budget, out.clone()));
        }
        Some(out)
    }

    /// The active screen as `format_tail` sends it within `budget`, then the newlines that bring
    /// a client to the row its cursor is on (`scroll_padding`).
    fn paint(&self, budget: usize, until: Option<Instant>) -> Vec<u8> {
        let Tail {
            mut bytes,
            history_rows,
            ..
        } = self.format_tail(budget, until);
        // How far down the client's content the paint leaves it. The formatter emits one line per
        // non-empty row and no trailing newline, so this is where its cursor ends up.
        let painted_rows = bytes.iter().filter(|byte| **byte == b'\n').count() as u32;
        bytes.extend_from_slice(&self.scroll_padding(painted_rows, history_rows));
        bytes
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
    fn format_tail(&self, budget: usize, until: Option<Instant>) -> Tail {
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
            return Tail {
                bytes: format(0),
                history_rows: 0,
            };
        }
        let mut best: Option<(u32, Vec<u8>)> = None;
        let mut rows = history.min(TAIL_SAMPLE_ROWS);
        let sample = format(rows);
        let (mut next, mut held_back) = guess(rows, sample.len());
        if sample.len() <= budget {
            if rows == history {
                return Tail {
                    bytes: sample,
                    history_rows: rows,
                };
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
        let (history_rows, bytes) = match best {
            Some(best) => best,
            // Only after every guess overshot, or the time ran out first.
            None => loop {
                rows = if late() { 0 } else { rows / 2 };
                let bytes = format(rows);
                if bytes.len() <= budget || rows == 0 {
                    break (rows, bytes);
                }
            },
        };
        Tail {
            bytes,
            history_rows,
        }
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
    /// The cursor's row in what was sent is `history_rows + cursor_y`, `history_rows` being the
    /// history `format_tail` sent rather than all this terminal keeps, and the paint leaves the
    /// client at `painted_rows`; the difference is what has to be scrolled through.
    fn scroll_padding(&self, painted_rows: u32, history_rows: u32) -> Vec<u8> {
        let Some(cursor_y) = self.get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y)
        else {
            return Vec::new();
        };
        let wanted = history_rows + cursor_y;
        if wanted <= painted_rows {
            return Vec::new();
        }
        // `\r\n` rather than `\n`: the client may have `LNM` unset, where a bare newline moves down
        // without returning to column 0, and the CUP that follows would then be applied from the
        // wrong place on every intermediate row.
        b"\r\n".repeat((wanted - painted_rows) as usize)
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
    /// is left: the leading erase, the kitty flags, the cursor, the scroll padding (counted at its
    /// most, `\r\n` for each screen row and one more) and, on the alternate screen, that screen's
    /// paint, which has no history. The output keeps the order a real session produced it in:
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
        let rows = self
            .get_u32(GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS)
            .unwrap_or(0) as usize;
        let padding = 2 * (rows + 1);
        let kitty = self.kitty_flags();
        let cursor = self.cursor_position();
        let fixed = ERASE.len() + kitty.len() + cursor.len();
        let late = until.is_some_and(|until| Instant::now() >= until);

        let mut out = if self.mode(modes::ALT_SCREEN) == Some(true) {
            let alternate = self.paint(
                budget.saturating_sub(fixed + padding + ALTERNATE.len()),
                None,
            );
            let left = budget.saturating_sub(fixed + alternate.len() + ALTERNATE.len());
            // The primary screen first, then re-entering the alt screen, then the alt screen's own
            // paint below — the order a real session produced them in.
            let primary = if late {
                None
            } else {
                self.primary_screen(left.saturating_sub(padding + CURSOR + KITTY), until)
            };
            // The switch whether or not the primary was painted. The formatter's mode extras set
            // it again within the paint (measured), but the screen switch is what separates the
            // two paints, so it is written here rather than left to them.
            let mut out = primary.unwrap_or_default();
            out.extend_from_slice(ALTERNATE);
            out.extend_from_slice(&alternate);
            out
        } else {
            self.paint(budget.saturating_sub(fixed + padding), until)
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
    let mut rest = bytes;
    while let Some(at) = rest.iter().position(|byte| *byte == 0x1b) {
        rest = &rest[at + 1..];
        if rest.first() == Some(&b'c') {
            return true;
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
                return true;
            }
        }
    }
    false
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
        assert!(tail.bytes.len() <= 1 << 20, "{} bytes", tail.bytes.len());
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
    /// and the next output lands where the producer's does: the padding follows the history sent,
    /// not the history kept. A cut can start inside a soft-wrapped line, whose first row then
    /// arrives as a line of its own, which is still the end of the producer's line.
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
    /// cursor row, at every cut point; fails_when=scroll_padding pads to the history kept rather
    /// than sent, or modes are cut with the history; why_new=no record was ever cut; seam=none
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

    /// The same under a full-screen program: the primary's paint is cut and padded on its own,
    /// so quitting the program brings back the shell's newest history and its cursor row.
    ///
    /// Value: protects=the primary's cut paint under the alternate screen; fails_when=the primary
    /// gets no scroll padding or the alternate screen's budget is not taken first; why_new=the
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
                assert!(tail.history_rows <= history, "{label}");
                assert!(
                    tail.bytes.len() <= budget || tail.history_rows == 0,
                    "{label}: {} bytes",
                    tail.bytes.len()
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
    /// the landing deterministic: the sample (the newest rows, with the screen and the palette)
    /// comes to more bytes a row than the history behind it, so the first guess comes in at about
    /// three fifths of the budget.
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
            (budget / 10 * 8..=budget).contains(&tail.bytes.len()),
            "the search stopped at {} of {budget} bytes: {sizes:?}",
            tail.bytes.len()
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
}
