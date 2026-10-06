//! The port contract, plus the two pieces the measurement did not cover.
//!
//! `golden_fixtures_replay_to_their_expected_change_points` is the contract from
//! `vcs/scripts/oq19/golden/README.md`: ten hold-out runs replay to EXACTLY their recorded verdict
//! change-points. A mismatch is a bug in this port, never a reason to rebuild a fixture.

use super::sample::Sample;
use super::*;
use std::path::PathBuf;

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/oq19/golden")
}

/// The fixtures keep their traces gzipped. `gzip -dc` rather than a gzip crate: the workspace has
/// none, and a test-only decompression is not worth a dependency.
fn read_maybe_gzipped(path: &std::path::Path) -> String {
    if path.exists() {
        return std::fs::read_to_string(path).expect("fixture readable");
    }
    let gz = path.with_extension(
        path.extension()
            .map(|e| format!("{}.gz", e.to_string_lossy()))
            .unwrap_or_else(|| "gz".into()),
    );
    let out = std::process::Command::new("gzip")
        .arg("-dc")
        .arg(&gz)
        .output()
        .unwrap_or_else(|e| panic!("gzip -dc {}: {e}", gz.display()));
    assert!(out.status.success(), "gzip -dc {} failed", gz.display());
    String::from_utf8(out.stdout).expect("the trace is UTF-8")
}

fn rows(path: &std::path::Path) -> Vec<serde_json::Value> {
    read_maybe_gzipped(path)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).expect("a JSONL row"))
        .collect()
}

struct Fixture {
    name: String,
    policy: Policy,
    boundary: Boundary,
    pty: Vec<(f64, bool, u64)>,
    samples: Vec<Sample>,
    expected: Vec<(f64, Verdict)>,
}

fn load(dir: &std::path::Path) -> Fixture {
    let meta: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("meta.json")).expect("meta.json"))
            .expect("meta.json parses");
    let trace = rows(&dir.join("trace.jsonl"));
    let header = trace
        .iter()
        .find(|r| r["type"] == "header")
        .expect("a header row");
    // The harness sampler forked `ss`, so ITS descendants are excluded; the harness driver stands in
    // for the agent and is excluded by pid, self only. See `Boundary::own_descendants`.
    let mut extra = vec![1];
    if let Some(pid) = header["driver_pid"].as_i64() {
        extra.push(pid as i32);
    }
    let boundary = Boundary {
        own_pid: header["pid"].as_i64().expect("the sampler's pid") as i32,
        own_descendants: true,
        extra_pids: extra,
    };
    let policy = if meta["compressed"].as_bool().unwrap_or(false) {
        FROZEN.compressed()
    } else {
        FROZEN
    };
    let mut pty: Vec<(f64, bool, u64)> = rows(&dir.join("pty.jsonl"))
        .iter()
        .map(|e| {
            (
                e["t"].as_f64().expect("pty t"),
                e["d"] == "out",
                e["n"].as_u64().unwrap_or(0),
            )
        })
        .collect();
    pty.sort_by(|a, b| a.0.total_cmp(&b.0));
    Fixture {
        name: dir.file_name().unwrap().to_string_lossy().into_owned(),
        policy,
        boundary,
        pty,
        samples: trace
            .into_iter()
            .filter(|r| r["type"] == "s")
            .map(|r| serde_json::from_value(r).expect("a sample row"))
            .collect(),
        expected: rows(&dir.join("expected.jsonl"))
            .iter()
            .map(|r| {
                (
                    r["t"].as_f64().expect("expected t"),
                    if r["verdict"] == "BUSY" {
                        Verdict::Busy
                    } else {
                        Verdict::Idle
                    },
                )
            })
            .collect(),
    }
}

fn replay(f: &Fixture, policy: Policy) -> Vec<(f64, Verdict)> {
    let mut c = Classifier::new(policy, f.boundary.clone());
    for &(t, out, n) in &f.pty {
        if out {
            c.push_pty_out(t, n);
        } else {
            c.push_pty_input(t);
        }
    }
    let mut got = Vec::new();
    for s in &f.samples {
        // No lifecycle events exist in any fixture and P4 does not read the signal anyway.
        got.extend(c.step(s, false));
    }
    got
}

fn fixtures() -> Vec<Fixture> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(golden_dir())
        .expect("golden/ exists")
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("expected.jsonl").is_file())
        .collect();
    dirs.sort();
    dirs.iter().map(|d| load(d)).collect()
}

#[test]
fn golden_fixtures_replay_to_their_expected_change_points() {
    let fixtures = fixtures();
    assert_eq!(
        fixtures.len(),
        10,
        "expected the ten golden fixtures, found {}",
        fixtures.len()
    );
    for f in &fixtures {
        let got = replay(f, f.policy);
        assert_eq!(got, f.expected, "{}", f.name);
        println!(
            "{}: {} samples, {} change-points, window {}s grace {}s",
            f.name,
            f.samples.len(),
            got.len(),
            f.policy.window,
            f.policy.grace
        );
    }
}

#[test]
fn a_changed_parameter_breaks_the_contract() {
    // The Python side's mutation check: the fixtures are sensitive to the configuration they were
    // built with. Scenario 5 is a background build — CPU is the signal that carries it.
    let f = fixtures()
        .into_iter()
        .find(|f| f.name.starts_with("5-"))
        .expect("scenario 5 is in the golden set");
    let blunted = Policy {
        cpu: 1e9,
        pty: 1e9,
        net: 1e9,
        grace: 0.0,
        ..f.policy
    };
    assert_ne!(replay(&f, blunted), f.expected);
}

// ---- the ceiling (OQ22) -----------------------------------------------------------------------

fn busy_until(c: &mut Ceiling, t: f64) -> bool {
    let mut prompted = false;
    let mut now = 0.0;
    while now <= t {
        prompted |= c.step(now, Verdict::Busy);
        now += 60.0;
    }
    prompted
}

#[test]
fn by_default_the_ceiling_only_reports() {
    let mut c = Ceiling::new(Settings::default());
    assert!(!busy_until(&mut c, 3.0 * 3600.0));
    assert!(!c.exceeded(), "3 h is inside the 4 h ceiling");
    assert!(!busy_until(&mut c, 5.0 * 3600.0));
    assert!(c.exceeded(), "past the ceiling the box is reported");
    assert!(
        !c.suppressing(),
        "advisory-only: the service keeps asserting BUSY"
    );
    assert_eq!(c.state(), CeilingState::Exceeded);
}

#[test]
fn asking_prompts_once_and_lets_the_box_sleep_if_nobody_answers() {
    let settings = Settings {
        ask: true,
        ..Settings::default()
    };
    let mut c = Ceiling::new(settings);
    assert!(busy_until(&mut c, 4.0 * 3600.0), "the ceiling prompts");
    let CeilingState::Prompted { deadline } = c.state() else {
        panic!("expected a pending prompt, got {:?}", c.state());
    };
    assert_eq!(deadline, 4.0 * 3600.0 + 600.0);
    assert!(!c.step(deadline - 1.0, Verdict::Busy), "prompts only once");
    assert!(!c.suppressing());
    c.step(deadline, Verdict::Busy);
    assert!(c.suppressing(), "unanswered: stop asserting BUSY");
    assert!(c.exceeded());
}

#[test]
fn keep_resets_the_ceiling_and_going_idle_clears_it() {
    let settings = Settings {
        ask: true,
        ..Settings::default()
    };
    let mut c = Ceiling::new(settings);
    busy_until(&mut c, 4.0 * 3600.0);
    c.keep(4.0 * 3600.0);
    assert_eq!(c.state(), CeilingState::Below);
    assert_eq!(c.awake_for(4.0 * 3600.0), 0.0);
    assert!(
        !c.step(7.0 * 3600.0, Verdict::Busy),
        "the ceiling restarts from the keep, so 3 h later is still inside it"
    );
    c.step(9.0 * 3600.0, Verdict::Busy);
    assert!(c.exceeded());
    c.step(9.0 * 3600.0 + 1.0, Verdict::Idle);
    assert_eq!(c.state(), CeilingState::Below, "idle clears the ceiling");
}

/// The exits from `Suppressed` a real user gets without the prompt card: typing answers it, and
/// the box coming back from the sleep the suppression allowed asks again. Neither existed at
/// first, so a user who woke the box and typed kept the classifier BUSY while the service kept
/// publishing IDLE, and the provider hibernated the box under them, again after every resume.
/// A resume once cleared the ceiling outright; but a connect wakes the box too, so every status
/// probe then bought a running job another full ceiling (#356).
#[test]
fn typing_clears_a_suppressed_ceiling_and_resuming_asks_again() {
    let settings = Settings {
        ask: true,
        ..Settings::default()
    };
    let suppressed = || {
        let mut c = Ceiling::new(settings);
        busy_until(&mut c, 4.0 * 3600.0);
        let CeilingState::Prompted { deadline } = c.state() else {
            panic!("expected a prompt")
        };
        c.step(deadline, Verdict::Busy);
        assert!(c.suppressing());
        (c, deadline)
    };

    // A job still running is not an answer.
    let (mut c, deadline) = suppressed();
    c.step(deadline + 60.0, Verdict::Busy);
    assert!(c.suppressing(), "BUSY alone never clears suppression");

    // The user typing is.
    let (mut c, deadline) = suppressed();
    c.user_acted(deadline + 60.0);
    assert_eq!(c.state(), CeilingState::Below);
    assert_eq!(
        c.awake_for(deadline + 60.0),
        0.0,
        "the ceiling restarts from the keystroke"
    );
    assert!(
        !c.step(deadline + 120.0, Verdict::Busy),
        "well inside the new ceiling"
    );

    // The box resuming is not an answer: it keeps the awake time from before the sleep, so the
    // next BUSY tick asks again, with a fresh deadline.
    let (mut c, deadline) = suppressed();
    let before = c.awake_for(deadline);
    let woke = deadline + 3600.0;
    c.resumed(woke);
    assert_eq!(c.state(), CeilingState::Below);
    assert_eq!(c.awake_for(woke), before, "sleep is not awake time");
    assert!(
        c.step(woke + 1.0, Verdict::Busy),
        "past the ceiling: ask again at once"
    );
    assert_eq!(
        c.state(),
        CeilingState::Prompted {
            deadline: woke + 1.0 + 600.0
        }
    );
    assert!(
        !c.suppressing(),
        "a fresh prompt keeps the box awake until its deadline"
    );

    // A resume from any other state starts the ceiling over: a job that resumes with the box gets
    // the full ceiling again.
    let mut c = Ceiling::new(settings);
    busy_until(&mut c, 3.0 * 3600.0);
    c.resumed(5.0 * 3600.0);
    assert_eq!(c.awake_for(5.0 * 3600.0), 0.0);
    assert!(!c.step(5.0 * 3600.0 + 60.0, Verdict::Busy));

    // Typing while the prompt is still pending answers it too: the user is there and working.
    let mut c = Ceiling::new(settings);
    busy_until(&mut c, 4.0 * 3600.0);
    assert!(matches!(c.state(), CeilingState::Prompted { .. }));
    c.user_acted(4.0 * 3600.0 + 30.0);
    assert_eq!(c.state(), CeilingState::Below);
    assert_eq!(c.awake_for(4.0 * 3600.0 + 30.0), 0.0);

    // Typing while merely past an advisory ceiling changes nothing: there is nothing to answer.
    let mut c = Ceiling::new(Settings::default());
    busy_until(&mut c, 5.0 * 3600.0);
    assert_eq!(c.state(), CeilingState::Exceeded);
    c.user_acted(5.0 * 3600.0);
    assert_eq!(c.state(), CeilingState::Exceeded);
}

// ---- the wake mask ----------------------------------------------------------------------------

/// A quiet box: one candidate process burning nothing, no sockets, no pty.
fn quiet(t: f64, net: u64) -> Sample {
    Sample {
        t,
        roots: vec![7],
        procs: vec![
            super::sample::Proc {
                pid: 7,
                ppid: 1,
                comm: "bash".into(),
                state: "S".into(),
                ticks: 0,
                wchan: "do_wait".into(),
            },
            super::sample::Proc {
                pid: 9,
                ppid: 7,
                comm: "cat".into(),
                state: "S".into(),
                ticks: 0,
                wchan: "wait_woken".into(),
            },
        ],
        sockets: Some(Vec::new()),
        net_rx: net,
        net_tx: 0,
    }
}

/// Five quiet seconds, a 300 s hibernate, then the provider's wake blip: ~1.5 KB/s for three
/// seconds, which on its own is three times the 500 B/s threshold. Returns the verdict as the blip
/// ends, and the verdict a further 40 s later.
fn resume_run(mask: bool) -> (Verdict, Verdict) {
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999));
    if mask {
        c = c.with_wake_mask();
    }
    let mut t = 1000.0;
    let mut net = 10_000u64;
    for _ in 0..5 {
        c.step(&quiet(t, net), false);
        t += 1.0;
    }
    t += 300.0;
    for _ in 0..3 {
        net += 1500;
        c.step(&quiet(t, net), false);
        t += 1.0;
    }
    let after_blip = c.verdict();
    // Past the mask, and past the hysteresis window if anything did vote BUSY.
    for _ in 0..40 {
        c.step(&quiet(t, net), false);
        t += 1.0;
    }
    (after_blip, c.verdict())
}

#[test]
fn the_wake_mask_swallows_the_resume_blip() {
    assert_eq!(resume_run(true), (Verdict::Idle, Verdict::Idle));
}

/// Masked bytes must not sit in the rate window and vote the tick the mask ends: the blip is three
/// seconds of 1.5 KB/s and the mask is three seconds, so the fourth tick sees the whole blip inside
/// a 3 s window unless the base moved with the mask.
#[test]
fn masked_traffic_does_not_vote_the_tick_the_mask_ends() {
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999)).with_wake_mask();
    let mut t = 1000.0;
    let mut net = 10_000u64;
    for _ in 0..5 {
        c.step(&quiet(t, net), false);
        t += 1.0;
    }
    t += 300.0;
    for _ in 0..3 {
        net += 1500;
        c.step(&quiet(t, net), false);
        t += 1.0;
    }
    // The first unmasked tick. Its delta is the last masked second's bytes, counted a tick late,
    // and the earlier masked bytes are still less than 3 s old.
    net += 1500;
    c.step(&quiet(t, net), false);
    assert_eq!(
        c.verdict(),
        Verdict::Idle,
        "masked bytes voted once the mask ended"
    );
    // From here on, bytes are real again.
    t += 1.0;
    net += 1500;
    c.step(&quiet(t, net), false);
    assert_eq!(c.verdict(), Verdict::Busy);
}

/// A session leader is a candidate like any other process. One at its prompt votes through no
/// signal, so excluding it bought nothing (the golden replay is exact either way); one that IS the
/// work — a leader that `exec`ed into the job, or a shell running a script itself — must vote.
#[test]
fn a_session_leader_that_does_work_is_work() {
    let burning = |comm: &str| {
        let mut c = Classifier::new(Policy::production(), Boundary::agent(999));
        let mut s = quiet(1000.0, 0);
        s.procs[0].comm = comm.into();
        c.step(&s, false);
        s.t += 1.0;
        s.procs[0].ticks = 100;
        c.step(&s, false);
        c.verdict()
    };
    assert_eq!(
        burning("bash"),
        Verdict::Busy,
        "a shell looping in a script is work"
    );
    assert_eq!(
        burning("cargo"),
        Verdict::Busy,
        "an exec'd leader burning a core is work"
    );
    // And a leader at its prompt still votes nothing.
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999));
    for i in 0..3 {
        c.step(&quiet(1000.0 + f64::from(i), 0), false);
    }
    assert_eq!(c.verdict(), Verdict::Idle);
}

/// CPU is a delta over the last interval, so the first tick after the resume mask measures the
/// last masked second: the wake blip's CPU must not vote there either.
#[test]
fn the_resume_masks_cpu_for_the_tick_after_it_too() {
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999)).with_wake_mask();
    let mut t = 1000.0;
    for _ in 0..3 {
        c.step(&quiet(t, 0), false);
        t += 1.0;
    }
    t += 300.0;
    let resumed = t;
    let mut s = quiet(t, 0);
    // 0.4 core per second for the three masked seconds, measured on the ticks up to and including
    // the first unmasked one.
    for ticks in [0, 40, 80, 120] {
        s.t = t;
        s.procs[1].ticks = ticks;
        c.step(&s, false);
        assert_eq!(c.verdict(), Verdict::Idle, "at resume + {}", t - resumed);
        t += 1.0;
    }
    // Real CPU after the boundary votes.
    s.t = t;
    s.procs[1].ticks = 160;
    c.step(&s, false);
    assert_eq!(c.verdict(), Verdict::Busy);
}

/// The service loop's ceiling steps, as `wakefulness.rs` runs them each tick. Returns whether a
/// prompt was raised, and the verdict the service publishes.
fn ceiling_tick(
    c: &mut Classifier,
    ceiling: &mut Ceiling,
    s: &Sample,
    honour_mask: bool,
) -> (bool, Verdict) {
    c.step(s, false);
    let raw = c.verdict();
    if c.resumed() {
        ceiling.resumed(s.t);
    }
    let prompted = if honour_mask {
        ceiling.step_unless_masked(s.t, raw, c.wake_masked())
    } else {
        ceiling.step(s.t, raw)
    };
    (prompted, ceiling.published(raw))
}

/// A CPU-only job outlasts its ceiling, nobody answers, the box sleeps, and a connect wakes it with
/// the job still running. The wake must ask again, not buy the job another ceiling. The resume mask
/// reads such a job IDLE for its first few ticks, and an IDLE step ends the ceiling, so those ticks
/// have to be ignored or the carried awake time is lost before the job is seen again.
fn wake_with_a_cpu_job_running(honour_mask: bool) -> Option<f64> {
    let settings = Settings {
        ceiling: 30.0,
        prompt_timeout: 10.0,
        ask: true,
    };
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999)).with_wake_mask();
    let mut ceiling = Ceiling::new(settings);
    let mut s = quiet(1000.0, 0);
    // One core of CPU a second.
    let tick = |s: &mut Sample, t: f64| {
        s.t = t;
        s.procs[1].ticks += 100;
    };
    let mut t = 1000.0;
    for _ in 0..60 {
        tick(&mut s, t);
        ceiling_tick(&mut c, &mut ceiling, &s, honour_mask);
        t += 1.0;
    }
    assert!(
        ceiling.suppressing(),
        "unanswered: the service let the box sleep"
    );
    // Asleep for 300 s; the job's CPU stops with the box.
    t += 300.0;
    for _ in 0..20 {
        tick(&mut s, t);
        let (prompted, published) = ceiling_tick(&mut c, &mut ceiling, &s, honour_mask);
        if prompted {
            assert!(matches!(ceiling.state(), CeilingState::Prompted { .. }));
            assert_eq!(
                published,
                Verdict::Busy,
                "a pending prompt keeps the box awake"
            );
            return Some(t);
        }
        t += 1.0;
    }
    None
}

#[test]
fn a_wake_with_the_job_still_running_asks_again() {
    let asked = wake_with_a_cpu_job_running(true).expect("the wake must ask again");
    assert!(
        asked - 1360.0 < 10.0,
        "asked within the resume mask's few seconds, at {asked}"
    );
    // The other half of the claim: acting on the masked IDLE ticks loses the carried awake time,
    // so the box is not asked and the job gets a whole new ceiling.
    assert_eq!(wake_with_a_cpu_job_running(false), None);
}

/// What the service reads off the classifier to drive the ceiling: the resume flag is up for the
/// first tick after the gap only, and the keystroke signal reflects the last tick's grace.
#[test]
fn the_classifier_reports_a_resume_and_a_recent_keystroke() {
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999)).with_wake_mask();
    let mut t = 1000.0;
    for _ in 0..3 {
        c.step(&quiet(t, 10_000), false);
        assert!(!c.resumed());
        t += 1.0;
    }
    t += 300.0;
    c.step(&quiet(t, 10_000), false);
    assert!(c.resumed(), "the first tick after the gap");
    t += 1.0;
    c.step(&quiet(t, 10_000), false);
    assert!(!c.resumed(), "only that tick");
    assert!(!c.user_acted());
    c.push_pty_input(t + 0.5);
    t += 1.0;
    c.step(&quiet(t, 10_000), false);
    assert!(c.user_acted());
    t += 11.0;
    c.step(&quiet(t, 10_000), false);
    assert!(!c.user_acted(), "past the 10 s grace");
    // Without a wake mask (the replay) a gap is never a resume.
    let mut plain = Classifier::new(FROZEN, Boundary::agent(999));
    plain.step(&quiet(1000.0, 0), false);
    plain.step(&quiet(2000.0, 0), false);
    assert!(!plain.resumed());
}

/// Output produced after the box woke is exactly what the resume mask promises to keep: a job that
/// resumes with the box is seen on the first tick, not after the pty window has refilled.
#[test]
fn output_since_the_wake_votes_on_the_first_resumed_tick() {
    let mut c = Classifier::new(Policy::production(), Boundary::agent(999)).with_wake_mask();
    let mut t = 1000.0;
    for _ in 0..5 {
        c.step(&quiet(t, 10_000), false);
        t += 1.0;
    }
    t += 300.0;
    // 2 KB in the second before this tick: 400 B/s over the 5 s window, double the threshold.
    c.push_pty_out(t - 0.5, 2000);
    c.step(&quiet(t, 10_000), false);
    assert_eq!(c.verdict(), Verdict::Busy);
}

/// `keep` over the wire flags the service thread; the reply alone proves nothing, since it is
/// unconditional.
#[test]
fn keep_flags_the_service_thread() {
    let w = shared();
    w.keep();
    let flagged = std::mem::take(
        &mut w
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keep_requested,
    );
    assert!(
        flagged,
        "keep() must leave keep_requested for the next tick"
    );
}

/// `serve` stops the service on its way out; `status` must stop saying it runs, and the flag the
/// service thread checks before it sets `running` or publishes must be left up, or a thread that
/// starts after an immediate accept failure revives a service nothing owns.
/// Value: protects=stop() leaves running=false and stopped=true; fails_when=stop() drops either
/// write; why_new=the only coverage was the removed verdict-file test; seam=none
#[test]
fn stop_leaves_the_service_stopped_and_not_running() {
    let w = shared();
    let before = {
        let mut state = w.state.lock().unwrap_or_else(|e| e.into_inner());
        let before = (state.running, state.stopped);
        state.running = true;
        state.stopped = false;
        before
    };
    stop();
    let mut state = w.state.lock().unwrap_or_else(|e| e.into_inner());
    let after = (state.running, state.stopped);
    // The state is process-global: put it back before asserting, so a failure leaks nothing.
    (state.running, state.stopped) = before;
    drop(state);
    assert_eq!(
        after,
        (false, true),
        "stop() must clear running and set stopped"
    );
}

/// The exclusion pre-filter is the union of the two lists, by construction; if either list changes
/// shape, the derivation still has to produce exactly the union.
#[test]
fn the_socket_prefilter_is_exactly_the_exclusion_lists() {
    let expected: Vec<&str> = EXCLUDED_WITH_DESCENDANTS
        .iter()
        .chain(EXCLUDED_SELF_ONLY.iter())
        .copied()
        .collect();
    assert_eq!(EXCLUDED_COMMS.to_vec(), expected);
}

#[test]
fn without_the_wake_mask_a_resume_votes_busy() {
    // Proves the mask is load-bearing: the stale rate-window base alone makes the 300 s gap look
    // like traffic that never happened, and the hysteresis window then holds the box awake for a
    // further 30 s. Six such blips were excused by hand in the measurement.
    assert_eq!(resume_run(false), (Verdict::Busy, Verdict::Idle));
}

// ---- the vote ---------------------------------------------------------------------------------

#[test]
fn every_frozen_signal_can_raise_busy_on_its_own() {
    let idle = Features {
        t: 0.0,
        cpu: 0.0,
        d_state: false,
        timer: false,
        socket: false,
        pty_rate: 0.0,
        since_input: f64::INFINITY,
        net: 0.0,
        lifecycle: false,
    };
    let p = Policy::production();
    assert!(!idle.votes_busy(&p));
    for (name, f) in [
        ("cpu", Features { cpu: 0.05, ..idle }),
        (
            "d-state",
            Features {
                d_state: true,
                ..idle
            },
        ),
        (
            "pty",
            Features {
                pty_rate: 200.0,
                ..idle
            },
        ),
        (
            "nanosleep",
            Features {
                timer: true,
                ..idle
            },
        ),
        (
            "socket",
            Features {
                socket: true,
                ..idle
            },
        ),
        ("net", Features { net: 500.0, ..idle }),
        (
            "keystroke grace",
            Features {
                since_input: 10.0,
                ..idle
            },
        ),
        (
            "exec lifecycle",
            Features {
                lifecycle: true,
                ..idle
            },
        ),
    ] {
        assert!(f.votes_busy(&p), "{name} should vote BUSY");
    }
    // Just under every threshold is IDLE.
    assert!(!Features {
        cpu: 0.0499,
        pty_rate: 199.9,
        net: 499.9,
        since_input: 10.001,
        ..idle
    }
    .votes_busy(&p));
    // P4 as frozen does not read the lifecycle signal; only production turns it on.
    assert!(!Features {
        lifecycle: true,
        ..idle
    }
    .votes_busy(&FROZEN));
}

#[test]
fn a_compressed_run_scales_the_window_and_the_grace_and_nothing_else() {
    let c = FROZEN.compressed();
    assert_eq!((c.window, c.grace), (3.0, 1.0));
    assert_eq!((c.cpu, c.pty, c.net, c.interval), (0.05, 200.0, 500.0, 1.0));
}

/// LOW 14: `comm` is mutable at runtime, so excluding `EXCLUDED_WITH_DESCENDANTS` by name alone lets
/// a session's own work escape detection by renaming itself `cron` — a real risk the frozen policy
/// never had to consider because the golden fixtures contain no such process. `roots` (a live
/// session's pty leaders) is the identity check: a process inside a session's own tree keeps voting
/// no matter what it calls itself, and only a `cron`/`wr-wakeshim` OUTSIDE every session — the actual
/// housekeeping daemon the list exists for — is still swept out with its descendants.
#[test]
fn a_session_process_renamed_to_an_excluded_name_still_votes() {
    fn proc(pid: i32, ppid: i32, comm: &str) -> Proc {
        Proc {
            pid,
            ppid,
            comm: comm.to_string(),
            state: "R".to_string(),
            ticks: 100,
            wchan: String::new(),
        }
    }
    let procs = vec![
        proc(2, 1, "bash"),   // the session leader (root)
        proc(3, 2, "cron"),   // session work, renamed to an excluded name
        proc(4, 3, "worker"), // its own descendant
        proc(5, 1, "cron"),   // the real daemon: not part of any session
    ];
    let boundary = Boundary::agent(999);
    let cand: HashSet<i32> = candidates(&procs, &[2], &boundary)
        .iter()
        .map(|p| p.pid)
        .collect();
    assert!(cand.contains(&2), "the session leader must still vote");
    assert!(
        cand.contains(&3),
        "a session process renamed to `cron` must not be excluded"
    );
    assert!(
        cand.contains(&4),
        "a session process's own descendant must not be swept out with a renamed ancestor"
    );
    assert!(
        !cand.contains(&5),
        "a `cron` process outside every session must still be excluded"
    );

    // A real `cron` that is an ANCESTOR of a session root (an agent started by an `@reboot` job):
    // the daemon and its other children go, the session tree beneath it stays.
    let procs = vec![
        proc(10, 1, "cron"),
        proc(11, 10, "backup"), // cron's own job: excluded with it
        proc(20, 10, "bash"),   // a session root under cron
        proc(21, 20, "worker"),
    ];
    let cand: HashSet<i32> = candidates(&procs, &[20], &boundary)
        .iter()
        .map(|p| p.pid)
        .collect();
    assert!(!cand.contains(&10) && !cand.contains(&11), "{cand:?}");
    assert!(
        cand.contains(&20) && cand.contains(&21),
        "a session beneath a `cron` ancestor was swept out with it: {cand:?}"
    );
}

// ---- settings from the app (#257) -------------------------------------------------------------

fn ask(ceiling: f64) -> Settings {
    Settings {
        ceiling,
        prompt_timeout: 600.0,
        ask: true,
    }
}

fn advisory(ceiling: f64) -> Settings {
    Settings {
        ceiling,
        prompt_timeout: 600.0,
        ask: false,
    }
}

/// What a new setting does to a box that is mid-ceiling: kept only when it still applies, and
/// otherwise re-decided by the next step as if the new settings had always been in force.
#[test]
fn new_settings_apply_from_the_next_tick() {
    let hours = |h: f64| h * 3600.0;
    // (name, settings before, busy until, new settings, state right after the next step)
    let cases: &[(&str, Settings, f64, Settings, CeilingState)] = &[
        (
            "the same settings again change nothing, a pending prompt included",
            ask(hours(4.0)),
            hours(4.0),
            ask(hours(4.0)),
            CeilingState::Prompted {
                deadline: hours(4.0) + 600.0,
            },
        ),
        (
            "turning ask off withdraws the prompt: the box is reported, and kept awake",
            ask(hours(4.0)),
            hours(4.0),
            advisory(hours(4.0)),
            CeilingState::Exceeded,
        ),
        (
            "a ceiling raised past the time awake withdraws the prompt",
            ask(hours(4.0)),
            hours(4.0),
            ask(hours(8.0)),
            CeilingState::Below,
        ),
        (
            "turning ask on past the ceiling prompts now",
            advisory(hours(4.0)),
            hours(5.0),
            ask(hours(4.0)),
            CeilingState::Prompted {
                deadline: hours(5.0) + 60.0 + 600.0,
            },
        ),
        (
            "a lowered ceiling the box is already past is reported at once",
            advisory(hours(4.0)),
            hours(2.0),
            advisory(hours(1.0)),
            CeilingState::Exceeded,
        ),
        (
            "a pending prompt that still applies keeps the deadline it was raised with",
            ask(hours(4.0)),
            hours(4.0),
            Settings {
                prompt_timeout: 300.0,
                ..ask(hours(4.0))
            },
            CeilingState::Prompted {
                deadline: hours(4.0) + 600.0,
            },
        ),
        (
            "an unanswered prompt stays unanswered under a lower ceiling",
            ask(hours(4.0)),
            hours(4.0) + 660.0,
            ask(hours(3.0)),
            CeilingState::Suppressed,
        ),
        (
            "turning ask off ends an unanswered prompt: reported, and kept awake again",
            ask(hours(4.0)),
            hours(4.0) + 660.0,
            advisory(hours(4.0)),
            CeilingState::Exceeded,
        ),
        (
            "a ceiling raised past the time awake ends an unanswered prompt",
            ask(hours(4.0)),
            hours(4.0) + 660.0,
            ask(hours(8.0)),
            CeilingState::Below,
        ),
    ];
    for (name, before, busy, after, expected) in cases {
        let mut c = Ceiling::new(*before);
        busy_until(&mut c, *busy);
        let now = (*busy / 60.0).floor() * 60.0 + 60.0;
        c.set_settings(now, *after);
        c.step(now, Verdict::Busy);
        assert_eq!(c.state(), *expected, "{name}");
        assert_eq!(c.settings, *after, "{name}");
    }
}

#[test]
fn an_unanswered_prompt_kept_by_the_same_settings_still_lets_the_box_sleep() {
    let mut c = Ceiling::new(ask(3600.0));
    busy_until(&mut c, 3600.0);
    c.set_settings(3660.0, ask(3600.0));
    c.step(3600.0 + 600.0, Verdict::Busy);
    assert!(c.suppressing());
}

/// The heartbeat runs on the PUBLISHED verdict: a minute apart while the prompt is pending, and
/// none once it has gone unanswered, so the provider sleeps the box.
#[test]
fn an_unanswered_prompt_stops_the_heartbeat() {
    let mut c = Ceiling::new(ask(3600.0));
    let mut keep_awake = heartbeat::KeepAwake::default();
    let mut sends = Vec::new();
    let mut t = 0.0;
    while t <= 3600.0 + 600.0 + 300.0 {
        c.step(t, Verdict::Busy);
        keep_awake.tick(t, &c, Verdict::Busy, || {
            sends.push(t);
            Ok(())
        });
        t += 60.0;
    }
    assert!(c.suppressing());
    assert_eq!(sends.first(), Some(&0.0));
    assert_eq!(
        sends.last(),
        Some(&(3600.0 + 540.0)),
        "none after the deadline"
    );
}

/// `status` says a service has stalled once it has gone `WAKE_GAP_S` without finishing a tick, and
/// not for a sampler starved the 7.9-14.3 s a CFS quota was measured to.
#[test]
fn a_service_that_stops_ticking_is_reported_stalled() {
    for (last, now, expected) in [
        (100.0, 101.0, false),
        (100.0, 114.3, false),
        (100.0, 130.0, false),
        (100.0, 130.5, true),
        (100.0, 4000.0, true),
    ] {
        assert_eq!(stalled(last, now), expected, "last {last} now {now}");
    }
}

/// What `status` says of a running service that has stopped ticking, and of one that is not
/// running at all (a macOS agent, a stopped one), whose old reading is no stall.
#[test]
fn status_reports_a_stall_only_for_a_running_service() {
    let mut s = shared()
        .state
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    s.t = 100.0;
    s.keep_awake_error = Some("no IPv4 default route".into());
    for (running, now, expected) in [
        (true, 101.0, false),
        (true, 131.0, true),
        (false, 4000.0, false),
    ] {
        s.running = running;
        let reply = status_json(&s, now);
        assert_eq!(reply["stalled"], expected, "running {running} now {now}");
        assert_eq!(reply["keep_awake"]["error"], "no IPv4 default route");
    }
}

#[test]
fn settings_parse_only_what_the_ceiling_can_use() {
    let good = serde_json::json!({
        "method": "settings",
        "ceiling_seconds": 7200.0,
        "prompt_timeout_seconds": 300,
        "ask_at_ceiling": true,
    });
    assert_eq!(
        Settings::from_json(&good),
        Ok(Settings {
            ceiling: 7200.0,
            prompt_timeout: 300.0,
            ask: true
        })
    );
    // Round trip: what `to_json` writes is what `from_json` reads.
    let settings = Settings::from_json(&good).unwrap();
    assert_eq!(Settings::from_json(&settings.to_json()), Ok(settings));
    for (name, field, value) in [
        ("zero", "ceiling_seconds", serde_json::json!(0)),
        ("negative", "prompt_timeout_seconds", serde_json::json!(-1)),
        (
            "no grace",
            "prompt_timeout_seconds",
            serde_json::json!(0.001),
        ),
        ("never reached", "ceiling_seconds", serde_json::json!(1e300)),
        (
            "just under 30 s",
            "prompt_timeout_seconds",
            serde_json::json!(29.999),
        ),
        (
            "just over 30 days",
            "ceiling_seconds",
            serde_json::json!(2_592_000.001),
        ),
        ("a string", "ceiling_seconds", serde_json::json!("7200")),
        ("missing", "ceiling_seconds", serde_json::Value::Null),
        ("not a bool", "ask_at_ceiling", serde_json::json!(1)),
    ] {
        let mut bad = good.clone();
        if value.is_null() {
            bad.as_object_mut().unwrap().remove(field);
        } else {
            bad[field] = value;
        }
        assert!(Settings::from_json(&bad).is_err(), "{name} {field}");
    }
}

/// Settings sent from many connections at once are kept whole, and the last one sent is the one
/// kept: one thread writes the file, so two saves never share its temporary file.
#[test]
fn settings_sent_at_once_are_kept_whole_and_the_last_wins() {
    let dir = std::env::temp_dir().join(format!("wr-saver-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("agent.sock.settings");
    let (sender, saver) = settings_saver(path.clone());
    let threads: Vec<_> = (0..8)
        .map(|i| {
            let sender = sender.clone();
            std::thread::spawn(move || {
                for j in 0..25 {
                    let ceiling = 60.0 + f64::from(i * 100 + j);
                    let settings = Settings {
                        ceiling,
                        prompt_timeout: 600.0,
                        ask: i % 2 == 0,
                    };
                    sender.send(settings).unwrap();
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    let last = Settings {
        ceiling: 7200.0,
        prompt_timeout: 120.0,
        ask: true,
    };
    sender.send(last).unwrap();
    drop(sender);
    saver.join().unwrap();
    assert_eq!(load_settings(&path), Some(last));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A remote agent's settings survive its restart, and a file that is gone or garbled is no
/// settings at all rather than a broken ceiling.
#[test]
fn kept_settings_load_back_and_a_bad_file_is_ignored() {
    let dir = std::env::temp_dir().join(format!("wr-settings-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = settings_path(&dir.join("agent.sock"));
    assert_eq!(path, dir.join("agent.sock.settings"));
    assert_eq!(load_settings(&path), None, "no file");
    save_settings(&path, ask(1800.0)).unwrap();
    assert_eq!(load_settings(&path), Some(ask(1800.0)));
    assert!(
        !dir.join("agent.sock.settings.tmp").exists(),
        "the temporary file is renamed into place"
    );
    std::fs::write(&path, "{\"ceiling_seconds\": \"nan\"").unwrap();
    assert_eq!(load_settings(&path), None, "garbled");
    std::fs::remove_dir_all(&dir).unwrap();
}
