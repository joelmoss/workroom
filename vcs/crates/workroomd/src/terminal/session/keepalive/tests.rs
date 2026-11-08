use super::*;

const ANSWER: &[u8] = b"\x1b[?25930;0$y";

/// The answer a terminal gives the probe never reaches the program, wherever it falls among what
/// the user typed.
#[test]
fn an_answer_is_taken_out_of_the_input_around_it() {
    let mut filter = AnswerFilter::default();
    assert_eq!(filter.strip(ANSWER), b"");
    assert_eq!(filter.strip(&[b"ls", ANSWER, b"\r"].concat()), b"ls\r");
    assert_eq!(filter.strip(&[ANSWER, ANSWER].concat()), b"");
    // Another state than "not recognized", from a terminal that answers differently.
    assert_eq!(filter.strip(b"\x1b[?25930;4$y"), b"");
}

/// An answer split where a frame ends, as a large paste can split it, is still taken out.
#[test]
fn an_answer_split_across_frames_is_still_taken_out() {
    for split in MIN_HELD..ANSWER.len() {
        let mut filter = AnswerFilter::default();
        let first = filter.strip(&[b"a", &ANSWER[..split]].concat());
        let second = filter.strip(&[&ANSWER[split..], b"b"].concat());
        assert_eq!([first, second].concat(), b"ab", "split at {split}");
    }
}

/// What a key sends at the end of a frame goes through at once: a bare Escape (vim) or Alt-[
/// waiting for the next keystroke would be a stuck key.
#[test]
fn a_key_at_the_end_of_a_frame_is_never_held() {
    let mut filter = AnswerFilter::default();
    assert_eq!(filter.strip(b"\x1b"), b"\x1b");
    assert_eq!(filter.strip(b"\x1b["), b"\x1b[");
    assert_eq!(filter.strip(b"x\x1b"), b"x\x1b");
}

/// Anything that only looks like the start of an answer goes through whole: a program's own
/// mode report, another mode's, a held tail whose rest turns out to be something else.
#[test]
fn what_is_not_an_answer_goes_through_unchanged() {
    let mut filter = AnswerFilter::default();
    for input in [
        &b"\x1b[?2026;2$y"[..],
        b"\x1b[?25931;0$y",
        b"\x1b[?25930;0$z",
        b"\x1b[?25930;$y",
        b"\x1b[?25930;0000$y",
        b"\x1b[A",
    ] {
        assert_eq!(filter.strip(input), input, "{input:?}");
    }
    assert_eq!(filter.strip(b"\x1b[?2593"), b"");
    assert_eq!(filter.strip(b"1;0$y"), b"\x1b[?25931;0$y");
}

/// A client stops counting as attached once `MISSES` probes in a row went unanswered, and not
/// before; any input brings it back. A tick whose probe never went out (the reader found no
/// moment to send it) is not a miss.
#[test]
fn a_client_goes_stale_after_its_misses_and_comes_back_on_input() {
    let mut keepalive = Keepalive::default();
    assert!(!keepalive.tick(), "nothing was outstanding");
    assert!(!keepalive.tick(), "the probe never went out");
    for miss in 1..MISSES {
        assert!(keepalive.take_due());
        assert!(!keepalive.tick(), "stale after {miss} misses");
        assert!(!keepalive.is_stale());
    }
    assert!(keepalive.take_due());
    assert!(keepalive.tick(), "the last miss makes it stale");
    assert!(keepalive.is_stale());
    assert!(keepalive.take_due());
    assert!(
        !keepalive.tick(),
        "only the tick that made it stale says so"
    );
    assert!(keepalive.heard(), "input brings it back");
    assert!(!keepalive.is_stale());
    assert!(!keepalive.heard(), "it was not stale any more");
}

/// A client that answers every probe before the next tick never goes stale, however long it
/// lasts.
#[test]
fn a_client_that_answers_never_goes_stale() {
    let mut keepalive = Keepalive::default();
    for _ in 0..(MISSES * 10) {
        assert!(!keepalive.tick());
        if keepalive.take_due() {
            keepalive.heard();
        }
        assert!(!keepalive.is_stale());
    }
}

/// libghostty, the terminal the app's panes run, answers the probe, and with exactly what the
/// filter takes out: a probe it ignored would make every pane stale, and an answer the filter
/// missed would be typed into the program every interval.
#[cfg(feature = "terminal-state")]
#[test]
fn libghostty_answers_the_probe_with_what_is_taken_out() {
    #[derive(Default)]
    struct Replies(Vec<u8>);
    impl ghostty_vt::Callbacks for Replies {
        fn write_pty(&mut self, bytes: &[u8]) {
            self.0.extend_from_slice(bytes);
        }
    }
    let mut terminal = ghostty_vt::Terminal::new(80, 24, Replies::default()).expect("terminal");
    terminal.write(PROBE);
    let answer = terminal.callbacks().0.clone();
    assert_eq!(answer, ANSWER);
    assert_eq!(AnswerFilter::default().strip(&answer), b"");
}

#[test]
fn only_the_variable_set_to_one_asks() {
    let env = |value: &str| vec![(OsString::from(VARIABLE), OsString::from(value))];
    assert!(requested(&env("1")));
    assert!(!requested(&env("0")));
    assert!(!requested(&env("")));
    assert!(!requested(&[]));
}
