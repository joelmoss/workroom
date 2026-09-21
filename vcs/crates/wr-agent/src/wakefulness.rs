//! Is this box busy? The wakefulness service (OQ19, issue #208).
//!
//! A remote workroom's provider hibernates an idle box. The agent is the only thing on the box that
//! knows whether the box is idle, so it decides BUSY or IDLE once a second and publishes the
//! verdict; a per-provider lifecycle shim reads it and works the provider's lever. This module is
//! the deciding half only — nothing here calls a provider.
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
//! * **A resume is masked** — see [`WAKE_GAP_S`].
//! * **The exec lifecycle votes.** P5 (P4 plus the agent's own exec operations) tied P4 on every gate
//!   and lost the tie to the earlier policy, so the signal is measured-but-unused. It is real and free
//!   here (`vcs::is_busy()` already exists), so production turns it on and the replay leaves it off,
//!   which keeps the golden contract a test of P4 rather than of P5-with-no-events.
//!
//! The staleness rule (a verdict older than two intervals means BUSY) belongs to the *reader*: a
//! stopped classifier cannot say anything. This service therefore must never go quiet while claiming
//! IDLE, and the verdict file carries the monotonic stamp the reader needs to apply the rule.

pub mod sample;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use sample::{Proc, Sample};
use serde_json::{json, Value};

use crate::protocol::envelope::{Envelope, Service};
use crate::session::SharedWriter;

/// Bumped when the Status service's JSON shape changes, exactly as `FILE_SERVICE_VERSION` is.
pub const STATUS_SERVICE_VERSION: u32 = 1;

// ---- the frozen policy (results/frozen.json) --------------------------------------------------

/// Seconds of pty-output history a rate is taken over. NOT scaled for a compressed run.
const PTY_WINDOW_S: f64 = 5.0;
/// Seconds of network history a rate is taken over. NOT scaled for a compressed run.
const NET_WINDOW_S: f64 = 3.0;
/// A sample older than this many intervals means BUSY — applied by the reader, recorded here.
const STALENESS_FACTOR: f64 = 2.0;
/// A compressed measurement run scales the policy's window and grace by this, nothing else.
const COMPRESSION: f64 = 0.1;

const TIMER_WCHAN: [&str; 3] = ["hrtimer_nanosleep", "do_nanosleep", "common_nsleep"];

/// Housekeeping daemons: their children are their own work, so the whole subtree is excluded.
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

/// Every name on the exclusion list, for the socket reader's cheap pre-filter.
pub const EXCLUDED_COMMS: [&str; 12] = [
    "cron",
    "unattended-upgr",
    "apt.systemd.dai",
    "wr-wakeshim",
    "sshd",
    "systemd",
    "systemd-journal",
    "systemd-logind",
    "dbus-daemon",
    "rsyslogd",
    "wr-agent",
    "boxd-automation",
];

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

/// The candidate set: every sampled process minus the exclusion list, the session leaders and the
/// zombies. Session leaders are excluded because a leader sitting at its prompt is not work.
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
    let daemons: Vec<i32> = procs
        .iter()
        .filter(|p| EXCLUDED_WITH_DESCENDANTS.contains(&p.comm.as_str()))
        .map(|p| p.pid)
        .collect();
    excluded.extend(
        procs
            .iter()
            .filter(|p| EXCLUDED_SELF_ONLY.contains(&p.comm.as_str()))
            .map(|p| p.pid),
    );
    excluded.extend(closure(&daemons, &kids));
    excluded.extend(daemons);
    let roots: HashSet<i32> = roots.iter().copied().collect();
    procs
        .iter()
        .filter(|p| !excluded.contains(&p.pid) && !roots.contains(&p.pid) && p.state != "Z")
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

    fn clear_out(&mut self) {
        self.out.clear();
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
        }
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

    fn features(&mut self, s: &Sample, lifecycle: bool, net_masked: bool) -> Features {
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
        let net_rate = self.net.feed(s.t, s.net_rx + s.net_tx);
        let masked = net_masked || self.wake_masked_until.is_some_and(|until| s.t < until);
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
            // The history still advances while masked; only the vote ignores it.
            net: if masked { 0.0 } else { net_rate },
            lifecycle,
        }
    }

    /// One tick. Returns the verdict change-points it produced, in order — zero, one, or two (a
    /// staleness BUSY for the gap that just ended, then this tick's own verdict).
    pub fn step(&mut self, s: &Sample, lifecycle: bool, net_masked: bool) -> Vec<(f64, Verdict)> {
        let mut events = Vec::new();
        if let Some(prev_t) = self.last_t {
            let gap = s.t - prev_t;
            if gap > STALENESS_FACTOR * self.policy.interval {
                // The reader already called this BUSY; recording it keeps the change-point series
                // equal to what the shim asserted.
                self.put(
                    &mut events,
                    prev_t + STALENESS_FACTOR * self.policy.interval,
                    Verdict::Busy,
                );
            }
            if self.wake_mask && gap >= WAKE_GAP_S {
                self.net.clear();
                self.pty.clear_out();
                self.wake_masked_until = Some(s.t + NET_WINDOW_S);
            }
        }
        let f = self.features(s, lifecycle, net_masked);
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

    /// The user said keep it awake: the ceiling restarts from here.
    pub fn keep(&mut self, t: f64) {
        self.busy_since = Some(t);
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

    pub fn exceeded(&self) -> bool {
        self.state != CeilingState::Below
    }
}

// ---- the pty counters the agent owns ----------------------------------------------------------

/// Pty bytes, counted where they already move. Process-global like `vcs::ACTIVE`, because the
/// verdict is per machine and not per connection.
static COUNTERS: Mutex<Counters> = Mutex::new(Counters {
    out: Vec::new(),
    ins: Vec::new(),
});

#[derive(Debug)]
struct Counters {
    out: Vec<(f64, u64)>,
    ins: Vec<f64>,
}

/// `n` bytes came out of a session's pty.
pub fn count_pty_out(n: usize) {
    if n == 0 {
        return;
    }
    if let Ok(mut c) = COUNTERS.lock() {
        c.out.push((sample::monotonic(), n as u64));
    }
}

/// The user typed into a session.
pub fn count_pty_input() {
    if let Ok(mut c) = COUNTERS.lock() {
        c.ins.push(sample::monotonic());
    }
}

/// Moves what the ptys have counted since the last tick into the classifier. Only the service
/// drains, and the service only exists where the signals do.
#[cfg(target_os = "linux")]
fn drain_counters(classifier: &mut Classifier) {
    let Ok(mut c) = COUNTERS.lock() else {
        return;
    };
    for (t, n) in c.out.drain(..) {
        classifier.push_pty_out(t, n);
    }
    for t in c.ins.drain(..) {
        classifier.push_pty_input(t);
    }
}

// ---- publishing the verdict -------------------------------------------------------------------

/// Writes `<VERDICT> <monotonic seconds>` to `path`, atomically.
///
/// Atomically because the reader polls it and must never see half a line, and every tick because
/// staleness is the reader's rule: a file that stops being rewritten means BUSY, so a service that
/// went quiet can never be mistaken for one reporting IDLE. The monotonic stamp is what lets a
/// reader apply that rule on the classifier's own clock rather than on file mtime.
pub fn write_verdict(path: &Path, verdict: Verdict, t: f64) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, format!("{} {:.3}\n", verdict.as_str(), t))?;
    std::fs::rename(&tmp, path)
}

/// Everything the app can ask about wakefulness. Process-global: one box, one verdict.
pub struct Wakefulness {
    state: Mutex<Published>,
    /// Connections that have asked about status and may be sent a ceiling prompt.
    listeners: Mutex<Vec<SharedWriter>>,
}

#[derive(Debug, Clone)]
struct Published {
    running: bool,
    /// What the reader sees: the classifier's verdict, or IDLE once the ceiling prompt timed out.
    verdict: Verdict,
    /// What the classifier itself decided, before the ceiling.
    raw: Verdict,
    t: f64,
    awake_for: f64,
    ceiling: CeilingState,
    settings: Settings,
    /// Set by a `keep`, consumed by the service thread on its next tick.
    keep_requested: bool,
    /// The service's own CPU as a fraction of one core, against the 0.5% gate.
    cpu_fraction: f64,
}

/// At most this many connections are remembered for ceiling prompts. The app is one client.
const MAX_LISTENERS: usize = 8;

pub fn shared() -> &'static Wakefulness {
    static SHARED: OnceLock<Wakefulness> = OnceLock::new();
    SHARED.get_or_init(|| Wakefulness {
        state: Mutex::new(Published {
            running: false,
            verdict: Verdict::Idle,
            raw: Verdict::Idle,
            t: 0.0,
            awake_for: 0.0,
            ceiling: CeilingState::Below,
            settings: Settings::default(),
            keep_requested: false,
            cpu_fraction: 0.0,
        }),
        listeners: Mutex::new(Vec::new()),
    })
}

impl Wakefulness {
    fn status(&self) -> Value {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner()).clone();
        json!({
            "running": s.running,
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
        })
    }

    /// The app answered "keep": the ceiling restarts. Taken by the service thread next tick, so one
    /// place owns the state machine.
    fn keep(&self) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keep_requested = true;
    }

    fn remember(&self, writer: &SharedWriter) {
        let mut listeners = self.listeners.lock().unwrap_or_else(|e| e.into_inner());
        if listeners.iter().any(|w| std::sync::Arc::ptr_eq(w, writer)) {
            return;
        }
        if listeners.len() >= MAX_LISTENERS {
            listeners.remove(0);
        }
        listeners.push(std::sync::Arc::clone(writer));
    }

    /// Raises the ceiling prompt on every connection that has asked about status. Unsolicited, on
    /// stream 0, exactly as the file service pushes watch events. Raised by the service thread, so
    /// it exists where the service does.
    #[cfg(target_os = "linux")]
    fn prompt(&self, awake_for: f64, deadline: f64) {
        let event = json!({
            "version": STATUS_SERVICE_VERSION,
            "event": "awake_ceiling_prompt",
            "awake_seconds": awake_for,
            "prompt_deadline": deadline,
        });
        let listeners = self
            .listeners
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        for writer in &listeners {
            crate::vcs::send(writer, Service::Status, 0, event.clone());
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
        _ => reply(json!({
            "version": STATUS_SERVICE_VERSION,
            "error": {"unsupported": "status requests are {\"method\": \"status\"|\"keep\"}"},
        })),
    }
}

// ---- the service ------------------------------------------------------------------------------

/// Where the verdict file sits for a given socket. The reader is a local process on the same box, so
/// it is a sibling of the socket and never on a bind mount: `os.replace` on a Docker Desktop mount
/// is not atomic for a reader, which the measurement found the hard way.
pub fn verdict_path(socket: &Path) -> PathBuf {
    socket.with_extension("wake")
}

#[cfg(target_os = "linux")]
pub use service::spawn;

#[cfg(target_os = "linux")]
mod service {
    use super::{
        drain_counters, shared, verdict_path, write_verdict, Boundary, Ceiling, CeilingState,
        Classifier, Policy, Settings, Verdict, EXCLUDED_COMMS, NET_WINDOW_S,
    };
    use crate::session::SessionStore;
    use std::path::Path;
    use std::time::{Duration, SystemTime};

    /// Starts the wakefulness thread. One per agent; it runs whether or not a client is attached,
    /// because the whole point is to keep reporting while the user's Mac is asleep.
    pub fn spawn(sessions: SessionStore, socket: &Path, settings: Settings) {
        let path = verdict_path(socket);
        std::thread::spawn(move || run(sessions, path, settings));
    }

    fn run(sessions: SessionStore, path: std::path::PathBuf, settings: Settings) {
        let policy = Policy::production();
        let mut classifier = Classifier::new(policy, Boundary::agent(std::process::id() as i32))
            .with_wake_mask()
            .with_clk_tck(super::sample::clk_tck());
        let mut ceiling = Ceiling::new(settings);
        // The shim touches this around each provider call: that traffic is ours, not the workroom's,
        // and without subtracting it the release's own HTTPS call re-votes BUSY and the timers flap.
        let selfcall = path.with_extension("selfcall");
        shared()
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .running = true;
        let start = super::sample::monotonic();
        let mut tick: u64 = 0;
        loop {
            let due = start + tick as f64 * policy.interval;
            let now = super::sample::monotonic();
            if now < due {
                std::thread::sleep(Duration::from_secs_f64(due - now));
            }
            tick += 1;

            let roots: Vec<i32> = sessions.list().iter().map(|s| s.pid).collect();
            let s = super::sample::sample(roots, &EXCLUDED_COMMS);
            drain_counters(&mut classifier);
            classifier.step(&s, crate::vcs::is_busy(), own_call_recent(&selfcall));
            let raw = classifier.verdict();

            let keep = {
                let mut state = shared().state.lock().unwrap_or_else(|e| e.into_inner());
                std::mem::take(&mut state.keep_requested)
            };
            if keep {
                ceiling.keep(s.t);
            }
            if ceiling.step(s.t, raw) {
                if let CeilingState::Prompted { deadline } = ceiling.state() {
                    shared().prompt(ceiling.awake_for(s.t), deadline);
                }
            }
            // Advisory-only: the ceiling never sleeps the box. It can only stop the service
            // ASSERTING busy, and only after an unanswered prompt.
            let verdict = if ceiling.suppressing() {
                Verdict::Idle
            } else {
                raw
            };
            let _ = write_verdict(&path, verdict, s.t);
            let mut state = shared().state.lock().unwrap_or_else(|e| e.into_inner());
            state.verdict = verdict;
            state.raw = raw;
            state.t = s.t;
            state.awake_for = ceiling.awake_for(s.t);
            state.ceiling = ceiling.state();
            state.settings = ceiling.settings;
            state.cpu_fraction = thread_cpu_fraction(s.t - start);

            // Skip ahead rather than bursting to catch up: a missed tick is a gap the reader's
            // staleness rule already covers, and catching up would hide it.
            let behind = ((super::sample::monotonic() - start) / policy.interval) as u64;
            tick = tick.max(behind);
        }
    }

    fn own_call_recent(selfcall: &Path) -> bool {
        let Ok(modified) = selfcall.metadata().and_then(|m| m.modified()) else {
            return false;
        };
        SystemTime::now()
            .duration_since(modified)
            .is_ok_and(|age| age.as_secs_f64() < NET_WINDOW_S + 1.0)
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
