//! One terminal, the callbacks it reports to, and everything the shadow reads from it: options,
//! data, the formatter, snapshots, Kitty images and the process's PNG decoder.

use std::ffi::c_void;
use std::marker::PhantomData;
use std::ptr;
use std::sync::OnceLock;

use crate::sys::*;

const OK: GhosttyResult = GhosttyResult_GHOSTTY_SUCCESS;

/// What a terminal reports while it parses output. Every method does nothing unless implemented.
///
/// They are called only from inside [`Terminal::write`] and [`Terminal::write_until`], which take
/// `&mut Terminal`, so nothing else can be reading the callbacks ([`Terminal::callbacks`]) while one
/// runs. Each is passed what the library passed, already checked against the size of the library's
/// own struct.
pub trait Callbacks: Default {
    /// `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT`: an OSC 9;4. `percent` is -1 when the report has
    /// none.
    fn progress_report(&mut self, _state: GhosttyTerminalProgressState, _percent: i8) {}

    /// `GHOSTTY_TERMINAL_OPT_WRITE_PTY`: bytes the terminal answers a query with, for the pty.
    fn write_pty(&mut self, _bytes: &[u8]) {}

    /// `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`: an OSC 7501 report or CLEAR.
    fn program_status(&mut self, _report: ProgramStatus<'_>) {}

    /// `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`: the title changed, and can be read from `title`.
    fn title_changed(&mut self, _title: Title<'_>) {}

    /// `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT`: an OSC 133 mark, with its exit code when it carries
    /// one.
    fn semantic_prompt(&mut self, _kind: GhosttySemanticPromptKind, _exit_code: Option<i32>) {}

    /// `GHOSTTY_TERMINAL_OPT_RESET`: RIS, after the CLEAR libghostty sends for it.
    fn reset(&mut self) {}
}

/// An OSC 7501 report, lent for the callback it was passed to.
pub struct ProgramStatus<'a> {
    report: &'a GhosttyTerminalProgramStatus,
}

impl ProgramStatus<'_> {
    pub fn state(&self) -> GhosttyProgramStatusState {
        self.report.state
    }

    pub fn kind(&self) -> GhosttyProgramStatusKind {
        self.report.kind
    }

    pub fn progress(&self) -> i8 {
        self.report.progress
    }

    pub fn id(&self) -> String {
        // SAFETY: the string is one this callback was passed, and lives as long as `self`.
        unsafe { copied(&self.report.id) }
    }

    pub fn app(&self) -> String {
        // SAFETY: as in `id`.
        unsafe { copied(&self.report.app) }
    }

    pub fn title(&self) -> String {
        // SAFETY: as in `id`.
        unsafe { copied(&self.report.title) }
    }

    pub fn message(&self) -> String {
        // SAFETY: as in `id`.
        unsafe { copied(&self.report.message) }
    }
}

/// The new title, for the callback it was passed to: read only if wanted.
pub struct Title<'a> {
    terminal: GhosttyTerminal,
    _call: PhantomData<&'a ()>,
}

impl Title<'_> {
    pub fn read(&self) -> Option<String> {
        let mut title = GhosttyString {
            ptr: ptr::null(),
            len: 0,
        };
        // SAFETY: `terminal` is the live terminal this callback runs for, which has already stored
        // the new title, and `title` is a live out-pointer of the type DATA_TITLE writes.
        let rc = unsafe {
            ghostty_terminal_get(
                self.terminal,
                GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_TITLE,
                (&mut title as *mut GhosttyString).cast(),
            )
        };
        // SAFETY: the title is borrowed until the next mutating call, and this copies it now.
        (rc == OK).then(|| unsafe { copied(&title) })
    }
}

/// The callbacks' userdata.
///
/// # Safety
/// `userdata` must be the `C` a `Terminal<C>` registered, and the call must come from inside
/// `ghostty_terminal_vt_write`, which `write(&mut self)` makes, so nothing else holds a reference
/// to it meanwhile.
unsafe fn callbacks<'a, C>(userdata: *mut c_void) -> Option<&'a mut C> {
    // SAFETY: per this function's contract, a live `C` reached by no other reference.
    unsafe { (userdata as *mut C).as_mut() }
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

unsafe extern "C" fn on_progress_report<C: Callbacks>(
    _terminal: GhosttyTerminal,
    userdata: *mut c_void,
    report: *const GhosttyTerminalProgressReport,
) {
    let (Some(callbacks), Some(report)) = (
        // SAFETY: libghostty passes the userdata `register` set, from inside a write.
        unsafe { callbacks::<C>(userdata) },
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
    callbacks.progress_report(report.state, percent);
}

unsafe extern "C" fn on_write_pty<C: Callbacks>(
    _terminal: GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    // SAFETY: libghostty passes the userdata `register` set, from inside a write.
    let Some(callbacks) = (unsafe { callbacks::<C>(userdata) }) else {
        return;
    };
    if data.is_null() {
        return;
    }
    // SAFETY: libghostty passes `len` bytes at `data`, valid for the duration of the call.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    callbacks.write_pty(bytes);
}

unsafe extern "C" fn on_program_status<C: Callbacks>(
    _terminal: GhosttyTerminal,
    userdata: *mut c_void,
    report: *const GhosttyTerminalProgramStatus,
) {
    let (Some(callbacks), Some(report)) = (
        // SAFETY: libghostty passes the userdata `register` set, from inside a write.
        unsafe { callbacks::<C>(userdata) },
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
    callbacks.program_status(ProgramStatus { report });
}

unsafe extern "C" fn on_title_changed<C: Callbacks>(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
) {
    // SAFETY: libghostty passes the userdata `register` set, from inside a write.
    let Some(callbacks) = (unsafe { callbacks::<C>(userdata) }) else {
        return;
    };
    callbacks.title_changed(Title {
        terminal,
        _call: PhantomData,
    });
}

unsafe extern "C" fn on_semantic_prompt<C: Callbacks>(
    _terminal: GhosttyTerminal,
    userdata: *mut c_void,
    event: *const GhosttyTerminalSemanticPrompt,
) {
    let (Some(callbacks), Some(event)) = (
        // SAFETY: libghostty passes the userdata `register` set, from inside a write.
        unsafe { callbacks::<C>(userdata) },
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
    let has_exit_code = event.size
        >= std::mem::offset_of!(GhosttyTerminalSemanticPrompt, exit_code)
            + std::mem::size_of::<i32>();
    let exit_code = (has_exit_code && event.has_exit_code).then_some(event.exit_code);
    callbacks.semantic_prompt(event.kind, exit_code);
}

unsafe extern "C" fn on_reset<C: Callbacks>(_terminal: GhosttyTerminal, userdata: *mut c_void) {
    // SAFETY: libghostty passes the userdata `register` set, from inside a write.
    if let Some(callbacks) = unsafe { callbacks::<C>(userdata) } {
        callbacks.reset();
    }
}

/// What the process's PNG decoder hands back: width, height and 8-bit RGBA.
pub type DecodePng = fn(&[u8]) -> Option<(u32, u32, Vec<u8>)>;

static PNG_DECODER: OnceLock<DecodePng> = OnceLock::new();

/// Sets the process's PNG decoder (`GHOSTTY_SYS_OPT_DECODE_PNG`) to `decode`, once: later calls
/// keep the first. Without a decoder a terminal rejects every PNG, which is what `kitten icat`
/// sends.
pub fn set_png_decoder(decode: DecodePng) {
    if PNG_DECODER.set(decode).is_err() {
        return;
    }
    let trampoline: GhosttySysDecodePngFn = Some(decode_png);
    // SAFETY: a function pointer option is passed directly, and `decode_png` matches it.
    unsafe {
        ghostty_sys_set(
            GhosttySysOption_GHOSTTY_SYS_OPT_DECODE_PNG,
            trampoline.map_or(ptr::null(), |function| function as *const c_void),
        );
    }
}

/// `GHOSTTY_SYS_OPT_DECODE_PNG`, through the decoder `set_png_decoder` was given.
unsafe extern "C" fn decode_png(
    _userdata: *mut c_void,
    allocator: *const GhosttyAllocator,
    data: *const u8,
    data_len: usize,
    out: *mut GhosttySysImage,
) -> bool {
    let Some(decode) = PNG_DECODER.get() else {
        return false;
    };
    if data.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: libghostty passes `data_len` bytes at `data`, valid for this call.
    let bytes = unsafe { std::slice::from_raw_parts(data, data_len) };
    // These bytes are whatever a program printed, and a panic cannot cross this C boundary: it
    // would abort the daemon, and every session with it, over one image.
    let Ok(Some((width, height, rgba))) = std::panic::catch_unwind(|| decode(bytes)) else {
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

/// How many bytes `ghostty_terminal_get` writes for each kind `Terminal::get_u32` reads: the size
/// of the output type terminal.h names, a `size_t` for the scrollback rows, a `uint16_t` for the
/// size and the cursor, a `uint8_t` for the kitty flags. `None` for any other kind. A test in
/// workroomd (`widths_are_what_libghostty_writes`) holds this table to the linked library.
pub fn width_of(data: GhosttyTerminalData) -> Option<usize> {
    if data == GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS {
        Some(std::mem::size_of::<usize>())
    } else if data == GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS
        || data == GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS
        || data == GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X
        || data == GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y
    {
        Some(std::mem::size_of::<u16>())
    } else if data == GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS {
        Some(std::mem::size_of::<u8>())
    } else {
        None
    }
}

/// One placement, as `Terminal::each_placement` reads it.
pub struct Placed {
    pub image: u32,
    pub generation: u64,
    pub id: u32,
    pub is_virtual: bool,
    pub x_offset: u32,
    pub y_offset: u32,
    pub columns: u32,
    pub rows: u32,
    pub z: i32,
    pub info: GhosttyKittyGraphicsPlacementRenderInfo,
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
}

/// A copy of one stored image's pixels, in the image's own format.
pub struct ImagePixels {
    pub width: u32,
    pub height: u32,
    pub format: GhosttyKittyImageFormat,
    pub data: Vec<u8>,
}

/// A cell of the screen, for a `Selection`: `x` and `y` in the coordinate system `tag` names.
pub struct Point {
    pub tag: GhosttyPointTag,
    pub x: u16,
    pub y: u32,
}

/// A selection of a terminal's cells, for `Terminal::format`. It borrows the terminal it was taken
/// from, because its cells are only valid until the next write.
pub struct Selection<'t> {
    raw: GhosttySelection,
    _terminal: PhantomData<&'t ()>,
}

/// What the formatter adds to the cells (`GhosttyFormatterTerminalExtra`). All off by default.
#[derive(Default, Clone, Copy)]
pub struct Extras {
    pub modes: bool,
    pub scrolling_region: bool,
    pub tabstops: bool,
    pub pwd: bool,
    pub keyboard: bool,
    pub charsets: bool,
}

/// One libghostty-vt terminal, reporting to its `C`.
pub struct Terminal<C: Callbacks> {
    inner: GhosttyTerminal,
    /// The callbacks' userdata. A raw allocation rather than a `Box` field: moving a `Box`
    /// asserts unique access to its contents, which the pointer the terminal holds would then
    /// alias. Freed in `Drop`, after the terminal that writes to it.
    callbacks: *mut C,
}

// SAFETY: the handle and the callbacks' userdata are owned exclusively, so moving them to another
// thread moves the only way to reach them. libghostty-vt requires the caller to serialise access,
// and it is: `Terminal` is not `Sync`, so only the thread holding it can call in, and `&mut self`
// orders the writes that run the callbacks.
unsafe impl<C: Callbacks + Send> Send for Terminal<C> {}

impl<C: Callbacks> Terminal<C> {
    /// A terminal of `columns` by `rows` (each at least 1) reporting to `callbacks`, or `None` if
    /// libghostty could not make one.
    pub fn new(columns: u16, rows: u16, callbacks: C) -> Option<Terminal<C>> {
        let mut inner: GhosttyTerminal = ptr::null_mut();
        // SAFETY: a null allocator selects the default one, `inner` is a live out-pointer, and
        // both dimensions are at least 1, as the call requires.
        let rc =
            unsafe { ghostty_terminal_new(ptr::null(), &mut inner, columns.max(1), rows.max(1)) };
        if rc != OK || inner.is_null() {
            return None;
        }
        let terminal = Terminal {
            inner,
            callbacks: Box::into_raw(Box::new(callbacks)),
        };
        terminal.register();
        Some(terminal)
    }

    /// Points every option the trait covers at its callback. Pointer-typed options are passed
    /// directly, not by address (`ghostty_terminal_set`'s doc).
    fn register(&self) {
        let callbacks: [(GhosttyTerminalOption, *const c_void); 6] = [
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT,
                on_progress_report::<C> as *const c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                on_write_pty::<C> as *const c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
                on_program_status::<C> as *const c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
                on_semantic_prompt::<C> as *const c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_RESET,
                on_reset::<C> as *const c_void,
            ),
            (
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                on_title_changed::<C> as *const c_void,
            ),
        ];
        // SAFETY: `inner` is a live terminal. The userdata is `callbacks`, which `Drop` frees only
        // after the terminal, and each callback matches its option's signature.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_USERDATA,
                self.callbacks as *const c_void,
            );
            for (option, callback) in callbacks {
                ghostty_terminal_set(self.inner, option, callback);
            }
        }
    }

    /// The handle, for a test that calls the C API itself.
    pub fn raw(&self) -> GhosttyTerminal {
        self.inner
    }

    /// The callbacks, as they were left by the last write.
    pub fn callbacks(&self) -> &C {
        // SAFETY: `callbacks` is a live allocation until `Drop`, and the callbacks that write it
        // only run inside a write (`&mut self`), never during this `&self` borrow.
        unsafe { &*self.callbacks }
    }

    pub fn callbacks_mut(&mut self) -> &mut C {
        // SAFETY: as in `callbacks`; `&mut self` also rules out the callbacks running meanwhile.
        unsafe { &mut *self.callbacks }
    }

    /// `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES`.
    pub fn set_continuation_max_bytes(&mut self, limit: usize) {
        // SAFETY: a non-pointer option is passed by address, and `limit` is a live `usize` (the
        // option's type) that the call reads before returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
                &limit as *const usize as *const c_void,
            );
        }
    }

    /// `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT`, in decoded bytes.
    pub fn set_kitty_image_storage_limit(&mut self, limit: u64) {
        // SAFETY: `inner` is a live terminal, and the option reads a `uint64_t` before returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                (&raw const limit).cast(),
            );
        }
    }

    /// `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`; `None` is no line limit.
    pub fn set_scrollback_max_lines(&mut self, lines: Option<usize>) {
        let limit = lines
            .as_ref()
            .map_or(ptr::null(), |lines| lines as *const usize as *const c_void);
        // SAFETY: `inner` is a live terminal. The option takes a `size_t*`: a NULL one removes the
        // line limit (terminal.h), and otherwise `lines` is a live `usize` the call reads before
        // returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                limit,
            );
        }
    }

    /// `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`.
    pub fn set_scrollback_max_bytes(&mut self, bytes: usize) {
        // SAFETY: `inner` is a live terminal, and the option takes a `size_t*`: `bytes` is a live
        // `usize` the call reads before returning.
        unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                &bytes as *const usize as *const c_void,
            );
        }
    }

    /// `GHOSTTY_TERMINAL_OPT_COLOR_PALETTE`: sets all 256 colours. Whether the library took them.
    pub fn set_palette(&mut self, colours: &[GhosttyColorRgb; 256]) -> bool {
        // SAFETY: COLOR_PALETTE reads a `GhosttyColorRgb[256]`, and `colours` is a live one.
        let rc = unsafe {
            ghostty_terminal_set(
                self.inner,
                GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
                colours.as_ptr().cast(),
            )
        };
        rc == OK
    }

    /// Feeds the terminal `bytes`, running the callbacks for what they hold.
    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: `inner` is a live terminal, and the pointer and length come from one live slice.
        unsafe { ghostty_terminal_vt_write(self.inner, bytes.as_ptr(), bytes.len()) }
    }

    /// `ghostty_terminal_vt_write_until`: feeds `bytes` up to and including the first byte that
    /// reaches one of `boundaries`, and says where that was, or `None` when none was reached (all
    /// of `bytes` consumed) or the call failed. Empty `bytes` with the GROUND boundary only asks
    /// whether the parser is at ground.
    pub fn write_until(
        &mut self,
        bytes: &[u8],
        boundaries: GhosttyTerminalBoundary,
    ) -> Option<GhosttyTerminalWriteStop> {
        // SAFETY: all zeroes is valid for this C struct of integers.
        let mut stop: GhosttyTerminalWriteStop = unsafe { std::mem::zeroed() };
        stop.size = std::mem::size_of::<GhosttyTerminalWriteStop>();
        let data = if bytes.is_empty() {
            ptr::null()
        } else {
            bytes.as_ptr()
        };
        // SAFETY: `inner` is live, the pointer and length come from one live slice (a NULL
        // pointer only at length zero, as allowed), and `stop` is live with its `size` set.
        // The flags are the boundary's own bits; the C type of the enum and of the parameter
        // differ by platform, so the cast is to whichever the parameter is.
        let rc = unsafe {
            ghostty_terminal_vt_write_until(
                self.inner,
                data,
                bytes.len(),
                boundaries as _,
                &mut stop,
            )
        };
        (rc == OK).then_some(stop)
    }

    /// `ghostty_terminal_resize`, each dimension at least 1.
    pub fn resize(&mut self, columns: u16, rows: u16, cell_width: u32, cell_height: u32) {
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
    }

    /// Compresses the history pages nothing has touched since they were last compressed, until
    /// the library has nothing more to do now. A failure leaves the history as it is.
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
    pub fn memory(&self) -> Option<GhosttyTerminalMemoryUsage> {
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

    /// The 256 colours of `data`, one of the two `COLOR_PALETTE` kinds; `None` for any other kind.
    pub fn palette(&self, data: GhosttyTerminalData) -> Option<[[u8; 3]; 256]> {
        if data != GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_PALETTE
            && data != GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT
        {
            return None;
        }
        let mut colours = [GhosttyColorRgb { r: 0, g: 0, b: 0 }; 256];
        // SAFETY: both palette kinds write a `GhosttyColorRgb[256]`, and `colours` is a live one.
        let rc = unsafe { ghostty_terminal_get(self.inner, data, colours.as_mut_ptr().cast()) };
        (rc == OK).then(|| colours.map(|colour| [colour.r, colour.g, colour.b]))
    }

    /// A `bool` kind: only `CURSOR_PENDING_WRAP` is read this way, and any other kind is refused.
    pub fn get_bool(&self, data: GhosttyTerminalData) -> Option<bool> {
        if data != GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP {
            return None;
        }
        let mut value = false;
        // SAFETY: the data kind passed here has `bool *` as its output type.
        let rc = unsafe { ghostty_terminal_get(self.inner, data, (&raw mut value).cast()) };
        (rc == OK).then_some(value)
    }

    /// A count or position, widened to `u32`, read into a variable exactly `width_of(data)` bytes
    /// wide, because that is how many bytes the library writes. A `u32` for every kind overran
    /// the stack for the scrollback rows. A kind with no known width is refused.
    pub fn get_u32(&self, data: GhosttyTerminalData) -> Option<u32> {
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
        let width = width_of(data)?;
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
                &mut config as *mut _ as *mut c_void,
            )
        };
        (rc == OK).then_some(config.value)
    }

    /// The bytes that would finish the sequence or codepoint the parser is part way through, up to
    /// the continuation limit; empty at ground.
    pub fn continuation(&self) -> Vec<u8> {
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

    /// The cells from `start` to `end`, or `None` when either cannot be resolved.
    pub fn selection(&self, start: Point, end: Point) -> Option<Selection<'_>> {
        let grid = |at: Point| -> Option<GhosttyGridRef> {
            // SAFETY: plain C structs of integers and pointers, for which all zeroes is valid.
            let mut point: GhosttyPoint = unsafe { std::mem::zeroed() };
            point.tag = at.tag;
            point.value.coordinate = GhosttyPointCoordinate { x: at.x, y: at.y };
            // SAFETY: as above.
            let mut grid: GhosttyGridRef = unsafe { std::mem::zeroed() };
            grid.size = std::mem::size_of::<GhosttyGridRef>();
            // SAFETY: `inner` is a live terminal and `grid` a live out-pointer with its size set.
            let rc = unsafe { ghostty_terminal_grid_ref(self.inner, point, &mut grid) };
            (rc == OK).then_some(grid)
        };
        Some(Selection {
            raw: GhosttySelection {
                size: std::mem::size_of::<GhosttySelection>(),
                start: grid(start)?,
                end: grid(end)?,
                rectangle: false,
            },
            _terminal: PhantomData,
        })
    }

    /// The terminal's active screen as `emit` (VT or plain text) with `extras`, of `selection` when
    /// given and of everything (scrollback included) when not. Empty when the format failed.
    pub fn format(
        &self,
        emit: GhosttyFormatterFormat,
        extras: Extras,
        selection: Option<&Selection<'_>>,
    ) -> Vec<u8> {
        let mut formatter: GhosttyFormatter = ptr::null_mut();
        // SAFETY: the options are a C struct of integers, bools and sized sub-structs, for which
        // all zeroes is a valid value; the fields that matter are set below.
        let mut options: GhosttyFormatterTerminalOptions = unsafe { std::mem::zeroed() };
        options.size = std::mem::size_of::<GhosttyFormatterTerminalOptions>();
        options.emit = emit;
        // `trim` stays false: untrimmed VT output keeps the blank rows at the end of the screen, so
        // a client scrolls as far as the producer did and the next write lands below the last line.
        options.extra.size = std::mem::size_of::<GhosttyFormatterTerminalExtra>();
        options.extra.modes = extras.modes;
        options.extra.scrolling_region = extras.scrolling_region;
        options.extra.tabstops = extras.tabstops;
        options.extra.pwd = extras.pwd;
        options.extra.keyboard = extras.keyboard;
        if extras.charsets {
            options.extra.screen.size = std::mem::size_of::<GhosttyFormatterScreenExtra>();
            options.extra.screen.charsets = true;
        }
        if let Some(selection) = selection {
            options.selection = &selection.raw;
        }
        // SAFETY: `inner` is a live terminal that outlives the formatter, which is freed before
        // this method returns; `formatter` is a live out-pointer. The selection, when set, lives
        // until this method returns and borrows this terminal, so no write came since it was taken.
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

    /// A byte-for-byte copy of this terminal, via the snapshot format, its history compressed as it
    /// is decoded when `compress_history`. The copy registers no callbacks: its own are a default
    /// `C` that nothing calls.
    pub fn snapshot_copy(&self, compress_history: bool) -> Option<Terminal<C>> {
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
        // SAFETY: `decoder` is live and has not started decoding, and a non-pointer option is
        // passed by address: `compress_history` is a live `bool` (the option's type) read before
        // the call returns.
        unsafe {
            ghostty_snapshot_decoder_set(
                decoder,
                GhosttySnapshotDecoderOption_GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY,
                &compress_history as *const bool as *const c_void,
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
        Some(Terminal {
            inner,
            callbacks: Box::into_raw(Box::default()),
        })
    }

    /// Calls `f` for each placement on the active screen. The storage is borrowed until the next
    /// write, which `&self` rules out here.
    pub fn each_placement(&self, mut f: impl FnMut(&Placed)) {
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

    /// A copy of image `id`'s pixels, or `None` if it is gone or is no longer `generation` (a
    /// program has replaced it since).
    pub fn image_pixels(&self, id: u32, generation: u64) -> Option<ImagePixels> {
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
        let handle = unsafe { ghostty_kitty_graphics_image(graphics, id) };
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
            let current: u64 = get(
                handle,
                GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
            )?;
            if current != generation {
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
            Some(ImagePixels {
                width,
                height,
                format,
                // The storage holds `length` bytes at `pointer` until the next write.
                data: std::slice::from_raw_parts(pointer, length).to_vec(),
            })
        }
    }
}

impl<C: Callbacks> Drop for Terminal<C> {
    fn drop(&mut self) {
        if !self.inner.is_null() {
            // SAFETY: `inner` is owned by this value and freed exactly once, here.
            unsafe { ghostty_terminal_free(self.inner) };
        }
        // After the terminal: it is what writes here.
        // SAFETY: `callbacks` came from `Box::into_raw` and is freed exactly once, here, after the
        // terminal that held a copy of it is gone.
        drop(unsafe { Box::from_raw(self.callbacks) });
    }
}
