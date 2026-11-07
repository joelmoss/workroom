use super::*;

fn chunk(stream: u32, body: &[u8], is_final: bool) -> Envelope {
    let mut payload = vec![REQUEST_CHUNK_MARKER, u8::from(is_final)];
    payload.extend_from_slice(body);
    Envelope::new(Service::Vcs, stream, payload)
}

/// A request split across envelopes must reassemble to exactly the bytes that were sent, and a
/// single-envelope request must still be handled byte-identically — the chunk marker exists so
/// the common path pays nothing.
#[test]
fn a_chunked_request_reassembles_and_an_unchunked_one_is_untouched() {
    let mut partial = PartialRequests::default();
    let whole = br#"{"version":1,"method":"capabilities"}"#.to_vec();

    // Unchunked: returned as-is, nothing buffered.
    let got = reassemble(&mut partial, &Envelope::new(Service::Vcs, 7, whole.clone())).unwrap();
    assert_eq!(got, Some(whole.clone()));
    assert_eq!(
        partial.streams.len(),
        0,
        "an unchunked request left state behind"
    );

    // Chunked: nothing until the final chunk, then the exact original.
    assert_eq!(
        reassemble(&mut partial, &chunk(9, &whole[..10], false)).unwrap(),
        None
    );
    assert_eq!(
        reassemble(&mut partial, &chunk(9, &whole[10..20], false)).unwrap(),
        None
    );
    assert_eq!(partial.streams.len(), 1, "the buffer was not retained");
    assert_eq!(
        reassemble(&mut partial, &chunk(9, &whole[20..], true)).unwrap(),
        Some(whole)
    );
    assert_eq!(partial.streams.len(), 0, "the buffer outlived its request");
}

/// Two streams interleaved, because that is what a busy connection actually does — the buffers
/// are keyed by stream and must not bleed into one another.
#[test]
fn interleaved_chunked_requests_do_not_mix() {
    let mut partial = PartialRequests::default();
    assert_eq!(
        reassemble(&mut partial, &chunk(1, b"AAA", false)).unwrap(),
        None
    );
    assert_eq!(
        reassemble(&mut partial, &chunk(2, b"BBB", false)).unwrap(),
        None
    );
    assert_eq!(
        reassemble(&mut partial, &chunk(1, b"aaa", true)).unwrap(),
        Some(b"AAAaaa".to_vec())
    );
    assert_eq!(
        reassemble(&mut partial, &chunk(2, b"bbb", true)).unwrap(),
        Some(b"BBBbbb".to_vec())
    );
    assert_eq!(partial.streams.len(), 0);
}

/// Two connections both number their first stream 1 — the client resets `nextStream` on every
/// connect while this daemon deliberately outlives the app. A shared map would have let an
/// abandoned buffer from one launch prepend itself to the next launch's request, or, if that
/// entry were a poison, swallow a live request whole and answer nothing.
#[test]
fn one_connections_abandoned_chunks_cannot_reach_another() {
    let mut first = PartialRequests::default();
    assert_eq!(
        reassemble(&mut first, &chunk(1, b"ABANDONED", false)).unwrap(),
        None
    );
    // That connection ends here; its state goes with it.
    drop(first);

    let mut second = PartialRequests::default();
    let whole = br#"{"version":1,"method":"capabilities"}"#.to_vec();
    assert_eq!(
        reassemble(&mut second, &chunk(1, &whole, true)).unwrap(),
        Some(whole),
        "a previous connection's bytes reached this one"
    );
}

/// The hazard the poisoning exists for: a refused request keeps arriving, and reassembling its
/// tail as a fresh request would produce a SECOND reply on a stream the client has already
/// completed — which the client treats as an unknown stream id, a protocol violation that tears
/// down every other in-flight request on that connection.
#[test]
fn a_refused_chunked_request_swallows_its_remaining_chunks() {
    let mut partial = PartialRequests::default();
    // Fill past the total cap in one chunk, on a request that is NOT final.
    let huge = vec![b'x'; MAX_PARTIAL_TOTAL + 1];
    assert!(
        reassemble(&mut partial, &chunk(4, &huge, false)).is_err(),
        "the cap did not hold"
    );
    // Every later chunk is silent — no value to execute, and crucially no second error.
    assert_eq!(
        reassemble(&mut partial, &chunk(4, b"more", false)).unwrap(),
        None
    );
    assert_eq!(
        reassemble(&mut partial, &chunk(4, b"last", true)).unwrap(),
        None
    );
    // And the poison is cleared by that final chunk rather than leaking.
    assert_eq!(
        partial.streams.len(),
        0,
        "the poisoned stream was never cleared"
    );
}

/// Enforcing the stream-count cap must not itself break it. Poisoning is an insert, so refusing
/// the 33rd stream by recording a poison for it would grow the map to 33 — a limit that adds an
/// entry every time it is hit is not a limit.
#[test]
fn refusing_the_stream_cap_does_not_add_another_stream() {
    let mut partial = PartialRequests::default();
    for stream in 0..32u32 {
        assert_eq!(
            reassemble(&mut partial, &chunk(stream, b"x", false)).unwrap(),
            None
        );
    }
    assert_eq!(partial.streams.len(), 32);
    for stream in 100..110u32 {
        assert!(
            reassemble(&mut partial, &chunk(stream, b"x", false)).is_err(),
            "the 33rd stream was accepted"
        );
    }
    assert_eq!(
        partial.streams.len(),
        32,
        "refusals grew the map they were capping"
    );
}

/// A chunk with no continuation byte at all is malformed, not an empty request.
#[test]
fn a_truncated_chunk_header_is_refused() {
    let mut partial = PartialRequests::default();
    let envelope = Envelope::new(Service::Vcs, 5, vec![REQUEST_CHUNK_MARKER]);
    assert!(reassemble(&mut partial, &envelope).is_err());
}

// `admit` and `quiesce` are tested on a counter of their own: `ACTIVE` is shared with every
// other test in this crate, and quiescing it would refuse their requests.

#[test]
fn a_hand_off_stops_new_requests_and_waits_for_running_ones() {
    let count = Arc::new(AtomicUsize::new(0));
    assert!(admit(&count), "a request runs");
    let waiting = {
        let count = Arc::clone(&count);
        std::thread::spawn(move || quiesce(&count, std::time::Duration::from_secs(5)))
    };
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert!(
        !admit(&count),
        "a new request is refused while a hand-off waits"
    );
    count.fetch_sub(1, Ordering::AcqRel);
    assert!(
        waiting.join().expect("join"),
        "the wait ends once the running one finishes"
    );
    assert!(
        !admit(&count),
        "and nothing starts until the hand-off lets go"
    );
}

#[test]
fn a_hand_off_that_times_out_lets_requests_in_again() {
    let count = AtomicUsize::new(0);
    assert!(admit(&count));
    assert!(!quiesce(&count, std::time::Duration::from_millis(50)));
    assert!(
        admit(&count),
        "the timed-out wait must not leave requests refused"
    );
    assert_eq!(count.load(Ordering::Acquire), 2);
}
