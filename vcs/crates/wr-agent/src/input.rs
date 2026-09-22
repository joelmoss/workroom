//! Telling the user acting apart from the terminal answering.
//!
//! The size-owner policy says a client claims the session's size by **typing**. That sounds like a
//! one-line check and is not, because a terminal writes to the same channel the user does: focus
//! reports, cursor-position reports and device-attribute answers all arrive as "input" without
//! anybody touching the keyboard. A client that has a pane merely visible would otherwise claim
//! ownership the moment it was focused, and the size would ping-pong between two machines that
//! nobody was using.
//!
//! The design doc names this explicitly as the same failure family as the replay buffer's query
//! stripping, and says to recognise it before it is rediscovered as a bug. Hence a parser rather
//! than a substring check, and hence the state carried BETWEEN calls: an escape sequence split
//! across two frames must not read as user input because its first half looked like nothing.
//!
//! Wheel scroll is excluded too, and a click is not — scrolling a pane you are reading is not a
//! claim on it, pressing a button in it is.

/// Decides whether bytes arriving from a client represent the user acting.
///
/// One per client, because it holds the tail of an unfinished escape sequence.
#[derive(Debug, Default)]
pub struct InputClassifier {
    state: State,
    /// Parameter and intermediate bytes of the sequence being parsed.
    params: Vec<u8>,
    /// Remaining bytes of a normal-mode mouse report (`CSI M` plus three).
    mouse: Vec<u8>,
}

#[derive(Debug, Default, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    /// `CSI` — parameters until a final byte in 0x40..=0x7E.
    ControlSequence,
    /// `OSC` — until BEL or ST. Everything a CLIENT sends here is an answer: colour queries,
    /// clipboard reads. None of it is the user.
    OperatingSystemCommand,
    /// `DCS` — until ST. Tertiary device attributes, XTVERSION, XTGETTCAP replies.
    DeviceControlString,
    /// `SS3` — one byte. F1-F4 and the application-mode cursor keys: the user.
    SingleShift,
    /// The three bytes following `CSI M` in normal (non-SGR) mouse reporting.
    MouseReport,
    /// Inside an OSC/DCS that has just seen an ESC, deciding whether it is the ST terminator.
    StringTerminator,
}

impl InputClassifier {
    pub fn new() -> InputClassifier {
        InputClassifier::default()
    }

    /// Whether `bytes` contain anything that counts as the user acting on this session.
    ///
    /// Every byte is consumed whatever the answer, so the parser stays in step with the stream —
    /// returning early on the first keystroke would strand the state machine mid-sequence and
    /// misread the next frame.
    pub fn is_user_input(&mut self, bytes: &[u8]) -> bool {
        let mut user = false;
        for &byte in bytes {
            user |= self.consume(byte);
        }
        user
    }

    fn consume(&mut self, byte: u8) -> bool {
        match self.state {
            State::Ground => {
                if byte == ESCAPE {
                    self.state = State::Escape;
                    self.params.clear();
                    return false;
                }
                // A printable character, a control character, a paste's contents: the user.
                true
            }
            State::Escape => match byte {
                b'[' => {
                    self.state = State::ControlSequence;
                    false
                }
                b']' => {
                    self.state = State::OperatingSystemCommand;
                    false
                }
                b'P' => {
                    self.state = State::DeviceControlString;
                    false
                }
                b'O' => {
                    self.state = State::SingleShift;
                    false
                }
                ESCAPE => true,
                // ESC followed by anything else is Alt+key, or a bare Escape: the user.
                _ => {
                    self.state = State::Ground;
                    true
                }
            },
            State::ControlSequence => {
                if (0x40..=0x7E).contains(&byte) {
                    if byte == b'M' && self.params.is_empty() {
                        // Normal-mode mouse reporting: the button and coordinates follow as three
                        // raw bytes, which must not be parsed as a fresh sequence.
                        self.state = State::MouseReport;
                        self.mouse.clear();
                        return false;
                    }
                    let user = claims_ownership(&self.params, byte);
                    self.state = State::Ground;
                    self.params.clear();
                    return user;
                }
                // Bounded, because a client controls this stream and the agent is shared: `ESC [`
                // followed by megabytes of digits and no final byte would otherwise grow this
                // vector until the agent — and every session it is holding — died. Real sequences
                // are a handful of bytes; past the cap the sequence is abandoned rather than
                // truncated, so what follows cannot be read as the tail of something legitimate.
                if self.params.len() >= MAX_PARAMETERS {
                    self.state = State::Ground;
                    self.params.clear();
                    return false;
                }
                self.params.push(byte);
                false
            }
            State::OperatingSystemCommand | State::DeviceControlString => {
                match byte {
                    BELL => self.state = State::Ground,
                    ESCAPE => self.state = State::StringTerminator,
                    _ => {}
                }
                false
            }
            State::StringTerminator => {
                // `ESC \` ends the string; anything else means the ESC belonged to the payload.
                self.state = if byte == b'\\' {
                    State::Ground
                } else {
                    State::OperatingSystemCommand
                };
                false
            }
            State::SingleShift => {
                self.state = State::Ground;
                true
            }
            State::MouseReport => {
                self.mouse.push(byte);
                if self.mouse.len() < 3 {
                    return false;
                }
                self.state = State::Ground;
                // The button byte is offset by 32, and bit 6 marks a wheel event.
                let button = self.mouse[0].wrapping_sub(32);
                self.mouse.clear();
                button & WHEEL_BIT == 0
            }
        }
    }
}

/// The longest parameter run any real control sequence has. A kitty keyboard event or an SGR
/// mouse report is a dozen bytes; the widest thing in practice is a multi-parameter SGR colour,
/// still well under this. The cap exists to bound what a client can make the agent hold, not to
/// reject anything a terminal actually emits.
const MAX_PARAMETERS: usize = 64;

const ESCAPE: u8 = 0x1B;
const BELL: u8 = 0x07;
/// Bit 6 of a mouse button byte marks a wheel event rather than a button.
const WHEEL_BIT: u8 = 0b0100_0000;

/// Whether a finished control sequence is the user rather than the terminal answering.
fn claims_ownership(params: &[u8], final_byte: u8) -> bool {
    match final_byte {
        // Focus in / focus out (DECSET 1004). Merely looking at a pane is not a claim on it.
        b'I' | b'O' => false,
        // Cursor position report, device status report, device attributes.
        b'R' | b'n' | b'c' => false,
        // A window-size report answering a query.
        b't' => false,
        // `CSI ? mode ; value $ y` is DECRPM, the terminal reporting a mode's state (synchronized
        // output, bracketed paste, ...) to a program that asked. A TUI asks on a timer; no key
        // produces a `$` intermediate.
        b'y' if params.ends_with(b"$") => false,
        // `CSI ? flags u` is the kitty keyboard protocol reporting its flags; `CSI n ; m u` with no
        // `?` is an actual key event in that protocol. One character apart, opposite meanings.
        b'u' => !params.starts_with(b"?"),
        // SGR mouse: `CSI < button ; x ; y M|m`. A wheel event is not a claim; a click is.
        b'M' | b'm' if params.starts_with(b"<") => !is_wheel(params),
        // Arrow keys, Home/End, the `~` keys, anything else a keyboard produces.
        _ => true,
    }
}

/// Whether an SGR mouse report's button field marks a wheel event.
fn is_wheel(params: &[u8]) -> bool {
    let digits: String = params[1..]
        .iter()
        .take_while(|b| b.is_ascii_digit())
        .map(|b| *b as char)
        .collect();
    digits
        .parse::<u16>()
        .is_ok_and(|button| button as u8 & WHEEL_BIT != 0)
}

#[cfg(test)]
mod tests {
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
    /// nobody at the keyboard. Counting it renewed the wakefulness keystroke grace forever.
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

    /// A client controls this stream and the agent is shared, so an unterminated sequence must not
    /// be able to grow the agent's memory. Bytes arrive in many frames here because that is the
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
}
