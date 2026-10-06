//! Keeping a busy box awake (issue #257).
//!
//! A provider that sleeps an idle machine decides "idle" by watching its network: boxd's suspend
//! and hibernate timers are both "idle network seconds" (design doc, Phase 0 item 5), and a probe
//! on 2026-10-05 showed one datagram to the default gateway resets them. A box with 120 s timers
//! stayed awake for six minutes on one a minute, and hibernated 120 s after the last one with its
//! job still running, while the box's own background chatter (40-140 bytes per 10 s) did not hold
//! it. So while the published verdict is BUSY the service sends one, and when it is IDLE (an idle
//! box, or a ceiling prompt nobody answered) or the agent has died, nothing is sent and the
//! provider's own timer decides. Nothing on the provider is changed, so nothing has to be put back
//! after a crash or an update, and no credential is needed.
//!
//! ```text
//!   each tick, with the published verdict
//!     IDLE ------------------------------------------> forget the last send; nothing sent
//!     BUSY, and no send yet or INTERVAL_S since the last one
//!       -> default gateway from /proc/net/route
//!            none ----------------------------------> error; due again next tick
//!            found -> 1-byte UDP datagram to it, port 9, non-blocking
//!                       sent ------------------------> last send = now, error cleared
//!                       failed ----------------------> error; due again next tick
//! ```
//!
//! About 30 bytes a minute on the wire, against the classifier's 500 bytes/s net threshold
//! (`vcs/scripts/oq19/results/frozen.json`), so the heartbeat cannot vote its own box BUSY.
//!
//! ponytail: IPv4 default gateway only. An IPv6-only box, or a default route with no gateway
//! (`default dev wg0`), reports an error and is shown unprotected; send to the route's own
//! interface, or over IPv6, if a provider ever hands out such a box.

use std::net::{Ipv4Addr, UdpSocket};

use super::{Ceiling, Verdict};

/// Measured: one a minute held a box whose timers were 120 s. A provider whose idle window is
/// shorter than this cannot be kept awake by it.
const INTERVAL_S: f64 = 60.0;

/// The discard port: nothing is expected to answer, and nothing needs to. The datagram only has to
/// cross the box's interface.
const PORT: u16 = 9;

/// The heartbeat's cadence, and what the status reports of it: when the last datagram went out,
/// and why the last one could not be. Pure apart from `send`, so the service's bookkeeping is
/// testable on any host.
#[derive(Debug, Default)]
pub struct KeepAwake {
    /// The send the next one is due a minute after. IDLE forgets it, so the box's next BUSY tick
    /// sends at once rather than up to a minute late.
    due_from: Option<f64>,
    pub last_sent: Option<f64>,
    /// Set means the box is BUSY and NOT being kept awake.
    pub error: Option<String>,
}

impl KeepAwake {
    /// One tick. The heartbeat follows the PUBLISHED verdict, after the ceiling, so an unanswered
    /// prompt stops it; taking the ceiling rather than a verdict keeps a caller from passing the
    /// classifier's raw one. `send` sends one datagram; only one that went out moves the cadence,
    /// so a failed send is due again on the next tick.
    pub fn tick(
        &mut self,
        t: f64,
        ceiling: &Ceiling,
        raw: Verdict,
        send: impl FnOnce() -> Result<(), String>,
    ) {
        if ceiling.published(raw) != Verdict::Busy {
            // Nothing to keep awake, so an old error no longer means anything.
            self.due_from = None;
            self.error = None;
            return;
        }
        if self.due_from.is_some_and(|last| t - last < INTERVAL_S) {
            // Between sends: the last outcome stands.
            return;
        }
        match send() {
            Ok(()) => {
                self.due_from = Some(t);
                self.last_sent = Some(t);
                self.error = None;
            }
            Err(error) => self.error = Some(error),
        }
    }

    /// The box resumed from a sleep: send on the next BUSY tick, whatever the last send's age
    /// reads as. The provider's idle timer started over with the resume, and a sleep shorter than a
    /// minute would otherwise leave the next send up to a minute away.
    pub fn resumed(&mut self) {
        self.due_from = None;
    }
}

/// The IPv4 default gateway in `/proc/net/route`'s text, the lowest metric's when there are
/// several.
///
/// The kernel prints each address as the hex of a `u32` that holds the address's network-order
/// bytes, read in host order, so the native byte order turns it back into the address on any host.
fn default_gateway(route: &str) -> Option<Ipv4Addr> {
    const RTF_UP: u32 = 0x1;
    const RTF_GATEWAY: u32 = 0x2;
    let hex = |field: &str| u32::from_str_radix(field, 16).ok();
    route
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let (destination, gateway, flags, metric, mask) = (
                hex(fields.get(1)?)?,
                hex(fields.get(2)?)?,
                hex(fields.get(3)?)?,
                fields.get(6)?.parse::<u32>().ok()?,
                hex(fields.get(7)?)?,
            );
            let usable = flags & (RTF_UP | RTF_GATEWAY) == RTF_UP | RTF_GATEWAY;
            (destination == 0 && mask == 0 && usable)
                .then_some((metric, Ipv4Addr::from(gateway.to_ne_bytes())))
        })
        .min_by_key(|(metric, _)| *metric)
        .map(|(_, gateway)| gateway)
}

/// One datagram to the default gateway, looked up afresh each time so a changed route is followed.
/// A fresh socket each time: at one a minute there is nothing worth keeping between sends. Never
/// blocks the tick: the socket is non-blocking, so a full send buffer is an error like any other
/// and is retried on the next tick.
pub fn send() -> Result<(), String> {
    let route = std::fs::read_to_string("/proc/net/route")
        .map_err(|e| format!("reading /proc/net/route: {e}"))?;
    let gateway = default_gateway(&route).ok_or("no IPv4 default route")?;
    send_to(gateway, PORT)
}

fn send_to(address: Ipv4Addr, port: u16) -> Result<(), String> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
        .map_err(|e| format!("opening a UDP socket: {e}"))?;
    socket
        .set_nonblocking(true)
        .map_err(|e| format!("making the UDP socket non-blocking: {e}"))?;
    socket
        .send_to(&[0], (address, port))
        .map(|_| ())
        .map_err(|e| format!("sending to {address}:{port}: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// The box's verdict over time, and the ticks a datagram goes out on.
    #[test]
    fn sends_on_the_first_busy_tick_then_once_a_minute_and_never_while_idle() {
        // (name, the verdict each tick, the ticks a datagram goes out on)
        type Case<'a> = (&'a str, &'a [(f64, Verdict)], &'a [f64]);
        let cases: &[Case] = &[
            (
                "an idle box sends nothing",
                &[(0.0, Verdict::Idle), (60.0, Verdict::Idle)],
                &[],
            ),
            (
                "the first BUSY tick sends, then every 60 s",
                &[
                    (10.0, Verdict::Busy),
                    (11.0, Verdict::Busy),
                    (69.0, Verdict::Busy),
                    (70.0, Verdict::Busy),
                    (130.0, Verdict::Busy),
                ],
                &[10.0, 70.0, 130.0],
            ),
            (
                "IDLE forgets the last send, so BUSY again sends at once",
                &[
                    (0.0, Verdict::Busy),
                    (20.0, Verdict::Idle),
                    (30.0, Verdict::Busy),
                ],
                &[0.0, 30.0],
            ),
        ];
        let c = Ceiling::new(Default::default());
        for (name, ticks, expected) in cases {
            let mut k = KeepAwake::default();
            let mut sent = Vec::new();
            for &(t, verdict) in *ticks {
                k.tick(t, &c, verdict, || {
                    sent.push(t);
                    Ok(())
                });
            }
            assert_eq!(&sent, expected, "{name}");
        }
    }

    /// What the status shows: an error while a BUSY box cannot be kept awake, cleared by a send or
    /// by the box going IDLE, and a failed send is never recorded as sent.
    #[test]
    fn the_status_shows_the_last_send_and_why_the_last_one_failed() {
        let c = Ceiling::new(Default::default());
        let mut k = KeepAwake::default();
        k.tick(0.0, &c, Verdict::Busy, || Ok(()));
        assert_eq!((k.last_sent, k.error.as_deref()), (Some(0.0), None));

        k.tick(60.0, &c, Verdict::Busy, || {
            Err("no IPv4 default route".into())
        });
        assert_eq!(
            (k.last_sent, k.error.as_deref()),
            (Some(0.0), Some("no IPv4 default route")),
            "a failed send is not recorded as sent"
        );

        let mut called = false;
        k.tick(61.0, &c, Verdict::Busy, || {
            called = true;
            Ok(())
        });
        assert!(called, "a failed send is due again on the next tick");
        assert_eq!((k.last_sent, k.error.as_deref()), (Some(61.0), None));

        k.tick(62.0, &c, Verdict::Busy, || Err("not due".into()));
        assert_eq!(k.error, None, "nothing is sent between sends");

        // A resume: the last send was a moment ago on the monotonic clock, but the box slept.
        k.tick(70.0, &c, Verdict::Busy, || Ok(()));
        k.resumed();
        let mut called = false;
        k.tick(71.0, &c, Verdict::Busy, || {
            called = true;
            Ok(())
        });
        assert!(called, "a resumed box sends on its next BUSY tick");

        k.tick(131.0, &c, Verdict::Busy, || Err("send failed".into()));
        k.tick(122.0, &c, Verdict::Idle, || {
            unreachable!("IDLE sends nothing")
        });
        assert_eq!(k.error, None, "an IDLE box has nothing to keep awake");
    }

    #[test]
    fn finds_the_default_gateway() {
        let header =
            "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n";
        // 10.33.0.1 is the boxd probe's gateway: bytes 0A 21 00 01, printed host-order.
        let gateway = u32::from_ne_bytes([10, 33, 0, 1]);
        let other = u32::from_ne_bytes([172, 17, 0, 1]);
        let line = |iface: &str, dest: u32, gw: u32, flags: u32, metric: u32, mask: u32| {
            format!(
                "{iface}\t{dest:08X}\t{gw:08X}\t{flags:04X}\t0\t0\t{metric}\t{mask:08X}\t0\t0\t0\n"
            )
        };
        let subnet = u32::from_ne_bytes([10, 33, 0, 0]);
        let netmask = u32::from_ne_bytes([255, 255, 0, 0]);
        let cases: &[(&str, String, Option<Ipv4Addr>)] = &[
            (
                "the boxd shape: a default and the local subnet",
                format!(
                    "{header}{}{}",
                    line("eth0", 0, gateway, 0x3, 0, 0),
                    line("eth0", subnet, 0, 0x1, 0, netmask)
                ),
                Some(Ipv4Addr::new(10, 33, 0, 1)),
            ),
            (
                "no default route",
                format!("{header}{}", line("eth0", subnet, 0, 0x1, 0, netmask)),
                None,
            ),
            (
                "a default that is down does not count",
                format!("{header}{}", line("eth0", 0, gateway, 0x2, 0, 0)),
                None,
            ),
            (
                "the lowest metric wins",
                format!(
                    "{header}{}{}",
                    line("eth1", 0, other, 0x3, 200, 0),
                    line("eth0", 0, gateway, 0x3, 100, 0)
                ),
                Some(Ipv4Addr::new(10, 33, 0, 1)),
            ),
            (
                "a default with no gateway (`default dev wg0`)",
                format!("{header}{}", line("wg0", 0, 0, 0x1, 0, 0)),
                None,
            ),
            ("an empty table", header.to_string(), None),
            ("a garbled line", format!("{header}eth0\tzz\n"), None),
        ];
        for (name, table, expected) in cases {
            assert_eq!(default_gateway(table), *expected, "{name}");
        }
        // A line as an x86_64 or aarch64 kernel prints it, not built with the convention under
        // test: the boxd probe's 10.33.0.1 is `0100210A`.
        #[cfg(target_endian = "little")]
        assert_eq!(
            default_gateway(&format!(
                "{header}eth0\t00000000\t0100210A\t0003\t0\t0\t0\t00000000\t0\t0\t0\n"
            )),
            Some(Ipv4Addr::new(10, 33, 0, 1))
        );
    }

    /// The real socket path, to a listener standing in for the gateway: the datagram arrives.
    #[test]
    fn a_datagram_reaches_the_address() {
        let listener = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        listener
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        send_to(Ipv4Addr::LOCALHOST, listener.local_addr().unwrap().port()).unwrap();
        let mut buffer = [9u8; 8];
        let (n, _) = listener.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..n], &[0]);
    }
}
