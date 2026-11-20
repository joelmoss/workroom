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

/// The session's reader never waits on a regex: it only queues what it read, bounded, while the
/// wait's own thread matches. Here that thread is stuck mid-match (its matcher held) while the
/// reader hands over 1 MiB, a read at a time, and the reader still finishes; the queue stays
/// within `QUEUE`, dropping the oldest. Once the thread runs, it matches what it kept.
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
    {
        let progress = lock_or_recover(&waiter.state);
        assert!(
            progress.queue.bytes.len() <= QUEUE,
            "{}",
            progress.queue.bytes.len()
        );
        assert!(progress.queue.lagged, "1 MiB fits no queue");
    }
    drop(stuck);
    assert_eq!(
        waiter.wait(in_20s()),
        Outcome::Met(Met::Output(b"MARK-1".to_vec()))
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

/// A lagged queue keeps the newest output, and starts matching it from a fresh window: no match
/// joins text from either side of what was dropped, and the kept bytes, which may start inside a
/// sequence, start where it is known to end.
#[test]
fn a_lagged_queue_matches_only_what_it_kept() {
    let mut queue = Queue::default();
    queue.push(b"needle ");
    queue.push(&vec![b'x'; QUEUE]);
    assert!(queue.lagged);
    assert_eq!(queue.bytes.len(), QUEUE);
    let mut matcher = Matcher::new("needle").unwrap();
    assert_eq!(matcher.take(queue), None, "the needle was dropped");

    let mut queue = Queue::default();
    queue.push(&vec![b'x'; QUEUE]);
    queue.push(b"\x1b]2;title NOPE\x07\r\nDONE\r\n");
    let mut matcher = Matcher::new("NOPE|DONE").unwrap();
    assert_eq!(matcher.take(queue), Some(b"DONE".to_vec()));
}

/// What `pattern` first matches in `chunks`, for a wait that joined the stream mid-sequence.
fn first_match_resynced(pattern: &str, chunks: &[&[u8]]) -> Option<String> {
    let mut matcher = Matcher::new(pattern).expect("a valid pattern");
    matcher.resync();
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
    assert_eq!(
        first_match_resynced("NOPE|DONE", title).as_deref(),
        Some("DONE")
    );
    // Without knowing, the title's rest reads as text.
    assert_eq!(first_match("NOPE|DONE", title).as_deref(), Some("NOPE"));
    // The rest of `ESC _ G a=T,f=100;` and its base64, ended by ST.
    let kitty: &[&[u8]] = &[b"Tk9QRQ==NOPE", b"\x1b\\DONE\r\n"];
    assert_eq!(
        first_match_resynced("NOPE|DONE", kitty).as_deref(),
        Some("DONE")
    );
    // A line's end is known ground, and kept: `^` still anchors the next line.
    assert_eq!(
        first_match_resynced("^DONE$", &[b"le NOPE\r\nDONE\r\n"]).as_deref(),
        Some("DONE")
    );
}
