use super::*;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "wr-host-environment-test-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// Written by `cp`, not by this process: a test on another thread that forks while this one
/// holds the file open for writing hands the child that descriptor, and running the script
/// then fails on Linux with "Text file busy" (ETXTBSY).
fn script(dir: &Path, name: &str, body: &str, mode: u32) -> PathBuf {
    let path = dir.join(name);
    let draft = dir.join(format!(".{name}.draft"));
    std::fs::write(&draft, body).unwrap();
    assert!(
        Command::new("cp")
            .arg(&draft)
            .arg(&path)
            .status()
            .unwrap()
            .success()
    );
    std::fs::remove_file(&draft).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
    path
}

fn profile_shell(root: &Path, body: &str) -> PathBuf {
    let shell = root.join("bash");
    let draft = root.join("profile.draft");
    std::fs::write(&draft, format!("#!/bin/sh\n{body}")).unwrap();
    // A simultaneous test fork must not inherit a writable descriptor to this executable
    // (ETXTBSY on Linux), as in `script` above.
    assert!(
        Command::new("cp")
            .arg(&draft)
            .arg(&shell)
            .status()
            .unwrap()
            .success()
    );
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o755)).unwrap();
    shell
}

#[test]
fn the_payload_is_read_between_the_first_pair_of_markers() {
    let data = b"noiseMARKA=1\0B=x=y\0MARKtrailingMARKjunk";
    let parsed = parse_probe_output(data, "MARK").unwrap();
    assert_eq!(parsed.get("A").map(String::as_str), Some("1"));
    assert_eq!(parsed.get("B").map(String::as_str), Some("x=y"));
    assert!(parse_probe_output(b"no markers here", "MARK").is_none());
    assert!(parse_probe_output(b"MARK only one", "MARK").is_none());
}

#[test]
fn merging_drops_the_probes_state_and_puts_the_overrides_on_top() {
    let probed = BTreeMap::from([
        ("PATH".to_string(), "/home/u/bin:/usr/bin".to_string()),
        ("WORKROOM_SHELL_PROBE".to_string(), "1".to_string()),
        ("SHLVL".to_string(), "2".to_string()),
        ("GIT_TERMINAL_PROMPT".to_string(), "1".to_string()),
        ("EDITOR".to_string(), "vim".to_string()),
    ]);
    let merged = merge(probed, "/usr/bin:/bin");
    assert_eq!(merged["PATH"], "/home/u/bin:/usr/bin:/bin");
    assert!(!merged.contains_key("WORKROOM_SHELL_PROBE"));
    assert!(!merged.contains_key("SHLVL"));
    assert_eq!(merged["GIT_TERMINAL_PROMPT"], "0");
    assert_eq!(merged["GIT_OPTIONAL_LOCKS"], "0");
    assert_eq!(merged["EDITOR"], "vim");
}

/// The cases are shared with the CLI's `loginShellInvocation` and the app's `ShellEnvironment`,
/// which read the same table, so the three copies of the rule can't drift.
#[test]
fn a_posix_shell_is_probed_login_and_interactive_and_anything_else_through_sh() {
    let table =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../testdata/twins/login_shell.tsv");
    let table = std::fs::read_to_string(&table).unwrap();
    let mut rows = 0;
    for line in table.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        let [shell, program, flag] = fields[..] else {
            panic!("malformed fixture line (want 3 fields): {line:?}");
        };
        assert_eq!(probe_invocation(shell), (program, flag), "shell {shell:?}");
        rows += 1;
    }
    assert!(rows > 0, "no cases in the fixture");
}

/// A fake POSIX shell (named `bash`) that exports a variable and runs the probe's line, as a
/// login shell reading its profile would.
#[test]
fn the_probe_reads_what_the_login_shell_exports() {
    let dir = scratch("probe");
    let shell = script(
        &dir,
        "bash",
        "#!/bin/sh\nexport FROM_PROFILE=yes\necho \"probe=$WORKROOM_SHELL_PROBE\" >&2\nexec /bin/sh -c \"$2\"\n",
        0o755,
    );
    let env = probe(shell.to_str().unwrap(), &dir, PROBE_TIMEOUT).unwrap();
    assert_eq!(env.get("FROM_PROFILE").map(String::as_str), Some("yes"));
    assert_eq!(
        env.get("WORKROOM_SHELL_PROBE").map(String::as_str),
        Some("1")
    );
}

#[test]
fn a_probe_that_hangs_gives_up() {
    let dir = scratch("probe-hang");
    let shell = script(&dir, "zsh", "#!/bin/sh\nsleep 30\n", 0o755);
    let started = Instant::now();
    assert_eq!(
        probe(shell.to_str().unwrap(), &dir, Duration::from_millis(300)),
        Err("timedOut")
    );
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn a_failed_login_read_reports_the_reason_and_uses_the_own_environment() {
    let dir = scratch("probe-fallback");
    let shell = script(&dir, "bash", "#!/bin/sh\nexit 4\n", 0o755);
    let mut reported = None;
    let env = login_environment(shell.to_str().unwrap(), &dir, PROBE_TIMEOUT, |reason| {
        reported = Some(reason.to_string());
    });
    assert_eq!(reported.as_deref(), Some("nonZeroExit"));
    assert_eq!(env, fallback());
}

#[test]
fn a_shell_that_execs_something_else_gives_no_environment() {
    let dir = scratch("probe-exec");
    let shell = script(&dir, "zsh", "#!/bin/sh\nexec true\n", 0o755);
    assert_eq!(
        probe(shell.to_str().unwrap(), &dir, PROBE_TIMEOUT),
        Err("noMarkers")
    );
}

/// A remote host's child environment (#229): the host's own, less what could point git at
/// another repository or let ssh prompt, with the app's pins on top.
#[test]
fn a_host_environment_is_the_hosts_own_with_the_pins_on_top_and_ssh_unable_to_prompt() {
    let pairs = |pairs: &[(&str, &str)]| {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect::<Vec<_>>()
    };
    let os = |pairs: Vec<(String, String)>| {
        pairs
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect::<Vec<(std::ffi::OsString, std::ffi::OsString)>>()
    };
    let own = pairs(&[
        ("HOME", "/home/workroom"),
        ("PATH", "/usr/bin:/bin"),
        ("GIT_DIR", "/elsewhere/.git"),
        ("SSH_ASKPASS", "/usr/bin/ask"),
        ("LC_ALL", "fr_FR.UTF-8"),
        ("GIT_SSH_COMMAND", "ssh -i /home/workroom/.ssh/deploy"),
    ]);
    let pins = pairs(&[("LC_ALL", "C"), ("GIT_TERMINAL_PROMPT", "0")])
        .into_iter()
        .collect();
    let env = host_environment(os(own).into_iter(), pins);
    assert_eq!(env["HOME"], "/home/workroom");
    assert_eq!(env["PATH"], "/usr/bin:/bin");
    assert!(!env.contains_key("GIT_DIR"));
    assert!(!env.contains_key("SSH_ASKPASS"));
    assert_eq!(env["LC_ALL"], "C", "a pin outranks the host's value");
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    assert_eq!(
        env["GIT_SSH_COMMAND"],
        "ssh -i /home/workroom/.ssh/deploy -o BatchMode=yes"
    );
    assert_eq!(env["SSH_ASKPASS_REQUIRE"], "never");

    // With none of its own, it gets none: set, it would outrank a repository's
    // `core.sshCommand`, where a deploy key usually lives.
    let bare = host_environment(std::iter::empty(), Default::default());
    assert!(!bare.contains_key("GIT_SSH_COMMAND"));
    assert_eq!(bare["SSH_ASKPASS_REQUIRE"], "never");

    // A variable that is not UTF-8 is dropped, not a panic.
    use std::os::unix::ffi::OsStringExt;
    let latin1 = vec![(
        std::ffi::OsString::from("LEGACY"),
        std::ffi::OsString::from_vec(vec![0xe9]),
    )];
    let env = host_environment(latin1.into_iter(), Default::default());
    assert!(!env.contains_key("LEGACY"));
}

#[test]
fn remote_git_reads_the_login_environment_from_home_not_a_clone() {
    let root = scratch("host-login-home");
    let shell = profile_shell(
        &root,
        "export READ_FROM=\"$(pwd -P)\"\nexec /bin/sh -c \"$2\"\n",
    );
    let cache = OnceLock::new();
    let login = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    let home = std::fs::canonicalize(std::env::var_os("HOME").unwrap()).unwrap();
    assert_eq!(login["READ_FROM"], home.to_str().unwrap());
}

/// The daemon reads a host profile once, and every remote exec then applies the existing scrub
/// and request pins to that cached result. A profile may provide git/gh and credentials, but it
/// cannot redirect a repository or enable a graphical prompt.
#[test]
fn remote_git_uses_the_cached_login_environment_with_the_policy_on_top() {
    let root = scratch("host-login-env");
    let shell = profile_shell(
        &root,
        "export FROM_PROFILE=host\nexport PATH=/home/u/.local/bin:$PATH\nexport GIT_DIR=/wrong/repo\nexport GIT_WORK_TREE=/wrong/worktree\nexport GIT_TERMINAL_PROMPT=1\nexport LC_ALL=fr_FR.UTF-8\nexport DISPLAY=:0\nexport SSH_ASKPASS=/host/ask\nexec /bin/sh -c \"$2\"\n",
    );
    let cache = OnceLock::new();
    let login = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    assert_eq!(login["FROM_PROFILE"], "host");
    assert!(login["PATH"].starts_with("/home/u/.local/bin:"));
    assert!(!login.contains_key("WORKROOM_SHELL_PROBE"));
    let env = host_environment(
        login.iter().map(|(key, value)| (key.into(), value.into())),
        BTreeMap::from([("LC_ALL".to_string(), "C".to_string())]),
    );
    assert_eq!(env["FROM_PROFILE"], "host");
    assert_eq!(env["LC_ALL"], "C");
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    assert!(!env.contains_key("GIT_DIR"));
    assert!(!env.contains_key("GIT_WORK_TREE"));
    assert!(!env.contains_key("DISPLAY"));
    assert!(!env.contains_key("SSH_ASKPASS"));
    assert_eq!(env["SSH_ASKPASS_REQUIRE"], "never");

    // Removing the shell proves the next exec never probes again: an uncached read would
    // fall back and lose FROM_PROFILE.
    std::fs::remove_file(&shell).unwrap();
    let again = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    assert!(std::ptr::eq(login, again));
    assert_eq!(again["FROM_PROFILE"], "host");
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_hanging_host_profile_falls_back_once_without_holding_remote_git() {
    let root = scratch("host-login-timeout");
    let shell = profile_shell(&root, "sleep 30\n");
    let cache = OnceLock::new();
    let started = Instant::now();
    let env = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_millis(100));
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(!env["PATH"].is_empty());
    assert!(!env.contains_key("WORKROOM_SHELL_PROBE"));
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    let again = cached_login_environment(&cache, shell.to_str().unwrap(), Duration::from_secs(2));
    assert!(std::ptr::eq(env, again), "the fallback is cached too");
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_listing_environment_scrubs_repository_overrides_and_pins_the_locale() {
    let vars = [
        ("GIT_DIR", "/elsewhere"),
        ("GIT_EXTERNAL_DIFF", "/bin/evil"),
        ("LC_ALL", "fr_FR.UTF-8"),
        ("HOME", "/home/someone"),
    ]
    .map(|(key, value)| (key.into(), value.into()));
    let env: BTreeMap<_, _> = scrubbed_environment(vars.into_iter()).into_iter().collect();
    assert!(!env.contains_key("GIT_DIR"));
    assert!(!env.contains_key("GIT_EXTERNAL_DIFF"));
    assert_eq!(env["LC_ALL"], "C");
    assert_eq!(env["GIT_OPTIONAL_LOCKS"], "0");
    assert_eq!(env["GIT_TERMINAL_PROMPT"], "0");
    assert_eq!(
        env["HOME"], "/home/someone",
        "everything else passes through"
    );
}
