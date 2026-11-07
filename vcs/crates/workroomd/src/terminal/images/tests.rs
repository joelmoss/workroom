use super::*;

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// Value: protects=the chunk framing Kitty requires; fails_when=a chunk over 4096 bytes, or m=
/// flags that do not end at the last chunk; why_new=new; seam=none; no_claim=Ghostty's
/// acceptance, which the transfer tests in session.rs cover
#[test]
fn a_long_image_is_chunked_with_its_header_on_the_first_chunk_only() {
    let chunks: Vec<String> = transmit_chunks(7, &[0u8; 6000])
        .iter()
        .map(|chunk| text(chunk))
        .collect();
    assert_eq!(chunks.len(), 2);
    assert!(chunks[0].starts_with("\x1b_Ga=t,f=100,i=7,q=2,m=1;"));
    assert!(chunks[1].starts_with("\x1b_Gq=2,m=0;"));
    let payload = |chunk: &str| chunk.split(';').nth(1).unwrap_or("").len() - 2;
    assert_eq!(payload(&chunks[0]), 4096);
    assert_eq!(payload(&chunks[0]) + payload(&chunks[1]), 8000);
}

#[test]
fn a_short_image_is_one_final_chunk() {
    let chunks = transmit_chunks(7, &[0u8; 3]);
    assert_eq!(chunks.len(), 1);
    assert!(text(&chunks[0]).starts_with("\x1b_Ga=t,f=100,i=7,q=2,m=0;"));
}

/// Value: protects=the client is told to abort only when a load is open; fails_when=stop
/// reports the wrong state; why_new=new; seam=none; no_claim=none beyond protects
#[test]
fn stopping_says_whether_a_load_was_open() {
    let idle = Transfer::default();
    idle.encoded(Some((1, transmit_chunks(1, &[0u8; 6000]))));
    assert!(!idle.stop(), "nothing was sent");
    assert!(!idle.has_more(), "stopping drops the queue");

    let shadow = Shadow::new(80, 24);
    let sending = Transfer::default();
    sending.encoded(Some((1, transmit_chunks(1, &[0u8; 6000]))));
    assert!(sending.next_bytes(&shadow).is_some());
    assert!(sending.stop(), "a load is open on the client");
}

/// Value: protects=a transfer ends once its image is placed, so output stops being watched;
/// fails_when=is_finished ignores a queue; why_new=new; seam=none; no_claim=placement bytes
#[test]
fn a_transfer_finishes_when_nothing_is_left() {
    let shadow = Shadow::new(80, 24);
    let transfer = Transfer::default();
    transfer.encoded(Some((1, transmit_chunks(1, &[0u8; 3]))));
    assert!(!transfer.is_finished());
    assert!(transfer.next_bytes(&shadow).is_some(), "the chunk");
    assert!(!transfer.is_finished(), "still to be placed");
    assert!(transfer.has_more(), "the reader must come back to place it");
    assert_eq!(transfer.next_bytes(&shadow), None, "gone from the screen");
    assert!(transfer.is_finished());
}
