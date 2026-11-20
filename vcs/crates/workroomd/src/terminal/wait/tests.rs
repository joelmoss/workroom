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
