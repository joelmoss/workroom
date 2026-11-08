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
    assert!(client.terminal.set_palette(&theme));

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

/// The kitty stack is the one thing the keyboard extra does not carry, so it is emitted by hand.
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
            producer.replay().len() < crate::terminal::screens::MAX_RECORD,
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
        .filter_map(|kind| ghostty_vt::width_of(kind).map(|width| (kind, width)))
        .collect();
    assert!(!kinds.is_empty(), "width_of claims no kinds");
    for (kind, width) in kinds {
        // Words, not bytes, so the buffer is aligned for the widest type written into it.
        let mut words = [u64::from_ne_bytes([SENTINEL; 8]); 2];
        // SAFETY: the handle is live, and only kinds the table claims are read. 16 aligned bytes
        // hold all of them, and a table entry off by up to 8 bytes is what this test reports.
        let rc = unsafe {
            ghostty_terminal_get(terminal.terminal.raw(), kind, words.as_mut_ptr().cast())
        };
        assert_eq!(rc, GhosttyResult_GHOSTTY_SUCCESS, "kind {kind}");
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
        const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
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
    out.extend_from_slice(crate::util::base64(&png_bytes(width, height)).as_bytes());
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
    client.write(&crate::terminal::images::transmit_bytes(7, &png));
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

/// The bytes `repaint_golden_matches` holds to `repaint.golden`, one section per thing a client
/// is sent: the replay, the formatter with and without the shadow's extras, a tail selection, the
/// plain text, and an image's pixels and placement.
fn repaint_golden() -> Vec<u8> {
    let mut primary = sized_terminal(80, 24);
    // History, with styles, colours, a hyperlink and wide and combining characters in it.
    for n in 0..40 {
        primary.write(
            format!(
                "\x1b[1;3{}mline {n}\x1b[0m \x1b[4:3;58;5;{n}m\x1b[38;5;{}mcurly\x1b[0m \
                 \x1b[38;2;{n};100;200m\x1b[48;2;5;{n};9mtrue\x1b[0m \x1b[2;7;9mfaint\x1b[0m \
                 \x1b]8;id=l{n};https://example.com/{n}\x1b\\link\x1b]8;;\x1b\\ \
                 漢字🙂e\u{301}\r\n",
                n % 8,
                n * 6
            )
            .as_bytes(),
        );
    }
    // A line the terminal wrapped, then the state the extras carry: tabstops, a scrolling region,
    // modes, the pwd, modifyOtherKeys, the kitty flags, a G1 charset, a palette colour.
    primary.write(&[b'w'; 130]);
    primary.write(b"\r\n\x1b[3g\x1b[5G\x1bH\x1b[17G\x1bH\r\tA\tB\r\n");
    primary.write(b"\x1b[?1h\x1b[?2004h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?25l");
    primary.write(b"\x1b]7;kitty-shell-cwd://host/tmp/repaint\x1b\\\x1b[>4;2m\x1b[>13u");
    primary.write(b"\x1b)0\x0elqqk\x0f\x1b]4;1;rgb:12/34/56\x1b\\\x1b]2;title\x07");
    primary.write(b"\x1b]133;A\x07$ \x1b]133;B\x07make\r\n\x1b]133;C\x07\x1b]9;4;1;50\x07");
    primary.write(b"\x1b[2;20r\x1b[10;5Hparked");

    let mut alternate = sized_terminal(80, 24);
    alternate.write(b"shell history\r\n$ vim\r\n\x1b[?1049h\x1b[2J\x1b[H\x1b[7mTUI\x1b[0m");
    alternate.write(b"\x1b[5;3H\x1b[1;35mbody\x1b[0m\x1b[3;12r\x1b[12;40H");

    let mut image = sized_terminal(20, 10);
    image.write(b"before\r\n");
    image.write(&raw_image(7, 20, 40));
    image.write(b"\r\nafter");

    let mut out = Vec::new();
    let mut section = |name: &str, bytes: &[u8]| {
        out.extend_from_slice(format!("\n=== {name} ({} bytes)\n", bytes.len()).as_bytes());
        out.extend_from_slice(bytes);
    };
    for (name, terminal) in [("primary", &primary), ("alternate", &alternate)] {
        section(&format!("{name} replay"), &terminal.replay());
        section(&format!("{name} extras"), &terminal.format_rows(true, None));
        section(
            &format!("{name} extras tail 10"),
            &terminal.format_rows(true, Some(10)),
        );
        section(&format!("{name} cells"), &terminal.format_rows(false, None));
        section(&format!("{name} text"), terminal.visible_text().as_bytes());
    }
    section("image replay", &image.replay());
    let images = image.visible_images();
    assert_eq!(images.len(), 1, "the fixture's image is not visible");
    let pixels = image.pixels(images[0]).expect("pixels");
    section(
        "image pixels",
        &[
            format!("{}x{} {:?}\n", pixels.width, pixels.height, pixels.color).as_bytes(),
            &pixels.data,
        ]
        .concat(),
    );
    section("image placement", &ready(image.placement(7, true)));
    out
}

/// Value: protects=the repaint bytes stay the same across an engine bump that should not change
/// them (vt-1.0.0 moved the formatter's options to keys, with new defaults); fails_when=TRIM or an
/// extra the shadow does not ask for is left at libghostty's default, or the image pixels are read
/// short; why_new=the round-trip tests compare state, not bytes, so a trimmed or restyled repaint
/// could still pass them; seam=none; no_claim=that the golden bytes are correct, only unchanged.
///
/// When a bump changes them on purpose, read the diff, then rewrite the file with
/// `WR_WRITE_REPAINT_GOLDEN=1`.
#[test]
fn repaint_golden_matches() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/src/terminal/vt/repaint.golden"
    );
    let actual = repaint_golden();
    if std::env::var_os("WR_WRITE_REPAINT_GOLDEN").is_some() {
        std::fs::write(path, &actual).expect("write the golden");
        return;
    }
    let expected = std::fs::read(path).expect("read the golden");
    if let Some(at) = actual.iter().zip(&expected).position(|(a, b)| a != b) {
        let from = at.saturating_sub(80);
        panic!(
            "the repaint differs from {path} at byte {at}:\n expected {:?}\n actual   {:?}",
            String::from_utf8_lossy(&expected[from..(at + 80).min(expected.len())]),
            String::from_utf8_lossy(&actual[from..(at + 80).min(actual.len())]),
        );
    }
    assert_eq!(
        actual.len(),
        expected.len(),
        "the repaint's length differs from {path}"
    );
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
