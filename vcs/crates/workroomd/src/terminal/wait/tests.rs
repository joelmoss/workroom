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
        Condition::Output(Matcher::new(pattern).expect("a valid pattern")),
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

/// A window trimmed where no line starts keeps text that starts mid-line, where `^` doesn't
/// match; one trimmed at a line's start keeps `^` there.
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
    assert_eq!(matcher.window_len(), 1, "trimmed to the line's start");
    assert_eq!(matcher.feed(b"z").as_deref(), Some(&b"yz"[..]));
}
