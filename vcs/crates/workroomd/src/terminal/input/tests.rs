use super::*;

fn user(bytes: &[u8]) -> bool {
    InputClassifier::new().is_user_input(bytes)
}

#[test]
fn typing_is_the_user() {
    assert!(user(b"a"));
    assert!(user(b"hello\r"));
    assert!(user(&[0x03]), "Ctrl-C");
    assert!(user(&[0x7F]), "backspace");
}

#[test]
fn arrow_keys_are_the_user() {
    assert!(user(b"\x1b[A"));
    assert!(user(b"\x1b[1;5C"), "Ctrl-Right");
    assert!(user(b"\x1bOA"), "application-mode Up");
    assert!(user(b"\x1b[3~"), "Delete");
}

#[test]
fn a_bare_escape_and_alt_keys_are_the_user() {
    assert!(!user(b"\x1b"), "a lone ESC is incomplete, not yet input");
    assert!(user(b"\x1bb"), "Alt-b");
}

/// The whole reason this module exists: a terminal answers on the input channel.
/// DECRPM: a TUI asking whether synchronized output is on gets this back on a timer, with
/// nobody at the keyboard. Counting it as the user would hand the size to a window nobody is in.
#[test]
fn mode_reports_are_not_the_user() {
    assert!(!user(b"\x1b[?2026;1$y"));
    assert!(!user(b"\x1b[?2004;2$y"));
    assert!(!user(b"\x1b[?2026;0$y"));
    assert!(
        user(b"\x1b[?2026;1y"),
        "no `$`: not a report, whatever it is"
    );
}

#[test]
fn focus_reports_are_not_the_user() {
    assert!(!user(b"\x1b[I"), "focus in");
    assert!(!user(b"\x1b[O"), "focus out");
}

#[test]
fn cursor_and_device_reports_are_not_the_user() {
    assert!(!user(b"\x1b[24;80R"), "cursor position report");
    assert!(!user(b"\x1b[0n"), "device status report");
    assert!(!user(b"\x1b[?62;1;4c"), "primary device attributes");
    assert!(!user(b"\x1b[>1;95;0c"), "secondary device attributes");
    assert!(!user(b"\x1b[8;24;80t"), "window size report");
}

#[test]
fn colour_and_clipboard_answers_are_not_the_user() {
    assert!(
        !user(b"\x1b]11;rgb:1e1e/1e1e/1e1e\x07"),
        "background colour, BEL-terminated"
    );
    assert!(
        !user(b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\"),
        "foreground colour, ST-terminated"
    );
    assert!(!user(b"\x1b]52;c;aGVsbG8=\x1b\\"), "clipboard read");
}

#[test]
fn device_control_answers_are_not_the_user() {
    assert!(
        !user(b"\x1bP!|00000000\x1b\\"),
        "tertiary device attributes"
    );
    assert!(!user(b"\x1bP>|ghostty 1.2.3\x1b\\"), "XTVERSION");
    assert!(!user(b"\x1bP1+r626c=5c45\x1b\\"), "XTGETTCAP reply");
}

/// One character apart, opposite meanings — and getting it backwards would either make every
/// keystroke silent or make a protocol handshake claim the session.
#[test]
fn kitty_flags_are_not_the_user_but_kitty_keys_are() {
    assert!(!user(b"\x1b[?5u"), "keyboard protocol flags report");
    assert!(user(b"\x1b[97;5u"), "Ctrl-a as a kitty key event");
}

#[test]
fn wheel_scroll_is_not_the_user_but_a_click_is() {
    assert!(!user(b"\x1b[<64;10;20M"), "SGR wheel up");
    assert!(!user(b"\x1b[<65;10;20M"), "SGR wheel down");
    assert!(user(b"\x1b[<0;10;20M"), "SGR left click");
    assert!(user(b"\x1b[<0;10;20m"), "SGR release");
    assert!(user(b"\x1b[<2;10;20M"), "SGR right click");
}

#[test]
fn normal_mode_mouse_reports_follow_the_same_rule() {
    // `CSI M` then button+32, x+32, y+32.
    assert!(!user(&[0x1b, b'[', b'M', 32 + 64, 33, 33]), "wheel up");
    assert!(user(&[0x1b, b'[', b'M', 32, 33, 33]), "left click");
}

/// Coordinates can contain bytes that look like the start of a sequence; parsing them as one
/// would both lose the click and misread whatever followed.
#[test]
fn mouse_coordinates_are_not_parsed_as_escapes() {
    let mut classifier = InputClassifier::new();
    assert!(
        !classifier.is_user_input(&[0x1b, b'[', b'M', 32 + 64, 0x1b, b'[']),
        "a wheel report whose coordinates happen to be ESC and ["
    );
    assert!(
        classifier.is_user_input(b"x"),
        "and the stream is still in step"
    );
}

/// The reason state is carried between calls: a frame boundary must not turn half a report
/// into a keystroke.
#[test]
fn a_report_split_across_frames_is_still_not_the_user() {
    let mut classifier = InputClassifier::new();
    assert!(!classifier.is_user_input(b"\x1b[24"));
    assert!(!classifier.is_user_input(b";80R"));
}

#[test]
fn a_keystroke_split_across_frames_is_still_the_user() {
    let mut classifier = InputClassifier::new();
    assert!(!classifier.is_user_input(b"\x1b["));
    assert!(classifier.is_user_input(b"A"));
}

/// A report and a keystroke in one frame is the user — the keystroke is what matters, and
/// returning at the first one would leave the parser mid-sequence.
#[test]
fn a_keystroke_alongside_a_report_still_counts() {
    let mut classifier = InputClassifier::new();
    assert!(classifier.is_user_input(b"\x1b[Ihello"));
    assert!(
        classifier.is_user_input(b"x"),
        "and the parser is back in step"
    );
}

/// Pasted text is the user, including text that contains escape characters.
#[test]
fn a_bracketed_paste_is_the_user() {
    assert!(user(b"\x1b[200~some text\x1b[201~"));
}

/// A client controls this stream and the daemon is shared, so an unterminated sequence must not
/// be able to grow the daemon's memory. Bytes arrive in many frames here because that is the
/// shape of the attack — one `ESC [` and then an endless tail.
///
/// What it does NOT assert is that the flood counts as nothing. Past the cap the sequence is
/// abandoned and the parser returns to ground, where those bytes are ordinary input — which is
/// the honest answer, because `write_input` passes them to the shell either way. A client
/// sending the pty ten thousand bytes IS acting on the session; the bug being fixed here is
/// the unbounded buffer, not the classification.
#[test]
fn an_unterminated_sequence_cannot_grow_without_bound() {
    let mut classifier = InputClassifier::new();
    assert!(!classifier.is_user_input(b"\x1b["));
    for _ in 0..1000 {
        classifier.is_user_input(&[b'1'; 64]);
        assert!(
            classifier.params.len() <= MAX_PARAMETERS,
            "parameters grew to {}",
            classifier.params.len()
        );
    }
    // And the parser is still usable rather than wedged mid-sequence.
    assert!(classifier.is_user_input(b"x"));
    assert!(!classifier.is_user_input(b"\x1b[I"), "still reads a report");
}

/// Abandoning past the cap must not leave the tail readable as a legitimate sequence. A cap
/// that merely stopped pushing — staying in `ControlSequence` — would let an attacker pad past
/// it and then have `I` classified as a focus report, which is the one answer this module
/// exists to get right.
#[test]
fn an_abandoned_sequence_does_not_classify_by_its_tail() {
    let mut classifier = InputClassifier::new();
    let mut flood = vec![0x1b, b'['];
    flood.extend(std::iter::repeat_n(b'1', MAX_PARAMETERS + 10));
    classifier.is_user_input(&flood);
    assert_eq!(
        classifier.state,
        State::Ground,
        "the sequence was abandoned"
    );
    // In ground, `I` is a printable character the user typed — not a focus report.
    assert!(classifier.is_user_input(b"I"));
}

#[test]
fn nothing_at_all_is_not_the_user() {
    assert!(!user(b""));
}
