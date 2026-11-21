use super::*;

const LEGACY: Modes = Modes {
    kitty_flags: 0,
    application_cursor_keys: false,
    bracketed_paste: false,
};

const APPLICATION: Modes = Modes {
    application_cursor_keys: true,
    ..LEGACY
};

const fn kitty(flags: u32) -> Modes {
    Modes {
        kitty_flags: flags,
        ..LEGACY
    }
}

/// Every row's key, encoded for its modes, is the bytes the published encoding gives it.
fn check(rows: &[(&str, Modes, &[u8])]) {
    for (name, modes, expected) in rows {
        let key = Key::parse(name).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            key.encode(*modes),
            expected.to_vec(),
            "{name} under {modes:?}: {:?} is not {:?}",
            String::from_utf8_lossy(&key.encode(*modes)),
            String::from_utf8_lossy(expected),
        );
    }
}

/// xterm's control sequences ("PC-Style Function Keys" and "Alt and Meta Keys" in ctlseqs), as
/// Ghostty's `function_keys.zig` sends them with no kitty flags and modifyOtherKeys off: cursor
/// keys, Home and End as `CSI` normally and `SS3` under DECCKM when no modifier is held, `CSI 1;m`
/// with one (m = 1 + Shift 1, Alt 2, Ctrl 4, Super 8), the editing keys and F5 to F12 as `CSI n~`,
/// F1 to F4 as `SS3`, modified F3 as `CSI 13;m~`.
#[test]
fn legacy_function_and_cursor_keys_are_xterms() {
    check(&[
        ("Up", LEGACY, b"\x1b[A"),
        ("Down", LEGACY, b"\x1b[B"),
        ("Right", LEGACY, b"\x1b[C"),
        ("Left", LEGACY, b"\x1b[D"),
        ("Home", LEGACY, b"\x1b[H"),
        ("End", LEGACY, b"\x1b[F"),
        ("Up", APPLICATION, b"\x1bOA"),
        ("Down", APPLICATION, b"\x1bOB"),
        ("Right", APPLICATION, b"\x1bOC"),
        ("Left", APPLICATION, b"\x1bOD"),
        ("Home", APPLICATION, b"\x1bOH"),
        ("End", APPLICATION, b"\x1bOF"),
        // A modifier is `CSI 1;m` whatever DECCKM says.
        ("Shift+Up", LEGACY, b"\x1b[1;2A"),
        ("Shift+Up", APPLICATION, b"\x1b[1;2A"),
        ("Alt+Left", LEGACY, b"\x1b[1;3D"),
        ("Ctrl+Right", APPLICATION, b"\x1b[1;5C"),
        ("Ctrl+Shift+Home", LEGACY, b"\x1b[1;6H"),
        ("Super+End", LEGACY, b"\x1b[1;9F"),
        ("Ctrl+Alt+Shift+Super+Down", LEGACY, b"\x1b[1;16B"),
        ("Insert", LEGACY, b"\x1b[2~"),
        ("Delete", APPLICATION, b"\x1b[3~"),
        ("PageUp", LEGACY, b"\x1b[5~"),
        ("PageDown", LEGACY, b"\x1b[6~"),
        ("Ctrl+Delete", LEGACY, b"\x1b[3;5~"),
        ("Shift+PageUp", LEGACY, b"\x1b[5;2~"),
        ("F1", LEGACY, b"\x1bOP"),
        ("F2", LEGACY, b"\x1bOQ"),
        ("F3", LEGACY, b"\x1bOR"),
        ("F4", APPLICATION, b"\x1bOS"),
        ("Shift+F1", LEGACY, b"\x1b[1;2P"),
        ("Ctrl+F2", LEGACY, b"\x1b[1;5Q"),
        ("Shift+F3", LEGACY, b"\x1b[13;2~"),
        ("Alt+F4", LEGACY, b"\x1b[1;3S"),
        ("F5", LEGACY, b"\x1b[15~"),
        ("F6", LEGACY, b"\x1b[17~"),
        ("F7", LEGACY, b"\x1b[18~"),
        ("F8", LEGACY, b"\x1b[19~"),
        ("F9", LEGACY, b"\x1b[20~"),
        ("F10", LEGACY, b"\x1b[21~"),
        ("F11", LEGACY, b"\x1b[23~"),
        ("F12", LEGACY, b"\x1b[24~"),
        ("Ctrl+F5", LEGACY, b"\x1b[15;5~"),
        ("Shift+F12", LEGACY, b"\x1b[24;2~"),
    ]);
}

/// The keys that type a byte: Enter is CR, Tab HT and Shift+Tab `CSI Z` (xterm's back tab),
/// Backspace DEL and Ctrl+Backspace BS, Escape ESC; Ctrl with a letter its C0 control, and with
/// `@`, space, `[`, `\`, `]`, `^`, `_`, `?` or a digit from 2 to 8 VT220's; Alt puts ESC before
/// the key (xterm's `metaSendsEscape`, Ghostty's Alt). Ctrl with a character no control has types
/// the character, as a terminal with modifyOtherKeys off does.
#[test]
fn legacy_keys_that_type_a_byte_are_c0_controls_and_alt_prefixes_escape() {
    check(&[
        ("Enter", LEGACY, b"\r"),
        ("Enter", APPLICATION, b"\r"),
        ("Alt+Enter", LEGACY, b"\x1b\r"),
        ("Ctrl+Enter", LEGACY, b"\r"),
        ("Tab", LEGACY, b"\t"),
        ("Shift+Tab", LEGACY, b"\x1b[Z"),
        ("Alt+Tab", LEGACY, b"\x1b\t"),
        ("Backspace", LEGACY, b"\x7f"),
        ("Ctrl+Backspace", LEGACY, b"\x08"),
        ("Alt+Backspace", LEGACY, b"\x1b\x7f"),
        ("Escape", LEGACY, b"\x1b"),
        ("Esc", LEGACY, b"\x1b"),
        ("Alt+Escape", LEGACY, b"\x1b\x1b"),
        ("Space", LEGACY, b" "),
        ("Ctrl+Space", LEGACY, b"\x00"),
        ("Alt+Space", LEGACY, b"\x1b "),
        ("Ctrl+C", LEGACY, b"\x03"),
        ("ctrl+c", LEGACY, b"\x03"),
        ("Ctrl+a", LEGACY, b"\x01"),
        ("Ctrl+z", LEGACY, b"\x1a"),
        ("Ctrl+Shift+A", LEGACY, b"\x01"),
        ("Ctrl+@", LEGACY, b"\x00"),
        ("Ctrl+2", LEGACY, b"\x00"),
        ("Ctrl+[", LEGACY, b"\x1b"),
        ("Ctrl+3", LEGACY, b"\x1b"),
        ("Ctrl+\\", LEGACY, b"\x1c"),
        ("Ctrl+]", LEGACY, b"\x1d"),
        ("Ctrl+^", LEGACY, b"\x1e"),
        ("Ctrl+_", LEGACY, b"\x1f"),
        ("Ctrl+/", LEGACY, b"\x1f"),
        ("Ctrl+?", LEGACY, b"\x7f"),
        ("Ctrl+8", LEGACY, b"\x7f"),
        ("Ctrl+1", LEGACY, b"1"),
        ("Ctrl+Alt+x", LEGACY, b"\x1b\x18"),
        ("Alt+b", LEGACY, b"\x1bb"),
        ("Alt+B", LEGACY, b"\x1bb"),
        ("Alt+Shift+b", LEGACY, b"\x1bB"),
        ("a", LEGACY, b"a"),
        ("A", LEGACY, b"A"),
        ("Shift+a", LEGACY, b"A"),
        ("Super+a", LEGACY, b"a"),
        ("+", LEGACY, b"+"),
        ("Alt++", LEGACY, b"\x1b+"),
        ("é", LEGACY, "é".as_bytes()),
    ]);
}

/// The kitty keyboard protocol's "Disambiguate escape codes" (flag 1): Escape, and a key with
/// Alt, Ctrl or Super, as `CSI code;m u` (the unshifted key's codepoint); functional keys as
/// `CSI number;m ~` or `CSI 1;m X`, the 1 left out with no modifier, never `SS3` (Ghostty consults
/// DECCKM only in the legacy encoding); F3 as `CSI 13~`. Enter, Tab and Backspace with no
/// modifier, and a key that types text with at most Shift, stay as they were.
#[test]
fn kitty_flags_disambiguate_keys_as_csi_u() {
    let one = kitty(0b1);
    let decckm = Modes {
        kitty_flags: 0b1,
        ..APPLICATION
    };
    check(&[
        ("Escape", one, b"\x1b[27u"),
        ("Alt+Escape", one, b"\x1b[27;3u"),
        ("Enter", one, b"\r"),
        ("Tab", one, b"\t"),
        ("Backspace", one, b"\x7f"),
        ("Shift+Enter", one, b"\x1b[13;2u"),
        ("Ctrl+Enter", one, b"\x1b[13;5u"),
        ("Shift+Tab", one, b"\x1b[9;2u"),
        ("Ctrl+Backspace", one, b"\x1b[127;5u"),
        ("Ctrl+C", one, b"\x1b[99;5u"),
        ("Ctrl+c", one, b"\x1b[99;5u"),
        ("Alt+a", one, b"\x1b[97;3u"),
        ("Ctrl+Alt+a", one, b"\x1b[97;7u"),
        ("Ctrl+Shift+a", one, b"\x1b[97;6u"),
        ("Super+s", one, b"\x1b[115;9u"),
        ("Ctrl+Space", one, b"\x1b[32;5u"),
        ("Ctrl+1", one, b"\x1b[49;5u"),
        ("a", one, b"a"),
        ("A", one, b"A"),
        ("Shift+a", one, b"A"),
        ("Space", one, b" "),
        ("Up", one, b"\x1b[A"),
        ("Up", decckm, b"\x1b[A"),
        ("Home", decckm, b"\x1b[H"),
        ("End", one, b"\x1b[F"),
        ("Shift+Down", one, b"\x1b[1;2B"),
        ("Ctrl+Left", decckm, b"\x1b[1;5D"),
        ("Insert", one, b"\x1b[2~"),
        ("Delete", one, b"\x1b[3~"),
        ("Shift+Delete", one, b"\x1b[3;2~"),
        ("PageUp", one, b"\x1b[5~"),
        ("PageDown", one, b"\x1b[6~"),
        ("F1", one, b"\x1b[P"),
        ("F2", one, b"\x1b[Q"),
        ("F3", one, b"\x1b[13~"),
        ("F4", one, b"\x1b[S"),
        ("Ctrl+F1", one, b"\x1b[1;5P"),
        ("Shift+F3", one, b"\x1b[13;2~"),
        ("F5", one, b"\x1b[15~"),
        ("F12", one, b"\x1b[24~"),
        ("Alt+F10", one, b"\x1b[21;3~"),
    ]);
}

/// "Report event types" (flag 2) changes nothing a press sends, since a press is the default
/// event and only a press is sent. "Report all keys as escape codes" (flag 8) sends Enter, Tab,
/// Backspace and text keys as `CSI code u` too; "Report alternate keys" (flag 4) adds the shifted
/// key after a colon when Shift is held, and "Report associated text" (flag 16, with 8) the text
/// as codepoints in a third field, the modifier field left empty when there is none. Text keys
/// with Ctrl, Alt or Super carry no text.
#[test]
fn kitty_flags_report_every_key_its_shifted_key_and_its_text_when_asked() {
    let events = kitty(0b11);
    let all = kitty(0b1001);
    let alternates = kitty(0b1101);
    let text = kitty(0b11001);
    let everything = kitty(0b11111);
    check(&[
        ("Escape", events, b"\x1b[27u"),
        ("Ctrl+c", events, b"\x1b[99;5u"),
        ("Enter", events, b"\r"),
        ("a", events, b"a"),
        ("Up", events, b"\x1b[A"),
        ("Enter", all, b"\x1b[13u"),
        ("Tab", all, b"\x1b[9u"),
        ("Backspace", all, b"\x1b[127u"),
        ("Shift+Enter", all, b"\x1b[13;2u"),
        ("a", all, b"\x1b[97u"),
        ("A", all, b"\x1b[97;2u"),
        ("Space", all, b"\x1b[32u"),
        ("Ctrl+c", all, b"\x1b[99;5u"),
        ("1", all, b"\x1b[49u"),
        ("Up", all, b"\x1b[A"),
        ("F5", all, b"\x1b[15~"),
        ("Shift+a", alternates, b"\x1b[97:65;2u"),
        ("Ctrl+Shift+a", alternates, b"\x1b[97:65;6u"),
        ("a", alternates, b"\x1b[97u"),
        ("Shift+1", alternates, b"\x1b[49;2u"),
        ("a", text, b"\x1b[97;;97u"),
        ("Shift+a", text, b"\x1b[97;2;65u"),
        ("Ctrl+a", text, b"\x1b[97;5u"),
        ("Space", text, b"\x1b[32;;32u"),
        ("Enter", text, b"\x1b[13u"),
        ("Shift+a", everything, b"\x1b[97:65;2;65u"),
        ("Alt+a", everything, b"\x1b[97;3u"),
    ]);
}

/// A name is its modifiers, each with a `+`, then the key, any case; anything else is refused,
/// naming what was wrong.
#[test]
fn a_key_name_is_its_modifiers_then_the_key_and_nothing_else() {
    for name in [
        "ENTER",
        "enter",
        "PageDown",
        "pagedown",
        "f12",
        "CTRL+SHIFT+UP",
    ] {
        assert!(Key::parse(name).is_ok(), "{name}");
    }
    assert_eq!(Key::parse("Enter"), Ok(Key::ENTER));
    assert_eq!(Key::parse("A"), Key::parse("Shift+a"));
    assert_eq!(Key::parse("Ctrl+C"), Key::parse("ctrl+c"));
    for (name, says) in [
        ("", "is no key"),
        ("Hyper+a", "is no modifier"),
        ("Ctrl+", "is no key"),
        ("Ctrl+Shift+", "is no key"),
        ("F0", "is no key"),
        ("F13", "is no key"),
        ("F01", "is no key"),
        ("Return", "is no key"),
        ("ab", "is no key"),
        ("\u{7}", "control character"),
        ("Ctrl+\u{1b}", "control character"),
    ] {
        let error = Key::parse(name).expect_err(name);
        assert!(error.contains(says), "{name:?}: {error}");
    }
}

/// Bracketed paste (xterm's `CSI ? 2004 h`) wraps the text in `CSI 200 ~` and `CSI 201 ~`; off,
/// and for no text, the text goes as it is.
#[test]
fn text_is_wrapped_in_a_paste_only_for_a_program_that_turned_it_on() {
    assert_eq!(
        pasted("ls\necho hi", true),
        b"\x1b[200~ls\necho hi\x1b[201~"
    );
    assert_eq!(pasted("ls\necho hi", false), b"ls\necho hi");
    assert_eq!(pasted("", true), b"");
}
