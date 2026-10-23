//! The binary's subcommands. `main.rs` parses the command line and calls one of these; everything
//! a subcommand does, beyond reading its own flags, lives here.

pub mod attach;
pub mod credential;
pub mod hand_off;
pub mod list;
pub mod program_status;
pub mod relay;
pub mod run_script;
pub mod run_supervisor;
pub mod serve;

use std::io::{Read, Write};
use std::process::ExitCode;

use crate::handoff;
use crate::serve::BUILD;
use wr_protocol::envelope::{
    Hello, MIN_FILE_VERSION, MIN_FORWARD_VERSION, MIN_HANDOFF_VERSION, MIN_LAYOUT_VERSION,
    MIN_PROGRAM_STATUS_VERSION, MIN_RUN_VERSION, MIN_SUPPORTED_VERSION, MIN_VCS_VERSION,
    PROTOCOL_VERSION, negotiate,
};

pub fn flag(args: &[String], name: &str) -> Option<String> {
    let index = args.iter().position(|a| a == name)?;
    args.get(index + 1).cloned()
}

/// Hands this process's crashes, and those of everything it starts, back to the kernel (#329).
///
/// The app's crash reporter (Sentry) takes the app's crashes through a Mach exception port, and
/// every process the app starts inherits that port: this daemon, then each session's shell and all
/// it runs. A crash in one of those goes to the app's handler, which never answers for another
/// process, so the faulting thread waits forever and the SIGSEGV a Go or C program would recover
/// from never arrives. With no port, the kernel delivers the signal as usual.
///
/// Not under a debugger: lldb catches breakpoints through the same ports, and launched under it
/// the daemon would die at the first one. Its sessions then inherit the debugger's port instead.
#[cfg(target_os = "macos")]
pub fn drop_inherited_exception_ports() {
    // <sys/proc_info.h>
    const PROC_FLAG_TRACED: u32 = 2;
    // SAFETY: `proc_bsdshortinfo` is plain old data, for which all zeroes is a valid value.
    let mut info: libc::proc_bsdshortinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdshortinfo>() as libc::c_int;
    // SAFETY: the buffer is `info` itself and `size` is its exact size, so the kernel cannot write
    // past it.
    let written = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDT_SHORTBSDINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    if written == size && info.pbsi_flags & PROC_FLAG_TRACED != 0 {
        return;
    }
    unsafe extern "C" {
        // What <mach/mach_init.h>'s `mach_task_self()` reads.
        static mach_task_self_: libc::mach_port_t;
        fn task_set_exception_ports(
            task: libc::mach_port_t,
            exception_mask: libc::c_uint,
            new_port: libc::mach_port_t,
            behavior: libc::c_int,
            new_flavor: libc::c_int,
        ) -> libc::c_int;
    }
    // <mach/exception_types.h> and <mach/thread_status.h>.
    const EXC_MASK_ALL: libc::c_uint = 0x1bfe;
    const EXCEPTION_DEFAULT: libc::c_int = 1;
    #[cfg(target_arch = "aarch64")]
    const THREAD_STATE_NONE: libc::c_int = 5;
    #[cfg(target_arch = "x86_64")]
    const THREAD_STATE_NONE: libc::c_int = 13;
    const MACH_PORT_NULL: libc::mach_port_t = 0;
    // Nothing to do on failure: the daemon runs as before, only without the fix.
    // SAFETY: libSystem sets `mach_task_self_` before `main` and never changes it, and the call
    // takes only integers and port names.
    let _ = unsafe {
        task_set_exception_ports(
            mach_task_self_,
            EXC_MASK_ALL,
            MACH_PORT_NULL,
            EXCEPTION_DEFAULT,
            THREAD_STATE_NONE,
        )
    };
}

/// Exit code the app already knows: `SessionAttachClient.daemonUnavailable`.
pub(crate) const DAEMON_UNAVAILABLE: u8 = 92;

/// Exchange greetings and agree a version before anything else crosses the stream. Returns the
/// peer's own version, which a version-gated request is checked against (never the negotiated one).
pub(crate) fn handshake<S: Read + Write>(stream: &mut S) -> Result<u16, ()> {
    let local = Hello::current(BUILD);
    stream.write_all(&local.encode()).map_err(|_| ())?;
    let _ = stream.flush();

    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    let remote = loop {
        // `Err` is a DECISION, not a "keep reading". `Hello::decode` reports `NotADaemon` on the
        // first byte that cannot be the magic — that early rejection is the whole reason the magic
        // exists, and its own doc says so: "otherwise an ssh banner stalls the connection instead
        // of reporting it".
        //
        // Swallowing it with `if let Ok(Some(..))` did exactly what the magic was added to prevent:
        // a peer that is not a daemon looped forever, one byte per iteration, appending each to
        // `greeting` without bound. An MOTD or an ssh warning on the stream hung the relay instead
        // of failing to `DAEMON_UNAVAILABLE` — and `serve --stdio` over ssh is the stated remote
        // path, so a banner is expected input rather than a hostile one. `serve.rs` propagates the
        // same error with `?`; this side now agrees with it.
        match Hello::decode(&greeting) {
            Ok(Some((hello, _))) => break hello,
            Err(_) => return Err(()),
            Ok(None) => {}
        }
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => return Err(()),
            Ok(_) => greeting.push(byte[0]),
        }
    };
    negotiate(&local, &remote).map_err(|_| ())?;
    Ok(remote.protocol_version)
}

/// `workroomd protocol`: what this build speaks, for the app's probe.
pub fn protocol() -> ExitCode {
    // The per-service minimums appended at the end, in the order they were introduced —
    // `SessionBackendProbe.parseProtocolVersion` (Swift) is explicitly "tolerant of trailing
    // detail by design", reading only the leading `protocol <n>` token, so this is safe to
    // grow without a matching app release. `DaemonVCSProtocolTests` checks every number but
    // `min-handoff` (which only `hand-off` reads) against the shipped binary; keep this
    // line's tokens in this order if it grows again.
    println!(
        "protocol {PROTOCOL_VERSION} (minimum supported {MIN_SUPPORTED_VERSION}) \
         min-vcs {MIN_VCS_VERSION} min-file {MIN_FILE_VERSION} \
         min-forward {MIN_FORWARD_VERSION} \
         min-handoff {MIN_HANDOFF_VERSION} min-layout {MIN_LAYOUT_VERSION} \
         min-program-status {MIN_PROGRAM_STATUS_VERSION} min-run {MIN_RUN_VERSION}"
    );
    println!("build {BUILD}");
    // The order between builds (#255): the app's probe reads it to decide whether to push.
    println!("build-number {}", handoff::build_number());
    // Whether this build can repaint a reattaching client. A build without it serves
    // sessions perfectly well and then hands a reconnecting pane a blank screen, which is
    // invisible until someone quits the app and comes back — so it is stated here and
    // asserted against the shipped binary by macapp/Scripts/build-daemon_test.sh.
    println!(
        "terminal-state {}",
        if cfg!(feature = "terminal-state") {
            "yes"
        } else {
            "no"
        }
    );
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
