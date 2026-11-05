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
                // Bounded, because a client controls this stream and the daemon is shared: `ESC [`
                // followed by megabytes of digits and no final byte would otherwise grow this
                // vector until the daemon — and every session it is holding — died. Real sequences
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
/// still well under this. The cap exists to bound what a client can make the daemon hold, not to
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
mod tests;
