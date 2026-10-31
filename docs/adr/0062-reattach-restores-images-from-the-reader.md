# A reattach restores images as a background transfer from the session's reader

Decided 2026-10-31 (owner, triage and engineering review of #551). Amends [ADR 0010](0010-shadow-terminal-attach-only.md): connected clients still get the pty's bytes untouched and in order, but image bytes can now go between them. Adds to [ADR 0031](0031-screens-persist-as-vt-bytes.md): images travel as VT bytes, never a snapshot.

A pane's images were lost on every reattach, because the formatter emits none and the repaint's erase clears them. Panes also reported 0x0 pixels, so `kitten icat` refused to run and the shadow gave an image no rows, which moved the text under it.

Clients now send their pixel size with attach and resize, and the size owner's reaches the pty and the shadow. A hand-off reads it back from the pty, whose kernel winsize survives the exec, so the table is unchanged.

The shadow decodes PNG through the `png` crate and keeps 32 MB of decoded images per screen, direct transfers only. After the text repaint, a client gets the images on its active screen re-sent as PNG in fast mode, in 4 KB Kitty chunks with `q=2`, then placed.

**The reader writes every byte of a transfer.** A read can end anywhere, including inside an escape sequence or a UTF-8 character, and a chunk there prints garbage. The shadow is one read ahead of a client until the reader has delivered that read, so only the reader knows what a client has. Encoders copy pixels and make chunks; they never touch a client. A chunk or placement goes out only at parser ground, tested with `ghostty_terminal_vt_write_until`, not `continuation()`, whose tracking stops at 4096 bytes.

A program's own string, a screen switch or a reset ends a transfer, with `m=0` ahead of those bytes where the stream allows, because a chunk after them would corrupt the program's image or reach the wrong screen. Every repaint starts with `m=0` too, since a transfer cut off midway would otherwise swallow the next image a program sends. A dropped image waits for the next reattach.

Placement is a plain cursor move there and back, never ESC 7 and ESC 8, which overwrite the program's saved cursor, and it waits out a pending wrap and origin mode. An image partly above the top row is cropped to what is left.

A hand-off carries images inside its screens, after all text, newest first, under its own 250 ms and 32 MiB.

Accepted costs: a slow client can pause another client on the same session for one chunk, as output already does, since writers cannot be skipped without a writer thread per client. Images in scrollback, behind a full-screen program, in the on-disk record, or sent by file, temp file or shared memory do not come back. PNGs are decoded on the read path, under the attachment lock.

Rejected: a transfer thread per client (needs parser state shared under a lock order opposite to `attach`'s); sending images inside the repaint (stalls the pty for their whole size); libghostty snapshots (no compatibility between revisions, and they reach another daemon, not the app's surface); lazy loading for hidden panes (a pane that is not mounted does not attach, and the rest needs a new signal from the app).

Source: [#551](https://github.com/joelmoss/workroom/issues/551), [`vcs/crates/workroomd/src/images.rs`](../../vcs/crates/workroomd/src/images.rs) (module comment), [`terminal.rs`](../../vcs/crates/workroomd/src/terminal.rs).
