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

    // The probe's libtest name, from this module's own path, so moving the module cannot leave
    // `--exact` naming a test that no longer exists: the child would then run nothing and exit at
    // once, and its environment would read as gone whenever it exited before the read.
    let probe = format!(
        "{}::claude_profile_probe",
        module_path!()
            .split_once("::")
            .expect("a crate-qualified path")
            .1
    );
    let profile_of = |configure: &dyn Fn(&mut Command)| {
        let mut command = Command::new(std::env::current_exe().expect("test binary"));
        command
            .args(["--exact", probe.as_str()])
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
        assert!(
            child.try_wait().expect("poll the profile probe").is_none(),
            "the profile probe exited before its environment was read: `--exact {probe}` ran no test"
        );
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

/// Every path a file: the tests of which argument is the script, apart from which exist.
fn any(_: &str) -> bool {
    true
}

fn argv(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| word.to_string()).collect()
}

#[test]
fn prefers_the_script_over_its_interpreter() {
    let argv = argv(&["/usr/bin/python3", "/home/u/fakecli"]);
    assert_eq!(name_from_argv(&argv, &any).as_deref(), Some("fakecli"));
}

#[test]
fn skips_interpreter_flags_when_finding_the_script() {
    let argv = argv(&[
        "/usr/bin/node",
        "--enable-source-maps",
        "/opt/claude/cli.js",
    ]);
    assert_eq!(name_from_argv(&argv, &any).as_deref(), Some("cli.js"));
}

#[test]
fn keeps_a_plain_command_as_itself() {
    let argv = argv(&["/opt/homebrew/bin/vim", "file.txt"]);
    assert_eq!(name_from_argv(&argv, &any).as_deref(), Some("vim"));
}

/// An interpreter with no script (a bare REPL) is its own answer — there is nothing better.
#[test]
fn bare_interpreter_reports_itself() {
    let argv = argv(&["/usr/bin/python3"]);
    assert_eq!(name_from_argv(&argv, &any).as_deref(), Some("python3"));
}

/// The review's repro (#793): a shell's `-c` string is code, never a script's path, though it
/// ends in a path to a coding agent; nor is any flag's code for the interpreters that take it.
#[test]
fn an_inline_program_is_never_a_script() {
    for words in [
        &["sh", "-c", "echo hi; ls /Users/u/.local/bin/codex"][..],
        &["/bin/bash", "-lc", "cd /tmp && /opt/homebrew/bin/claude"],
        &["zsh", "-ec", "claude"],
        &["fish", "--command", "codex"],
        &["python3", "-c", "import os; os.system('claude')"],
        &["python3", "-m", "claude"],
        &["node", "-e", "require('/opt/claude/cli.js')"],
        &["node", "--eval", "x", "/opt/claude/cli.js"],
        &["perl", "-e", "exec 'claude'"],
    ] {
        let name = basename(words[0]).map(str::to_string);
        assert_eq!(name_from_argv(&argv(words), &any), name, "{words:?}");
    }
}

/// An interpreter's script is the first argument past its flags only when that is a file, as
/// the process would find it; a flag's value or any other word is not.
#[test]
fn an_interpreters_script_is_a_file_that_exists() {
    let dir = std::env::temp_dir().join(format!("workroom-process-script-{}", std::process::id()));
    std::fs::create_dir(&dir).expect("a folder of this test's own");
    let script = dir.join("claude");
    std::fs::write(&script, "#!/bin/sh\n").expect("script");
    let script = script.to_string_lossy().into_owned();
    let gone = dir.join("codex").to_string_lossy().into_owned();
    let is_file = |path: &str| std::path::Path::new(path).is_file();
    let name = |words: &[&str]| name_from_argv(&argv(words), &is_file);
    assert_eq!(name(&["/bin/sh", &script, "x"]).as_deref(), Some("claude"));
    assert_eq!(name(&["/bin/sh", "-e", &script]).as_deref(), Some("claude"));
    assert_eq!(name(&["/bin/sh", &gone]).as_deref(), Some("sh"));
    assert_eq!(
        name(&["python3", "-W", "ignore", &script]).as_deref(),
        Some("python3")
    );
    assert_eq!(
        name(&["/bin/sh", &dir.to_string_lossy()]).as_deref(),
        Some("sh")
    );
    // A relative path is the process's, against its own folder: this one's here.
    let here = std::env::current_dir().expect("cwd");
    let pid = std::process::id() as i32;
    assert!(names_a_file(pid, &script));
    assert!(!names_a_file(pid, "no-such-file-here"));
    let manifest = here.join("Cargo.toml");
    if manifest.is_file() {
        assert!(names_a_file(pid, "Cargo.toml"));
    }
    std::fs::remove_dir_all(&dir).expect("remove the folder");
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

/// Value: protects=a process's image being the file it runs, whatever path names it, and not a
/// file it doesn't, so a resume can tell `exec` replaced its shell (#825); fails_when=the image
/// is read from a path or name rather than the file, or two files compare equal;
/// why_new=new (#825, `exec tmux` in a `.zshrc`); seam=none
#[test]
fn a_process_image_is_the_file_it_runs() {
    let exe = std::env::current_exe().expect("this test's binary");
    let mine = image(std::process::id()).expect("this process's image");
    assert_eq!(Some(mine), image_of(&exe));
    let linked = std::env::temp_dir().join(format!("wr-image-link-{}", std::process::id()));
    let _ = std::fs::remove_file(&linked);
    std::os::unix::fs::symlink(&exe, &linked).expect("a link to it");
    assert_eq!(image_of(&linked), Some(mine), "a link names the same file");
    let _ = std::fs::remove_file(&linked);
    assert_ne!(image_of(Path::new("/bin/sh")), Some(mine), "another file");
    assert_eq!(
        image_of(Path::new("sh")),
        None,
        "a relative path names no one file"
    );
    assert_eq!(image(0), None);
}

/// A `KERN_PROCARGS2` buffer: `argc`, the exec path and its padding, then `words`, each ended,
/// then the environment.
fn procargs(argc: i32, words: &[&str]) -> Vec<u8> {
    let mut buffer = argc.to_ne_bytes().to_vec();
    buffer.extend_from_slice(b"/opt/node/bin/node\0\0\0\0");
    for word in words {
        buffer.extend_from_slice(word.as_bytes());
        buffer.push(0);
    }
    buffer.extend_from_slice(b"PATH=/usr/bin\0");
    buffer
}

fn owned(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| word.to_string()).collect()
}

/// Value: protects=a report never resuming Claude without the flags it ran with (#828);
/// fails_when=the exact read drops empty words, or stops short of `argc` without saying;
/// why_new=new (#828 review: node's `process.title` blanks argv); seam=none
#[test]
fn an_exact_procargs_read_keeps_blank_words_and_refuses_a_short_buffer() {
    let whole = [
        "node",
        "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        "--model",
        "x",
    ];
    assert_eq!(exact_procargs(&procargs(4, &whole)), Some(owned(&whole)));
    // What libuv's title leaves: the title, then every word after it empty.
    assert_eq!(
        exact_procargs(&procargs(4, &["claude", "", "", ""])),
        Some(owned(&["claude", "", "", ""]))
    );
    // Fewer words in the buffer than `argc` says.
    let mut short = 4i32.to_ne_bytes().to_vec();
    short.extend_from_slice(b"/bin/node\0\0node\0cli.js\0");
    assert_eq!(exact_procargs(&short), None);
    assert_eq!(exact_procargs(&procargs(0, &[])), None);
    let mut bad = 1i32.to_ne_bytes().to_vec();
    bad.extend_from_slice(b"/bin/x\0\xff\0");
    assert_eq!(exact_procargs(&bad), None, "not UTF-8");
}

/// Value: protects=a report never resuming Claude without the flags it ran with (#828);
/// fails_when=the exact cmdline read drops empty words, or takes a `cmdline` the kernel cut at a
/// rewritten end; why_new=new (#828 review); seam=none
#[test]
fn an_exact_cmdline_read_keeps_blank_words_and_refuses_an_unended_one() {
    assert_eq!(
        exact_cmdline(b"node\0/x/cli.js\0--model\0x\0"),
        Some(owned(&["node", "/x/cli.js", "--model", "x"]))
    );
    // A title written over argv, the rest zeroed: the area's NULs read as empty words.
    assert_eq!(
        exact_cmdline(b"claude\0\0\0\0"),
        Some(owned(&["claude", "", "", ""]))
    );
    // A title over the argv's last NUL: the kernel gives the title alone, unended.
    assert_eq!(exact_cmdline(b"claude --model x"), None);
    assert_eq!(exact_cmdline(b""), None);
    assert_eq!(exact_cmdline(b"x\0\xff\0"), None, "not UTF-8");
}

#[test]
fn this_process_reads_back_exactly_and_names_its_own_file() {
    let pid = std::process::id() as i32;
    assert_eq!(exact_arguments(pid), Some(std::env::args().collect()));
    let path = executable_path(pid).expect("this test's binary");
    assert_eq!(
        std::fs::canonicalize(path).ok(),
        std::env::current_exe()
            .ok()
            .and_then(|exe| std::fs::canonicalize(exe).ok())
    );
    assert_eq!(exact_arguments(0), None);
    assert_eq!(executable_path(0), None);
}
