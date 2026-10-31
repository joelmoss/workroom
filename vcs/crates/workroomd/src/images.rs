//! Restoring Kitty images to a client that reattaches (#551).
//!
//! The text repaint cannot carry an image: the formatter emits none, and one image can be larger
//! than the whole repaint budget. So after the repaint a client gets its visible images as a
//! background transfer of Kitty escape sequences, the same VT bytes a program would send.
//!
//! **The session's reader writes every byte of a transfer, on purpose.** ADR 0010 promises a
//! client the pty's bytes untouched, and a read can end anywhere, including inside an escape
//! sequence or a UTF-8 character, where an inserted chunk prints garbage. Only the reader knows
//! the stream is between sequences for every client, because the shadow is one read ahead of a
//! client until the reader has delivered that read. A second writer would need that state shared
//! across threads, under a lock order opposite to `attach`'s.
//!
//! ```text
//! attach    repaint -> client registered -> visible images queued here
//! encoders  a slot is free -> copy pixels from the shadow -> PNG -> chunks on the Transfer
//! reader    read -> shadow -> disturbed? stop, m=0 -> deliver
//!           at ground: place a finished image, or send one chunk
//! ```

use std::collections::VecDeque;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use crate::pty::Pty;
use crate::shadow::Shadow;

/// Ends a chunked load. It clears what a transfer cut off midway left behind, which would
/// otherwise swallow the next image a program sends, so every repaint starts with it.
pub const ABORT: &[u8] = b"\x1b_Gm=0,q=2;\x1b\\";

/// The most base64 in one Kitty chunk, from the protocol.
const CHUNK_BYTES: usize = 4096;

/// How many images are encoded at once across the daemon. Pixels are copied out of the shadow only
/// when an encode starts, so this is also how many raw copies exist.
const ENCODERS: usize = 2;

/// An image in a shadow's storage. The generation changes when a program replaces it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageRef {
    pub id: u32,
    pub generation: u64,
}

/// Where a placement stands when the reader asks for it.
#[derive(Debug, PartialEq, Eq)]
pub enum Placement {
    /// The cursor cannot go there and back unnoticed yet: try after the next read.
    Hold,
    /// The bytes to place it. Empty when it has scrolled away.
    Ready(Vec<u8>),
}

/// `id`'s PNG as Kitty transmit chunks. No placement: that comes when the pixels have arrived, at
/// wherever the image is by then.
fn transmit_chunks(id: u32, png: &[u8]) -> VecDeque<Vec<u8>> {
    let encoded = crate::file::base64(png);
    let parts: Vec<&[u8]> = encoded.as_bytes().chunks(CHUNK_BYTES).collect();
    let last = parts.len().saturating_sub(1);
    parts
        .iter()
        .enumerate()
        .map(|(index, part)| {
            let first = if index == 0 {
                format!("a=t,f=100,i={id},")
            } else {
                String::new()
            };
            let more = u8::from(index != last);
            let mut chunk = format!("\x1b_G{first}q=2,m={more};").into_bytes();
            chunk.extend_from_slice(part);
            chunk.extend_from_slice(b"\x1b\\");
            chunk
        })
        .collect()
}

/// `id`'s PNG as one run of bytes, for a screen no live output can interleave with: a hand-off's.
#[cfg(feature = "terminal-state")]
pub fn transmit_bytes(id: u32, png: &[u8]) -> Vec<u8> {
    transmit_chunks(id, png).into_iter().flatten().collect()
}

#[derive(Default)]
struct Queues {
    /// Encoded, waiting their turn.
    ready: VecDeque<(u32, VecDeque<Vec<u8>>)>,
    /// The image part way out, and its chunks still to go.
    sending: Option<(u32, VecDeque<Vec<u8>>)>,
    /// Sent in full, waiting to be placed.
    placing: VecDeque<u32>,
    /// Images an encoder has yet to finish with.
    encoding: usize,
    /// The next placement could not go last time, so only more output can release it.
    held: bool,
    stopped: bool,
}

/// One client's images on their way. Owned by the `Client`, so it goes when the client does; an
/// encoder holds only a `Weak` and drops work nobody is left to receive.
#[derive(Default)]
pub struct Transfer {
    queues: Mutex<Queues>,
}

impl Transfer {
    /// An encoder has finished with an image, with its chunks if it has any.
    fn encoded(&self, encoded: Option<(u32, VecDeque<Vec<u8>>)>) {
        if let Ok(mut queues) = self.queues.lock() {
            queues.encoding = queues.encoding.saturating_sub(1);
            if let (false, Some(image)) = (queues.stopped, encoded) {
                queues.ready.push_back(image);
            }
        }
    }

    /// Whether there is nothing left to send or place, so output need not be watched for it.
    pub fn is_finished(&self) -> bool {
        self.queues.lock().map_or(true, |queues| {
            queues.encoding == 0
                && queues.ready.is_empty()
                && queues.sending.is_none()
                && queues.placing.is_empty()
        })
    }

    /// Ends the transfer. Returns whether the client is part way through a load, and so needs
    /// `ABORT`.
    pub fn stop(&self) -> bool {
        let Ok(mut queues) = self.queues.lock() else {
            return false;
        };
        let loading = queues.sending.is_some();
        *queues = Queues {
            stopped: true,
            ..Queues::default()
        };
        loading
    }

    /// Whether the client is part way through a load.
    pub fn is_loading(&self) -> bool {
        self.queues
            .lock()
            .is_ok_and(|queues| queues.sending.is_some())
    }

    fn is_stopped(&self) -> bool {
        self.queues.lock().map_or(true, |queues| queues.stopped)
    }

    /// The next bytes for the client, for the reader to deliver at ground: a finished image's
    /// placement first, then one chunk, so a transfer never holds the writer for longer.
    pub fn next_bytes(&self, shadow: &Shadow) -> Option<Vec<u8>> {
        let mut queues = self.queues.lock().ok()?;
        if let Some(id) = queues.placing.front().copied() {
            match shadow.placement(id, false) {
                Placement::Hold => queues.held = true,
                Placement::Ready(bytes) => {
                    queues.held = false;
                    queues.placing.pop_front();
                    if !bytes.is_empty() {
                        return Some(bytes);
                    }
                }
            }
        }
        if queues.sending.is_none() {
            queues.sending = queues.ready.pop_front();
        }
        let (id, chunks) = queues.sending.as_mut()?;
        let id = *id;
        let chunk = chunks.pop_front();
        if chunks.is_empty() {
            queues.sending = None;
            queues.placing.push_back(id);
        }
        chunk
    }

    /// Whether the reader should come straight back: there is more it can send now.
    pub fn has_more(&self) -> bool {
        self.queues.lock().is_ok_and(|queues| {
            queues.sending.is_some()
                || !queues.ready.is_empty()
                || (!queues.placing.is_empty() && !queues.held)
        })
    }
}

/// One image to encode for one client.
struct Job {
    image: ImageRef,
    shadow: Weak<Mutex<Shadow>>,
    pty: Weak<Pty>,
    transfer: Weak<Transfer>,
}

impl Job {
    fn run(self) {
        let Some(transfer) = self.transfer.upgrade() else {
            return;
        };
        let encoded = (!transfer.is_stopped())
            .then(|| self.encode())
            .flatten()
            .map(|png| (self.image.id, transmit_chunks(self.image.id, &png)));
        transfer.encoded(encoded);
        if let Some(pty) = self.pty.upgrade() {
            pty.wake_reader();
        }
    }

    fn encode(&self) -> Option<Vec<u8>> {
        // The lock is held for the copy alone. The reader is what waits on it.
        let pixels = self.shadow.upgrade()?.lock().ok()?.pixels(self.image)?;
        pixels.to_png()
    }
}

fn encoders() -> &'static Mutex<Sender<Job>> {
    static SENDER: OnceLock<Mutex<Sender<Job>>> = OnceLock::new();
    SENDER.get_or_init(|| {
        let (sender, receiver) = channel::<Job>();
        let receiver = Arc::new(Mutex::new(receiver));
        for _ in 0..ENCODERS {
            let receiver = Arc::clone(&receiver);
            let _ = std::thread::Builder::new()
                .name("image-encoder".into())
                .spawn(move || encode_forever(&receiver));
        }
        Mutex::new(sender)
    })
}

fn encode_forever(receiver: &Mutex<Receiver<Job>>) {
    loop {
        // Released before the work, so the other encoder can take the next job.
        let job = match receiver.lock() {
            Ok(receiver) => receiver.recv(),
            Err(_) => return,
        };
        let Ok(job) = job else {
            return;
        };
        job.run();
    }
}

/// Queues `images` for a client. Returns its transfer, or nothing when there are no images, so a
/// session without any never reaches an encoder thread.
pub fn start_transfer(
    images: Vec<ImageRef>,
    shadow: &Arc<Mutex<Shadow>>,
    pty: &Arc<Pty>,
) -> Option<Arc<Transfer>> {
    if images.is_empty() {
        return None;
    }
    let transfer = Arc::new(Transfer {
        queues: Mutex::new(Queues {
            encoding: images.len(),
            ..Queues::default()
        }),
    });
    let sender = encoders().lock().ok()?;
    for image in images {
        let job = Job {
            image,
            shadow: Arc::downgrade(shadow),
            pty: Arc::downgrade(pty),
            transfer: Arc::downgrade(&transfer),
        };
        if sender.send(job).is_err() {
            return None;
        }
    }
    Some(transfer)
}

#[cfg(test)]
mod tests {
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
}
