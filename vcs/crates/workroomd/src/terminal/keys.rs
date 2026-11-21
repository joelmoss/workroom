//! Named keys as the bytes a terminal sends for them (#689, `terminal.send`): `Enter`, `Ctrl+C`,
//! `Up`, `Shift+F5`, encoded for the keyboard modes the session's program has turned on, as the
//! pane's own terminal (Ghostty) would send them, so a key reaches vim, Claude Code or a shell the
//! way a keystroke does.
//!
//! **Two encodings.** With no kitty keyboard flags, the legacy one: xterm's PC-style function keys
//! (`CSI A`, `CSI 1;5A`, `CSI 15~`), cursor keys and Home/End as `SS3` under application cursor
//! keys (DECCKM) when no modifier is held, C0 controls for Ctrl with a character, and Escape before
//! a key for Alt; Enter, Tab and Escape with any other modifiers as Ghostty's `function_keys.zig`
//! has them, `CSI 27;m;13~` (Shift+Enter), `CSI 27;5;9~` (Ctrl+Tab), but for Shift+Tab's `CSI Z`.
//! With any kitty flag, the kitty keyboard protocol's (`CSI 99;5u`): Ghostty
//! consults DECCKM only for the legacy encoding, so none of a kitty encoding is `SS3`. Enter, Tab
//! and Backspace with no modifier stay legacy bytes, and a key that types text with nothing but
//! Shift stays its text, unless the program asked for every key as an escape code (flag 8). That
//! one is told the shifted key (flag 4) and the text (flag 16) when it asked for them.
//!
//! **What is left out.** A press only, never a release, whatever flag 2 (report event types)
//! says: a release is no keystroke of its own, and programs that ask for them take a press alone.
//! xterm's modifyOtherKeys is not tracked: keys are encoded as Ghostty encodes them with it off
//! (mode 2 changes Alt with Enter, Tab or Escape, and every modified Backspace). No keypad keys, and no keyboard layout: Shift with a character other than
//! a letter is that character, with Shift reported only where the kitty encoding has a place for
//! it.
//!
//! **Names.** Modifiers `Ctrl`, `Alt`, `Shift` and `Super` before the key, each with a `+`
//! (`Ctrl+Shift+Up`). Keys `Enter`, `Tab`, `Escape` (or `Esc`), `Backspace`, `Space`, `Up`,
//! `Down`, `Left`, `Right`, `Home`, `End`, `Insert`, `Delete`, `PageUp`, `PageDown` and `F1` to
//! `F12`, or one character. Names and modifiers are any case; so is a letter with a modifier
//! (`Ctrl+C` is `Ctrl+c`), while a letter alone is the one typed (`A` is `Shift+a`).

/// The session's input modes what it is sent depends on, as its shadow terminal knows them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modes {
    /// The active screen's kitty keyboard flags (`CSI > flags u`); 0 for the legacy encoding.
    pub kitty_keyboard_flags: u32,
    /// DECCKM (`CSI ? 1 h`): unmodified cursor keys, Home and End as `SS3`.
    pub application_cursor_keys: bool,
    /// `CSI ? 2004 h`: text goes as a bracketed paste ([`pasted`]). No key depends on it.
    pub bracketed_paste: bool,
}

/// Kitty keyboard protocol flags (its "progressive enhancement" bits).
mod kitty {
    /// Every key as an escape code, text keys and Enter, Tab and Backspace included.
    pub const REPORT_ALL: u32 = 0b1000;
    /// The shifted key beside the key, as `code:shifted`.
    pub const ALTERNATES: u32 = 0b100;
    /// The text a key types, as codepoints, with `REPORT_ALL`.
    pub const ASSOCIATED_TEXT: u32 = 0b1_0000;
}

/// One key and the modifiers held with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Key {
    code: Code,
    mods: Mods,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Code {
    /// A key that types a character: a letter (lower case), a digit, punctuation, a space.
    Char(char),
    Enter,
    Tab,
    Backspace,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    Insert,
    Delete,
    PageUp,
    PageDown,
    /// F1 to F12.
    F(u8),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct Mods {
    shift: bool,
    alt: bool,
    ctrl: bool,
    super_: bool,
}

impl Mods {
    /// The modifier parameter of xterm and the kitty protocol alike: 1 plus Shift 1, Alt 2,
    /// Ctrl 4 and Super 8.
    fn parameter(self) -> u32 {
        1 + u32::from(self.shift)
            + 2 * u32::from(self.alt)
            + 4 * u32::from(self.ctrl)
            + 8 * u32::from(self.super_)
    }

    fn any(self) -> bool {
        self.parameter() > 1
    }
}

/// The names of the keys that are no character, lower case, and the code of each.
const NAMED: &[(&str, Code)] = &[
    ("enter", Code::Enter),
    ("tab", Code::Tab),
    ("escape", Code::Escape),
    ("esc", Code::Escape),
    ("backspace", Code::Backspace),
    ("space", Code::Char(' ')),
    ("up", Code::Up),
    ("down", Code::Down),
    ("left", Code::Left),
    ("right", Code::Right),
    ("home", Code::Home),
    ("end", Code::End),
    ("insert", Code::Insert),
    ("delete", Code::Delete),
    ("pageup", Code::PageUp),
    ("pagedown", Code::PageDown),
];

impl Key {
    /// The key `name` names, or why it names none.
    pub fn parse(name: &str) -> Result<Key, String> {
        let mut mods = Mods::default();
        let mut rest = name;
        // Each `Modifier+` in front; what follows the last is the key, which may be `+` itself.
        while let Some(plus) = rest
            .get(1..)
            .and_then(|after| after.find('+'))
            .map(|at| at + 1)
        {
            let (modifier, after) = (&rest[..plus], &rest[plus + 1..]);
            if after.is_empty() {
                break;
            }
            let held = match modifier.to_ascii_lowercase().as_str() {
                "ctrl" => &mut mods.ctrl,
                "alt" => &mut mods.alt,
                "shift" => &mut mods.shift,
                "super" => &mut mods.super_,
                _ => {
                    return Err(format!(
                        "{name:?}: {modifier:?} is no modifier (Ctrl, Alt, Shift or Super)"
                    ));
                }
            };
            *held = true;
            rest = after;
        }
        let lower = rest.to_ascii_lowercase();
        let code = if let Some((_, code)) = NAMED.iter().find(|(named, _)| *named == lower) {
            *code
        } else if let Some(number) = lower
            .strip_prefix('f')
            .and_then(|number| number.parse::<u8>().ok())
            .filter(|number| (1..=12).contains(number) && !lower.starts_with("f0"))
        {
            Code::F(number)
        } else {
            let mut chars = rest.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) if c.is_control() => {
                    return Err(format!("{name:?}: a control character is no key name"));
                }
                (Some(c), None) if c.is_ascii_uppercase() => {
                    // Alone, the letter typed; with a modifier, any case.
                    if !mods.any() {
                        mods.shift = true;
                    }
                    Code::Char(c.to_ascii_lowercase())
                }
                (Some(c), None) => Code::Char(c),
                _ => {
                    return Err(format!(
                        "{name:?} is no key: name one of Enter, Tab, Escape, Backspace, Space, \
                         Up, Down, Left, Right, Home, End, Insert, Delete, PageUp, PageDown or \
                         F1 to F12, or one character, after any of Ctrl+, Alt+, Shift+ and Super+"
                    ));
                }
            }
        };
        Ok(Key { code, mods })
    }

    /// Enter, as `--enter` sends it.
    pub const ENTER: Key = Key {
        code: Code::Enter,
        mods: Mods {
            shift: false,
            alt: false,
            ctrl: false,
            super_: false,
        },
    };

    /// The bytes a terminal in `modes` sends for this key.
    pub fn encode(self, modes: Modes) -> Vec<u8> {
        if modes.kitty_keyboard_flags == 0 {
            self.legacy(modes.application_cursor_keys)
        } else {
            self.kitty(modes.kitty_keyboard_flags)
        }
    }

    /// The text the key types: its character, a letter in upper case with Shift.
    fn text(self) -> Option<char> {
        match self.code {
            Code::Char(c) if self.mods.shift => Some(c.to_ascii_uppercase()),
            Code::Char(c) => Some(c),
            _ => None,
        }
    }

    /// xterm's encoding, as Ghostty sends it with no kitty flags and modifyOtherKeys off.
    fn legacy(self, application_cursor_keys: bool) -> Vec<u8> {
        let Key { code, mods } = self;
        let alt = |bytes: Vec<u8>| -> Vec<u8> {
            if mods.alt {
                [b"\x1b".as_slice(), &bytes].concat()
            } else {
                bytes
            }
        };
        let parameter = mods.parameter();
        // `CSI 1;m X` with a modifier; else `CSI X`, or `SS3 X` where `ss3` says.
        let letter = |last: char, ss3: bool| -> Vec<u8> {
            if parameter > 1 {
                format!("\x1b[1;{parameter}{last}").into_bytes()
            } else if ss3 {
                format!("\x1bO{last}").into_bytes()
            } else {
                format!("\x1b[{last}").into_bytes()
            }
        };
        let tilde = |number: u32| -> Vec<u8> {
            if parameter > 1 {
                format!("\x1b[{number};{parameter}~").into_bytes()
            } else {
                format!("\x1b[{number}~").into_bytes()
            }
        };
        match code {
            Code::Char(c) => {
                let text = self.text().unwrap_or(c);
                let typed = match control(c).filter(|_| mods.ctrl) {
                    Some(byte) => vec![byte],
                    None => text.to_string().into_bytes(),
                };
                alt(typed)
            }
            // Ghostty's `function_keys.zig`: Alt alone puts ESC before the key, Shift+Tab is
            // xterm's back tab, and every other modified Enter, Tab or Escape is `CSI 27;m;code~`.
            // Backspace keeps its byte, BS with Ctrl, ESC before it with Alt, whatever else is held.
            Code::Enter | Code::Tab | Code::Escape if mods.any() && !alt_only(mods) => match code {
                Code::Tab if shift_only(mods) => b"\x1b[Z".to_vec(),
                _ => {
                    let number = match code {
                        Code::Enter => 13,
                        Code::Tab => 9,
                        _ => 27,
                    };
                    format!("\x1b[27;{parameter};{number}~").into_bytes()
                }
            },
            Code::Enter => alt(b"\r".to_vec()),
            Code::Tab => alt(b"\t".to_vec()),
            Code::Backspace if mods.ctrl => alt(vec![0x08]),
            Code::Backspace => alt(vec![0x7f]),
            Code::Escape => alt(b"\x1b".to_vec()),
            Code::Up => letter('A', application_cursor_keys),
            Code::Down => letter('B', application_cursor_keys),
            Code::Right => letter('C', application_cursor_keys),
            Code::Left => letter('D', application_cursor_keys),
            Code::Home => letter('H', application_cursor_keys),
            Code::End => letter('F', application_cursor_keys),
            Code::Insert => tilde(2),
            Code::Delete => tilde(3),
            Code::PageUp => tilde(5),
            Code::PageDown => tilde(6),
            Code::F(1) => letter('P', true),
            Code::F(2) => letter('Q', true),
            // Modified, `CSI 13;m~`, as Ghostty sends it: `CSI 1;m R` would read as a cursor
            // position report.
            Code::F(3) if parameter > 1 => tilde(13),
            Code::F(3) => letter('R', true),
            Code::F(4) => letter('S', true),
            Code::F(number) => tilde(function_number(number)),
        }
    }

    /// The kitty keyboard protocol's encoding, for a program that pushed `flags`.
    fn kitty(self, flags: u32) -> Vec<u8> {
        let Key { code, mods } = self;
        let report_all = flags & kitty::REPORT_ALL != 0;
        let parameter = mods.parameter();
        // `CSI number [; m] u|~`, the modifier left out when there is none.
        let csi = |number: u32, last: char, extra: &str| -> Vec<u8> {
            let mut out = format!("\x1b[{number}{extra}");
            if parameter > 1 {
                out.push_str(&format!(";{parameter}"));
            }
            out.push(last);
            out.into_bytes()
        };
        let letter = |last: char| -> Vec<u8> {
            if parameter > 1 {
                format!("\x1b[1;{parameter}{last}").into_bytes()
            } else {
                format!("\x1b[{last}").into_bytes()
            }
        };
        let plain = !mods.any() && !report_all;
        match code {
            Code::Enter if plain => b"\r".to_vec(),
            Code::Tab if plain => b"\t".to_vec(),
            Code::Backspace if plain => vec![0x7f],
            Code::Enter => csi(13, 'u', ""),
            Code::Tab => csi(9, 'u', ""),
            Code::Backspace => csi(127, 'u', ""),
            Code::Escape => csi(27, 'u', ""),
            Code::Char(c) => {
                let text = self.text().unwrap_or(c);
                // A key that types text with at most Shift types it, unless every key is asked
                // for as an escape code.
                let bound = mods.alt || mods.ctrl || mods.super_;
                if !bound && !report_all {
                    return text.to_string().into_bytes();
                }
                let mut out = format!("\x1b[{}", u32::from(c));
                if flags & kitty::ALTERNATES != 0 && mods.shift && text != c {
                    out.push_str(&format!(":{}", u32::from(text)));
                }
                let associated = flags & kitty::ASSOCIATED_TEXT != 0 && report_all && !bound;
                if parameter > 1 {
                    out.push_str(&format!(";{parameter}"));
                } else if associated {
                    out.push(';');
                }
                if associated {
                    out.push_str(&format!(";{}", u32::from(text)));
                }
                out.push('u');
                out.into_bytes()
            }
            Code::Up => letter('A'),
            Code::Down => letter('B'),
            Code::Right => letter('C'),
            Code::Left => letter('D'),
            Code::Home => letter('H'),
            Code::End => letter('F'),
            Code::Insert => csi(2, '~', ""),
            Code::Delete => csi(3, '~', ""),
            Code::PageUp => csi(5, '~', ""),
            Code::PageDown => csi(6, '~', ""),
            Code::F(1) => letter('P'),
            Code::F(2) => letter('Q'),
            // `CSI R` is a cursor position report, so the kitty protocol has F3 as `CSI 13~`.
            Code::F(3) => csi(13, '~', ""),
            Code::F(4) => letter('S'),
            Code::F(number) => csi(function_number(number), '~', ""),
        }
    }
}

/// Whether Alt is the one modifier held.
fn alt_only(mods: Mods) -> bool {
    mods == Mods {
        alt: true,
        ..Mods::default()
    }
}

/// Whether Shift is the one modifier held.
fn shift_only(mods: Mods) -> bool {
    mods == Mods {
        shift: true,
        ..Mods::default()
    }
}

/// The C0 control Ctrl with `c` types, as xterm sends it: Ctrl with a letter is its place in the
/// alphabet, and with `@`, space, `[`, `\`, `]`, `^`, `_`, `?` and the digits 2 to 8 the controls
/// VT220 keyboards put there. `None` for a character Ctrl has no control for, which then types
/// the character itself.
fn control(c: char) -> Option<u8> {
    match c {
        'a'..='z' => Some(c as u8 - b'a' + 1),
        '@' | ' ' | '2' => Some(0),
        '[' | '3' => Some(0x1b),
        '\\' | '4' => Some(0x1c),
        ']' | '5' => Some(0x1d),
        '^' | '6' => Some(0x1e),
        '_' | '/' | '7' => Some(0x1f),
        '?' | '8' => Some(0x7f),
        _ => None,
    }
}

/// The `CSI n ~` number of F5 to F12 (xterm's, which skips 16 and 22).
fn function_number(key: u8) -> u32 {
    match key {
        5 => 15,
        6 => 17,
        7 => 18,
        8 => 19,
        9 => 20,
        10 => 21,
        11 => 23,
        _ => 24,
    }
}

/// The bracketed paste's end (`CSI 201 ~`): text holding it would end a paste early, and what
/// followed it would reach the program as typed keys.
pub const PASTE_END: &str = "\x1b[201~";

/// Whether `text` holds a paste's end, as ESC `[` ([`PASTE_END`]) or as C1's CSI, U+009B (UTF-8
/// `C2 9B`), which a terminal that reads C1 controls in UTF-8 takes for the same sequence. Either
/// would end a paste early.
pub fn holds_paste_end(text: &str) -> bool {
    text.contains(PASTE_END) || text.contains("\u{9b}201~")
}

/// `text` as a program that turned bracketed paste on (`CSI ? 2004 h`) is pasted it, or as it is
/// for one that didn't. Text holding [`PASTE_END`] is refused before this.
pub fn pasted(text: &str, bracketed: bool) -> Vec<u8> {
    if bracketed && !text.is_empty() {
        [
            b"\x1b[200~".as_slice(),
            text.as_bytes(),
            PASTE_END.as_bytes(),
        ]
        .concat()
    } else {
        text.as_bytes().to_vec()
    }
}

#[cfg(test)]
mod tests;
