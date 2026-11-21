use super::*;

/// What `pattern` first matches in `chunks`, fed in order to one matcher.
fn first_match(pattern: &str, chunks: &[&[u8]]) -> Option<String> {
    let mut matcher = Matcher::new(pattern).expect("a valid pattern");
    chunks
        .iter()
        .find_map(|chunk| matcher.feed(chunk))
        .map(|found| String::from_utf8_lossy(&found).into_owned())
}

/// Output as a program writes it: colours, a title, a hyperlink, a cursor move, `\r\n` line ends.
const STREAM: &[u8] = b"\x1b[1;32mcompiling\x1b[0m...\r\n\x1b]2;vite\x07\x1b]8;;https://x.test\x1b\\link\x1b]8;;\x1b\\ \x1b[2K\x1b[3Gready in \x1b[1m312\x1b[22m ms\r\nnext\r\n";

#[test]
fn escape_sequences_are_stripped_before_matching() {
    assert_eq!(
        first_match(r"ready in \d+ ms", &[STREAM]).as_deref(),
        Some("ready in 312 ms")
    );
    assert_eq!(
        first_match(r"compiling\.\.\.", &[STREAM]).as_deref(),
        Some("compiling...")
    );
    // An OSC's payload is never text: the title and the link's URL are not matched.
    assert_eq!(first_match("vite|https", &[STREAM]), None);
    assert_eq!(first_match("link", &[STREAM]).as_deref(), Some("link"));
}

#[test]
fn a_match_split_at_any_byte_is_found_the_same() {
    let whole = first_match(r"ready in \d+ ms$", &[STREAM]);
    assert_eq!(whole.as_deref(), Some("ready in 312 ms"));
    for at in 0..=STREAM.len() {
        let (head, tail) = STREAM.split_at(at);
        assert_eq!(
            first_match(r"ready in \d+ ms$", &[head, tail]),
            whole,
            "split at {at}"
        );
    }
    let bytes: Vec<&[u8]> = STREAM.chunks(1).collect();
    assert_eq!(
        first_match(r"ready in \d+ ms$", &bytes),
        whole,
        "byte by byte"
    );
}

#[test]
fn a_multibyte_character_split_across_reads_still_matches() {
    let text = "built ✓ done\r\n".as_bytes();
    for at in 0..=text.len() {
        let (head, tail) = text.split_at(at);
        assert_eq!(
            first_match("built ✓ done", &[head, tail]).as_deref(),
            Some("built ✓ done"),
            "split at {at}"
        );
    }
}

#[test]
fn caret_and_dollar_are_line_anchors_with_crlf_endings() {
    let output: &[u8] = b"server ready\r\nlistening on 3000\r\n";
    assert_eq!(
        first_match("^listening on (\\d+)$", &[output]).as_deref(),
        Some("listening on 3000")
    );
    assert_eq!(first_match("^ready", &[output]), None);
}

#[test]
fn a_string_sequence_left_open_hides_what_follows_until_it_ends() {
    // An OSC with no terminator yet: its payload spans reads and is never matched.
    let chunks: &[&[u8]] = &[b"\x1b]0;ready", b" still the title", b"\x07ready\r\n"];
    assert_eq!(first_match("title", chunks), None);
    assert_eq!(first_match("^ready", chunks).as_deref(), Some("ready"));
}

#[test]
fn the_window_is_bounded_and_old_text_falls_out_of_it() {
    let mut matcher = Matcher::new("needle.*haystack").unwrap();
    assert_eq!(matcher.feed(b"needle "), None);
    let filler = vec![b'x'; WINDOW * 2];
    assert_eq!(matcher.feed(&filler), None);
    assert!(matcher.window_len() <= WINDOW, "{}", matcher.window_len());
    // The needle has left the window, so a match would have to be longer than it holds.
    assert_eq!(matcher.feed(b" haystack"), None);
    // A long OSC payload costs nothing: it is dropped as it arrives.
    let mut payload = b"\x1b]2;".to_vec();
    payload.extend(std::iter::repeat_n(b't', WINDOW * 4));
    matcher.feed(&payload);
    assert!(matcher.window_len() <= WINDOW + 16);
}

#[test]
fn a_pattern_the_regex_engine_refuses_is_an_error() {
    assert!(Matcher::new("(unclosed").is_err());
    assert!(
        Matcher::new(r"\w{1000}{1000}").is_err(),
        "over the size limit"
    );
}

fn output_waiter(pattern: &str) -> std::sync::Arc<Waiter> {
    std::sync::Arc::new(Waiter::new(
        Condition::Output(Box::new(Matcher::new(pattern).expect("a valid pattern"))),
        Seen::default(),
    ))
}

fn in_20s() -> Option<Instant> {
    Some(Instant::now() + std::time::Duration::from_secs(20))
}

/// The bytes a waiter's queue has allocated, and holds.
fn queued(waiter: &Waiter) -> (usize, usize) {
    let progress = lock_or_recover(&waiter.state);
    let allocated = progress.queue.chunks.iter().map(Vec::capacity).sum();
    (allocated, progress.queue.len)
}

/// The session's reader never waits on a regex: it only queues what it read, bounded, while the
/// wait's own thread matches. Here that thread is stuck mid-match (its matcher held) while the
/// reader hands over 1 MiB, a read at a time, and the reader still finishes; the queue holds the
/// first `QUEUE` of it, no more allocated than that and a chunk, and drops the rest. The thread,
/// once it runs, matches what it kept, and with nothing there says it fell behind: the mark came
/// after what was dropped, and a match may have been in it.
#[test]
fn the_reader_never_waits_on_a_match() {
    let waiter = output_waiter("MARK-[0-9]+");
    let stuck = lock_or_recover(&waiter.matcher);
    let (done, finished) = std::sync::mpsc::channel();
    let reader = {
        let waiter = std::sync::Arc::clone(&waiter);
        std::thread::spawn(move || {
            for _ in 0..1024 {
                waiter.output(&[b'x'; 1024]);
            }
            waiter.output(b"\nMARK-1\r\n");
            done.send(()).unwrap();
        })
    };
    // A guard against a hang, not a budget: the reader is done in microseconds.
    finished
        .recv_timeout(std::time::Duration::from_secs(20))
        .expect("the reader waited on the match");
    reader.join().unwrap();
    let (allocated, held) = queued(&waiter);
    assert_eq!(
        held, QUEUE,
        "the first QUEUE of 1 MiB, read 1 KiB at a time"
    );
    assert!(allocated <= QUEUE + CHUNK, "{allocated}");
    assert!(
        lock_or_recover(&waiter.state).queue.lagged,
        "1 MiB fits no queue"
    );
    drop(stuck);
    assert_eq!(waiter.wait(in_20s()), Outcome::FellBehind);
}

/// A wait that fell behind still meets a match in what it kept, which came before anything it
/// dropped. Many small reads share a chunk rather than take an allocation each.
#[test]
fn a_wait_that_fell_behind_matches_what_it_kept() {
    let waiter = output_waiter("needle");
    let stuck = lock_or_recover(&waiter.matcher);
    for byte in b"a needle " {
        waiter.output(&[*byte]);
    }
    assert_eq!(queued(&waiter), (CHUNK, 9));
    waiter.output(&vec![b'x'; QUEUE]);
    assert!(lock_or_recover(&waiter.state).queue.lagged);
    drop(stuck);
    assert_eq!(
        waiter.wait(in_20s()),
        Outcome::Met(Met::Output(b"needle".to_vec()))
    );
}

/// What the thread has taken and not matched yet counts against `QUEUE` with what is queued, so a
/// wait matching one batch while the reader queues the next holds `QUEUE` in all, not twice it.
#[test]
fn a_batch_being_matched_counts_against_the_queue() {
    let waiter = output_waiter("NEVER");
    lock_or_recover(&waiter.state).in_hand = QUEUE - CHUNK;
    waiter.output(&vec![b'x'; CHUNK]);
    assert!(
        !lock_or_recover(&waiter.state).queue.lagged,
        "it fits beside"
    );
    waiter.output(b"x");
    assert!(
        lock_or_recover(&waiter.state).queue.lagged,
        "one byte more doesn't"
    );
}

/// Output queued before the session ended, or before the deadline, is matched before either is
/// believed: it came first.
#[test]
fn queued_output_meets_the_wait_before_its_end_or_deadline() {
    let waiter = output_waiter("ready");
    waiter.output(b"server ready\r\n");
    waiter.ended(Some(0));
    assert_eq!(
        waiter.wait(in_20s()),
        Outcome::Met(Met::Output(b"ready".to_vec()))
    );

    let waiter = output_waiter("ready");
    waiter.output(b"server ready\r\n");
    assert_eq!(
        waiter.wait(Some(Instant::now())),
        Outcome::Met(Met::Output(b"ready".to_vec()))
    );

    let waiter = output_waiter("ready");
    waiter.output(b"not yet\r\n");
    waiter.ended(Some(0));
    assert_eq!(waiter.wait(in_20s()), Outcome::SessionEnded);
}

/// Output that goes `QUIET` settles what the wait holds, as the session's end would: a prompt
/// with no line end meets `$`, and a number that could still grow is answered as it stands.
#[test]
fn a_wait_whose_output_goes_quiet_settles_what_it_holds() {
    for (pattern, output, want) in [
        (
            "Password: $",
            &b"login ok\r\nPassword: "[..],
            &b"Password: "[..],
        ),
        (r"exit \d+", b"exit 42", b"exit 42"),
    ] {
        let waiter = output_waiter(pattern);
        waiter.output(output);
        assert_eq!(
            waiter.wait(in_20s()),
            Outcome::Met(Met::Output(want.to_vec())),
            "{pattern}"
        );
    }
}

/// A session printing without end (`yes`) never leaves a regex wait's queue empty, and the wait
/// still times out at its deadline: the batch taken past it is the last. The printer here keeps
/// the queue within half its bound, so the wait never falls behind (which would end it sooner).
#[test]
fn a_wait_on_endless_output_still_times_out() {
    let waiter = output_waiter("NEVER");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let printer = {
        let (waiter, stop) = (std::sync::Arc::clone(&waiter), std::sync::Arc::clone(&stop));
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                let held = {
                    let progress = lock_or_recover(&waiter.state);
                    progress.queue.len + progress.in_hand
                };
                if held < QUEUE / 2 {
                    waiter.output(b"y\r\n");
                } else {
                    std::thread::yield_now();
                }
            }
        })
    };
    let (done, outcome) = std::sync::mpsc::channel();
    {
        let waiter = std::sync::Arc::clone(&waiter);
        std::thread::spawn(move || {
            let deadline = Instant::now() + std::time::Duration::from_millis(200);
            let _ = done.send(waiter.wait(Some(deadline)));
        });
    }
    // A guard against a hang, not a budget.
    let outcome = outcome.recv_timeout(std::time::Duration::from_secs(20));
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    printer.join().unwrap();
    assert_eq!(outcome, Ok(Outcome::TimedOut));
}

/// A lagged queue keeps the oldest output, contiguous with what came before it, and nothing after
/// the read it dropped: no match joins text from either side of the gap.
#[test]
fn a_lagged_queue_keeps_only_what_came_before_the_gap() {
    let mut queue = Queue::default();
    queue.push(&vec![b'x'; QUEUE - 4], 0);
    queue.push(b"need", 0);
    queue.push(b"le", 0);
    assert!(queue.lagged);
    queue.push(b"\r\n", 0);
    assert_eq!(queue.len, QUEUE);
    let mut matcher = Matcher::new("needle|need\r").unwrap();
    let mut matched = 0;
    assert_eq!(matcher.take(queue, |n| matched += n), None);
    assert_eq!(matched, QUEUE, "every chunk is counted as it is matched");
}

/// What `pattern` first matches in `chunks`, for a wait that joined the stream inside `open`, the
/// sequence so far as the parser continuation has it (empty: one too long for it to keep).
fn first_match_resynced(pattern: &str, open: &[u8], chunks: &[&[u8]]) -> Option<String> {
    let mut matcher = Matcher::new(pattern).expect("a valid pattern");
    matcher.resync(open);
    chunks
        .iter()
        .find_map(|chunk| matcher.feed(chunk))
        .map(|found| String::from_utf8_lossy(&found).into_owned())
}

/// A wait that starts inside a title's OSC, or a kitty image's APC, drops the rest of it: its
/// payload is never text, and the text after its BEL or ST is (#690).
#[test]
fn a_wait_joining_mid_sequence_drops_the_rest_of_it() {
    // The rest of `ESC ] 2 ; build `, then the screen's own text.
    let title: &[&[u8]] = &[b"NOPE watch", b"\x07DONE\r\n"];
    for open in [&b"\x1b]2;build "[..], b""] {
        assert_eq!(
            first_match_resynced("NOPE|DONE", open, title).as_deref(),
            Some("DONE"),
            "{open:?}"
        );
    }
    // Without knowing, the title's rest reads as text.
    assert_eq!(first_match("NOPE|DONE", title).as_deref(), Some("NOPE"));
    // The rest of `ESC _ G a=T,f=100;` and its base64, ended by ST.
    let kitty: &[&[u8]] = &[b"Tk9QRQ==NOPE", b"\x1b\\DONE\r\n"];
    for open in [&b"\x1b_Ga=T,f=100;"[..], b""] {
        assert_eq!(
            first_match_resynced("NOPE|DONE", open, kitty).as_deref(),
            Some("DONE"),
            "{open:?}"
        );
    }
    // A line's end is known ground, and kept: `^` still anchors the next line.
    assert_eq!(
        first_match_resynced("^DONE$", b"", &[b"le NOPE\r\nDONE\r\n"]).as_deref(),
        Some("DONE")
    );
}

/// Inside a CSI, the stripper picks up where the parser is, and the text after the CSI's final
/// byte is text: a colour cut at `ESC [ 3` still lets `ready` after it match. Where the line
/// started is unknown, so `^` doesn't match at the text's start, and does from the next line.
#[test]
fn a_wait_joining_inside_a_csi_keeps_the_text_after_it() {
    assert_eq!(
        first_match_resynced("ready", b"\x1b[3", &[b"2mready\x1b[0m\r\n"]).as_deref(),
        Some("ready")
    );
    for open in [&b"\x1b[3"[..], b""] {
        let rest: &[u8] = if open.is_empty() { b"\x07" } else { b"2m" };
        assert_eq!(
            first_match_resynced("^foo", open, &[rest, b"foo\r\n"]),
            None,
            "{open:?}: mid-line"
        );
        assert_eq!(
            first_match_resynced("^bar", open, &[rest, b"foo\r\nbar\r\n"]).as_deref(),
            Some("bar"),
            "{open:?}: the next line"
        );
    }
    // A character's first bytes are no sequence: its rest is text.
    assert_eq!(
        first_match_resynced(
            "✓ done",
            "✓".as_bytes().get(..1).unwrap(),
            &["✓ done".as_bytes()]
        )
        .as_deref(),
        Some("✓ done")
    );
}

/// A run wait hears its run's logged transitions numbered past the last when it started, and
/// whatever the status file shows: one logged before it started is no news.
#[test]
fn a_run_wait_hears_only_transitions_after_it_started() {
    let waiter = Waiter::new(Condition::Run(RunState::Stopping), Seen::default());
    waiter.runs_after(5);
    waiter.run("stopping", Some(4));
    waiter.run("stopping", Some(5));
    assert_eq!(waiter.outcome(), None, "logged before the wait started");
    waiter.run("starting", Some(6));
    assert_eq!(waiter.outcome(), None, "not the state waited for");
    waiter.run("stopping", Some(7));
    assert_eq!(
        waiter.outcome(),
        Some(Outcome::Met(Met::Run {
            state: RunState::Stopping,
            exit_code: None,
        }))
    );
    // A supervisor that logs nothing: its status file's changes, as ever.
    let waiter = Waiter::new(Condition::Run(RunState::Exited), Seen::default());
    waiter.run("exited 3 1", None);
    assert_eq!(
        waiter.outcome(),
        Some(Outcome::Met(Met::Run {
            state: RunState::Exited,
            exit_code: Some(3),
        }))
    );
}

/// Commands that end together are heard in order: a wait for the next to finish answers with the
/// first after it started, the last's code only when that is the one.
#[test]
fn a_command_wait_answers_with_the_first_command_to_end_after_it() {
    let seen = |commands: u64, exits: &[i32]| Seen {
        shell_marks: true,
        commands,
        exits: exits.iter().copied().map(Some).collect(),
        ..Seen::default()
    };
    for (before, want) in [(0, Some(1)), (1, Some(2)), (2, Some(0))] {
        let waiter = Waiter::new(Condition::CommandFinished, seen(before, &[]));
        waiter.shadow(&seen(3, &[1, 2, 0]));
        assert_eq!(
            waiter.outcome(),
            Some(Outcome::Met(Met::CommandFinished(want))),
            "{before}"
        );
    }
    // Older than the shadow keeps: unknown, rather than another command's.
    let waiter = Waiter::new(Condition::CommandFinished, seen(0, &[]));
    waiter.shadow(&seen(3, &[2, 0]));
    assert_eq!(
        waiter.outcome(),
        Some(Outcome::Met(Met::CommandFinished(None)))
    );
}

/// A window is trimmed to its last `WINDOW` bytes wherever they start, and what the stream had
/// just before them still decides `^` there: mid-line, it doesn't match; after a line's end, it
/// does.
#[test]
fn a_window_trimmed_mid_line_does_not_start_a_line() {
    let mut matcher = Matcher::new("^y").unwrap();
    let mut line = vec![b'x'; WINDOW];
    line.extend(std::iter::repeat_n(b'y', WINDOW));
    assert_eq!(matcher.feed(&line), None);
    assert_eq!(matcher.window_len(), WINDOW, "trimmed to the y's");
    assert_eq!(matcher.feed(b"y"), None, "the y's start mid-line");

    let mut matcher = Matcher::new("^yz").unwrap();
    let mut lines = vec![b'x'; WINDOW];
    lines.extend_from_slice(b"\ny");
    assert_eq!(matcher.feed(&lines), None);
    assert_eq!(
        matcher.window_len(),
        WINDOW,
        "trimmed to its last WINDOW bytes"
    );
    assert_eq!(matcher.feed(b"z").as_deref(), Some(&b"yz"[..]));
}

/// Trimming never loses a match the window must still hold: a line longer than the window, then
/// `DONE\r\nREADY`, matches a pattern spanning the two lines however the batches split it, even
/// where the line's end falls inside the window and a trim to it would have dropped `DONE`.
#[test]
fn a_match_after_a_line_longer_than_the_window_survives_the_trim() {
    // `DONE` ends the long line, whose only line end in the window is the one in the match.
    for (pattern, line_end) in [
        (r"DONE\r\nREADY", &b""[..]),
        (r"(?m)^DONE$\r\n^READY$", b"\r\n"),
    ] {
        let mut stream = vec![b'x'; WINDOW + 1024];
        stream.extend_from_slice(line_end);
        stream.extend_from_slice(b"DONE\r\nREADY\r\n");
        let at = stream.len() - b"READY\r\n".len();
        for split in [at - 6, at - 2, at - 1, at, at + 2] {
            let (head, tail) = stream.split_at(split);
            assert_eq!(
                first_match(pattern, &[head, tail]).as_deref(),
                Some("DONE\r\nREADY"),
                "{pattern} split at {split}"
            );
        }
    }
}

/// A match the DFA can't settle (a Unicode `\b` beside text that isn't ASCII) is still answered
/// as soon as the character after it is whole, not left for the session's end: a dev server that
/// prints a check mark and goes quiet still meets the wait.
#[test]
fn a_unicode_word_boundary_beside_non_ascii_text_still_answers_at_once() {
    assert_eq!(
        first_match(r"\bready\b", &["✓ ready\r\n".as_bytes()]).as_deref(),
        Some("ready")
    );
    assert_eq!(
        first_match(r"\bécrit\b", &["✓ écrit ✓".as_bytes()]).as_deref(),
        Some("écrit")
    );
    // The character after is whole at its own length, not at four bytes: a prompt that ends in
    // `…` and waits for input meets the wait at once.
    for reads in [&["Ready…"][..], &["Ready", "…"]] {
        let reads: Vec<&[u8]> = reads.iter().map(|read| read.as_bytes()).collect();
        assert_eq!(
            first_match(r"\bReady\b", &reads).as_deref(),
            Some("Ready"),
            "{reads:?}"
        );
    }
    assert_eq!(
        first_match(r"\bok\b", &["ok🚀".as_bytes()]).as_deref(),
        Some("ok"),
        "a four-byte character that is no word's"
    );
    // A four-byte word character after a match shorter than the longest: the byte the longest
    // reaches is inside it, and the whole of it says there is no boundary.
    let mut matcher = Matcher::new(r"\b(ok|okay)\b").unwrap();
    for byte in "ok𠀀 x".bytes() {
        assert_eq!(matcher.feed(&[byte]), None, "{byte:#x}");
    }
}

/// A match is the whole stream's, not the one a read happened to end in: a greedy match goes on
/// while more could lengthen it, and `$` needs the line's end, not the end of what has arrived.
/// The session's end settles what is left.
#[test]
fn a_match_is_answered_once_more_output_cannot_change_it() {
    let mut matcher = Matcher::new(r"TICK-\d+").unwrap();
    assert_eq!(matcher.feed(b"TICK-1"), None, "a digit more may come");
    assert_eq!(matcher.feed(b"2\r\n").as_deref(), Some(&b"TICK-12"[..]));

    let mut matcher = Matcher::new("ready$").unwrap();
    assert_eq!(matcher.feed(b"ready"), None, "the line may go on");
    assert_eq!(matcher.feed(b"\r\n").as_deref(), Some(&b"ready"[..]));
    let mut matcher = Matcher::new("ready$").unwrap();
    assert_eq!(matcher.feed(b"ready"), None);
    assert_eq!(matcher.feed(b"made"), None, "it did");

    // A literal is settled the moment it is all there: a prompt that ends the output matches.
    let mut matcher = Matcher::new(r"\$ ").unwrap();
    assert_eq!(matcher.feed(b"build ok\r\n$ ").as_deref(), Some(&b"$ "[..]));

    let mut matcher = Matcher::new(r"\d+$").unwrap();
    assert_eq!(matcher.feed(b"exit 42"), None);
    assert_eq!(
        matcher.finish().as_deref(),
        Some(&b"42"[..]),
        "the end settles it"
    );
}

/// `\A` matches at the start of the wait's text, and nowhere else: not after a join mid-sequence,
/// where the text starts mid-line, nor once the window is trimmed past it.
#[test]
fn backslash_a_is_the_start_of_the_waits_text() {
    assert_eq!(
        first_match(r"\Aready", &[b"ready\r\n"]).as_deref(),
        Some("ready")
    );
    assert_eq!(first_match(r"\Aready", &[b"x\r\nready\r\n"]), None);
    assert_eq!(
        first_match_resynced(r"\Aready", b"\x1b[3", &[b"2mready\r\n"]),
        None
    );
    let mut matcher = Matcher::new(r"\Aready|(?-m)^ready").unwrap();
    assert_eq!(matcher.feed(&vec![b'x'; WINDOW * 2]), None);
    assert_eq!(matcher.feed(b"\nready\r\n"), None, "trimmed past the start");

    // The screen's text, with `include_screen`, starts the wait's text at its top row.
    for pattern in [r"\Aready", r"(?-m:^)ready"] {
        let mut matcher = Matcher::new(pattern).unwrap();
        assert_eq!(
            matcher.feed_plain(b"ready on :5173\n$ ").as_deref(),
            Some(&b"ready"[..]),
            "{pattern}"
        );
        let mut matcher = Matcher::new(pattern).unwrap();
        assert_eq!(matcher.feed_plain(b"$ npm run dev\n"), None, "{pattern}");
        assert_eq!(
            matcher.feed(b"ready\r\n"),
            None,
            "{pattern}: after the screen"
        );
    }
    // As a waiter has it: the first output after it starts, a byte at a time, and the screen.
    let waiter = output_waiter(r"\Aready");
    for byte in b"ready\r\n" {
        waiter.output(&[*byte]);
    }
    assert_eq!(
        waiter.wait(in_20s()),
        Outcome::Met(Met::Output(b"ready".to_vec()))
    );
    let waiter = output_waiter(r"(?-m:^)ready");
    waiter.screen(b"ready on :5173\n".to_vec());
    waiter.output(b"ready\r\n");
    assert_eq!(
        waiter.wait(in_20s()),
        Outcome::Met(Met::Output(b"ready".to_vec()))
    );
}

/// The patterns the split-invariance test asks about: literals, line anchors, word boundaries
/// (Unicode's, which the lazy DFA gives up on beside text that isn't ASCII, and ASCII's), an
/// alternation whose longer branch needs more bytes, greedy repeats, a pattern across lines,
/// Unicode text, and `\A`. Every one is bounded or settled by the DFA: the documented
/// approximation (an unbounded pattern with a Unicode `\b`) is left out.
const SPLIT_PATTERNS: &[&str] = &[
    "READY",
    "^READY$",
    r"^DONE\r?\nREADY",
    r"\bok\b",
    // Unicode `\b` and `\B` beside characters of two, three and four bytes, which the DFA leaves
    // to the bound: one shorter than its longest, so the bound falls inside the next character.
    r"\bREADY\b",
    r"\b(ok|okay)\b",
    r"\B(é|本)",
    r"本\B|é\b",
    r"\b\w{2}\b",
    "error|warn(ing)?",
    r"TICK-\d+",
    r"\d+$",
    r"ready in \d{1,4} ms$",
    "✓ done|écrit",
    r"(?-u:\b)DONE",
    r"\A(x{1,3}|READY)",
    r"[^\r\n]{3}\r\nDONE",
    // Every next byte ends a match at `DONE`'s end, but which one, and so its text, is the byte's.
    "DONE$|ONE",
];

/// The answer the whole stream gives, worked out apart from the matcher: its escape sequences
/// stripped by a pattern for the sequences the test makes, its other controls but `\t`, `\n` and
/// `\r` dropped, and the `regex` crate's leftmost-first search of the whole of it, once, with the
/// session's end at its end. Every pattern tested is far shorter than `WINDOW`, the one limit
/// the matcher documents, so the window changes nothing here.
///
/// With it, whether the answer is due before the session ends: a match of a pattern with a
/// longest is settled once the text holds that many bytes from its start and the whole of the
/// character that holds the byte after them, which is all a match from there, or a `\b` at its
/// end, can look at. One that a line's end and a byte more follow is settled by then too, for
/// every pattern tested, but for one with a Unicode `\b` over text that isn't ASCII, where the
/// DFA gives up and only the bound settles it.
fn oracle(pattern: &str, stream: &[u8]) -> (Option<Vec<u8>>, bool) {
    let sequences = regex::bytes::Regex::new(
        r"(?-u)\x1b\[[0-?]*[ -/]*[@-~]|\x1b[\]_P^X][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[ -/]*[0-~]",
    )
    .unwrap();
    let controls = regex::bytes::Regex::new(r"(?-u)[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]").unwrap();
    let text = sequences.replace_all(stream, &b""[..]);
    let text = controls.replace_all(&text, &b""[..]);
    let found = regex::bytes::RegexBuilder::new(pattern)
        .multi_line(true)
        .crlf(true)
        .build()
        .unwrap()
        .find(&text);
    let syntax = syntax::Config::new()
        .multi_line(true)
        .crlf(true)
        .utf8(false);
    let hir = syntax::parse_with(pattern, &syntax).unwrap();
    let longest = hir.properties().maximum_len();
    // Settled by its bound alone, where the DFA gives up.
    let bound_alone = hir.properties().look_set().contains_word_unicode() && !text.is_ascii();
    let due = found.is_some_and(|found| {
        let line = !bound_alone
            && text[found.end()..]
                .iter()
                .position(|byte| *byte == b'\n')
                .is_some_and(|at| found.end() + at + 1 < text.len());
        let bound = longest.is_some_and(|longest| whole_through(&text, found.start() + longest));
        line || bound
    });
    (found.map(|found| found.as_bytes().to_vec()), due)
}

/// Whether `text` holds the whole of the character byte `at` is in: walked as UTF-8 from the
/// start, each character a unit, and each byte of a sequence that is invalid a unit of its own,
/// but for a valid start of one cut short by the text's end, which more text would finish.
fn whole_through(text: &[u8], at: usize) -> bool {
    let mut start = 0;
    let mut chunks = text.utf8_chunks().peekable();
    while let Some(chunk) = chunks.next() {
        for character in chunk.valid().chars() {
            start += character.len_utf8();
            if at < start {
                return true;
            }
        }
        let invalid = chunk.invalid();
        let short = chunks.peek().is_none()
            && std::str::from_utf8(invalid).is_err_and(|error| error.error_len().is_none());
        start += invalid.len();
        if at < start {
            return !short;
        }
    }
    false
}

/// What a wait answers for `stream`, read in `reads` (their lengths) and taken by its thread in
/// batches (`batches[i]` reads each), as the session's reader and the wait's thread hand it over:
/// queued, chunked and matched, and the session's end settling what is left. With it, whether it
/// answered before the end.
///
/// With a `pause` (an offset a read ends at), the output goes quiet there for `QUIET`, which the
/// wait's thread meets with `Matcher::finish`, as `Waiter::wait` does once its timer runs out:
/// that call is the seam, made here at once, so no test sleeps.
fn answered(
    matcher: &Matcher,
    stream: &[u8],
    reads: &[usize],
    batches: &[usize],
    pause: Option<usize>,
) -> (Option<Vec<u8>>, bool) {
    let mut matcher = matcher.clone();
    let mut reads = reads.iter();
    let mut at = 0;
    for &batch in batches {
        let mut queue = Queue::default();
        for &read in reads.by_ref().take(batch) {
            queue.push(&stream[at..at + read], 0);
            at += read;
            // The thread takes what came before the pause, then hears nothing for `QUIET`.
            if pause == Some(at) {
                if let Some(found) = matcher.take(std::mem::take(&mut queue), |_| {}) {
                    return (Some(found), true);
                }
                if let Some(found) = matcher.finish() {
                    return (Some(found), true);
                }
            }
        }
        assert!(!queue.lagged, "the test's streams fit a queue");
        if let Some(found) = matcher.take(queue, |_| {}) {
            return (Some(found), true);
        }
    }
    assert_eq!(at, stream.len(), "every read is taken");
    (matcher.finish(), false)
}

/// [`oracle`], for a stream that goes quiet at `pause`: the output so far, searched once as if
/// it ended there, when that gives a match, which is then due; else the whole stream's answer.
fn oracle_paused(pattern: &str, stream: &[u8], pause: usize) -> (Option<Vec<u8>>, bool) {
    match oracle(pattern, &stream[..pause]) {
        (Some(found), _) => (Some(found), true),
        (None, _) => oracle(pattern, stream),
    }
}

/// `reads` cut so that one ends at `at`.
fn ending_at(reads: &[usize], at: usize) -> Vec<usize> {
    let mut out = Vec::new();
    let mut start = 0;
    for &read in reads {
        if start < at && at < start + read {
            out.extend([at - start, start + read - at]);
        } else {
            out.push(read);
        }
        start += read;
    }
    out
}

/// Whether `answered` gave what `oracle` says, and early enough.
fn agrees(answer: (Option<Vec<u8>>, bool), want: &(Option<Vec<u8>>, bool)) -> bool {
    answer.0 == want.0 && (answer.1 || !want.1)
}

/// A small, seeded generator, so a failure names the case that reproduces it.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        usize::try_from(self.next() % n as u64).unwrap()
    }

    fn one_in(&mut self, n: usize) -> bool {
        self.below(n) == 0
    }
}

/// The pieces a generated stream is made of: text, line ends, CSI, OSC (BEL and ST), a kitty
/// image's APC, a charset designation, a stray BEL, and multi-byte characters.
const PIECES: &[&str] = &[
    "READY",
    "DONE",
    "ok",
    "okay",
    "error",
    "warn",
    "warning",
    "TICK-",
    "7",
    "42",
    "ready in 312 ms",
    "x",
    " ",
    "écrit",
    "✓ done",
    "日本",
    "é",
    "本",
    "…",
    "𠀀",
    "🚀",
    "\r\n",
    "\r\n",
    "\n",
    "\r",
    "\x1b[1;32m",
    "\x1b[0m",
    "\x1b[2K",
    "\x1b[?25l",
    "\x1b]2;READY ok title\x07",
    "\x1b]8;;https://x.test/DONE\x1b\\",
    "\x1b_Ga=T,f=100;UkVBRFk=\x1b\\",
    "\x1b(B",
    "\x07",
];

/// A stream, and the offsets where it may go quiet: between its pieces, and inside a character
/// of one that is text, where a program's write ended mid-character. No sequence is open at any,
/// so the output so far strips as it would on its own.
fn stream(rng: &mut Rng) -> (Vec<u8>, Vec<usize>) {
    let mut out = Vec::new();
    let mut between = Vec::new();
    for _ in 0..3 + rng.below(30) {
        // Now and then a line longer than the window, so trims fall everywhere.
        if rng.one_in(60) {
            out.extend(std::iter::repeat_n(b'x', WINDOW + rng.below(3 * CHUNK)));
        }
        let piece = PIECES[rng.below(PIECES.len())];
        if !piece.contains('\x1b') {
            between.extend(
                piece
                    .char_indices()
                    .filter(|(_, character)| character.len_utf8() > 1)
                    .map(|(at, _)| out.len() + at + 1),
            );
        }
        out.extend_from_slice(piece.as_bytes());
        between.push(out.len());
    }
    (out, between)
}

/// `len` bytes cut into reads, each boundary a cut one time in `one_in`.
fn cuts(rng: &mut Rng, len: usize, one_in: usize) -> Vec<usize> {
    let mut reads = Vec::new();
    let mut read = 0;
    for _ in 0..len {
        read += 1;
        if rng.one_in(one_in) {
            reads.push(read);
            read = 0;
        }
    }
    if read > 0 {
        reads.push(read);
    }
    reads
}

/// A regex wait's answer, matched or not and the text it matched, is the same however its output
/// arrives: in one read or split anywhere, inside an escape sequence or a character included, and
/// however the wait's thread takes the reads in batches. Checked against the whole stream
/// searched once ([`oracle`]): every split of small streams, and a seeded sweep of generated ones
/// with lines longer than the window, and characters of two, three and four bytes beside word
/// boundaries. Output that goes quiet, at its end, between two pieces or inside a character, is
/// answered as the output so far searched once as if it ended there ([`oracle_paused`]). No
/// property-test crate: the workspace has none, and an exhaustive enumeration and a seeded
/// generator need no dependency.
#[test]
fn a_regex_waits_answer_is_the_same_however_its_output_is_split() {
    let matchers: Vec<(&str, Matcher)> = SPLIT_PATTERNS
        .iter()
        .map(|pattern| (*pattern, Matcher::new(pattern).expect("a valid pattern")))
        .collect();
    // Every way to split these into reads, each read its own batch.
    for small in [
        &b"\x1b[1mok\r\n"[..],
        b"DONE\nREADY\n",
        "é✓ done".as_bytes(),
        b"TICK-12\x07\n",
        b"\x1b]x\x07warn\n",
        b"DONEx\n",
        // Ending at a character of three bytes, and of four, a word's and not.
        "READY…".as_bytes(),
        "ok𠀀".as_bytes(),
        "ok🚀".as_bytes(),
        "xé本 ".as_bytes(),
    ] {
        for (pattern, matcher) in &matchers {
            let want = oracle(pattern, small);
            let quiet = oracle_paused(pattern, small, small.len());
            for mask in 0u32..1 << (small.len() - 1) {
                let mut reads = vec![1];
                for at in 0..small.len() - 1 {
                    match mask & (1 << at) {
                        0 => *reads.last_mut().unwrap() += 1,
                        _ => reads.push(1),
                    }
                }
                let batches = vec![1; reads.len()];
                // Half the splits end in the session's end, half in a quiet at the output's end.
                let (pause, want) = match mask % 2 {
                    0 => (None, &want),
                    _ => (Some(small.len()), &quiet),
                };
                let answer = answered(matcher, small, &reads, &batches, pause);
                assert!(
                    agrees(answer.clone(), want),
                    "{pattern:?} over {small:?} read as {reads:?}, quiet at {pause:?}: \
                     {answer:?}, not {want:?}"
                );
            }
        }
    }
    // Generated streams, each read three ways and batched at random.
    let mut rng = Rng(0x0690_5eed_cafe_f00d);
    for case in 0..60 {
        let (stream, between) = stream(&mut rng);
        // A stream with a line longer than the window is read in fewer, longer reads, as a pty
        // reads one: each read rescans the window, and a byte at a time would take minutes.
        let fine = if stream.len() > WINDOW {
            [300, 2_000]
        } else {
            [2, 9]
        };
        let ways: Vec<Vec<usize>> = [fine[0], fine[1], 400]
            .into_iter()
            .map(|one_in| cuts(&mut rng, stream.len(), one_in))
            .collect();
        for (pattern, matcher) in &matchers {
            for reads in &ways {
                // No quiet, one at the end, or one between two pieces.
                let pause = match rng.below(3) {
                    0 => None,
                    1 => Some(stream.len()),
                    _ => Some(between[rng.below(between.len())]),
                };
                let (reads, want) = match pause {
                    None => (reads.clone(), oracle(pattern, &stream)),
                    Some(at) => (ending_at(reads, at), oracle_paused(pattern, &stream, at)),
                };
                let reads = &reads;
                let mut batches = Vec::new();
                let mut left = reads.len();
                while left > 0 {
                    let batch = 1 + rng.below(left.min(8));
                    batches.push(batch);
                    left -= batch;
                }
                let answer = answered(matcher, &stream, reads, &batches, pause);
                assert!(
                    agrees(answer.clone(), &want),
                    "case {case}: {pattern:?} over {:?} read as {reads:?}, batched {batches:?}, \
                     quiet at {pause:?}: {answer:?}, not {want:?}",
                    String::from_utf8_lossy(&stream)
                );
            }
        }
    }
}

/// What the shadow says after a read that left the agent in `passed`, in order, ending in `agent`.
fn read_left(passed: &[State], agent: Option<State>) -> Seen {
    Seen {
        agent,
        passed: passed.to_vec(),
        ..Seen::default()
    }
}

/// Value: protects=`prompt --wait` answering on the `done` left from the turn before (#692); fails_when=a turn's end is taken before a fresh `working`, or a turn started and ended within one read is missed; why_new=no other wait needs one state after another; seam=none
#[test]
fn a_turn_ends_only_after_a_working_seen_since_it_started() {
    let now = |agent| read_left(&[], agent);
    let ended = |state| Some(Outcome::Met(Met::Turn(state)));
    // The `done` the turn before left, then `idle` and a report gone: none of them its end.
    let next = Waiter::new(Condition::Turn(Turn::Next), now(Some(State::Done)));
    for seen in [now(Some(State::Done)), now(Some(State::Idle)), now(None)] {
        next.shadow(&seen);
        assert_eq!(next.outcome(), None, "{seen:?}");
    }
    next.shadow(&now(Some(State::Working)));
    next.shadow(&now(Some(State::Working)));
    assert_eq!(next.outcome(), None, "still working");
    next.shadow(&now(Some(State::Blocked)));
    assert_eq!(next.outcome(), ended(Some(State::Blocked)));

    // Started and ended within one read.
    let quick = Waiter::new(Condition::Turn(Turn::Next), now(Some(State::Done)));
    quick.shadow(&read_left(
        &[State::Done, State::Working, State::Done],
        Some(State::Done),
    ));
    assert_eq!(quick.outcome(), ended(Some(State::Done)));

    // An agent working as the wait starts has started its turn; its report going ends it.
    let exited = Waiter::new(Condition::Turn(Turn::Next), now(Some(State::Working)));
    assert_eq!(exited.outcome(), None);
    exited.shadow(&read_left(&[State::Working], None));
    assert_eq!(exited.outcome(), ended(None));

    // The turn under way: any status but `working` ends it, now counting.
    let current = Waiter::new(Condition::Turn(Turn::Current), now(Some(State::Done)));
    assert_eq!(current.outcome(), ended(Some(State::Done)));
    let working = Waiter::new(Condition::Turn(Turn::Current), now(Some(State::Working)));
    assert_eq!(working.outcome(), None);
    working.shadow(&now(Some(State::Error)));
    assert_eq!(working.outcome(), ended(Some(State::Error)));
}

/// Value: protects=`prompt --wait` taking a turn the agent started before the prompt's Enter for the prompt's (#692); fails_when=a held turn starts on a `working` from a read at or before its mark; why_new=only a prompt holds its turn; seam=none
#[test]
fn a_held_turn_starts_only_on_a_working_read_after_its_mark() {
    let read = |reads, passed: &[State], agent| Seen {
        agent,
        passed: passed.to_vec(),
        reads,
        ..Seen::default()
    };
    let turn = Waiter::new(Condition::Turn(Turn::Next), read(3, &[], Some(State::Done)));
    turn.hold_turn();
    // Reading the paste, and a turn of its own, before the Enter: held, none of them counts.
    turn.shadow(&read(4, &[], Some(State::Working)));
    turn.shadow(&read(5, &[State::Working, State::Done], Some(State::Done)));
    assert_eq!(turn.outcome(), None);
    turn.mark_turn(6);
    // Read before the mark, told after it: still not the prompt's.
    turn.shadow(&read(6, &[State::Working, State::Done], Some(State::Done)));
    assert_eq!(turn.outcome(), None);
    turn.shadow(&read(7, &[], Some(State::Working)));
    turn.shadow(&read(8, &[], Some(State::Done)));
    assert_eq!(
        turn.outcome(),
        Some(Outcome::Met(Met::Turn(Some(State::Done))))
    );
}
