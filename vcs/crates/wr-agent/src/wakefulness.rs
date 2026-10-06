//! Is this box busy? The wakefulness service (OQ19, issue #208).
//!
//! A remote workroom's provider hibernates an idle box. The agent is the only thing on the box that
//! knows whether the box is idle, so it decides BUSY or IDLE once a second and publishes the
//! verdict. While the published verdict is BUSY it also keeps the box awake, with a small network
//! heartbeat the provider's idle timer counts ([`heartbeat`], issue #257). Nothing here calls a
//! provider or changes its settings: the heartbeat stopping is all it takes for the box to sleep.
//!
//! **The policy is not invented here.** It is P4, frozen in
//! `vcs/scripts/oq19/results/frozen.json` and measured in
//! `docs/designs/oq19-wakefulness-measurements.md`: zero false-idle and zero busy-forever errors on
//! 150 closed-loop hold-out runs, confirmed on a real provider. `vcs/scripts/oq19/golden/` holds ten
//! of those runs with their expected verdict change-points, and the test at the bottom of this file
//! replays all ten through the code below and demands EXACT equality. A mismatch is a bug here, never
//! a reason to touch the fixtures.
//!
//! What differs from the Python that was measured, and why:
//!
//! * **Sockets come from `/proc/net/tcp`, not `ss -tinp`.** The frozen policy has `age: null`, so an
//!   ESTAB socket counts at any age and the `last*` timings are never compared. The `ss` fork was
//!   measured at ~0.75% of a core per Hz against a 0.5% budget.
//! * **The classifier's own descendants are not excluded in production.** In the harness the sampler
//!   is a sibling of the work and the closure catches only its `ss` forks; here the agent is the
//!   *parent* of every pty session, so excluding its descendants would empty the candidate set. That
//!   is boundary.md's amendment 2 ("a process that hosts user work excludes only itself") and the
//!   failure mode it names, so [`Boundary::own_descendants`] is explicit and the replay is the only
//!   caller that sets it.
//! * **Session leaders are not excluded.** `boundary.md` excludes them ("a leader at its prompt is
//!   not work"), but a leader at its prompt votes through no signal, so the ten fixtures replay
//!   exactly without the exclusion — and with it, a leader that IS the work (a command session's
//!   `exec`ed program, a shell running a script) was invisible while burning a core. See
//!   `candidates`.
//! * **A resume is masked** — see [`WAKE_GAP_S`].
//! * **The exec lifecycle votes.** P5 (P4 plus the agent's own exec operations) tied P4 on every gate
//!   and lost the tie to the earlier policy, so the signal is measured-but-unused. It is real and free
//!   here (`vcs::is_busy()` already exists), so production turns it on and the replay leaves it off,
//!   which keeps the golden contract a test of P4 rather than of P5-with-no-events.
//!
//! The staleness rule (a verdict older than two intervals means BUSY) belonged to the far-side shim
//! that was to read this service's verdict from a file beside the socket. #257 replaced that shim
//! with the service's own heartbeat ([`heartbeat`]), and the file went with it. The classifier still
//! records a long gap as a BUSY change-point, because the golden fixtures were scored that way.

pub mod heartbeat;
pub mod sample;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use sample::{Proc, Sample};
use serde_json::{json, Value};

use crate::protocol::envelope::{Envelope, Service};
use crate::session::SharedWriter;

/// Bumped when the Status service's JSON shape changes, exactly as `FILE_SERVICE_VERSION` is.
pub const STATUS_SERVICE_VERSION: u32 = 1;

/// A `SharedWriter` held without keeping its connection alive.
type WeakWriter = Weak<Mutex<Box<dyn std::io::Write + Send>>>;

// ---- the frozen policy (results/frozen.json) --------------------------------------------------

/// Seconds of pty-output history a rate is taken over. NOT scaled for a compressed run.
const PTY_WINDOW_S: f64 = 5.0;
/// Seconds of network history a rate is taken over. NOT scaled for a compressed run.
const NET_WINDOW_S: f64 = 3.0;
/// A gap longer than this many intervals is recorded as BUSY, as the golden fixtures were scored.
const STALENESS_FACTOR: f64 = 2.0;
/// A compressed measurement run scales the policy's window and grace by this, nothing else.
const COMPRESSION: f64 = 0.1;

const TIMER_WCHAN: [&str; 3] = ["hrtimer_nanosleep", "do_nanosleep", "common_nsleep"];

/// Housekeeping daemons: their children are their own work, so the whole subtree is excluded.
/// `wr-wakeshim` is the name the measurement harness ran its shim under (`vcs/scripts/oq19`). No
/// such process runs beside the agent since #257 replaced the shim with the heartbeat, but every
/// golden fixture has one burning CPU, so dropping the name breaks the replay contract.
const EXCLUDED_WITH_DESCENDANTS: [&str; 4] =
    ["cron", "unattended-upgr", "apt.systemd.dai", "wr-wakeshim"];
/// Hosts of user work: excluded themselves, never their children. On a real box `systemd` is pid 1
/// and the ancestor of everything, and a command started through `sshd` is work.
const EXCLUDED_SELF_ONLY: [&str; 8] = [
    "sshd",
    "systemd",
    "systemd-journal",
    "systemd-logind",
    "dbus-daemon",
    "rsyslogd",
    "wr-agent",
    "boxd-automation",
];

/// Every name on the exclusion list, for the socket reader's cheap pre-filter. Derived from the two
/// lists above rather than typed a third time: a name present there and missing here would leave a
/// candidate's sockets unwalked, which is a silent false IDLE.
pub const EXCLUDED_COMMS: [&str; 12] = excluded_comms();

const fn excluded_comms() -> [&'static str; 12] {
    let mut out = [""; 12];
    let mut i = 0;
    while i < EXCLUDED_WITH_DESCENDANTS.len() {
        out[i] = EXCLUDED_WITH_DESCENDANTS[i];
        i += 1;
    }
    let mut j = 0;
    while j < EXCLUDED_SELF_ONLY.len() {
        out[i + j] = EXCLUDED_SELF_ONLY[j];
        j += 1;
    }
    out
}

/// A tick gap of at least this long is a resume, not a slow tick. Derived, not picked: the provider
/// sleeps measured on boxd were 79-424 s, while a CFS quota starved the sampler for 7.9-14.3 s and
/// the staleness scenario injects a 15 s stop. 30 s (one hysteresis window) separates them.
const WAKE_GAP_S: f64 = 30.0;

/// P4, with the two knobs a compressed measurement run scales.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Policy {
    /// Cores of candidate CPU that count as work.
    pub cpu: f64,
    /// Pty output bytes/s over [`PTY_WINDOW_S`].
    pub pty: f64,
    /// eth0 rx+tx bytes/s over [`NET_WINDOW_S`].
    pub net: f64,
    /// Seconds after the last keystroke that still count as work.
    pub grace: f64,
    /// A BUSY vote holds the verdict BUSY for this long.
    pub window: f64,
    pub interval: f64,
    /// Whether an agent-owned exec operation votes BUSY (P5's signal; see the module docs).
    pub lifecycle: bool,
}

/// `P4|cpu 0.05|pty 200 B/s|net 500 B/s|agnostic wait|no socket-age rule|grace 10 s|window 30 s|1 s`
pub const FROZEN: Policy = Policy {
    cpu: 0.05,
    pty: 200.0,
    net: 500.0,
    grace: 10.0,
    window: 30.0,
    interval: 1.0,
    lifecycle: false,
};

impl Policy {
    /// The policy as a compressed measurement run applies it: grace and window scale, the rate
    /// windows do not (`analyze.effective` and `analyze.window_for`).
    pub fn compressed(self) -> Self {
        Self {
            grace: self.grace * COMPRESSION,
            window: self.window * COMPRESSION,
            ..self
        }
    }

    /// What production runs: the frozen policy with the exec-lifecycle signal on.
    pub fn production() -> Self {
        Self {
            lifecycle: true,
            ..FROZEN
        }
    }
}

// ---- the counting boundary (boundary.md) ------------------------------------------------------

/// Who is never counted. See the module docs for why `own_descendants` exists.
#[derive(Debug, Clone)]
pub struct Boundary {
    /// The classifier's own pid.
    pub own_pid: i32,
    /// Exclude the classifier's descendants too. True only for the measurement harness, whose
    /// sampler forked `ss`; the agent's descendants ARE the work.
    pub own_descendants: bool,
    /// Excluded by pid, self only (pid 1, and the harness's driver).
    pub extra_pids: Vec<i32>,
}

impl Boundary {
    pub fn agent(pid: i32) -> Self {
        Self {
            own_pid: pid,
            own_descendants: false,
            extra_pids: vec![1],
        }
    }
}

// ---- features and the vote --------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Features {
    pub t: f64,
    /// Cores of CPU used by the candidate set over the last interval.
    pub cpu: f64,
    /// A candidate in uninterruptible sleep, which counts as CPU.
    pub d_state: bool,
    /// A candidate blocked in `nanosleep`: a `sleep 900 && ...` job is work.
    pub timer: bool,
    /// A candidate owns an established TCP connection, of any age.
    pub socket: bool,
    pub pty_rate: f64,
    pub since_input: f64,
    pub net: f64,
    /// An agent-owned exec operation is in flight.
    pub lifecycle: bool,
}

impl Features {
    /// One tick's instantaneous BUSY vote.
    pub fn votes_busy(&self, p: &Policy) -> bool {
        self.cpu >= p.cpu
            || self.d_state
            || self.pty_rate >= p.pty
            || self.timer
            || self.socket
            || self.net >= p.net
            || (p.grace > 0.0 && self.since_input <= p.grace)
            || (p.lifecycle && self.lifecycle)
    }
}

/// Pids reachable from `roots` through the parent links.
fn closure(roots: &[i32], kids: &HashMap<i32, Vec<i32>>) -> HashSet<i32> {
    let mut seen = HashSet::new();
    let mut stack: Vec<i32> = roots.to_vec();
    while let Some(p) = stack.pop() {
        for c in kids.get(&p).into_iter().flatten() {
            if seen.insert(*c) {
                stack.push(*c);
            }
        }
    }
    seen
}

/// The candidate set: every sampled process minus the exclusion list and the zombies.
///
/// Session leaders are NOT excluded, although `boundary.md` says "a leader sitting at its prompt is
/// not work". A shell at its prompt votes through no signal — no CPU, blocked in `do_wait` or a
/// tty read rather than `nanosleep`, no socket — so nothing needs excluding, and the ten golden
/// fixtures replay exactly with or without the exclusion. What the exclusion DID do was hide a
/// leader that is the work: the pty child keeps its pid through `exec`, so a command session
/// (`sh -c "exec …"`), a user typing `exec cargo build`, or a shell running a script itself became
/// invisible to every vote while burning a core.
///
/// **`roots` (a session's own pty leaders) protects `EXCLUDED_WITH_DESCENDANTS` from `comm`.**
/// `comm` is mutable at runtime (`prctl(PR_SET_NAME)`, or `exec -a`) — unlike the process's ancestry
/// — so a session program renamed to `cron` or `wr-wakeshim` used to be swept out of the candidate
/// set along with every one of its descendants, and could then burn CPU indefinitely without ever
/// voting BUSY. A process that IS part of a live session's tree is never excluded by name: only a
/// `cron`/`wr-wakeshim` outside every session — the real housekeeping daemon this list exists for —
/// still is, along with its descendants that are not session work. `roots` is carried by `Sample`
/// already (see its doc); the golden fixtures contain no `cron`, and their `wr-wakeshim` runs
/// outside every session, so this cannot change what they replay to.
fn candidates<'a>(procs: &'a [Proc], roots: &[i32], boundary: &Boundary) -> Vec<&'a Proc> {
    let mut kids: HashMap<i32, Vec<i32>> = HashMap::new();
    for p in procs {
        kids.entry(p.ppid).or_default().push(p.pid);
    }
    let mut excluded: HashSet<i32> = boundary.extra_pids.iter().copied().collect();
    excluded.insert(boundary.own_pid);
    if boundary.own_descendants {
        excluded.extend(closure(&[boundary.own_pid], &kids));
    }
    let mut protected: HashSet<i32> = roots.iter().copied().collect();
    protected.extend(closure(roots, &kids));
    let daemons: Vec<i32> = procs
        .iter()
        .filter(|p| {
            EXCLUDED_WITH_DESCENDANTS.contains(&p.comm.as_str()) && !protected.contains(&p.pid)
        })
        .map(|p| p.pid)
        .collect();
    excluded.extend(
        procs
            .iter()
            .filter(|p| EXCLUDED_SELF_ONLY.contains(&p.comm.as_str()))
            .map(|p| p.pid),
    );
    // Minus the session trees: a real `cron` can be an ANCESTOR of a session root (an agent started
    // by an `@reboot` job), and its closure would otherwise sweep every session out with it.
    excluded.extend(closure(&daemons, &kids).difference(&protected));
    excluded.extend(daemons);
    procs
        .iter()
        .filter(|p| !excluded.contains(&p.pid) && p.state != "Z")
        .collect()
}

// ---- rate windows -----------------------------------------------------------------------------

/// Bytes/s of a cumulative counter over the last `window`. The base is the newest sample at or
/// before `t - window`, and the divisor is always the window, so a burst counts for exactly one
/// window and the first ticks under-count rather than divide by a tiny dt.
#[derive(Debug)]
struct RateWindow {
    window: f64,
    t: Vec<f64>,
    v: Vec<u64>,
}

impl RateWindow {
    fn new(window: f64) -> Self {
        Self {
            window,
            t: Vec::new(),
            v: Vec::new(),
        }
    }

    fn feed(&mut self, t: f64, v: u64) -> f64 {
        self.t.push(t);
        self.v.push(v);
        let i = self
            .t
            .partition_point(|x| *x <= t - self.window)
            .saturating_sub(1);
        let base = self.v[i];
        self.t.drain(..i);
        self.v.drain(..i);
        v.saturating_sub(base) as f64 / self.window
    }

    /// Forget the history. After a hibernate the base would be from before the sleep, and a 400 s
    /// gap divided by a 3 s window is a guaranteed BUSY vote out of nothing.
    fn clear(&mut self) {
        self.t.clear();
        self.v.clear();
    }
}

/// Pty bytes the agent itself saw, as the policy reads them: output summed over `(t - window, t]`,
/// and the time of the last keystroke at or before `t`. Events must arrive in time order, which
/// both callers do (the replay preloads a sorted file, the live path appends as bytes move).
#[derive(Debug, Default)]
struct PtyWindow {
    out: Vec<(f64, u64)>,
    ins: Vec<f64>,
}

impl PtyWindow {
    fn push_out(&mut self, t: f64, n: u64) {
        self.out.push((t, n));
    }

    fn push_input(&mut self, t: f64) {
        self.ins.push(t);
    }

    fn rate(&mut self, t: f64) -> f64 {
        let lo = t - PTY_WINDOW_S;
        let stale = self.out.partition_point(|(x, _)| *x <= lo);
        self.out.drain(..stale);
        let sum: u64 = self
            .out
            .iter()
            .take_while(|(x, _)| *x <= t)
            .map(|(_, n)| n)
            .sum();
        sum as f64 / PTY_WINDOW_S
    }

    fn since_input(&mut self, t: f64) -> f64 {
        let i = self.ins.partition_point(|x| *x <= t);
        if i == 0 {
            return f64::INFINITY;
        }
        let last = self.ins[i - 1];
        self.ins.drain(..i - 1);
        t - last
    }
}

// ---- the classifier ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Busy,
    Idle,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Busy => "BUSY",
            Verdict::Idle => "IDLE",
        }
    }
}

/// Turns samples into a verdict. One instance per box; the replay and the live loop drive the same
/// code, which is why the closed loop cannot drift from what the gates were scored with.
pub struct Classifier {
    policy: Policy,
    boundary: Boundary,
    clk_tck: f64,
    prev: Option<(f64, HashMap<i32, i64>)>,
    net: RateWindow,
    pty: PtyWindow,
    last_busy: Option<f64>,
    current: Option<Verdict>,
    last_t: Option<f64>,
    /// Production only: see [`WAKE_GAP_S`] and [`Classifier::wake_masked_until`].
    wake_mask: bool,
    wake_masked_until: Option<f64>,
    /// The last tick was the first after a resume (a gap of [`WAKE_GAP_S`] or more).
    resumed: bool,
    /// The last tick was under the resume mask, so this tick's CPU and network deltas (what the
    /// last masked second used) are masked too.
    wake_masked_last: bool,
    /// The last tick's keystroke age, so the ceiling can tell a user acting from a job running.
    since_input: f64,
}

impl Classifier {
    pub fn new(policy: Policy, boundary: Boundary) -> Self {
        Self {
            policy,
            boundary,
            clk_tck: 100.0,
            prev: None,
            net: RateWindow::new(NET_WINDOW_S),
            pty: PtyWindow::default(),
            last_busy: None,
            current: None,
            last_t: None,
            wake_mask: false,
            wake_masked_until: None,
            resumed: false,
            wake_masked_last: false,
            since_input: f64::INFINITY,
        }
    }

    /// Whether the last tick was the first after a resume. Production only, like the mask.
    pub fn resumed(&self) -> bool {
        self.resumed
    }

    /// Whether the user acted within the policy's grace as of the last tick: the keystroke signal,
    /// which `session.rs` feeds only for input its classifier calls the user's own.
    pub fn user_acted(&self) -> bool {
        self.policy.grace > 0.0 && self.since_input <= self.policy.grace
    }

    /// Mask the box's own resume. After a wake the provider's guest tooling burns 0.2-0.4 core and
    /// ~1.5 KB/s for a few seconds; the measurement excused six such blips and said a production
    /// service should handle them.
    ///
    /// **The rule.** A tick gap of at least [`WAKE_GAP_S`] is a resume. On one: the rate windows are
    /// cleared, because their base would be pre-sleep and a 400 s gap over a 3 s window is a
    /// guaranteed BUSY vote out of nothing; and the CPU and network signals are ignored for one
    /// [`NET_WINDOW_S`] afterwards, which is how long the blip lasted and exactly the allowance the
    /// measurement's scorer excused. Pty output, keystrokes, `nanosleep`, sockets and the exec
    /// lifecycle keep voting throughout, so work that resumes with the box is seen on the first tick.
    pub fn with_wake_mask(mut self) -> Self {
        self.wake_mask = true;
        self
    }

    pub fn with_clk_tck(mut self, clk_tck: f64) -> Self {
        self.clk_tck = clk_tck;
        self
    }

    pub fn push_pty_out(&mut self, t: f64, n: u64) {
        self.pty.push_out(t, n);
    }

    pub fn push_pty_input(&mut self, t: f64) {
        self.pty.push_input(t);
    }

    fn features(&mut self, s: &Sample, lifecycle: bool) -> Features {
        let cand = candidates(&s.procs, &s.roots, &self.boundary);
        let dt = match &self.prev {
            Some((prev_t, _)) => s.t - prev_t,
            None => self.policy.interval,
        };
        let mut cpu = 0.0;
        for p in &cand {
            // A process first seen now is credited at most one core for this interval: its earlier
            // CPU is unknown.
            let used = match self.prev.as_ref().and_then(|(_, ticks)| ticks.get(&p.pid)) {
                Some(before) => p.ticks - before,
                None => p.ticks.min((dt * self.clk_tck) as i64),
            };
            cpu += used.max(0) as f64 / self.clk_tck;
        }
        cpu = if self.prev.is_some() { cpu / dt } else { 0.0 };
        let cand_pids: HashSet<i32> = cand.iter().map(|p| p.pid).collect();
        let socket =
            s.sockets.iter().flatten().any(|sock| {
                sock.state == "ESTAB" && sock.pids.iter().any(|p| cand_pids.contains(p))
            });
        let wake_masked = self.wake_masked_until.is_some_and(|until| s.t < until);
        // CPU and network are deltas over the last interval, so the first tick after the resume
        // mask still measures the last masked second; it is masked too.
        let masked = wake_masked || self.wake_masked_last;
        self.wake_masked_last = wake_masked;
        // A masked tick moves the window's base to itself instead of feeding it: bytes that arrive
        // under a mask must not sit in the window and vote BUSY the tick the mask ends (the resume
        // blip is ~1.5 KB/s for three seconds; unmasking on the fourth with those bytes still inside
        // a 3 s window is a guaranteed vote and a 30 s hold).
        let net = if masked {
            self.net.clear();
            self.net.feed(s.t, s.net_rx + s.net_tx);
            0.0
        } else {
            self.net.feed(s.t, s.net_rx + s.net_tx)
        };
        Features {
            t: s.t,
            cpu: if masked { 0.0 } else { cpu },
            d_state: cand.iter().any(|p| p.state == "D"),
            timer: cand
                .iter()
                .any(|p| TIMER_WCHAN.iter().any(|w| p.wchan.starts_with(w))),
            socket,
            pty_rate: self.pty.rate(s.t),
            since_input: self.pty.since_input(s.t),
            net,
            lifecycle,
        }
    }

    /// One tick. Returns the verdict change-points it produced, in order — zero, one, or two (a
    /// staleness BUSY for the gap that just ended, then this tick's own verdict).
    pub fn step(&mut self, s: &Sample, lifecycle: bool) -> Vec<(f64, Verdict)> {
        let mut events = Vec::new();
        self.resumed = false;
        if let Some(prev_t) = self.last_t {
            let gap = s.t - prev_t;
            if gap > STALENESS_FACTOR * self.policy.interval {
                // Recorded so the change-point series equals the golden fixtures', whose scorer
                // called a gap this long BUSY.
                self.put(
                    &mut events,
                    prev_t + STALENESS_FACTOR * self.policy.interval,
                    Verdict::Busy,
                );
            }
            if self.wake_mask && gap >= WAKE_GAP_S {
                // The net window's base is pre-sleep and has to go. The pty window is NOT cleared:
                // its own expiry is by timestamp, so pre-sleep output is already outside it, and
                // clearing it would also drop the output a job produced since the box woke — the
                // one signal the doc above promises survives a resume.
                self.net.clear();
                self.wake_masked_until = Some(s.t + NET_WINDOW_S);
                self.resumed = true;
            }
        }
        let f = self.features(s, lifecycle);
        self.since_input = f.since_input;
        if f.votes_busy(&self.policy) {
            self.last_busy = Some(f.t);
        }
        let held = self
            .last_busy
            .is_some_and(|last| f.t - last < self.policy.window);
        let verdict = if self.last_busy == Some(f.t) || held {
            Verdict::Busy
        } else {
            Verdict::Idle
        };
        self.put(&mut events, f.t, verdict);
        self.prev = Some((s.t, s.procs.iter().map(|p| (p.pid, p.ticks)).collect()));
        self.last_t = Some(s.t);
        events
    }

    fn put(&mut self, events: &mut Vec<(f64, Verdict)>, t: f64, verdict: Verdict) {
        if self.current != Some(verdict) {
            events.push((t, verdict));
            self.current = Some(verdict);
        }
    }

    pub fn verdict(&self) -> Verdict {
        self.current.unwrap_or(Verdict::Idle)
    }
}

// ---- the awake ceiling (OQ22) -----------------------------------------------------------------

/// How the ceiling behaves. Advisory-only by default: past the ceiling a BUSY box is REPORTED,
/// never hibernated by this service. Force-sleep is not offered.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Settings {
    /// How long a box may stay continuously BUSY before the ceiling trips.
    pub ceiling: f64,
    /// How long the user has to answer the prompt before the service stops asserting BUSY.
    pub prompt_timeout: f64,
    /// Off: report only. On: prompt at the ceiling, and let the box sleep if nobody answers.
    pub ask: bool,
}

/// 4 h spares the longest job the measurement ran; 10 min to answer a prompt.
impl Default for Settings {
    fn default() -> Self {
        Self {
            ceiling: 4.0 * 3600.0,
            prompt_timeout: 600.0,
            ask: false,
        }
    }
}

/// A number of seconds the ceiling can use: 30 s to 30 days. `f64::parse` accepts "nan", "inf"
/// and "-1", and each breaks the ceiling a different way: NaN trips it on the first BUSY tick
/// (every comparison is false), infinity never trips it, and a non-positive prompt timeout expires
/// the prompt on the next tick and lets the box sleep with no grace at all. The bounds stop the
/// finite versions of the same: a ceiling of 1e300 s is never reached, and a prompt timeout of a
/// millisecond is no grace. They matter more since #257, because a remote agent keeps what the app
/// sends it across restarts, ahead of its flags.
pub fn usable_seconds(seconds: f64) -> bool {
    (USABLE_SECONDS_MIN..=USABLE_SECONDS_MAX).contains(&seconds)
}

/// Mirrored by the app's `AgentWakefulnessSettings.usableSeconds`.
const USABLE_SECONDS_MIN: f64 = 30.0;
const USABLE_SECONDS_MAX: f64 = 30.0 * 24.0 * 3600.0;

impl Settings {
    /// From a `settings` request, or the file a remote agent keeps them in (#257): the same three
    /// fields `status` reports, all required, each number [`usable_seconds`].
    pub fn from_json(value: &Value) -> Result<Settings, String> {
        let seconds = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_f64)
                .filter(|v| usable_seconds(*v))
                .ok_or_else(|| {
                    format!(
                        "{key} must be between {USABLE_SECONDS_MIN} and {USABLE_SECONDS_MAX} seconds"
                    )
                })
        };
        Ok(Settings {
            ceiling: seconds("ceiling_seconds")?,
            prompt_timeout: seconds("prompt_timeout_seconds")?,
            ask: value
                .get("ask_at_ceiling")
                .and_then(Value::as_bool)
                .ok_or("ask_at_ceiling must be true or false")?,
        })
    }

    pub fn to_json(self) -> Value {
        json!({
            "ceiling_seconds": self.ceiling,
            "prompt_timeout_seconds": self.prompt_timeout,
            "ask_at_ceiling": self.ask,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CeilingState {
    /// Inside the ceiling, or not BUSY at all.
    Below,
    /// Past the ceiling, reported to the app. The service keeps asserting BUSY (advisory-only).
    Exceeded,
    /// Past the ceiling with `ask` on: the app has been asked, and has until `deadline`.
    Prompted { deadline: f64 },
    /// Nobody answered: the service stops asserting BUSY and lets the provider's own timer sleep
    /// the box. It never sleeps the box itself.
    Suppressed,
}

/// The ceiling state machine. Nothing here hibernates anything.
#[derive(Debug)]
pub struct Ceiling {
    pub settings: Settings,
    busy_since: Option<f64>,
    state: CeilingState,
}

impl Ceiling {
    pub fn new(settings: Settings) -> Self {
        Self {
            settings,
            busy_since: None,
            state: CeilingState::Below,
        }
    }

    /// Feeds the classifier's verdict. Returns true when a prompt should be raised NOW (once per
    /// crossing, not once per tick).
    pub fn step(&mut self, t: f64, verdict: Verdict) -> bool {
        if verdict == Verdict::Idle {
            // The box went idle on its own: the ceiling has nothing left to cap.
            self.busy_since = None;
            self.state = CeilingState::Below;
            return false;
        }
        let since = *self.busy_since.get_or_insert(t);
        if let CeilingState::Prompted { deadline } = self.state {
            if t >= deadline {
                self.state = CeilingState::Suppressed;
            }
            return false;
        }
        if self.state != CeilingState::Below || t - since < self.settings.ceiling {
            return false;
        }
        if self.settings.ask {
            self.state = CeilingState::Prompted {
                deadline: t + self.settings.prompt_timeout,
            };
            true
        } else {
            self.state = CeilingState::Exceeded;
            false
        }
    }

    /// New settings from the app (#257), in force from this tick. The app sends them on every
    /// connect, so the same settings again change nothing. Otherwise a pending or unanswered prompt
    /// is kept only while ask mode stays on and the box is still past the new ceiling, and a kept
    /// prompt keeps the deadline it was raised with; anything else goes back below, and the next
    /// `step` crosses again under the new settings if the box is past them: an advisory crossing,
    /// or a fresh prompt.
    pub fn set_settings(&mut self, t: f64, settings: Settings) {
        if settings == self.settings {
            return;
        }
        let keep_prompt = settings.ask
            && matches!(
                self.state,
                CeilingState::Prompted { .. } | CeilingState::Suppressed
            )
            && self.awake_for(t) >= settings.ceiling;
        self.settings = settings;
        if !keep_prompt {
            self.state = CeilingState::Below;
        }
    }

    /// The user said keep it awake: the ceiling restarts from here.
    pub fn keep(&mut self, t: f64) {
        self.busy_since = Some(t);
        self.state = CeilingState::Below;
    }

    /// The user acted (a keystroke the input classifier called theirs). While a prompt is pending,
    /// or has gone unanswered and the service has stopped asserting BUSY, that IS the answer:
    /// someone is at the box, so it is kept awake from here. Without this, `Suppressed` held until
    /// the classifier went idle on its own, which a user typing never lets it do — the box was
    /// hibernated under them, and again after every resume. Past an advisory ceiling there is
    /// nothing to answer, so typing changes nothing there.
    pub fn user_acted(&mut self, t: f64) {
        if matches!(
            self.state,
            CeilingState::Suppressed | CeilingState::Prompted { .. }
        ) {
            self.keep(t);
        }
    }

    /// The box resumed from a sleep. Whatever continuous awake period the ceiling was capping has
    /// ended, so it starts over: a job that resumes with the box gets the full ceiling again, and
    /// `awake_for` does not count the hours the box spent asleep.
    pub fn resumed(&mut self) {
        self.busy_since = None;
        self.state = CeilingState::Below;
    }

    pub fn state(&self) -> CeilingState {
        self.state
    }

    /// Seconds the box has been continuously BUSY.
    pub fn awake_for(&self, t: f64) -> f64 {
        self.busy_since.map_or(0.0, |since| t - since)
    }

    /// True once the prompt timed out: the service stops asserting BUSY, so the provider's own idle
    /// timer may sleep the box.
    pub fn suppressing(&self) -> bool {
        self.state == CeilingState::Suppressed
    }

    /// The verdict the service publishes, and keeps the box awake on: the classifier's, except IDLE
    /// once a prompt went unanswered. Advisory-only: the ceiling never sleeps the box, it can only
    /// stop the service ASSERTING busy.
    pub fn published(&self, raw: Verdict) -> Verdict {
        if self.suppressing() {
            Verdict::Idle
        } else {
            raw
        }
    }

    pub fn exceeded(&self) -> bool {
        self.state != CeilingState::Below
    }
}

// ---- the pty counters the agent owns ----------------------------------------------------------

/// Pty bytes, counted where they already move. Process-global like `vcs::ACTIVE`, because the
/// verdict is per machine and not per connection.
#[cfg(target_os = "linux")]
static COUNTERS: Mutex<Counters> = Mutex::new(Counters {
    out: Vec::new(),
    ins: Vec::new(),
});

#[cfg(target_os = "linux")]
#[derive(Debug)]
struct Counters {
    out: Vec<(f64, u64)>,
    ins: Vec<f64>,
}

/// Bounds what the counters hold between drains. The service drains every tick, so this is only
/// reached where no service runs (macOS, a unit test) or under output so torrential that the pty
/// and CPU signals have voted BUSY many times over. Dropping the overflow keeps a busy box from
/// growing a queue nobody empties.
#[cfg(target_os = "linux")]
const MAX_PENDING_PTY_EVENTS: usize = 8192;

/// `n` bytes came out of a session's pty. A no-op where no service drains: the pty read path pays
/// no lock and no clock read for a counter nothing will ever empty.
pub fn count_pty_out(n: usize) {
    #[cfg(target_os = "linux")]
    if n > 0 {
        if let Ok(mut c) = COUNTERS.lock() {
            if c.out.len() < MAX_PENDING_PTY_EVENTS {
                c.out.push((sample::monotonic(), n as u64));
            }
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = n;
}

/// The user typed into a session. The caller decides what "typed" means (`session.rs` gates this
/// on its input classifier): a terminal answering a query is not the user acting.
pub fn count_pty_input() {
    #[cfg(target_os = "linux")]
    if let Ok(mut c) = COUNTERS.lock() {
        if c.ins.len() < MAX_PENDING_PTY_EVENTS {
            c.ins.push(sample::monotonic());
        }
    }
}

/// Moves what the ptys have counted since the last tick into the classifier. Only the service
/// drains, and the service only exists where the signals do. The lock is held for the swap only,
/// so a pty reader never waits behind the classifier's own bookkeeping.
#[cfg(target_os = "linux")]
fn drain_counters(classifier: &mut Classifier) {
    let (out, ins) = {
        let Ok(mut c) = COUNTERS.lock() else {
            return;
        };
        (std::mem::take(&mut c.out), std::mem::take(&mut c.ins))
    };
    for (t, n) in out {
        classifier.push_pty_out(t, n);
    }
    for t in ins {
        classifier.push_pty_input(t);
    }
}

// ---- publishing the state ---------------------------------------------------------------------

/// Stops the service for good: `status` says it is not running, and the service thread publishes
/// nothing more and ends within a tick (that last tick may still send one heartbeat, which an agent
/// on its way out can afford). Called by `serve` on its way out, and by the service thread if it
/// panics.
pub fn stop() {
    let mut state = shared().state.lock().unwrap_or_else(|e| e.into_inner());
    state.stopped = true;
    state.running = false;
}

/// Everything the app can ask about wakefulness. Process-global: one box, one verdict.
pub struct Wakefulness {
    state: Mutex<Published>,
    /// Connections that have asked about status and may be sent a ceiling prompt. Weak, so a
    /// closed connection drops out of the list instead of being kept alive by it.
    listeners: Mutex<Vec<WeakWriter>>,
}

#[derive(Debug, Clone)]
struct Published {
    running: bool,
    /// Set by [`stop`]. The service thread ends at its next look, so `running` is never set back.
    stopped: bool,
    /// What the heartbeat follows: the classifier's verdict, or IDLE once the ceiling prompt timed
    /// out.
    verdict: Verdict,
    /// What the classifier itself decided, before the ceiling.
    raw: Verdict,
    t: f64,
    awake_for: f64,
    ceiling: CeilingState,
    settings: Settings,
    /// Set by a `keep`, consumed by the service thread on its next tick.
    keep_requested: bool,
    /// Set by a `settings` request, consumed by the service thread on its next tick, so one place
    /// owns the ceiling.
    settings_requested: Option<Settings>,
    /// The thread that keeps `settings` requests for the next start (`settings_saver`), set before
    /// the agent accepts a connection. Neither the service's thread nor a connection's reader
    /// writes the file: a slow disk must hold up neither the heartbeat nor a connection's requests.
    settings_saver: Option<std::sync::mpsc::Sender<Settings>>,
    /// The service's own CPU as a fraction of one core, against the 0.5% gate.
    cpu_fraction: f64,
    /// When the last heartbeat went out, on the service's monotonic clock.
    keep_awake_sent: Option<f64>,
    /// Why the last heartbeat could not be sent, while the box is BUSY. Set means the box is NOT
    /// being kept awake whatever `verdict` says, so the app shows it as unprotected.
    keep_awake_error: Option<String>,
}

/// At most this many connections are remembered for ceiling prompts. The app is one client.
const MAX_LISTENERS: usize = 8;

pub fn shared() -> &'static Wakefulness {
    static SHARED: OnceLock<Wakefulness> = OnceLock::new();
    SHARED.get_or_init(|| Wakefulness {
        state: Mutex::new(Published {
            running: false,
            stopped: false,
            verdict: Verdict::Idle,
            raw: Verdict::Idle,
            t: 0.0,
            awake_for: 0.0,
            ceiling: CeilingState::Below,
            settings: Settings::default(),
            keep_requested: false,
            settings_requested: None,
            settings_saver: None,
            cpu_fraction: 0.0,
            keep_awake_sent: None,
            keep_awake_error: None,
        }),
        listeners: Mutex::new(Vec::new()),
    })
}

impl Wakefulness {
    fn status(&self) -> Value {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner()).clone();
        status_json(&s, sample::monotonic())
    }

    /// The app's ceiling settings (#257). Taken by the service thread next tick, as `keep` is.
    /// Kept for the next start too, queued under the same lock, so the order the file is written in
    /// is the order the requests took effect, whatever connections they came on.
    fn request_settings(&self, settings: Settings) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.settings_requested = Some(settings);
        if let Some(saver) = &state.settings_saver {
            let _ = saver.send(settings);
        }
    }

    /// The app answered "keep": the ceiling restarts. Taken by the service thread next tick, so one
    /// place owns the state machine.
    fn keep(&self) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keep_requested = true;
    }

    /// Remembers a connection so the ceiling prompt can reach it.
    ///
    /// Weakly, and pruned on every touch. A connection's `Subscriptions` are torn down with it
    /// because `ConnectionServices` owns them; this list is process-global (one box, one verdict),
    /// so it has no such teardown and a strong reference here would keep every connection the app
    /// ever opened alive and eligible for a prompt it can no longer read.
    fn remember(&self, writer: &SharedWriter) {
        let mut listeners = self.listeners.lock().unwrap_or_else(|e| e.into_inner());
        listeners.retain(|w| w.strong_count() > 0);
        if listeners
            .iter()
            .any(|w| w.upgrade().is_some_and(|w| Arc::ptr_eq(&w, writer)))
        {
            return;
        }
        if listeners.len() >= MAX_LISTENERS {
            listeners.remove(0);
        }
        listeners.push(Arc::downgrade(writer));
    }

    /// Raises the ceiling prompt on every connection that has asked about status. Unsolicited, on
    /// stream 0, exactly as the file service pushes watch events. Raised by the service thread, so
    /// it exists where the service does.
    ///
    /// Nobody listening is not an error and does not stop the deadline: ask mode means an
    /// unattended box past its ceiling gets to sleep, and "the app is closed" is the commonest way
    /// to be unattended. An app that connects during the prompt sees `prompt_pending` and the
    /// deadline in its first `status` reply, so it can still answer in time.
    #[cfg(target_os = "linux")]
    fn prompt(&self, awake_for: f64, deadline: f64) {
        let event = json!({
            "version": STATUS_SERVICE_VERSION,
            "event": "awake_ceiling_prompt",
            "awake_seconds": awake_for,
            "prompt_deadline": deadline,
        });
        let listeners: Vec<SharedWriter> = {
            let mut held = self.listeners.lock().unwrap_or_else(|e| e.into_inner());
            held.retain(|w| w.strong_count() > 0);
            held.iter().filter_map(std::sync::Weak::upgrade).collect()
        };
        // Off the tick thread, one thread per listener: `send` blocks on the writer, and the
        // moment the prompt fires is the moment the app is likeliest to be wedged (that is why
        // nobody answered). A stalled write on the tick thread would stop the next heartbeat, and
        // the provider could then sleep a busy box; a stalled write ahead of another listener
        // would eat that listener's whole prompt timeout.
        for writer in listeners {
            let event = event.clone();
            std::thread::spawn(move || crate::vcs::send(&writer, Service::Status, 0, event));
        }
    }
}

/// Handles one Status envelope. Shaped like `file::dispatch`: a single JSON object in, a
/// `{version, result|error}` object back on the same stream.
pub fn dispatch(envelope: &Envelope, writer: &SharedWriter) {
    // Stream 0 belongs to the agent: it is where the ceiling prompt goes, never where a request
    // arrives.
    if envelope.stream == 0 {
        return;
    }
    let reply = |value: Value| crate::vcs::send(writer, Service::Status, envelope.stream, value);
    let method = serde_json::from_slice::<Value>(&envelope.payload)
        .ok()
        .and_then(|v| v.get("method")?.as_str().map(str::to_owned));
    let wakefulness = shared();
    match method.as_deref() {
        Some("status") => {
            wakefulness.remember(writer);
            reply(json!({"version": STATUS_SERVICE_VERSION, "result": wakefulness.status()}));
        }
        Some("keep") => {
            wakefulness.keep();
            reply(json!({"version": STATUS_SERVICE_VERSION, "result": {"kept": true}}));
        }
        // An added request, not a changed shape, so `STATUS_SERVICE_VERSION` stays: an app that
        // never sends it sees nothing new, and an agent that predates it answers `unsupported`.
        Some("settings") => {
            let parsed = serde_json::from_slice::<Value>(&envelope.payload)
                .map_err(|e| e.to_string())
                .and_then(|request| Settings::from_json(&request));
            match parsed {
                Ok(settings) => {
                    wakefulness.request_settings(settings);
                    reply(json!({
                        "version": STATUS_SERVICE_VERSION,
                        "result": {"settings": settings.to_json()},
                    }));
                }
                Err(message) => reply(json!({
                    "version": STATUS_SERVICE_VERSION,
                    "error": {"invalid": message},
                })),
            }
        }
        _ => reply(json!({
            "version": STATUS_SERVICE_VERSION,
            "error": {"unsupported": "status requests are {\"method\": \"status\"|\"keep\"|\"settings\"}"},
        })),
    }
}

// ---- the service ------------------------------------------------------------------------------

/// The `status` reply for the published state `s`, read at `now` on the monotonic clock.
fn status_json(s: &Published, now: f64) -> Value {
    let stalled = s.running && stalled(s.t, now);
    json!({
        "running": s.running,
        // The service has not finished a tick for a while (a blocked `/proc` read, say): what
        // follows is that tick's, and the heartbeat has stopped with it (#257). Read against a
        // clock of the request's own, because the service's is the one that stopped.
        "stalled": stalled,
        "verdict": s.verdict.as_str(),
        "busy": s.verdict == Verdict::Busy,
        "classifier_verdict": s.raw.as_str(),
        "monotonic": s.t,
        "awake_seconds": s.awake_for,
        // OQ22: advisory-only. True means "this box has been BUSY past the ceiling", which the
        // app shows; the service has not hibernated anything and will not.
        "awake_ceiling_exceeded": s.ceiling != CeilingState::Below,
        "prompt_pending": matches!(s.ceiling, CeilingState::Prompted { .. }),
        "prompt_deadline": match s.ceiling {
            CeilingState::Prompted { deadline } => json!(deadline),
            _ => Value::Null,
        },
        // The prompt went unanswered: the service has stopped asserting BUSY, so the provider's
        // own idle timer may sleep the box.
        "asserting": s.verdict == Verdict::Busy,
        "suppressed": s.ceiling == CeilingState::Suppressed,
        "ceiling_seconds": s.settings.ceiling,
        "prompt_timeout_seconds": s.settings.prompt_timeout,
        "ask_at_ceiling": s.settings.ask,
        "cpu_fraction": s.cpu_fraction,
        // What actually keeps a BUSY box awake (#257). An error while BUSY means nothing is:
        // the provider's own idle timer may sleep the box.
        "keep_awake": {
            "last_sent": s.keep_awake_sent,
            "error": s.keep_awake_error,
        },
    })
}

/// How long the service may go without finishing a tick before `status` says it has stalled:
/// `WAKE_GAP_S`, past the 7.9-14.3 s a CFS quota was measured starving the sampler, so a throttled
/// busy box is not reported unprotected, and well inside the heartbeat's 60 s. A status taken just
/// after a resume, before the service's next tick, can read as stalled for that one tick: the
/// monotonic clock ran on through the sleep (`sample::Sample`).
const STALL_AFTER_S: f64 = WAKE_GAP_S;

/// Whether a service whose last tick was at `last` has stalled, at `now`.
fn stalled(last: f64, now: f64) -> bool {
    now - last > STALL_AFTER_S
}

/// Where an agent keeps the last settings the app sent it (#257), beside its socket. A
/// remote agent outlives every connection and keeps its environment through a hand-off,
/// so this is how the app's settings survive the agent's own restart. A remote host's socket is a
/// fixed path, so every app that connects to it, any Mac's and any channel's, shares this one file
/// and the last to connect wins (TODOS.md).
pub fn settings_path(socket: &Path) -> PathBuf {
    let mut name = socket.as_os_str().to_owned();
    name.push(".settings");
    PathBuf::from(name)
}

/// The settings kept at `path`, or None when there are none or they do not parse: the agent then
/// starts with its flags, environment or defaults.
pub fn load_settings(path: &Path) -> Option<Settings> {
    let text = std::fs::read(path).ok()?;
    Settings::from_json(&serde_json::from_slice(&text).ok()?).ok()
}

/// The one thread that writes `path`, in the order settings are sent to it: two requests at once
/// (two apps connected, say) would otherwise share the temporary file and could leave it garbled,
/// and the next start would then quietly fall back to the flags. Best effort: a failed save costs
/// the next start these settings, and the app sends them again on its next connect. The thread
/// ends when every sender is gone.
pub fn settings_saver(
    path: PathBuf,
) -> (
    std::sync::mpsc::Sender<Settings>,
    std::thread::JoinHandle<()>,
) {
    let (sender, receiver) = std::sync::mpsc::channel::<Settings>();
    let thread = std::thread::Builder::new()
        .name("wr-settings".into())
        .spawn(move || {
            for settings in receiver {
                if let Err(e) = save_settings(&path, settings) {
                    crate::note!("wakefulness: settings not kept for the next start: {e}");
                }
            }
        })
        .expect("spawn the settings saver");
    (sender, thread)
}

/// Keeps `settings` at `path`, atomically, so a crash mid-write leaves the old file or the new one.
pub fn save_settings(path: &Path, settings: Settings) -> std::io::Result<()> {
    let tmp = path.with_extension("settings.tmp");
    std::fs::write(&tmp, settings.to_json().to_string())?;
    std::fs::rename(&tmp, path)
}

#[cfg(target_os = "linux")]
pub use service::spawn;

#[cfg(target_os = "linux")]
mod service {
    use super::heartbeat::{self, KeepAwake};
    use super::{
        drain_counters, load_settings, settings_path, settings_saver, shared, Boundary, Ceiling,
        CeilingState, Classifier, Policy, Settings, EXCLUDED_COMMS,
    };
    use crate::session::SessionStore;
    use std::path::Path;
    use std::time::Duration;

    /// Starts the wakefulness thread. One per agent; it runs whether or not a client is attached,
    /// because the whole point is to keep reporting while the user's Mac is asleep.
    ///
    /// The settings the app last sent this agent (#257) win over `settings` (its flags, environment
    /// or defaults): they are the app's latest word, and a remote agent is started by its
    /// supervisor with none of its own.
    pub fn spawn(sessions: SessionStore, socket: &Path, settings: Settings) {
        // Before `serve` accepts a connection, so no `settings` request can arrive with nowhere to
        // be kept, and the kept file is read before any request can rewrite it.
        let kept = settings_path(socket);
        let settings = load_settings(&kept).unwrap_or(settings);
        shared()
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .settings_saver = Some(settings_saver(kept).0);
        std::thread::spawn(move || {
            let run = std::panic::AssertUnwindSafe(|| run(sessions, settings));
            // A panic here is otherwise silent: the handle is dropped and nothing restarts the
            // thread. The heartbeat stops, so the provider may sleep a busy box, and `status` says
            // `running: false`, which hides the badge (TODOS.md).
            if std::panic::catch_unwind(run).is_err() {
                super::stop();
            }
        });
    }

    fn run(sessions: SessionStore, settings: Settings) {
        // Named so this thread's own cost can be read from outside the process, at
        // /proc/<pid>/task/<tid>/, against the plan's 0.5%-of-a-core gate. Thread names do not reach
        // /proc/<pid>/comm, so this cannot change how the classifier sees the agent.
        // SAFETY: a NUL-terminated name of at most 16 bytes, which is prctl's contract.
        unsafe {
            libc::prctl(libc::PR_SET_NAME, c"wr-wakeful".as_ptr());
        }
        let policy = Policy::production();
        let mut classifier = Classifier::new(policy, Boundary::agent(std::process::id() as i32))
            .with_wake_mask()
            .with_clk_tck(super::sample::clk_tck());
        let mut ceiling = Ceiling::new(settings);
        let start = super::sample::monotonic();
        let mut keep_awake = KeepAwake::default();
        {
            let mut state = shared().state.lock().unwrap_or_else(|e| e.into_inner());
            // `serve` may already have stopped the service (an immediate accept failure), and
            // `running` must not be set back to true after it.
            if state.stopped {
                return;
            }
            state.running = true;
            // Published with `running`, so a `status` before the first tick reads a service that
            // has just started, not one that stalled at clock 0, with the settings it started with.
            state.t = start;
            state.settings = settings;
        }
        let mut tick: u64 = 0;
        loop {
            let due = start + tick as f64 * policy.interval;
            let now = super::sample::monotonic();
            if now < due {
                std::thread::sleep(Duration::from_secs_f64(due - now));
            }
            tick += 1;

            let roots = sessions.pids();
            let s = super::sample::sample(roots, &EXCLUDED_COMMS);
            drain_counters(&mut classifier);
            // The heartbeat's own bytes need no mask: ~30 bytes a minute against a 500 bytes/s
            // threshold.
            classifier.step(&s, crate::vcs::is_busy());
            let raw = classifier.verdict();

            let (keep, requested) = {
                let mut state = shared().state.lock().unwrap_or_else(|e| e.into_inner());
                (
                    std::mem::take(&mut state.keep_requested),
                    state.settings_requested.take(),
                )
            };
            if let Some(settings) = requested {
                ceiling.set_settings(s.t, settings);
            }
            if classifier.resumed() {
                ceiling.resumed();
                keep_awake.resumed();
            }
            if keep {
                ceiling.keep(s.t);
            }
            let prompted = ceiling.step(s.t, raw);
            // After the step, so a keystroke inside the grace on the very tick the prompt is
            // raised or expires answers it at once rather than a tick later.
            if classifier.user_acted() {
                ceiling.user_acted(s.t);
            }
            // Raised only after this tick's state is published below: an app that reacts to the
            // event by asking for `status` must see `prompt_pending`, not the previous tick.
            let prompt = match ceiling.state() {
                CeilingState::Prompted { deadline } if prompted => {
                    Some((ceiling.awake_for(s.t), deadline))
                }
                _ => None,
            };
            let verdict = ceiling.published(raw);
            // The published verdict, after the ceiling, is what keeps the box awake: an unanswered
            // prompt stops the heartbeat, and the provider's own timer then sleeps the box.
            keep_awake.tick(s.t, &ceiling, raw, heartbeat::send);
            let mut state = shared().state.lock().unwrap_or_else(|e| e.into_inner());
            if state.stopped {
                return;
            }
            state.keep_awake_sent = keep_awake.last_sent;
            state.keep_awake_error.clone_from(&keep_awake.error);
            state.verdict = verdict;
            state.raw = raw;
            state.t = s.t;
            state.awake_for = ceiling.awake_for(s.t);
            state.ceiling = ceiling.state();
            state.settings = ceiling.settings;
            state.cpu_fraction = thread_cpu_fraction(s.t - start);
            drop(state);
            if let Some((awake_for, deadline)) = prompt {
                shared().prompt(awake_for, deadline);
            }

            // Skip ahead rather than bursting to catch up: a missed tick is simply missed, and
            // catching up would only take back-to-back samples of the same moment. The next due
            // tick is the first one strictly after now: `behind` alone is the tick just passed, and
            // scheduling that again means an immediate second sample.
            let behind = ((super::sample::monotonic() - start) / policy.interval) as u64;
            tick = tick.max(behind + 1);
        }
    }

    /// This thread's own CPU as a fraction of one core, for the plan's 0.5% gate. `RUSAGE_THREAD` so
    /// the number is the service's and not the whole agent's.
    fn thread_cpu_fraction(elapsed: f64) -> f64 {
        if elapsed <= 0.0 {
            return 0.0;
        }
        let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
        // SAFETY: `usage` is a valid, writable `rusage` for the duration of the call.
        if unsafe { libc::getrusage(libc::RUSAGE_THREAD, &mut usage) } != 0 {
            return 0.0;
        }
        let secs = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
        (secs(usage.ru_utime) + secs(usage.ru_stime)) / elapsed
    }
}

#[cfg(test)]
mod tests;
