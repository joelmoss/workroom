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
        // No lifecycle events exist in any fixture and P4 does not read the signal anyway; no net
        // mask, because the replay is scored the way `analyze.features` scores it.
        got.extend(c.step(s, false, false));
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
    assert!(
        fixtures.len() >= 8,
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
        c.step(&quiet(t, net), false, false);
        t += 1.0;
    }
    t += 300.0;
    for _ in 0..3 {
        net += 1500;
        c.step(&quiet(t, net), false, false);
        t += 1.0;
    }
    let after_blip = c.verdict();
    // Past the mask, and past the hysteresis window if anything did vote BUSY.
    for _ in 0..40 {
        c.step(&quiet(t, net), false, false);
        t += 1.0;
    }
    (after_blip, c.verdict())
}

#[test]
fn the_wake_mask_swallows_the_resume_blip() {
    assert_eq!(resume_run(true), (Verdict::Idle, Verdict::Idle));
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

#[test]
fn the_verdict_file_carries_the_monotonic_stamp() {
    let dir = std::env::temp_dir().join(format!("wr-wake-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("agent.wake");
    write_verdict(&path, Verdict::Busy, 389_975.387_370_9).expect("writes");
    assert_eq!(
        std::fs::read_to_string(&path).expect("reads"),
        "BUSY 389975.387\n"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
