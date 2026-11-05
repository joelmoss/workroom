use super::*;

// Value: protects=`serve --own <dir>` can be given more than once and every folder is kept, in order;
// fails_when=flags() returns only the first or last value, or picks up another flag's value;
// why_new=nothing else reads a repeatable flag; seam=none; no_claim=what serve does with the folders
#[test]
fn a_repeatable_flag_gives_every_value_in_order() {
    let args: Vec<String> = ["serve", "--own", "/a", "--user", "u", "--own", "/b"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(flags(&args, "--own"), ["/a", "/b"]);
    assert_eq!(flags(&args, "--user"), ["u"]);
    assert!(flags(&args, "--screens").is_empty());
}

/// A stream that serves an endless login banner, counting how much of it is consumed.
///
/// The byte cap is what keeps a regression a FAILURE rather than a hung suite: without it a
/// handshake that never gives up would read forever. With it, both the fixed and the broken
/// version end in `Err` — so the discriminating assertion is the COUNT, not the result.
struct Banner {
    served: usize,
    cap: usize,
}

impl Read for Banner {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.served >= self.cap {
            return Ok(0);
        }
        const TEXT: &[u8] = b"Welcome to Ubuntu 24.04.1 LTS (GNU/Linux)\r\n";
        buffer[0] = TEXT[self.served % TEXT.len()];
        self.served += 1;
        Ok(1)
    }
}

impl Write for Banner {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A peer that is not a daemon must be rejected on the first byte that cannot be the magic.
///
/// `serve --stdio` over ssh is the stated remote path, so an MOTD or an ssh warning on the
/// stream is expected input, not a hostile one. `Hello::decode` reports `NotADaemon`
/// immediately for exactly this reason; the relay used to discard that error and loop one byte
/// at a time, appending each to an unbounded buffer, so the banner hung the client instead of
/// failing it.
#[test]
fn a_login_banner_is_rejected_without_reading_it_all() {
    let mut banner = Banner {
        served: 0,
        cap: 64 * 1024,
    };

    assert!(handshake(&mut banner).is_err(), "a banner is not a daemon");
    assert!(
        banner.served <= 8,
        "consumed {} bytes of the banner before giving up — the decode error is being \
             swallowed and the loop is reading to EOF",
        banner.served
    );
}

/// The control: a real daemon greeting still completes, so the rejection above is not simply
/// "this handshake never succeeds".
#[test]
fn a_real_daemon_greeting_still_handshakes() {
    struct Peer {
        greeting: Vec<u8>,
        offset: usize,
    }
    impl Read for Peer {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            if self.offset >= self.greeting.len() {
                return Ok(0);
            }
            buffer[0] = self.greeting[self.offset];
            self.offset += 1;
            Ok(1)
        }
    }
    impl Write for Peer {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    let mut peer = Peer {
        greeting: Hello::current("test").encode(),
        offset: 0,
    };
    assert!(handshake(&mut peer).is_ok());
}
