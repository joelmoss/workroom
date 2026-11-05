use super::*;

#[test]
fn reads_this_process() {
    let pid = std::process::id() as i32;
    // The test binary's own name varies by harness, so assert the shape rather than a literal.
    let name = executable_name(pid).expect("own executable name");
    assert!(!name.is_empty());
    assert!(!name.contains('/'), "must be a basename, got {name:?}");

    let cwd = working_directory(pid).expect("own cwd");
    assert!(cwd.starts_with('/'), "cwd must be absolute, got {cwd:?}");
    assert_eq!(
        std::fs::canonicalize(&cwd).ok(),
        std::env::current_dir()
            .ok()
            .and_then(|p| std::fs::canonicalize(p).ok())
    );
}

/// The bug this module exists for, reproduced end to end rather than argued about.
///
/// `exec -a NAME cmd` runs `cmd` with `argv[0]` set to NAME, so `/proc/<pid>/cmdline` reads
/// NAME while `/proc/<pid>/exe` still points at the real binary. That is the same shape as a
/// CLI rewriting its own title after launch, and it is exactly the case Phase 0 measured
/// `cmdline` getting wrong. If this returns "definitely-not-sleep", the implementation has
/// regressed to the obvious-but-wrong source.
///
/// Linux-only on purpose: on macOS `KERN_PROCARGS2` records the exec-time argv faithfully, so
/// `exec -a` is a legitimate rename there rather than a lie, and reporting it is correct.
#[cfg(target_os = "linux")]
#[test]
fn prefers_the_real_binary_over_a_rewritten_argv0() {
    use std::process::{Command, Stdio};

    // `exec -a` is a bashism — /bin/sh is dash on Debian/Ubuntu, where it silently fails and
    // the fixture exits before it can be observed. Require bash explicitly, and skip rather
    // than fail where there is none, so this never becomes a flake on a minimal image.
    if !std::path::Path::new("/bin/bash").exists() {
        eprintln!("skipping: /bin/bash not present, and `exec -a` needs it");
        return;
    }

    // Both facts are read in ONE observation, and the loop waits for the REWRITE rather than
    // for the name: reading `cmdline` after the loop instead meant a fixture that had already
    // exited read back as "" — a dead process has an empty cmdline — and the test then blamed
    // the fixture for not rewriting argv[0]. That is what it did on CI, on one matrix leg,
    // while the other passed.
    let observe = || -> Option<(String, Option<String>)> {
        let mut child = Command::new("/bin/bash")
            .args(["-c", "exec -a definitely-not-sleep sleep 30"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn");
        let pid = child.id() as i32;
        // `exec` replaces the shell in place, so the pid is stable; give it a moment to land.
        let mut seen = None;
        for _ in 0..50 {
            std::thread::sleep(std::time::Duration::from_millis(20));
            let cmdline =
                std::fs::read_to_string(format!("/proc/{pid}/cmdline")).unwrap_or_default();
            if cmdline.starts_with("definitely-not-sleep") {
                seen = Some((cmdline, executable_name(pid)));
                break;
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        seen
    };

    // A fixture that dies before it can be observed is a flaky FIXTURE, not a failing
    // assertion, so give it a couple of goes before believing it.
    let Some((cmdline, name)) = (0..3).find_map(|_| observe()) else {
        panic!("the `exec -a` fixture never came up; cannot test what argv[0] is preferred");
    };

    assert!(
        cmdline.starts_with("definitely-not-sleep"),
        "the fixture did not rewrite argv[0]; cmdline was {cmdline:?}"
    );
    assert_eq!(
        name.as_deref(),
        Some("sleep"),
        "must report the real binary, not the rewritten argv[0]"
    );
}

/// Set on the child `reads_a_childs_claude_profile` spawns, which makes this test sleep so the
/// parent can read its environment. Without it (an ordinary test run) it returns at once.
const PROFILE_PROBE: &str = "WORKROOMD_CLAUDE_PROFILE_PROBE";

#[test]
fn claude_profile_probe() {
    if std::env::var_os(PROFILE_PROBE).is_some() {
        std::thread::sleep(std::time::Duration::from_secs(30));
    }
}

/// The Claude profile a running `claude` uses is read from its environment (#480). A spawned
/// child stands in for it, so the read crosses a real process boundary rather than reading our
/// own environment back. The child is this test binary, not `/bin/sleep`: macOS withholds the
/// environment of Apple platform binaries from `KERN_PROCARGS2` (measured: `ps eww` shows none
/// for `/bin/sleep`, `/bin/sh` or a copy of either), while `claude` is not one.
#[test]
fn reads_a_childs_claude_profile() {
    use std::process::{Command, Stdio};

    let profile_of = |configure: &dyn Fn(&mut Command)| {
        let mut command = Command::new(std::env::current_exe().expect("test binary"));
        command
            .args(["--exact", "process::tests::claude_profile_probe"])
            .env(PROFILE_PROBE, "1")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        configure(&mut command);
        let mut child = command.spawn().expect("spawn the profile probe");
        let pid = child.id() as i32;
        // On Linux `spawn` can return before `execve` has laid out the new environment, which
        // then reads as empty: wait until the probe's own variable is readable.
        for _ in 0..100 {
            if platform::environment_value(pid, PROFILE_PROBE).is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let profile = claude_profile(pid);
        let _ = child.kill();
        let _ = child.wait();
        profile
    };

    assert_eq!(
        profile_of(&|c| {
            c.env(
                "CLAUDE_CONFIG_DIR",
                "/Users/u/.claude-swap-backup/sessions/2-u_example.com",
            );
        })
        .as_deref(),
        Some("/Users/u/.claude-swap-backup/sessions/2-u_example.com")
    );
    assert_eq!(
        profile_of(&|c| {
            c.env("CLAUDE_CONFIG_DIR", "");
        })
        .as_deref(),
        Some("")
    );
    assert_eq!(
        profile_of(&|c| {
            c.env_remove("CLAUDE_CONFIG_DIR");
        }),
        None
    );
}

// Value: protects=the profile lookup returning exactly CLAUDE_CONFIG_DIR's value;
// fails_when=matching is by prefix or substring (CLAUDE_CONFIG_DIR_OLD, or a value that
// mentions the key) or padding is read as an entry; why_new=the spawned-child test only sets
// the one variable; seam=none; no_claim=reading a live process.
#[test]
fn environment_lookup_matches_the_whole_key_only() {
    let env: &[&[u8]] = &[
        b"CLAUDE_CONFIG_DIR_OLD=/old",
        b"NOTE=CLAUDE_CONFIG_DIR=/in/value",
        b"CLAUDE_CONFIG_DIR=/p/sessions/2-u",
        b"",
    ];
    assert_eq!(
        value_in_environment(env.iter().copied(), "CLAUDE_CONFIG_DIR").as_deref(),
        Some("/p/sessions/2-u")
    );
    assert_eq!(
        value_in_environment(env[..2].iter().copied(), "CLAUDE_CONFIG_DIR"),
        None
    );
    assert_eq!(
        value_in_environment(
            [b"CLAUDE_CONFIG_DIR=".as_slice()].into_iter(),
            "CLAUDE_CONFIG_DIR"
        )
        .as_deref(),
        Some("")
    );
}

#[test]
fn rejects_invalid_pids() {
    assert_eq!(claude_profile(0), None);
    assert_eq!(executable_name(0), None);
    assert_eq!(executable_name(-1), None);
    assert_eq!(working_directory(0), None);
}

#[test]
fn prefers_the_script_over_its_interpreter() {
    let argv = vec![
        "/usr/bin/python3".to_string(),
        "/home/u/fakecli".to_string(),
    ];
    assert_eq!(name_from_argv(&argv).as_deref(), Some("fakecli"));
}

#[test]
fn skips_interpreter_flags_when_finding_the_script() {
    let argv = vec![
        "/usr/bin/node".to_string(),
        "--enable-source-maps".to_string(),
        "/opt/claude/cli.js".to_string(),
    ];
    assert_eq!(name_from_argv(&argv).as_deref(), Some("cli.js"));
}

#[test]
fn keeps_a_plain_command_as_itself() {
    let argv = vec!["/opt/homebrew/bin/vim".to_string(), "file.txt".to_string()];
    assert_eq!(name_from_argv(&argv).as_deref(), Some("vim"));
}

/// An interpreter with no script (a bare REPL) is its own answer — there is nothing better.
#[test]
fn bare_interpreter_reports_itself() {
    let argv = vec!["/usr/bin/python3".to_string()];
    assert_eq!(name_from_argv(&argv).as_deref(), Some("python3"));
}

#[test]
fn versioned_interpreters_are_recognised() {
    assert!(is_interpreter("python3.12"));
    assert!(is_interpreter("python3"));
    assert!(is_interpreter("node"));
    assert!(!is_interpreter("vim"));
    assert!(!is_interpreter("claude"));
}

/// The invariant is "never empty", not "matches Swift byte for byte" — see `basename`'s doc.
#[test]
fn basename_never_returns_an_empty_name() {
    for path in ["/usr/bin/", "/", "", "vim", "/opt/homebrew/bin/vim", "./x/"] {
        if let Some(name) = basename(path) {
            assert!(!name.is_empty(), "{path:?} produced an empty basename");
        }
    }
    assert_eq!(basename("/"), None);
    assert_eq!(basename("vim"), Some("vim"));
    // Rust normalises the trailing slash rather than yielding nil, which is the more useful
    // answer and still satisfies the invariant above.
    assert_eq!(basename("/usr/bin/"), Some("bin"));
}
