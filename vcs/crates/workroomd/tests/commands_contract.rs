//! The `workroom` CLI's contract (ADR 0013), run as a black box against whatever binary
//! `WORKROOM_BIN` names: the Go CLI today, and the Rust `workroom` as each command group is ported
//! (ADR 0078, #667). A run checks what a caller sees: the one JSON envelope on stdout, stderr, the
//! exit code and `kind`, and the config.json the command leaves behind.
//!
//! Without `WORKROOM_BIN` the binary under test is this crate's own `workroom`. A group's tests
//! are `#[ignore]`d until its commands are ported to Rust, so a plain `cargo test` runs only the
//! ported groups (`version_`, `update_`, `list_`, `config_`, `include_archive_`, `base_`, `host_`,
//! `trust_`, `completion_`, `add_project_`, `delete_project_` and `claim_provisioned_` today).
//! `make contract-test` builds the Go CLI and runs every test against it with `--include-ignored`.
//!
//! The Mac-only commands' groups (`list_`, `config_`, `include_archive_`, `base_`, `host_`,
//! `trust_`, `add_project_`, `delete_project_`, `claim_provisioned_`) are ignored off the Mac too,
//! where the Rust binary answers them with `MacOnly` (ADR 0078): a plain `cargo test` on Linux runs
//! `version_`, `update_` and `completion_`, which work anywhere, and
//! `--include-ignored` against the Go CLI still runs everything.
//!
//! Tests are named for their command group (`version_`, `update_`, `list_`, `config_`,
//! `include_archive_`, `base_`, `host_`, `trust_`, `completion_`, `add_project_`,
//! `delete_project_`, `claim_provisioned_`), so a port can run only its own group's names against
//! Rust.
//!
//! The JSON goldens are `testdata/contracts`, the files Go's contract tests
//! (`cmd/contract_test.go`) and the app's `CLIContractTests.swift` check too, with the temporary
//! HOME written as `/Users/dev`. `WORKROOM_CONTRACT_UPDATE=1` rewrites the goldens this suite owns
//! from the binary under test; it never rewrites the ones Go's tests own.
//!
//! Each run gets a cleared environment: only `PATH`, its own HOME and `WORKROOM_CONFIG`, and git
//! with no global or system config. Nothing a run does can reach the real home or config.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The temporary HOME's stand-in in every golden.
const GOLDEN_HOME: &str = "/Users/dev";

/// The binary under test, by an absolute path, since each run starts in its own directory:
/// `WORKROOM_BIN`, else this crate's own `workroom`.
fn binary() -> PathBuf {
    match std::env::var_os("WORKROOM_BIN") {
        Some(path) if !path.is_empty() => PathBuf::from(&path)
            .canonicalize()
            .unwrap_or_else(|error| panic!("WORKROOM_BIN {path:?}: {error}")),
        _ => PathBuf::from(env!("CARGO_BIN_EXE_workroom")),
    }
}

/// A throwaway HOME, removed when the test ends. Its path is symlink-resolved, as the CLI
/// canonicalizes paths, so it matches what the CLI prints.
struct Home {
    dir: PathBuf,
}

impl Home {
    /// A directory this run made itself: `create_dir` fails on any path that already exists, so a
    /// leftover from a killed run, or another run's live HOME, is skipped rather than reused, and
    /// only what this call created is ever removed.
    fn new(name: &str) -> Home {
        let parent = std::env::temp_dir();
        let pid = std::process::id();
        for attempt in 0u32.. {
            let dir = parent.join(format!("workroom-contract-{name}-{pid}-{attempt}"));
            match std::fs::create_dir(&dir) {
                Ok(()) => {
                    let dir = dir.canonicalize().expect("resolve HOME");
                    return Home { dir };
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create HOME {}: {error}", dir.display()),
            }
        }
        unreachable!("u32 attempts ran out")
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.dir.join(relative)
    }

    fn config_path(&self) -> PathBuf {
        self.path(".config/workroom/config.json")
    }

    /// Writes config.json as given, for the binary to read.
    fn write_config(&self, text: &str) {
        let path = self.config_path();
        std::fs::create_dir_all(path.parent().expect("config dir")).expect("create config dir");
        std::fs::write(path, text).expect("write config");
    }

    /// The environment every process in this HOME runs with, and nothing else.
    fn command(&self, program: impl AsRef<std::ffi::OsStr>, cwd: &Path) -> Command {
        let mut command = Command::new(program);
        command
            .env_clear()
            .current_dir(cwd)
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &self.dir)
            .env("WORKROOM_CONFIG", self.config_path())
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t");
        command
    }

    /// Runs the binary under test with `args`, from `cwd`. An argument may be any bytes, as a
    /// shell can pass, not only UTF-8.
    fn run<S: AsRef<OsStr>>(&self, cwd: &Path, args: &[S]) -> Run {
        self.run_program(&binary(), cwd, args)
    }

    /// Runs `program`, a copy of the binary under test, as [`Home::run`] runs that.
    fn run_program<S: AsRef<OsStr>>(&self, program: &Path, cwd: &Path, args: &[S]) -> Run {
        let output = self
            .command(program, cwd)
            .args(args)
            .output()
            .unwrap_or_else(|error| panic!("run {}: {error}", program.display()));
        Run::from(args, output)
    }

    /// Runs the binary under test as [`Home::run`] does, with `stdin` (a pipe, not a terminal) as
    /// its standard input.
    fn run_with_stdin<S: AsRef<OsStr>>(&self, cwd: &Path, args: &[S], stdin: &[u8]) -> Run {
        use std::io::Write;
        let mut child = self
            .command(binary(), cwd)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("run the binary under test");
        // A binary that never reads its stdin may close it first, which is no failure here.
        let _ = child.stdin.take().expect("stdin").write_all(stdin);
        Run::from(args, child.wait_with_output().expect("wait"))
    }

    /// Runs git in `dir`, which must succeed.
    fn git(&self, dir: &Path, args: &[&str]) {
        let output = self
            .command("git", dir)
            .args(args)
            .output()
            .expect("run git");
        assert!(
            output.status.success(),
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    /// A git repository with one commit on `main`, at `relative`.
    fn repo(&self, relative: &str) -> PathBuf {
        let dir = self.path(relative);
        std::fs::create_dir_all(&dir).expect("create repo dir");
        self.git(&dir, &["init", "-q", "-b", "main"]);
        self.git(
            &dir,
            &[
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "first",
            ],
        );
        dir
    }

    /// `text` with this HOME written as the goldens write it.
    fn normalize(&self, text: &str) -> String {
        text.replace(&*self.dir.to_string_lossy(), GOLDEN_HOME)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// One finished run of the binary under test.
struct Run {
    args: String,
    code: i32,
    stdout: String,
    stderr: String,
}

impl Run {
    fn from<S: AsRef<OsStr>>(args: &[S], output: std::process::Output) -> Run {
        Run {
            args: args
                .iter()
                .map(|arg| arg.as_ref().to_string_lossy())
                .collect::<Vec<_>>()
                .join(" "),
            code: output
                .status
                .code()
                .expect("exited, not killed by a signal"),
            stdout: String::from_utf8(output.stdout).expect("stdout is UTF-8"),
            stderr: String::from_utf8(output.stderr).expect("stderr is UTF-8"),
        }
    }

    fn assert_code(&self, code: i32) -> &Run {
        assert_eq!(
            self.code, code,
            "`{}` exit code; stdout {:?}, stderr {:?}",
            self.args, self.stdout, self.stderr
        );
        self
    }

    fn assert_quiet_stderr(&self) -> &Run {
        assert_eq!(self.stderr, "", "`{}` wrote to stderr", self.args);
        self
    }

    fn assert_quiet_stdout(&self) -> &Run {
        assert_eq!(self.stdout, "", "`{}` wrote to stdout", self.args);
        self
    }

    /// stdout as the one JSON envelope the contract allows. In `--json` mode stderr may carry only
    /// NDJSON logs, one JSON object per line, so that is checked on the way.
    fn envelope(&self) -> serde_json::Value {
        for line in self.stderr.lines() {
            let log: serde_json::Value = serde_json::from_str(line).unwrap_or_else(|error| {
                panic!(
                    "`{}` stderr line is not JSON ({error}): {line:?}",
                    self.args
                )
            });
            assert!(
                log.is_object(),
                "`{}` stderr line is not an object: {line}",
                self.args
            );
        }
        assert!(
            self.stdout.ends_with('\n') && self.stdout.matches('\n').count() == 1,
            "`{}` must print one line of JSON, got {:?}",
            self.args,
            self.stdout
        );
        serde_json::from_str(&self.stdout).unwrap_or_else(|error| {
            panic!(
                "`{}` stdout is not JSON ({error}): {:?}",
                self.args, self.stdout
            )
        })
    }

    /// The error envelope's `kind`, checking the rest of its shape on the way.
    fn error_kind(&self) -> String {
        let envelope = self.envelope();
        assert_eq!(envelope["ok"], false, "`{}`: {envelope}", self.args);
        assert_eq!(envelope["schema_version"], 1, "`{}`: {envelope}", self.args);
        assert!(
            envelope["error"]["message"]
                .as_str()
                .is_some_and(|m| !m.is_empty()),
            "`{}` error has no message: {envelope}",
            self.args
        );
        envelope["error"]["kind"]
            .as_str()
            .unwrap_or_else(|| panic!("`{}` error has no kind: {envelope}", self.args))
            .to_string()
    }
}

/// `envelope` with the version every binary reports differently written as the goldens write it
/// (`dev`, a plain `go build`'s). Only those values change, so the bytes around them, key order and
/// spacing included, are still compared.
fn normalize_version(envelope: &str) -> String {
    let value: serde_json::Value = serde_json::from_str(envelope).expect("JSON");
    let mut text = envelope.to_string();
    for key in ["cli_version", "version"] {
        if let Some(version) = value.get(key) {
            text = text.replace(
                &format!("\"{key}\":{version}"),
                &format!("\"{key}\":\"dev\""),
            );
        }
    }
    text
}

/// `testdata/contracts/<file>`.
fn golden_path(file: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../testdata/contracts")
        .join(file)
}

/// Who writes a golden: this suite, or Go's contract tests, whose goldens this suite only reads,
/// or the Go CLI itself, whose output a golden keeps as it was (a completion script it generated).
#[derive(Clone, Copy, PartialEq)]
enum Owner {
    ThisSuite,
    GoContractTests,
    GoCli,
}

/// Compares `got` with `testdata/contracts/<file>`. A golden this suite owns is rewritten instead
/// under `WORKROOM_CONTRACT_UPDATE=1`; one Go's tests own is rewritten only by `go test -update`.
fn check_golden(owner: Owner, file: &str, got: &str) {
    let path = golden_path(file);
    let update = std::env::var_os("WORKROOM_CONTRACT_UPDATE").is_some_and(|v| v == "1");
    if update && owner == Owner::ThisSuite {
        std::fs::write(&path, got).expect("write golden");
        return;
    }
    let want = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let how = match owner {
        Owner::ThisSuite => "rerun with WORKROOM_CONTRACT_UPDATE=1",
        Owner::GoContractTests => "rerun `go test ./cmd -run TestContract -update`",
        Owner::GoCli => "it is the Go CLI's output, kept as it was: the binary must match it",
    };
    assert!(
        got == want,
        "{file} no longer matches; a deliberate change should {how}\n got: {got}\nwant: {want}"
    );
}

// --- version ---

#[test]
fn version_prints_the_bare_version_the_json_reports() {
    let home = Home::new("version-bare");
    let bare = home.run(&home.dir, &["version"]);
    bare.assert_code(0).assert_quiet_stderr();
    let json = home.run(&home.dir, &["version", "--json"]);
    json.assert_code(0).assert_quiet_stderr();

    // Scripts parse the bare form: one line, the version alone.
    let version = json.envelope()["version"]
        .as_str()
        .expect("version")
        .to_string();
    assert!(!version.is_empty() && !version.contains(char::is_whitespace));
    assert_eq!(bare.stdout, format!("{version}\n"));
}

#[test]
fn version_json_matches_the_golden() {
    let home = Home::new("version-json");
    let run = home.run(&home.dir, &["version", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    let envelope = run.envelope();
    assert_eq!(envelope["cli_version"], envelope["version"]);
    check_golden(
        Owner::ThisSuite,
        "version.json",
        &normalize_version(&run.stdout),
    );
}

/// `--json` is a flag of every command, so it may come before the command too.
#[test]
fn version_json_flag_may_come_before_the_command() {
    let home = Home::new("version-json-first");
    let run = home.run(&home.dir, &["--json", "version"]);
    run.assert_code(0).assert_quiet_stderr();
    check_golden(
        Owner::ThisSuite,
        "version.json",
        &normalize_version(&run.stdout),
    );
}

/// The channel is config's `channel` when that is a non-empty string, whatever it says, and
/// `stable` otherwise, including when config.json can't be read: `version` never fails on config.
#[test]
fn version_json_reports_the_configured_channel() {
    for (config, channel) in [
        (Some(r#"{"channel": "pre"}"#), "pre"),
        (Some(r#"{"channel": "nightly"}"#), "nightly"),
        (Some(r#"{"channel": "bogus"}"#), "bogus"),
        (Some(r#"{"channel": ""}"#), "stable"),
        (Some(r#"{"channel": 5}"#), "stable"),
        (Some("{not json"), "stable"),
        (None, "stable"),
    ] {
        let home = Home::new("version-channel");
        if let Some(config) = config {
            home.write_config(config);
        }
        let run = home.run(&home.dir, &["version", "--json"]);
        run.assert_code(0).assert_quiet_stderr();
        assert_eq!(run.envelope()["channel"], channel, "config {config:?}");
        let bare = home.run(&home.dir, &["version"]);
        bare.assert_code(0).assert_quiet_stderr();
    }
}

/// `version` takes no arguments; an extra one is a usage error, in the envelope under `--json`
/// and as an `Error:` line on stderr without it.
#[test]
fn version_refuses_an_argument() {
    let home = Home::new("version-extra");
    let json = home.run(&home.dir, &["version", "--json", "extra"]);
    json.assert_code(1).assert_quiet_stderr();
    assert_eq!(json.error_kind(), "InternalError");
    let plain = home.run(&home.dir, &["version", "extra"]);
    plain.assert_code(1);
    assert_eq!(plain.stdout, "");
    assert!(
        plain.stderr.starts_with("Error: "),
        "stderr {:?}",
        plain.stderr
    );
}

/// The envelope is encoded as Go's encoder writes it, which serde_json's default does not: `<`,
/// `>`, `&`, `/`, DEL and non-ASCII as they are; `"` and `\` escaped; U+2028 and U+2029 as
/// six-character `\u` escapes; control characters as `\b`, `\f`, `\n`, `\r`, `\t` or a `\u`
/// escape; and a
/// byte that isn't UTF-8 as U+FFFD. An unknown flag's name is echoed in the message, so it carries
/// each case to the encoder.
#[test]
fn version_json_encodes_an_echoed_argument_as_go_does() {
    use std::os::unix::ffi::OsStrExt;
    let home = Home::new("version-escaping");
    let flag =
        OsStr::from_bytes(b"--x<&>\xe2\x80\xa8\xe2\x80\xa9\x01\x08\x0c\x1f\x7f\"\\/\xc3\xa9\xff");
    let run = home.run(
        &home.dir,
        &[OsStr::new("version"), OsStr::new("--json"), flag],
    );
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
    let message = run.envelope()["error"]["message"]
        .as_str()
        .expect("message")
        .to_string();
    let echoed = "x<&>\u{2028}\u{2029}\u{1}\u{8}\u{c}\u{1f}\u{7f}\"\\/\u{e9}\u{fffd}";
    assert!(
        message.contains(echoed),
        "message {message:?} doesn't echo the flag"
    );
    // Each escape spelled out: a backslash, then the escape's letters.
    let encoded = [
        "x<&>",
        "\\u2028",
        "\\u2029",
        "\\u0001",
        "\\b",
        "\\f",
        "\\u001f",
        "\u{7f}",
        "\\\"",
        "\\\\",
        "/\u{e9}\u{fffd}",
    ]
    .concat();
    assert!(
        run.stdout.contains(&encoded),
        "stdout {:?} doesn't encode the message as Go does ({encoded:?})",
        run.stdout
    );
}

// --- update ---
//
// Only what ends before the network: a run that asked GitHub would print `Checking the … channel`
// first, so each test checks it didn't. The releases themselves (each channel, checksums, the
// swap) are `commands/update/tests.rs`'s, against a fake releases server.

/// Whether the binary under test is the Go CLI, which has none of the daemon's subcommands.
fn under_test_is_go() -> bool {
    Command::new(binary())
        .arg("protocol")
        .env_clear()
        .output()
        .is_ok_and(|output| !output.status.success())
}

/// The binary under test copied to `relative` in `home`, for a run from there.
///
/// Copied by a `cp` child, not `std::fs::copy`: while this process holds the copy open for
/// writing, another test thread's fork inherits that descriptor until its child execs, and on
/// Linux exec'ing the copy then fails with ETXTBSY ("Text file busy"). In `cp`'s own process the
/// descriptor is closed for good once it exits.
fn copy_binary(home: &Home, relative: &str) -> PathBuf {
    let copy = home.path(relative);
    std::fs::create_dir_all(copy.parent().expect("parent")).expect("create folders");
    let status = Command::new("cp")
        .arg(binary())
        .arg(&copy)
        .status()
        .expect("run cp");
    assert!(
        status.success(),
        "cp the binary under test to {}",
        copy.display()
    );
    copy
}

fn assert_never_checked(run: &Run) {
    assert!(
        !run.stdout.contains("Checking the"),
        "`{}` asked for a release: {:?}",
        run.args,
        run.stdout
    );
}

#[test]
fn update_json_refuses_a_channel_it_cant_switch_to() {
    let home = Home::new("update-channel");
    for (channel, message) in [
        (
            "nightly",
            "nightly is a separate install, not a channel switch",
        ),
        ("bogus", "invalid channel \"bogus\" (want stable or pre)"),
        ("", "invalid channel \"\" (want stable or pre)"),
    ] {
        let run = home.run(&home.dir, &["update", "--json", "--channel", channel]);
        run.assert_code(1).assert_quiet_stderr();
        assert_never_checked(&run);
        assert_eq!(run.error_kind(), "InternalError");
        let envelope = run.envelope();
        assert_eq!(envelope["command"], "update");
        assert!(
            envelope["error"]["message"]
                .as_str()
                .is_some_and(|text| text.starts_with(message)),
            "--channel {channel:?}: {envelope}"
        );
    }
    // Nothing was remembered.
    assert!(!home.config_path().exists());
}

/// A usage error is reported before the command runs, so its envelope names no command.
#[test]
fn update_json_reports_a_usage_error_without_a_command() {
    let home = Home::new("update-usage");
    for (args, message) in [
        (
            &["update", "--json", "--channel"][..],
            "flag needs an argument: --channel",
        ),
        (
            &["update", "--json", "extra"][..],
            "unknown command \"extra\" for \"workroom update\"",
        ),
        (
            &["update", "--json", "--bogus"][..],
            "unknown flag: --bogus",
        ),
    ] {
        let run = home.run(&home.dir, args);
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message, "{args:?}");
        assert!(envelope.get("command").is_none(), "{args:?}: {envelope}");
    }
}

/// The copy inside the app bundle is the app's, which Sparkle updates. Go refused it as an
/// `InternalError`; the Rust binary gives it its own kind, `ManagedInstall` (exit 3, ADR 0078).
/// Go refused a dev build before it looked where it was, so it is checked only with a version, as
/// `make contract-test` builds it; the Rust binary looks first.
#[test]
fn update_inside_the_app_bundle_is_a_managed_install() {
    let home = Home::new("update-bundle");
    if under_test_is_go() && is_dev_build(&home) {
        return;
    }
    let bundled = copy_binary(
        &home,
        "Applications/Workroom.app/Contents/Resources/workroom",
    );
    let (kind, code) = if under_test_is_go() {
        ("InternalError", 1)
    } else {
        ("ManagedInstall", 3)
    };
    let message = "this workroom is bundled inside the Workroom app and is managed by it";

    let run = home.run_program(&bundled, &home.dir, &["update", "--json"]);
    run.assert_code(code).assert_quiet_stderr();
    assert_never_checked(&run);
    assert_eq!(run.error_kind(), kind);
    let envelope = run.envelope();
    assert_eq!(envelope["command"], "update");
    assert!(
        envelope["error"]["message"]
            .as_str()
            .is_some_and(|text| text.starts_with(message)),
        "{envelope}"
    );

    let plain = home.run_program(&bundled, &home.dir, &["update"]);
    plain.assert_code(code);
    assert_never_checked(&plain);
    assert!(
        plain.stderr.starts_with(&format!("Error: {message}")),
        "stderr {:?}",
        plain.stderr
    );
    // Reached through a link, as the app's /usr/local/bin link reaches it.
    let link = home.path("bin/workroom");
    std::fs::create_dir_all(home.path("bin")).expect("bin");
    std::os::unix::fs::symlink(&bundled, &link).expect("link");
    let linked = home.run_program(&link, &home.dir, &["update", "--json"]);
    linked.assert_code(code);
    assert_eq!(linked.error_kind(), kind);
}

/// On a host, the daemon bootstrap installed is bootstrap's to update: `<daemon dir>/workroomd`
/// (ADR 0057), reached as itself or through the `workroom` link beside it. New with the Rust
/// binary; Go would ask GitHub here, so it is skipped for Go.
#[test]
fn update_in_a_hosts_daemon_directory_is_a_managed_install() {
    if under_test_is_go() {
        return;
    }
    let home = Home::new("update-daemon-dir");
    let daemon = copy_binary(&home, ".local/state/workroom/daemon/workroomd");
    let link = home.path(".local/state/workroom/daemon/workroom");
    std::os::unix::fs::symlink("workroomd", &link).expect("link");
    for program in [&daemon, &link] {
        let run = home.run_program(program, &home.dir, &["update", "--json"]);
        run.assert_code(3).assert_quiet_stderr();
        assert_never_checked(&run);
        assert_eq!(run.error_kind(), "ManagedInstall", "{}", program.display());
    }
    // `--check` only reads, so it runs there too; only a dev build asks GitHub nothing.
    if is_dev_build(&home) {
        let check = home.run_program(&daemon, &home.dir, &["update", "--check", "--json"]);
        check.assert_code(0);
        assert_never_checked(&check);
    }
}

/// Whether the binary under test reports the version a build without one has.
fn is_dev_build(home: &Home) -> bool {
    home.run(&home.dir, &["version"]).stdout == "dev\n"
}

/// `--check` on a dev build says it can't check, as text even under `--json`, as Go's does.
/// Only a dev build is network-free, so a binary built with a version skips it.
#[test]
fn update_check_on_a_dev_build_says_it_cant_check() {
    let home = Home::new("update-check-dev");
    if !is_dev_build(&home) {
        return;
    }
    for args in [&["update", "--check"][..], &["update", "-c", "--json"][..]] {
        let run = home.run(&home.dir, args);
        run.assert_code(0).assert_quiet_stderr();
        assert_eq!(
            run.stdout, "Running dev build \u{2014} cannot check for updates\n",
            "{args:?}"
        );
    }
}

/// `update --help` explains its flags and the channels, as Go's does (its wording may change).
#[test]
fn update_help_explains_the_channels_and_its_flags() {
    let home = Home::new("update-help");
    let run = home.run(&home.dir, &["update", "--help"]);
    run.assert_code(0).assert_quiet_stderr();
    for text in [
        "Check for and install the latest version of workroom from GitHub Releases.",
        "  stable   GA releases only (default)\n",
        "  pre      betas / release candidates, plus stable\n",
        "Nightly is not a channel switch",
        "--channel string",
        "Release channel: stable or pre (remembered for next time)",
        "-c, --check",
        "Only check if an update is available",
        "update, u",
    ] {
        assert!(
            run.stdout.contains(text),
            "{text:?} not in:\n{}",
            run.stdout
        );
    }
}

// --- list ---

/// The config `list.json` was recorded from (`TestContractList` in `cmd/contract_test.go`): a
/// project with a healthy workroom, a stray directory, a missing one, a remote one whose host
/// descriptor the CLI must report verbatim, a destroyed one, a project base and a global base,
/// and a second project with no workrooms. `{home}` is the temporary HOME.
const LIST_CONFIG: &str = r#"{
  "base_branch": "main",
  "{home}/src/app": {
    "base_branch": "develop",
    "vcs": "git",
    "workrooms": {
      "gone": {"host": {"driver": "boxd", "state": "destroyed"}, "path": "/home/workroom/gone"},
      "missing": {"path": "{home}/workrooms/missing"},
      "ok": {"path": "{home}/workrooms/ok"},
      "remote": {
        "host": {
          "account": "user-1", "clone_url": "https://github.com/acme/app.git",
          "container": {"address": "127.0.0.1", "context": "colima", "host_key": "ssh-ed25519 AAAA",
                        "port": 2222, "user": "workroom"},
          "credentials": "relay", "driver": "container", "grant_id": "grant-1",
          "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "org": "acme",
          "provisioner": "com.developwithstyle.workroom.dev", "repository": "acme/app",
          "state": "running", "workroom_id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"
        },
        "path": "/home/workroom/remote"
      },
      "stray": {"path": "{home}/workrooms/stray"}
    }
  },
  "{home}/src/empty": {"vcs": "git", "workrooms": {}}
}"#;

#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_matches_the_golden() {
    let home = Home::new("list-json");
    let app = home.repo("src/app");
    home.repo("src/empty");
    let ok = home.path("workrooms/ok");
    home.git(
        &app,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "workroom/ok",
            &ok.to_string_lossy(),
        ],
    );
    std::fs::create_dir_all(home.path("workrooms/stray")).expect("stray dir");
    // app has an include file and empty has none, so has_include is in the golden both ways.
    std::fs::write(app.join(".worktreeinclude"), ".env\n").expect("include file");
    home.write_config(&LIST_CONFIG.replace("{home}", &home.dir.to_string_lossy()));

    let run = home.run(&home.dir, &["list", "--json", "--warnings=full"]);
    run.assert_code(0).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "list.json",
        &home.normalize(&normalize_version(&run.stdout)),
    );
}

/// Plain `list` from each kind of directory, as Go prints it (`TestListOutput` in
/// `cmd/list_output_test.go`), uncoloured since stdout is a pipe. ADR 0078 lets human text change
/// its wording, so these are pinned apart from the machine contract: a port that rewords them
/// updates the strings here, keeping the information.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_human_text_from_each_kind_of_directory() {
    let home = Home::new("list-human");
    let elsewhere = home.path("elsewhere");
    std::fs::create_dir_all(&elsewhere).expect("elsewhere");
    let list = |cwd: &Path| {
        let run = home.run(cwd, &["list"]);
        run.assert_code(0).assert_quiet_stderr();
        run.stdout
    };

    assert_eq!(
        list(&elsewhere),
        "No workrooms found.\n",
        "nothing registered"
    );

    let app = home.repo("src/app");
    let empty = home.repo("src/empty");
    home.repo("src/other");
    let in_workroom = home.path("workrooms/calm-river");
    home.git(
        &app,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "workroom/calm-river",
            &in_workroom.to_string_lossy(),
        ],
    );
    home.write_config(
        &r#"{
  "{home}/src/app": {"vcs": "git", "workrooms": {
    "calm-river": {"path": "{home}/workrooms/calm-river"},
    "gone": {"path": "{home}/workrooms/gone"}
  }},
  "{home}/src/empty": {"vcs": "git", "workrooms": {}},
  "{home}/src/other": {"vcs": "git", "workrooms": {"solo": {"path": "{home}/workrooms/solo"}}}
}"#
        .replace("{home}", &home.dir.to_string_lossy()),
    );

    let missing = "[directory not found, git workroom not found]";
    assert_eq!(
        list(&in_workroom),
        "You are already in a workroom.\nParent project is at ~/src/app\n",
        "in a workroom"
    );
    assert_eq!(
        list(&empty),
        "No workrooms found for this project.\n",
        "a project with none"
    );
    assert_eq!(
        list(&app),
        format!(
            "  calm-river  ~/workrooms/calm-river\n  gone        ~/workrooms/gone        {missing}\n"
        ),
        "a project's root"
    );
    assert_eq!(
        list(&elsewhere),
        format!(
            "~/src/app:\n  calm-river  ~/workrooms/calm-river\n  gone        ~/workrooms/gone        {missing}\n\n~/src/other:\n  solo  ~/workrooms/solo  {missing}\n\n"
        ),
        "elsewhere"
    );
}

#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_reports_a_bad_flag_value_as_an_error_envelope() {
    let home = Home::new("list-bad-warnings");
    let run = home.run(&home.dir, &["list", "--json", "--warnings=bad"]);
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
    assert_eq!(run.envelope()["command"], "list");
}

#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_reports_an_unknown_flag_as_an_error_envelope() {
    let home = Home::new("list-unknown-flag");
    let run = home.run(&home.dir, &["list", "--json", "--bogus"]);
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
}

// --- config ---

/// A write keeps every key the binary doesn't know and every value it doesn't interpret, the
/// app's opaque `host` descriptors above all, and lays the file out as Go does: keys sorted,
/// two-space indent, numbers exactly as written, `<`, `>`, `&`, U+2028 and U+2029 escaped, no
/// trailing newline. The input is laid out unlike that on purpose.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn config_write_keeps_unknown_keys_and_host_descriptors_byte_for_byte() {
    let home = Home::new("config-roundtrip");
    let before = std::fs::read_to_string(golden_path("config-roundtrip-before.json"))
        .expect("read config-roundtrip-before.json");
    home.write_config(&before);

    let run = home.run(&home.dir, &["base", "set", "--global", "main", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["ok"], true);
    let after = std::fs::read_to_string(home.config_path()).expect("read the written config");

    // First what the file says, so a port that loses a key hears that rather than a layout diff:
    // the input with only the global base added.
    let mut expected: serde_json::Value = serde_json::from_str(&before).expect("parse input");
    expected["base_branch"] = "main".into();
    let written: serde_json::Value = serde_json::from_str(&after).expect("parse written config");
    assert_eq!(
        written, expected,
        "the write changed more than the global base"
    );

    check_golden(Owner::ThisSuite, "config-roundtrip-after.json", &after);
}

/// What a write makes of input Go reads its own way, through `base clear --global`, which reads the
/// config and writes it back with nothing changed: each expected file is what the Go CLI wrote.
/// Input it can't read fails with `ConfigReadFailed`, exit 6, and is left as it was.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn config_rewrites_odd_input_as_go_does() {
    for (input, written) in [
        // A null config is Go's nil map, written back as null.
        (&b"null"[..], Some("null")),
        (b"{}  \n", Some("{}")),
        // Numbers no float or 64-bit integer holds, kept as written.
        (
            b"{\"n\":[1e999,-1E+400,123456789012345678901234567890123456789012345678901234567890]}",
            Some(
                "{\n  \"n\": [\n    1e999,\n    -1E+400,\n    123456789012345678901234567890123456789012345678901234567890\n  ]\n}",
            ),
        ),
        (b"{\"a\":1,\"a\":2}", Some("{\n  \"a\": 2\n}")),
        (
            b"{\"a\":{\"x\":1},\"a\":{\"y\":2}}",
            Some("{\n  \"a\": {\n    \"y\": 2\n  }\n}"),
        ),
        (
            b"{\"a\":\"\\ud800\",\"b\":\"\\udc00\\ud800x\",\"c\":\"\\ud83d\\ude00\"}",
            Some(
                "{\n  \"a\": \"\u{fffd}\",\n  \"b\": \"\u{fffd}\u{fffd}x\",\n  \"c\": \"\u{1f600}\"\n}",
            ),
        ),
        (
            b"{\"a\":\"\xe2\x80\",\"\xff\":\"\x7f\"}",
            Some("{\n  \"a\": \"\u{fffd}\u{fffd}\",\n  \"\u{fffd}\": \"\u{7f}\"\n}"),
        ),
        (
            b"{\"a\":\"\\u00e9\\/\\b\\f\\u0001\\u001f\"}",
            Some("{\n  \"a\": \"\u{e9}/\\b\\f\\u0001\\u001f\"\n}"),
        ),
        (b"", None),
        (b"[]", None),
        (b"{} x", None),
        (b"{}}", None),
        (b"{\"a\":\"\x01\"}", None),
        (b"{\"a\":01}", None),
        (b"{\"a\":1.}", None),
        (b"{\"a\":-}", None),
        (b"{\"a\":1e}", None),
        (b"{\"a\":tru}", None),
        (b"\xef\xbb\xbf{}", None),
        (b"{\"a\":", None),
        (b"{\"a\":\"\\q\"}", None),
    ] {
        let home = Home::new("config-odd");
        std::fs::create_dir_all(home.config_path().parent().expect("config dir"))
            .expect("create config dir");
        std::fs::write(home.config_path(), input).expect("write config");
        let run = home.run(&home.dir, &["base", "clear", "--global", "--json"]);
        let after = std::fs::read(home.config_path()).expect("read config");
        let shown = String::from_utf8_lossy(input);
        match written {
            Some(written) => {
                run.assert_code(0).assert_quiet_stderr();
                assert_eq!(String::from_utf8_lossy(&after), written, "{shown:?}");
            }
            None => {
                run.assert_code(6).assert_quiet_stderr();
                assert_eq!(run.error_kind(), "ConfigReadFailed", "{shown:?}");
                assert_eq!(after, input, "{shown:?} was rewritten");
            }
        }
    }
}

/// A write takes `<config>.lock` with flock(2), as every Workroom binary does, waits while another
/// process holds it rather than writing past it, and reads config.json only once it has the lock.
///
/// No sleep decides it: the test holds the lock throughout, and the one thing it waits for is the
/// binary's `git check-ref-format`, which both binaries run just before they take the lock, to
/// have finished (a `git` on PATH that leaves a marker). It then changes config.json, still holding
/// the lock: a binary that waits can't have exited or read the file yet, so its write must keep the
/// change.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn config_write_waits_for_another_process_holding_the_lock() {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new("config-lock");
    home.write_config("{}");
    let lock_path = home.path(".config/workroom/config.json.lock");
    let lock = std::fs::File::create(&lock_path).expect("create lock file");
    // SAFETY: the descriptor belongs to `lock`, which stays open across the call.
    let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(rc, 0, "take the lock");

    let path = std::env::var_os("PATH").unwrap_or_default();
    let git = std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|git| git.is_file())
        .expect("git on PATH");
    let marker = home.path("git-ran");
    let bin = home.path("bin");
    std::fs::create_dir(&bin).expect("create bin");
    let wrapper = bin.join("git");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\n'{}' \"$@\"\nstatus=$?\n: > '{}'\nexit $status\n",
            git.display(),
            marker.display()
        ),
    )
    .expect("write git wrapper");
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755))
        .expect("make git wrapper executable");
    let mut search = vec![bin];
    search.extend(std::env::split_paths(&path));

    let mut child = home
        .command(binary(), &home.dir)
        .env("PATH", std::env::join_paths(search).expect("PATH"))
        .args(["base", "set", "--global", "main", "--json"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn");
    // A backstop, not a budget: the marker comes as soon as git has run.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !marker.exists() {
        if let Some(status) = child.try_wait().expect("poll") {
            panic!("the binary exited ({status}) before its git check finished");
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the binary's git check-ref-format didn't finish within 30 s"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    std::fs::write(home.config_path(), "{\"x\": 1}").expect("change config");
    assert!(
        child.try_wait().expect("poll").is_none(),
        "the write didn't wait for the lock"
    );

    drop(lock);
    let output = child.wait_with_output().expect("wait");
    assert!(output.status.success(), "{output:?}");
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        "{\n  \"base_branch\": \"main\",\n  \"x\": 1\n}",
        "the binary read config.json before it had the lock"
    );
    assert!(lock_path.exists(), "the lock file is never removed");
}

/// `base set --global` refuses what git wouldn't take as a branch name, before touching config,
/// and `--pretend` reports the change without making it.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn config_global_base_refuses_a_bad_name_and_pretends() {
    let home = Home::new("config-base");
    home.write_config("{\"x\": 1}");
    let bad = home.run(&home.dir, &["base", "set", "--global", "a..b", "--json"]);
    bad.assert_code(1).assert_quiet_stderr();
    assert_eq!(bad.error_kind(), "InternalError");
    assert_eq!(bad.envelope()["command"], "base");
    let pretend = home.run(
        &home.dir,
        &["base", "set", "--global", "main", "-p", "--json"],
    );
    pretend.assert_code(0).assert_quiet_stderr();
    assert_eq!(pretend.envelope()["global"], true);
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        "{\"x\": 1}"
    );
    let missing = home.run(&home.dir, &["base", "set", "--global", "--json"]);
    missing.assert_code(1);
    assert_eq!(missing.error_kind(), "InternalError");
}

/// `list` at the default `--warnings fast` detects each project's type from disk and heals a
/// stale one in config (a `jj` from before Jujutsu support was removed): a write, which keeps the
/// rest of the file as Go keeps it. `--warnings none` reads config alone and writes nothing.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_heals_a_stale_vcs_keeping_the_rest_of_the_file() {
    let home = Home::new("list-heal");
    home.repo("src/app");
    let before = r#"{"{home}/src/app": {"vcs": "jj", "future": [1.50, {"z": "<&>"}],
        "workrooms": {"w": {"path": "{home}/workrooms/w", "label": "x"}}}, "zz": 1e3}"#
        .replace("{home}", &home.dir.to_string_lossy());
    home.write_config(&before);

    let none = home.run(&home.dir, &["list", "--json", "--warnings=none"]);
    none.assert_code(0).assert_quiet_stderr();
    let project = &none.envelope()["projects"][0];
    assert_eq!(project["vcs"], "jj");
    assert!(project.get("has_include").is_none(), "{project}");
    assert_eq!(project["workrooms"][0]["warnings"], serde_json::json!([]));
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        before
    );

    let fast = home.run(&home.dir, &["list", "--json"]);
    fast.assert_code(0).assert_quiet_stderr();
    let project = &fast.envelope()["projects"][0];
    assert_eq!(project["vcs"], "git");
    assert_eq!(project["has_include"], false);
    assert_eq!(
        project["workrooms"][0]["warnings"][0]["kind"],
        "DirectoryMissing"
    );
    let after = std::fs::read_to_string(home.config_path()).expect("read");
    assert_eq!(
        home.normalize(&after),
        r#"{
  "/Users/dev/src/app": {
    "future": [
      1.50,
      {
        "z": "\u003c\u0026\u003e"
      }
    ],
    "vcs": "git",
    "workrooms": {
      "w": {
        "label": "x",
        "path": "/Users/dev/workrooms/w"
      }
    }
  },
  "zz": 1e3
}"#
    );
}

/// Any `host` but null is a remote workroom's, reported verbatim, even one that isn't an object;
/// a null one is no host at all. A remote workroom's path is on its host, so it never warns of a
/// missing directory.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_reports_any_non_null_host_verbatim() {
    let home = Home::new("list-hosts");
    home.repo("src/app");
    home.write_config(
        &r#"{"{home}/src/app": {"vcs": "git", "host": {"b": 1.0, "a": "<x>"}, "workrooms": {
  "empty": {"path": "/r/empty", "host": {}},
  "false": {"path": "/r/false", "host": false},
  "local": {"path": "/r/local", "host": null},
  "string": {"path": "/r/string", "host": ""}
}}}"#
            .replace("{home}", &home.dir.to_string_lossy()),
    );
    let run = home.run(&home.dir, &["list", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert!(
        run.stdout
            .contains(r#""vcs":"git","host":{"a":"<x>","b":1.0},"has_include""#),
        "the project's host isn't verbatim: {}",
        run.stdout
    );
    let envelope = run.envelope();
    let workrooms = envelope["projects"][0]["workrooms"]
        .as_array()
        .expect("workrooms");
    let by_name = |name: &str| {
        workrooms
            .iter()
            .find(|workroom| workroom["name"] == name)
            .unwrap_or_else(|| panic!("{name} not listed"))
    };
    assert_eq!(by_name("empty")["host"], serde_json::json!({}));
    assert_eq!(by_name("false")["host"], false);
    assert_eq!(by_name("string")["host"], "");
    for name in ["empty", "false", "string"] {
        assert_eq!(by_name(name)["warnings"], serde_json::json!([]), "{name}");
    }
    assert!(by_name("local").get("host").is_none());
    assert_eq!(by_name("local")["warnings"][0]["kind"], "DirectoryMissing");
}

/// The human list finds where it is run as Go's `os.Getwd` names the directory: by `$PWD`, which
/// every shell sets, when that names the directory, so a workroom registered under a symlinked
/// path is recognised from it.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_human_text_names_the_directory_by_pwd() {
    let home = Home::new("list-pwd");
    home.repo("src/app");
    let real = home.path("real/w");
    std::fs::create_dir_all(&real).expect("workroom dir");
    std::os::unix::fs::symlink(home.path("real"), home.path("link")).expect("symlink");
    let link = home.path("link/w");
    home.write_config(
        &r#"{"{home}/src/app": {"vcs": "git", "workrooms": {"w": {"path": "{home}/link/w"}}}}"#
            .replace("{home}", &home.dir.to_string_lossy()),
    );
    let list = |pwd: Option<&Path>| {
        let mut command = home.command(binary(), &real);
        if let Some(pwd) = pwd {
            command.env("PWD", pwd);
        }
        let output = command.arg("list").output().expect("run list");
        assert!(output.status.success(), "{output:?}");
        String::from_utf8(output.stdout).expect("UTF-8")
    };
    assert_eq!(
        list(Some(&link)),
        "You are already in a workroom.\nParent project is at ~/src/app\n"
    );
    // Without it the directory is its resolved path, which no workroom is registered under.
    assert!(list(None).starts_with("~/src/app:\n"));
    // A $PWD naming another directory is ignored.
    assert!(list(Some(&home.dir)).starts_with("~/src/app:\n"));
}

/// `--project` keeps the one project it names, by its canonical path or as written; one that isn't
/// registered leaves none.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_project_limits_the_listing() {
    let home = Home::new("list-project");
    home.repo("src/app");
    home.repo("src/other");
    std::os::unix::fs::symlink(home.path("src/app"), home.path("app-link")).expect("symlink");
    home.write_config(
        &r#"{"{home}/src/app": {"vcs": "git", "workrooms": {}},
             "{home}/src/other": {"vcs": "git", "workrooms": {}}}"#
            .replace("{home}", &home.dir.to_string_lossy()),
    );
    let listed = |project: &str| {
        let run = home.run(&home.dir, &["list", "--json", "--project", project]);
        run.assert_code(0).assert_quiet_stderr();
        run.envelope()["projects"]
            .as_array()
            .expect("projects")
            .iter()
            .map(|project| home.normalize(project["path"].as_str().expect("path")))
            .collect::<Vec<_>>()
    };
    let app = home.path("src/app").to_string_lossy().into_owned();
    assert_eq!(listed(&app), ["/Users/dev/src/app"]);
    assert_eq!(listed(&format!("{app}/")), ["/Users/dev/src/app"]);
    assert_eq!(listed("app-link"), ["/Users/dev/src/app"]);
    assert_eq!(listed("src/other/../app"), ["/Users/dev/src/app"]);
    assert!(listed("src/nope").is_empty());
}

/// `--project` names a directory as Go's `filepath.EvalSymlinks` does: symlinks resolved, every
/// other name in the case it was given, never rewritten to the case on disk as realpath would. The
/// Mac's disk is case-insensitive, so `caseproj` is the `CaseProj` directory, and its config key
/// matches only in the case it was registered under.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn list_json_project_keeps_the_case_it_was_given() {
    let home = Home::new("list-case");
    let ct = home.path("ct");
    std::fs::create_dir_all(ct.join("CaseProj")).expect("project dir");
    // The case only folds on a case-insensitive disk (macOS's default). On a case-sensitive one,
    // such as the Go job's Linux runner with --include-ignored, `caseproj` simply doesn't exist.
    if !ct.join("caseproj").exists() {
        eprintln!("skipped: {} is on a case-sensitive disk", ct.display());
        return;
    }
    std::os::unix::fs::symlink("CaseProj", ct.join("Link")).expect("symlink");
    home.write_config(
        &r#"{"{home}/ct/caseproj": {"vcs": "git", "workrooms": {}},
             "{home}/ct/CaseProj": {"vcs": "git", "workrooms": {}}}"#
            .replace("{home}", &home.dir.to_string_lossy()),
    );
    let listed = |project: &str| {
        let run = home.run(
            &ct,
            &["list", "--json", "--warnings=none", "--project", project],
        );
        run.assert_code(0).assert_quiet_stderr();
        run.envelope()["projects"]
            .as_array()
            .expect("projects")
            .iter()
            .map(|project| home.normalize(project["path"].as_str().expect("path")))
            .collect::<Vec<_>>()
    };
    assert_eq!(listed("caseproj"), ["/Users/dev/ct/caseproj"]);
    assert_eq!(listed("CaseProj/"), ["/Users/dev/ct/CaseProj"]);
    assert!(listed("CASEPROJ").is_empty(), "no key in that case");
    // A link is resolved to its target as the link names it, whatever case the link is given in.
    assert_eq!(listed("LINK"), ["/Users/dev/ct/CaseProj"]);
    assert_eq!(listed("link/../caseproj"), ["/Users/dev/ct/caseproj"]);
}

// --- include-archive ---

/// One member of a tar, as an extractor reads it: the pax `path` and `mtime` records where the
/// archive has them, else the ustar header's fields.
#[derive(Debug, PartialEq)]
struct Member {
    name: String,
    regular: bool,
    mode: u32,
    owner: (u64, u64),
    owner_names: (Vec<u8>, Vec<u8>),
    /// Seconds and nanoseconds.
    mtime: (i64, u32),
    contents: Vec<u8>,
}

/// The members of the tar at `path`, in order. Each pax extended header is read into the member
/// it describes, not listed; its own name, the headers' device numbers and the padding aren't
/// compared, since no extractor reads them.
fn tar_members(path: &Path) -> Vec<Member> {
    use std::io::Read;
    let file = std::fs::File::open(path)
        .unwrap_or_else(|error| panic!("open {}: {error}", path.display()));
    let mut archive = tar::Archive::new(file);
    let mut members = Vec::new();
    for entry in archive.entries().expect("read the tar") {
        let mut entry = entry.expect("a tar entry");
        let mut mtime = (
            i64::try_from(entry.header().mtime().expect("mtime")).expect("mtime fits"),
            0,
        );
        if let Some(records) = entry.pax_extensions().expect("pax records") {
            for record in records {
                let record = record.expect("pax record");
                if record.key() == Ok("mtime") {
                    let value = record.value().expect("mtime is UTF-8");
                    let (secs, fraction) = value.split_once('.').unwrap_or((value, "0"));
                    let nanos = format!("{fraction:0<9}");
                    mtime = (secs.parse().expect("secs"), nanos.parse().expect("nanos"));
                }
            }
        }
        let header = entry.header();
        let mut member = Member {
            name: String::from_utf8(entry.path_bytes().into_owned()).expect("UTF-8 name"),
            regular: header.entry_type() == tar::EntryType::Regular,
            mode: header.mode().expect("mode"),
            owner: (header.uid().expect("uid"), header.gid().expect("gid")),
            owner_names: (
                header.username_bytes().unwrap_or_default().to_vec(),
                header.groupname_bytes().unwrap_or_default().to_vec(),
            ),
            mtime,
            contents: Vec::new(),
        };
        entry
            .read_to_end(&mut member.contents)
            .expect("member contents");
        members.push(member);
    }
    members
}

/// The member an extractor should make `root/relative` from, as the file is now: its name, mode,
/// mtime to the nanosecond and contents, owned by uid and gid 0 with no owner names, so a host's
/// extraction as root doesn't chown it to the Mac's uid.
fn member_for(root: &Path, relative: &str) -> Member {
    use std::os::unix::fs::MetadataExt;
    let path = root.join(relative);
    let metadata = std::fs::metadata(&path).expect("stat the source");
    Member {
        name: relative.to_string(),
        regular: true,
        mode: metadata.mode() & 0o777,
        owner: (0, 0),
        owner_names: (Vec::new(), Vec::new()),
        mtime: (
            metadata.mtime(),
            u32::try_from(metadata.mtime_nsec()).expect("nanos"),
        ),
        contents: std::fs::read(&path).expect("read the source"),
    }
}

/// Writes `contents` at `root/relative` with `mode`, making its directories.
fn write_file(root: &Path, relative: &str, contents: &str, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let path = root.join(relative);
    std::fs::create_dir_all(path.parent().expect("parent")).expect("create dirs");
    std::fs::write(&path, contents).expect("write file");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).expect("chmod");
}

/// A path over the 100 bytes a ustar name holds, so the tar needs a pax `path` record for it.
fn long_include_path() -> String {
    format!("{}/{}.key", "d".repeat(60), "f".repeat(60))
}

/// A repo whose include file names each kind of file there is: included ones with several modes,
/// a non-ASCII name and a long path; ones it names that git doesn't ignore (`loose.txt`) or that
/// are tracked (`tracked.txt`); an ignored one it doesn't name; a symlink out of the root, a FIFO,
/// and `bad.key`, which can't be read unless the tests run as root. Returns the repo and whether
/// `bad.key` is unreadable.
fn include_fixture(home: &Home) -> (PathBuf, bool) {
    let root = home.repo("src/app");
    write_file(
        &root,
        ".gitignore",
        ".env\nsecrets/\n*.key\nbin.sh\nignored-only.txt\ntracked.txt\n",
        0o644,
    );
    write_file(
        &root,
        ".worktreeinclude",
        ".env\nsecrets/\n*.key\nbin.sh\nloose.txt\ntracked.txt\n",
        0o644,
    );
    write_file(&root, ".env", "SECRET=1", 0o600);
    write_file(&root, "secrets/a.json", "{}", 0o644);
    write_file(&root, "secrets/nested/b.txt", "bee", 0o640);
    write_file(&root, "bin.sh", "#!/bin/sh\n", 0o755);
    // A whole-second mtime, as a restored file often has: its member needs no pax header at all.
    std::fs::File::options()
        .write(true)
        .open(root.join("bin.sh"))
        .and_then(|file| {
            file.set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000))
        })
        .expect("set bin.sh's mtime");
    write_file(&root, "caf\u{e9}.key", "c", 0o644);
    write_file(&root, &long_include_path(), "long", 0o644);
    write_file(&root, "loose.txt", "not ignored", 0o644);
    write_file(&root, "ignored-only.txt", "not included", 0o644);
    write_file(&root, "tracked.txt", "tracked", 0o644);
    home.git(&root, &["add", "-f", "tracked.txt"]);
    home.git(
        &root,
        &[
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-q",
            "-m",
            "tracked",
        ],
    );
    write_file(&home.dir, "outside/secret", "outside", 0o644);
    std::os::unix::fs::symlink(home.path("outside/secret"), root.join("link.key"))
        .expect("symlink");
    let fifo = std::ffi::CString::new(root.join("pipe.key").into_os_string().into_encoded_bytes())
        .expect("path");
    // SAFETY: `fifo` is a NUL-terminated path that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o644) }, 0, "mkfifo");
    // SAFETY: geteuid has no preconditions.
    let unreadable = unsafe { libc::geteuid() } != 0;
    write_file(&root, "bad.key", "k", if unreadable { 0 } else { 0o644 });
    (root, unreadable)
}

/// The envelope the app decodes into `IncludeArchive` (`TestContractIncludeArchive` in
/// `cmd/contract_test.go`, and `CLIContractTests.swift`).
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn include_archive_json_matches_the_golden() {
    let home = Home::new("include-archive-json");
    let root = home.repo("src/app");
    write_file(&root, ".gitignore", ".env\n", 0o644);
    write_file(&root, ".worktreeinclude", ".env\n", 0o644);
    write_file(&root, ".env", "SECRET=1", 0o644);
    let archive = home.path("a.tar");
    let run = home.run(
        &home.dir,
        &[
            "include-archive",
            "--json",
            "--project",
            &root.to_string_lossy(),
            "--output",
            &archive.to_string_lossy(),
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "include-archive.json",
        &home.normalize(&normalize_version(&run.stdout)),
    );
    assert_eq!(tar_members(&archive), [member_for(&root, ".env")]);
}

/// The tar holds exactly the regular files the include file names that git ignores and doesn't
/// track, each with its mode, mtime and contents. The envelope lists them, their size, the symlink
/// it skipped and the file it couldn't read, and an unreadable file costs only itself. The FIFO is
/// in neither list: git lists only files and symlinks.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn include_archive_writes_each_included_file_with_its_mode() {
    let home = Home::new("include-archive-modes");
    let (root, unreadable) = include_fixture(&home);
    let archive = home.path("included.tar");
    let run = home.run(
        &root,
        &[
            "include-archive",
            "--json",
            "--output",
            &archive.to_string_lossy(),
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    let envelope = run.envelope();

    let long = long_include_path();
    let mut paths = vec![".env"];
    if !unreadable {
        paths.push("bad.key");
    }
    paths.extend([
        "bin.sh",
        "caf\u{e9}.key",
        &long,
        "secrets/a.json",
        "secrets/nested/b.txt",
    ]);
    assert_eq!(envelope["paths"], serde_json::json!(paths), "{envelope}");
    assert_eq!(envelope["count"], paths.len(), "{envelope}");
    assert_eq!(
        envelope["skipped"],
        serde_json::json!(["link.key"]),
        "{envelope}"
    );
    let members: Vec<Member> = paths.iter().map(|path| member_for(&root, path)).collect();
    let bytes: usize = members.iter().map(|member| member.contents.len()).sum();
    assert_eq!(envelope["bytes"], bytes, "{envelope}");
    let warnings = envelope["warnings"].as_array().expect("warnings");
    if unreadable {
        assert_eq!(warnings.len(), 1, "{envelope}");
        let warning = warnings[0].as_str().expect("a string");
        assert_eq!(
            warning,
            format!(
                "bad.key: open {}: permission denied",
                root.join("bad.key").display()
            )
        );
    } else {
        assert!(warnings.is_empty(), "{envelope}");
    }
    assert_eq!(tar_members(&archive), members);
}

/// Without `--json`: the count and the tar's path on stdout, each file it couldn't read on stderr.
/// ADR 0078 lets this text change its wording, keeping the information.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn include_archive_human_text_reports_the_count_and_each_failure() {
    let home = Home::new("include-archive-human");
    let (root, unreadable) = include_fixture(&home);
    let archive = home.path("included.tar");
    let run = home.run(
        &home.dir,
        &[
            "include-archive",
            "--project",
            &root.to_string_lossy(),
            "--output",
            &archive.to_string_lossy(),
        ],
    );
    run.assert_code(0);
    let count = if unreadable { 6 } else { 7 };
    assert_eq!(
        run.stdout,
        format!("Archived {count} files to {}\n", archive.display())
    );
    if unreadable {
        assert_eq!(
            run.stderr,
            format!(
                "bad.key: open {}: permission denied\n",
                root.join("bad.key").display()
            )
        );
    } else {
        run.assert_quiet_stderr();
    }
}

/// A root with no include file archives nothing, without failing, and still writes a valid tar.
/// So does a project directory that doesn't exist: it has no include file either.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn include_archive_without_an_include_file_writes_an_empty_tar() {
    let home = Home::new("include-archive-none");
    let root = home.repo("src/app");
    write_file(&root, ".gitignore", ".env\n", 0o644);
    write_file(&root, ".env", "SECRET=1", 0o644);
    for (project, archive) in [
        (root, home.path("root.tar")),
        (home.path("src/missing"), home.path("missing.tar")),
    ] {
        let run = home.run(
            &home.dir,
            &[
                "include-archive",
                "--json",
                "--project",
                &project.to_string_lossy(),
                "--output",
                &archive.to_string_lossy(),
            ],
        );
        run.assert_code(0).assert_quiet_stderr();
        let envelope = run.envelope();
        assert_eq!(envelope["ok"], true, "{envelope}");
        assert_eq!(envelope["count"], 0, "{envelope}");
        assert_eq!(envelope["bytes"], 0, "{envelope}");
        for list in ["paths", "skipped", "warnings"] {
            assert_eq!(envelope[list], serde_json::json!([]), "{list}: {envelope}");
        }
        // The tar's end and nothing else: two zero blocks.
        assert_eq!(std::fs::read(&archive).expect("read tar"), vec![0; 1024]);
    }
}

/// The tar goes only where `--output` says, so it is required: without it the command fails as a
/// usage error, before it runs, so the envelope names no command. A flag with no value and an
/// argument fail the same way.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn include_archive_refuses_a_missing_output_or_flag_value() {
    let home = Home::new("include-archive-usage");
    let root = home.repo("src/app");
    let root = root.to_string_lossy();
    for (args, message) in [
        (
            &["include-archive", "--json", "--project", &root][..],
            "required flag(s) \"output\" not set",
        ),
        (
            &["include-archive", "--json", "--project"],
            "flag needs an argument: --project",
        ),
        (
            &["include-archive", "--json", "--output", "x.tar", "extra"],
            "unknown command \"extra\" for \"workroom include-archive\"",
        ),
    ] {
        let run = home.run(&home.dir, args);
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message, "{args:?}");
        assert!(envelope.get("command").is_none(), "{args:?}: {envelope}");
    }
    assert!(!home.path("x.tar").exists());
}

/// A project with an include file that isn't a repository fails git's listing, reported in the
/// envelope, and leaves no tar behind: the files are listed before the tar is opened. A tar that
/// can't be created fails the command too.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn include_archive_reports_a_failed_listing_or_output() {
    let home = Home::new("include-archive-failure");
    let plain = home.path("plain");
    write_file(&plain, ".worktreeinclude", ".env\n", 0o644);
    let archive = home.path("included.tar");
    let run = home.run(
        &home.dir,
        &[
            "include-archive",
            "--json",
            "--project",
            &plain.to_string_lossy(),
            "--output",
            &archive.to_string_lossy(),
        ],
    );
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
    let envelope = run.envelope();
    assert_eq!(envelope["command"], "include-archive");
    let message = envelope["error"]["message"].as_str().expect("message");
    assert!(
        message.starts_with("git ls-files: exit status 128: ")
            && message.contains("not a git repository"),
        "{message}"
    );
    assert!(!archive.exists(), "the tar was opened before the listing");

    let root = home.repo("src/app");
    let unwritable = home.path("no-such-dir/included.tar");
    let run = home.run(
        &home.dir,
        &[
            "include-archive",
            "--json",
            "--project",
            &root.to_string_lossy(),
            "--output",
            &unwritable.to_string_lossy(),
        ],
    );
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
    assert_eq!(
        run.envelope()["error"]["message"],
        format!("open {}: no such file or directory", unwritable.display())
    );
}

// --- base ---

/// `run`'s one line of stdout as the goldens write it: this HOME as `/Users/dev`, the version as a
/// plain `go build`'s. Compared whole, so key order, a key left out and spacing all count.
fn normalized_stdout(home: &Home, run: &Run) -> String {
    home.normalize(&normalize_version(&run.stdout))
}

/// The config file as the goldens write it.
fn normalized_config(home: &Home) -> String {
    home.normalize(&std::fs::read_to_string(home.config_path()).expect("read config"))
}

/// `base set` checks only that git would take BRANCH as a branch name: one that exists nowhere is
/// stored, since it may be pushed later (a create looks for it, and fails with
/// `BaseBranchNotFound` there). It registers the repository as add-project does, refreshing an
/// existing entry's type and keeping the rest of it, and `clear` removes the base again. The app
/// passes `--project`; without it the project is the current directory.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn base_set_registers_the_project_and_clear_removes_the_base() {
    let home = Home::new("base-set");
    let repo = home.repo("repo");
    let project = repo.to_string_lossy();
    let run = home.run(
        &home.dir,
        &[
            "base",
            "set",
            "no-such-branch",
            "--json",
            "--project",
            &project,
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"base_branch\":\"no-such-branch\",\"cli_version\":\"dev\",\"command\":\"base\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1}\n"
    );
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/repo\": {\n    \"base_branch\": \"no-such-branch\",\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );

    let run = home.run(
        &home.dir,
        &["base", "clear", "--json", "--project", &project],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"base_branch\":\"\",\"cli_version\":\"dev\",\"command\":\"base\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1}\n"
    );
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/repo\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );

    // An existing entry: its stale type refreshed, its workrooms and unknown keys kept. From the
    // repository itself, with no `--project`, and without `--json`, which prints nothing.
    let other = home.repo("other");
    home.write_config(&format!(
        "{{\"{}\": {{\"vcs\": \"jj\", \"x\": [1.50], \"workrooms\": {{\"w\": {{\"path\": \"/p\"}}}}}}}}",
        other.display()
    ));
    let run = home.run(&other, &["base", "set", "upstream/main"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.stdout, "");
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/other\": {\n    \"base_branch\": \"upstream/main\",\n    \"vcs\": \"git\",\n    \"workrooms\": {\n      \"w\": {\n        \"path\": \"/p\"\n      }\n    },\n    \"x\": [\n      1.50\n    ]\n  }\n}"
    );
}

/// What git wouldn't take as a branch name, "" included, is refused with git's own words before
/// config is read, so even an unreadable config doesn't hide it. A wrong number of arguments is a
/// usage error, before the command runs, so its envelope names no command.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn base_refuses_a_bad_branch_name_or_arguments() {
    let home = Home::new("base-bad-name");
    let repo = home.repo("repo");
    let project = repo.to_string_lossy();
    home.write_config("not json");
    // "" is a name git refuses too, never a way to clear the base, for one project or all.
    for (name, scope) in [
        ("a..b", &["--project", &*project][..]),
        ("", &["--project", &*project]),
        ("", &["--global"]),
    ] {
        let run = home.run(
            &home.dir,
            &[&["base", "set", name, "--json"], scope].concat(),
        );
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError", "{name:?} {scope:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["command"], "base");
        // Then git's own words, which differ between git versions.
        let message = envelope["error"]["message"].as_str().expect("message");
        assert!(
            message.starts_with(&format!("invalid branch name {name:?}: ")) && message.len() > 25,
            "{message:?}"
        );
    }
    for (args, message) in [
        (
            &["base", "set", "--json"][..],
            "accepts 1 arg(s), received 0",
        ),
        (
            &["base", "set", "a", "b", "--json"],
            "accepts 1 arg(s), received 2",
        ),
        (
            &["base", "clear", "x", "--json"],
            "unknown command \"x\" for \"workroom base clear\"",
        ),
    ] {
        let run = home.run(&repo, args);
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError", "{args:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message, "{args:?}");
        assert_eq!(envelope.get("command"), None, "{args:?}");
    }
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        "not json"
    );
}

/// A base belongs to a project's root checkout, so `set` and `clear` both refuse a workroom: a
/// linked worktree, or a directory registered as any project's workroom. A root whose `.git` is a
/// file but isn't a linked worktree (`git init --separate-git-dir`) is a project. `set` refuses a
/// directory that isn't a repository, and an unreadable config fails both.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn base_refuses_a_workroom_or_a_directory_that_isnt_a_repository() {
    let home = Home::new("base-refuses");
    let repo = home.repo("repo");
    home.git(&repo, &["worktree", "add", "-q", "../linked"]);
    let registered = home.path("registered");
    std::fs::create_dir(&registered).expect("create registered");
    let plain = home.path("plain");
    std::fs::create_dir(&plain).expect("create plain");
    let config = format!(
        "{{\"/elsewhere\": {{\"vcs\": \"git\", \"workrooms\": {{\"r\": {{\"path\": \"{}\"}}}}}}}}",
        registered.display()
    );
    home.write_config(&config);
    for (dir, kind, code) in [
        (home.path("linked"), "InWorkroom", 3),
        (registered, "InWorkroom", 3),
    ] {
        for args in [&["set", "main"][..], &["clear"]] {
            let project = dir.to_string_lossy();
            let run = home.run(
                &home.dir,
                &[&["base"], args, &["--json", "--project", &project]].concat(),
            );
            run.assert_code(code).assert_quiet_stderr();
            assert_eq!(run.error_kind(), kind, "{args:?} in {project}");
            assert_eq!(
                run.envelope()["error"]["message"],
                "looks like you are already in a workroom. Run this command from the root of your \
                 main development directory, not from within an existing workroom"
            );
        }
    }
    let run = home.run(
        &home.dir,
        &[
            "base",
            "set",
            "main",
            "--json",
            "--project",
            &plain.to_string_lossy(),
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "UnsupportedVCS");
    assert_eq!(
        run.envelope()["error"]["message"],
        "no supported VCS detected in this directory. Workroom requires Git to manage workrooms"
    );
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        config,
        "a refused base changed config"
    );

    let separate = home.path("separate");
    home.git(
        &home.dir,
        &[
            "init",
            "-q",
            "--separate-git-dir",
            "separate.git",
            "separate",
        ],
    );
    let run = home.run(&separate, &["base", "set", "main", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.envelope()["project"],
        separate.to_string_lossy().as_ref()
    );

    home.write_config("{");
    for args in [&["set", "main"][..], &["clear"]] {
        let run = home.run(&repo, &[&["base"], args, &["--json"]].concat());
        run.assert_code(6).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "ConfigReadFailed", "{args:?}");
    }
}

/// `clear` only edits: it needs the project registered, though not its folder, which may have
/// moved, and it registers nothing. `--pretend` writes nothing, and `clear` under it skips the
/// edit and so the registration check too.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn base_clear_needs_a_registered_project_and_pretend_writes_nothing() {
    let home = Home::new("base-clear");
    let gone = home.path("gone");
    let run = home.run(
        &home.dir,
        &[
            "base",
            "clear",
            "--json",
            "--project",
            &gone.to_string_lossy(),
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ProjectNotFound");
    assert_eq!(
        home.normalize(
            run.envelope()["error"]["message"]
                .as_str()
                .expect("message")
        ),
        "project is not registered: /Users/dev/gone"
    );
    assert!(!home.config_path().exists(), "a failed clear wrote config");

    let run = home.run(
        &home.dir,
        &[
            "base",
            "clear",
            "-p",
            "--json",
            "--project",
            &gone.to_string_lossy(),
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["base_branch"], "");
    let repo = home.repo("repo");
    let run = home.run(&repo, &["base", "set", "main", "--pretend", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"base_branch\":\"main\",\"cli_version\":\"dev\",\"command\":\"base\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1}\n"
    );
    assert!(!home.config_path().exists(), "--pretend wrote config");

    home.write_config(&format!(
        "{{\"{}\": {{\"base_branch\": \"dev\", \"vcs\": \"git\"}}}}",
        gone.display()
    ));
    let run = home.run(
        &home.dir,
        &[
            "base",
            "clear",
            "--json",
            "--project",
            &gone.to_string_lossy(),
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/gone\": {\n    \"vcs\": \"git\"\n  }\n}"
    );
}

// --- host ---

/// A project with one workroom, `w`, as config for the host tests.
fn host_fixture(home: &Home) -> PathBuf {
    let repo = home.repo("repo");
    home.write_config(&format!(
        "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{\"w\": {{\"path\": \"/remote/w\"}}}}}}}}",
        repo.display()
    ));
    repo
}

/// A descriptor is the app's, stored verbatim on the project or one of its workrooms: every key
/// kept, numbers exactly as written, strings re-escaped as Go writes config. `clear` removes it
/// and nothing else. The arguments are in the app's order (`WorkroomCLI.setHost`).
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn host_set_stores_the_descriptor_verbatim_and_clear_removes_it() {
    let home = Home::new("host-set");
    let repo = host_fixture(&home);
    let project = repo.to_string_lossy();
    let descriptor = "{\"driver\":\"boxd\",\"port\":12345678901234567890123,\"cost\":2.50,\
                      \"far\":1e999,\"note\":\"<&>\\u2028\",\"z\":{\"u\":[1,null,true]},\"z\":{\"k\":-0}}";
    let run = home.run(
        &home.dir,
        &[
            "host",
            "set",
            descriptor,
            "--json",
            "--project",
            &project,
            "--workroom",
            "w",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"cli_version\":\"dev\",\"command\":\"host\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1,\"workroom\":\"w\"}\n"
    );
    let run = home.run(
        &home.dir,
        &[
            "host",
            "set",
            "{\"base\": {\"id\": 7}}  \n",
            "--json",
            "--project",
            &project,
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"cli_version\":\"dev\",\"command\":\"host\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1,\"workroom\":\"\"}\n"
    );
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/repo\": {\n    \"host\": {\n      \"base\": {\n        \"id\": 7\n      }\n    },\n    \"vcs\": \"git\",\n    \"workrooms\": {\n      \"w\": {\n        \"host\": {\n          \"cost\": 2.50,\n          \"driver\": \"boxd\",\n          \"far\": 1e999,\n          \"note\": \"\\u003c\\u0026\\u003e\\u2028\",\n          \"port\": 12345678901234567890123,\n          \"z\": {\n            \"k\": -0\n          }\n        },\n        \"path\": \"/remote/w\"\n      }\n    }\n  }\n}"
    );

    let run = home.run(&repo, &["host", "clear", "--workroom", "w"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.stdout, "");
    let run = home.run(
        &home.dir,
        &["host", "clear", "--json", "--project", &project],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["workroom"], "");
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/repo\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {\n      \"w\": {\n        \"path\": \"/remote/w\"\n      }\n    }\n  }\n}"
    );
}

/// A descriptor must be one JSON object: `null` (which would clear it), any other value, more
/// than one value, and what isn't JSON are refused with `InvalidHostDescriptor`, exit 2, before
/// config or the project is looked at. A missing or extra argument is a usage error.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn host_set_refuses_what_isnt_one_json_object() {
    let home = Home::new("host-invalid");
    home.write_config("not json");
    let project = home.path("unregistered");
    for descriptor in [
        "null",
        "[]",
        "\"x\"",
        "1",
        "true",
        "",
        " ",
        "{} {}",
        "{}}",
        "{} x",
        "{\"a\":}",
        "{\"a\":1",
        "{\"a\":01}",
    ] {
        let run = home.run(
            &home.dir,
            &[
                "host",
                "set",
                descriptor,
                "--json",
                "--project",
                &project.to_string_lossy(),
            ],
        );
        run.assert_code(2).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InvalidHostDescriptor", "{descriptor:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["command"], "host", "{descriptor:?}");
        assert_eq!(
            envelope["error"]["message"],
            format!("a host descriptor must be a JSON object: {descriptor}")
        );
    }
    for (args, message) in [
        (
            &["host", "set", "--json"][..],
            "accepts 1 arg(s), received 0",
        ),
        (
            &["host", "set", "{}", "{}", "--json"],
            "accepts 1 arg(s), received 2",
        ),
        (
            &["host", "clear", "x", "--json"],
            "unknown command \"x\" for \"workroom host clear\"",
        ),
    ] {
        let run = home.run(&home.dir, args);
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError", "{args:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message, "{args:?}");
        assert_eq!(envelope.get("command"), None, "{args:?}");
    }
}

/// A descriptor is never a new entry: the project, and the workroom `--workroom` names, must be
/// registered, for `set` and `clear` alike, and `--pretend` checks that too, writing nothing. An
/// unreadable config fails.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn host_needs_a_registered_project_and_workroom() {
    let home = Home::new("host-missing");
    let repo = host_fixture(&home);
    let before = std::fs::read_to_string(home.config_path()).expect("read");
    let project = repo.to_string_lossy();
    let other = home.repo("other");
    let other = other.to_string_lossy();
    for pretend in [&[][..], &["--pretend"]] {
        for sub in [&["set", "{\"a\":1}"][..], &["clear"]] {
            let run = home.run(
                &home.dir,
                &[&["host"], sub, &["--json", "--project", &other], pretend].concat(),
            );
            run.assert_code(3).assert_quiet_stderr();
            assert_eq!(run.error_kind(), "ProjectNotFound", "{sub:?} {pretend:?}");
            assert_eq!(
                home.normalize(
                    run.envelope()["error"]["message"]
                        .as_str()
                        .expect("message")
                ),
                "project is not registered: /Users/dev/other"
            );
            let run = home.run(
                &home.dir,
                &[
                    &["host"],
                    sub,
                    &["--json", "--project", &project, "--workroom", "nope"],
                    pretend,
                ]
                .concat(),
            );
            run.assert_code(3).assert_quiet_stderr();
            assert_eq!(run.error_kind(), "WorkroomNotFound", "{sub:?} {pretend:?}");
            assert_eq!(
                home.normalize(
                    run.envelope()["error"]["message"]
                        .as_str()
                        .expect("message")
                ),
                "workroom is not registered: 'nope' in /Users/dev/repo"
            );
        }
    }
    let run = home.run(
        &home.dir,
        &[
            "host",
            "set",
            "{\"a\":1}",
            "-p",
            "--json",
            "--project",
            &project,
            "--workroom",
            "w",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["workroom"], "w");
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        before,
        "a refused or pretended host changed config"
    );

    home.write_config("[]");
    let run = home.run(&repo, &["host", "set", "{}", "--json"]);
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigReadFailed");
}

// --- add-project, delete-project and claim-provisioned (#672) ---
//
// The app's project commands, which it runs only with `--json`. Each test checks the envelope, the
// config the run leaves and what is on disk: a delete that drops the wrong entry, or a clone that
// leaves its staging behind, passes on the envelope alone.

/// The names in `dir`, sorted.
fn entries(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap_or_else(|error| panic!("read {}: {error}", dir.display()))
        .map(|entry| {
            entry
                .expect("entry")
                .file_name()
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    names.sort();
    names
}

/// config.json as the run left it, or "" when there is none.
fn config_text(home: &Home) -> String {
    std::fs::read_to_string(home.config_path()).unwrap_or_default()
}

/// What git prints for `args` in `dir`, which must succeed.
fn git_output(home: &Home, dir: &Path, args: &[&str]) -> String {
    let output = home
        .command("git", dir)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("UTF-8")
}

// --- add-project ---

/// The goldens Go's `TestContractAddProject` records: a repository registered, a folder that is
/// no repository refused, what a clone would do, and a full folder a clone refuses.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_json_matches_the_goldens() {
    let home = Home::new("add-project-goldens");
    let project = home.repo("src/app");
    let run = home.run(
        &home.dir,
        &["add-project", &project.to_string_lossy(), "--json"],
    );
    run.assert_code(0).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "add-project.json",
        &home.normalize(&normalize_version(&run.stdout)),
    );
    assert_eq!(
        home.normalize(&config_text(&home)),
        "{\n  \"/Users/dev/src/app\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );

    let plain = home.path("src/plain");
    std::fs::create_dir_all(&plain).expect("plain");
    let run = home.run(
        &home.dir,
        &["add-project", &plain.to_string_lossy(), "--json"],
    );
    run.assert_code(3).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "add-project-unsupported-vcs.json",
        &home.normalize(&normalize_version(&run.stdout)),
    );

    let origin = format!("file://{}", project.display());
    let api = home.path("src/api");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &api.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
            "--pretend",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "add-project-clone-pretend.json",
        &home.normalize(&normalize_version(&run.stdout)),
    );
    assert!(!api.exists(), "--pretend cloned");

    std::fs::write(plain.join("README"), "x").expect("README");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &plain.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "add-project-destination-not-empty.json",
        &home.normalize(&normalize_version(&run.stdout)),
    );
    assert_eq!(entries(&plain), ["README"]);
    // Only the first add registered anything.
    assert_eq!(
        home.normalize(&config_text(&home)),
        "{\n  \"/Users/dev/src/app\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );
}

/// A relative path is registered by its canonical form, an existing entry keeps its other keys,
/// and `--pretend` reports `would_create` without writing.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_registers_the_canonical_path_and_keeps_an_entry() {
    let home = Home::new("add-project-canonical");
    let project = home.repo("src/app");
    let key = project.to_string_lossy().into_owned();
    home.write_config(&format!(
        "{{\"{key}\": {{\"base_branch\": \"dev\", \"vcs\": \"jj\", \"workrooms\": {{\"w\": {{\"path\": \"/w\"}}}}}}, \"channel\": \"pre\"}}"
    ));
    let pretend = home.run(
        &home.dir,
        &["add-project", "src/app", "--json", "--pretend"],
    );
    pretend.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        home.normalize(&normalize_version(&pretend.stdout)),
        "{\"cli_version\":\"dev\",\"command\":\"add-project\",\"ok\":true,\"path\":\"/Users/dev/src/app\",\"schema_version\":1,\"vcs\":\"git\",\"would_create\":false}\n"
    );
    assert!(
        config_text(&home).starts_with("{\"/"),
        "--pretend wrote config"
    );

    let run = home.run(&home.dir, &["add-project", "src/app/", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["path"], key.as_str());
    assert_eq!(
        home.normalize(&config_text(&home)),
        "{\n  \"/Users/dev/src/app\": {\n    \"base_branch\": \"dev\",\n    \"vcs\": \"git\",\n    \"workrooms\": {\n      \"w\": {\n        \"path\": \"/w\"\n      }\n    }\n  },\n  \"channel\": \"pre\"\n}"
    );
}

/// `--create` makes a missing folder (and its parents) and git-initializes it with one empty
/// commit, initializes an empty folder (Finder's junk aside), registers a repository as it is,
/// and refuses a file or a folder with files in it, leaving that as it was.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_create_initializes_an_empty_or_missing_folder() {
    let home = Home::new("add-project-create");
    let fresh = home.path("src/deep/new");
    let fresh_arg = fresh.to_string_lossy().into_owned();

    let pretend = home.run(
        &home.dir,
        &["add-project", &fresh_arg, "--create", "--json", "--pretend"],
    );
    pretend.assert_code(0).assert_quiet_stderr();
    assert_eq!(pretend.envelope()["would_create"], true);
    assert_eq!(pretend.envelope()["vcs"], "git");
    assert!(!home.path("src").exists(), "--pretend made a folder");
    assert_eq!(config_text(&home), "");

    let run = home.run(
        &home.dir,
        &["add-project", &fresh_arg, "--create", "--json"],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        home.normalize(&normalize_version(&run.stdout)),
        "{\"cli_version\":\"dev\",\"command\":\"add-project\",\"ok\":true,\"path\":\"/Users/dev/src/deep/new\",\"schema_version\":1,\"vcs\":\"git\"}\n"
    );
    assert_eq!(entries(&fresh), [".git"]);
    assert_eq!(
        git_output(&home, &fresh, &["log", "--format=%s"]),
        "Initial commit\n"
    );

    let junk = home.path("src/junk");
    std::fs::create_dir_all(&junk).expect("junk");
    std::fs::write(junk.join(".DS_Store"), "x").expect("DS_Store");
    let run = home.run(
        &home.dir,
        &["add-project", &junk.to_string_lossy(), "--create", "--json"],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(entries(&junk), [".DS_Store", ".git"]);

    let repo = home.repo("src/repo");
    let pretend = home.run(
        &home.dir,
        &[
            "add-project",
            &repo.to_string_lossy(),
            "--create",
            "--json",
            "--pretend",
        ],
    );
    pretend.assert_code(0).assert_quiet_stderr();
    assert_eq!(pretend.envelope()["would_create"], false);
    let run = home.run(
        &home.dir,
        &["add-project", &repo.to_string_lossy(), "--create", "--json"],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        git_output(&home, &repo, &["log", "--format=%s"]),
        "first\n",
        "a repository is registered as it is"
    );

    let full = home.path("src/full");
    std::fs::create_dir_all(&full).expect("full");
    std::fs::write(full.join("notes"), "x").expect("notes");
    let run = home.run(
        &home.dir,
        &["add-project", &full.to_string_lossy(), "--create", "--json"],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "UnsupportedVCS");
    assert_eq!(entries(&full), ["notes"]);

    let file = home.path("src/file");
    std::fs::write(&file, "x").expect("file");
    for path in [file.clone(), file.join("child")] {
        let run = home.run(
            &home.dir,
            &["add-project", &path.to_string_lossy(), "--create", "--json"],
        );
        run.assert_code(3).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "NotADirectory");
        assert_eq!(
            run.envelope()["error"]["message"],
            "path exists but is not a directory"
        );
    }
    assert_eq!(std::fs::read_to_string(&file).expect("file"), "x");

    assert_eq!(
        home.normalize(&config_text(&home)),
        "{\n  \"/Users/dev/src/deep/new\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  },\n  \"/Users/dev/src/junk\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  },\n  \"/Users/dev/src/repo\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );
}

/// Each way the command refuses before it touches anything: without `--json`, without a path,
/// with two, with `--clone` and `--create` together, with a remote path, or with a config it can't
/// read.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_refuses_what_it_cant_register() {
    let home = Home::new("add-project-refusals");
    let project = home.repo("src/app");
    let project = project.to_string_lossy().into_owned();

    let plain = home.run(&home.dir, &["add-project", &project]);
    plain.assert_code(1);
    assert_eq!(plain.stdout, "");
    assert_eq!(
        plain.stderr,
        "Error: add-project is only available in --json mode\n"
    );

    for (args, code, kind, message, command) in [
        (
            &["add-project", "--json"][..],
            1,
            "InternalError",
            "a path argument is required".to_string(),
            true,
        ),
        (
            &["add-project", "a", "b", "--json"],
            1,
            "InternalError",
            "accepts at most 1 arg(s), received 2".to_string(),
            false,
        ),
        (
            &["add-project", "x", "--clone", "y", "--create", "--json"],
            1,
            "InternalError",
            "--clone and --create cannot be used together".to_string(),
            true,
        ),
        (
            &["add-project", "host:repo", "--json"],
            3,
            "RemoteProjectUnsupported",
            "remote projects are not supported: add the project from a local Git repository. A \
             remote workroom belongs to a local project: host:repo"
                .to_string(),
            true,
        ),
        (
            &[
                "add-project",
                "ssh://host/repo",
                "--clone",
                "file:///x",
                "--json",
            ],
            3,
            "RemoteProjectUnsupported",
            "remote projects are not supported: add the project from a local Git repository. A \
             remote workroom belongs to a local project: ssh://host/repo"
                .to_string(),
            true,
        ),
    ] {
        let run = home.run(&home.dir, args);
        run.assert_code(code).assert_quiet_stderr();
        assert_eq!(run.error_kind(), kind, "{args:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message.as_str(), "{args:?}");
        assert_eq!(
            envelope.get("command").is_some(),
            command,
            "{args:?}: {envelope}"
        );
    }
    assert_eq!(config_text(&home), "");

    home.write_config("{bad");
    let run = home.run(&home.dir, &["add-project", &project, "--json"]);
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigReadFailed");
    assert_eq!(config_text(&home), "{bad");
}

/// A real clone from a `file://` repository, into a missing folder and into an empty one: git's
/// progress streams as `clone` events, the clone is registered, and no staging is left beside or
/// inside it. A clone git refuses is `CloneFailed` and leaves nothing behind.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_clones_registers_and_cleans_up() {
    let home = Home::new("add-project-clone");
    let origin_repo = home.repo("origin/app");
    std::fs::write(origin_repo.join("README"), "hello\n").expect("README");
    home.git(&origin_repo, &["add", "README"]);
    home.git(
        &origin_repo,
        &["-c", "commit.gpgsign=false", "commit", "-q", "-m", "readme"],
    );
    let origin = format!("file://{}", origin_repo.display());
    std::fs::create_dir_all(home.path("src")).expect("src");

    let missing = home.path("src/deep/cloned");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &missing.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(0);
    assert_eq!(
        home.normalize(&normalize_version(&run.stdout)),
        "{\"cli_version\":\"dev\",\"command\":\"add-project\",\"ok\":true,\"path\":\"/Users/dev/src/deep/cloned\",\"schema_version\":1,\"vcs\":\"git\"}\n"
    );
    let events: Vec<serde_json::Value> = run
        .stderr
        .lines()
        .map(|line| serde_json::from_str(line).expect("NDJSON"))
        .collect();
    assert!(!events.is_empty(), "no clone progress");
    for event in &events {
        assert_eq!(event["type"], "log", "{event}");
        assert_eq!(event["phase"], "clone", "{event}");
    }
    assert!(
        events[0]["text"].as_str().is_some_and(
            |text| text.starts_with("Cloning into ") && text.contains("/.cloned.clone-")
        ),
        "{}",
        events[0]
    );
    assert_eq!(entries(&missing), [".git", "README"]);
    assert_eq!(entries(&home.path("src/deep")), ["cloned"]);
    assert_eq!(
        std::fs::read_to_string(missing.join("README")).expect("README"),
        "hello\n"
    );

    let empty = home.path("src/empty");
    std::fs::create_dir_all(&empty).expect("empty");
    std::fs::write(empty.join(".DS_Store"), "x").expect("DS_Store");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &empty.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(0);
    assert_eq!(run.envelope()["path"], empty.to_string_lossy().as_ref());
    assert_eq!(entries(&empty), [".git", "README"]);

    let before = entries(&home.path("src"));
    let nowhere = format!("file://{}", home.path("nothing").display());
    let failed = home.path("src/failed/deeper");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &failed.to_string_lossy(),
            "--clone",
            &nowhere,
            "--json",
        ],
    );
    run.assert_code(1);
    assert_eq!(run.error_kind(), "CloneFailed");
    let message = run.envelope()["error"]["message"]
        .as_str()
        .expect("message")
        .to_string();
    assert!(message.starts_with("git clone failed: "), "{message}");
    assert!(!message.contains("Cloning into"), "{message}");
    assert_eq!(
        entries(&home.path("src")),
        before,
        "the failed clone left something"
    );

    let failed_empty = home.path("src/failed-empty");
    std::fs::create_dir_all(&failed_empty).expect("failed-empty");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &failed_empty.to_string_lossy(),
            "--clone",
            &nowhere,
            "--json",
        ],
    );
    run.assert_code(1);
    assert_eq!(run.error_kind(), "CloneFailed");
    assert!(entries(&failed_empty).is_empty(), "its staging is left");

    let file = home.path("src/file");
    std::fs::write(&file, "x").expect("file");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &file.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "NotADirectory");

    assert_eq!(
        home.normalize(&config_text(&home)),
        "{\n  \"/Users/dev/src/deep/cloned\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  },\n  \"/Users/dev/src/empty\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );
}

/// A clone whose staging another clone left in the way: one with no owner in its name is never
/// removed, and is named in the refusal.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_names_staging_it_cannot_prove_dead() {
    let home = Home::new("add-project-clone-staging");
    let origin = format!("file://{}", home.repo("origin/app").display());
    let dest = home.path("src/app");
    std::fs::create_dir_all(dest.join(".clone-unowned")).expect("staging");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &dest.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "DestinationNotEmpty");
    assert_eq!(
        run.envelope()["error"]["message"],
        format!(
            "the destination folder is not empty: {} (a clone's staging is in the way: \
             .clone-unowned; remove it if no clone is running)",
            dest.display()
        )
    );
    assert_eq!(entries(&dest), [".clone-unowned"]);
}

/// Whether this process runs as root, whom a 0555 folder doesn't stop writing: a test that needs
/// a write to fail says so on stderr and skips that part (CI's Go job may run as root on Linux).
fn skip_as_root(test: &str) -> bool {
    // SAFETY: geteuid has no preconditions and can't fail.
    let root = unsafe { libc::geteuid() } == 0;
    if root {
        eprintln!("{test}: skipped as root, whom a read-only folder doesn't stop writing");
    }
    root
}

/// Runs the binary under test as [`Home::run`] does, with `env` added to its environment.
fn run_with_env(home: &Home, args: &[&str], env: &[(&str, &OsStr)]) -> Run {
    finish(args, spawn_with_env(home, args, env))
}

/// Starts the binary under test in `home` with `env` added, its stdout and stderr piped.
fn spawn_with_env(home: &Home, args: &[&str], env: &[(&str, &OsStr)]) -> std::process::Child {
    let mut command = home.command(binary(), &home.dir);
    command
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    for (key, value) in env {
        command.env(key, value);
    }
    command.spawn().expect("start the binary")
}

/// A run started by [`spawn_with_env`], once it has exited.
fn finish(args: &[&str], child: std::process::Child) -> Run {
    let output = child.wait_with_output().expect("wait for the binary");
    Run {
        args: args.join(" "),
        code: output
            .status
            .code()
            .expect("exited, not killed by a signal"),
        stdout: String::from_utf8(output.stdout).expect("stdout is UTF-8"),
        stderr: String::from_utf8(output.stderr).expect("stderr is UTF-8"),
    }
}

/// The `text` of each NDJSON log event on `stderr`, checking each is a `clone` event.
fn clone_log(stderr: &str) -> Vec<String> {
    stderr
        .lines()
        .map(|line| {
            let event: serde_json::Value = serde_json::from_str(line).expect("NDJSON");
            assert_eq!(event["type"], "log", "{event}");
            assert_eq!(event["phase"], "clone", "{event}");
            event["text"].as_str().expect("text").to_string()
        })
        .collect()
}

/// This machine's part of a clone's staging name, worked out here as Go's `machineHost` does it:
/// FNV-32a of the Mac's IOPlatformUUID, or of /etc/machine-id elsewhere, as 8 hex digits. None
/// when the machine has no id, where nothing is swept. A staging name the binary makes is checked
/// against it, so Go and Rust are held to the same id.
fn machine_host() -> Option<String> {
    let id = if cfg!(target_os = "macos") {
        let output = Command::new("/usr/sbin/ioreg")
            .args(["-rd1", "-c", "IOPlatformExpertDevice"])
            .output()
            .ok()?;
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| line.trim().split_once('='))
            .find(|(key, _)| key.trim() == "\"IOPlatformUUID\"")
            .map(|(_, value)| value.trim().trim_matches('"').to_string())?
    } else {
        ["/etc/machine-id", "/var/lib/dbus/machine-id"]
            .iter()
            .filter_map(|path| std::fs::read_to_string(path).ok())
            .map(|text| text.trim().to_string())
            .find(|id| !id.is_empty() && id != "uninitialized")?
    };
    if id.is_empty() {
        return None;
    }
    let mut hash: u32 = 0x811c_9dc5;
    for byte in id.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    Some(format!("{hash:08x}"))
}

/// [`machine_host`], or a note on stderr that the test is skipped without one.
fn machine_host_or_skip(test: &str) -> Option<String> {
    let host = machine_host();
    if host.is_none() {
        eprintln!("{test}: skipped: this machine has no machine id, so no staging is swept");
    }
    host
}

/// A pid no process has: a child's, once it has been reaped.
fn dead_pid() -> u32 {
    let mut child = Command::new("true").spawn().expect("run true");
    let pid = child.id();
    child.wait().expect("wait for true");
    pid
}

/// A staging folder as a clone leaves one, with a file in it.
fn make_staging(path: &Path) {
    std::fs::create_dir_all(path.join(".git")).expect("staging");
    std::fs::write(path.join(".git/HEAD"), "ref: refs/heads/main\n").expect("HEAD");
}

/// Takes `path`'s flock, as a clone's git holds its staging lock, until the file is dropped.
fn hold_lock(path: &Path) -> std::fs::File {
    use std::os::fd::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .expect("open lock");
    // SAFETY: a valid descriptor this owns.
    let locked = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(locked, 0, "take {}", path.display());
    file
}

/// Whether something holds `path`'s flock.
fn lock_is_held(path: &Path) -> bool {
    use std::os::fd::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .expect("open lock");
    // SAFETY: a valid descriptor this owns; closing it lets go of a lock taken here.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) != 0 }
}

/// An `ext::` transport that never answers: it writes its pid to the returned file, then hangs.
/// Local, with no network: git runs it in place of a remote.
fn hanging_transport(home: &Home) -> (String, PathBuf) {
    let pid_file = home.path("tools/helper.pid");
    write_file(
        &home.dir,
        "tools/hang.sh",
        &format!(
            "#!/bin/sh\necho $$ > {}\nexec sleep 30\n",
            pid_file.display()
        ),
        0o755,
    );
    (
        format!("ext::{}", home.path("tools/hang.sh").display()),
        pid_file,
    )
}

/// The pid the hanging transport wrote, once it has.
fn wait_for_pid(pid_file: &Path) -> i32 {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        if let Some(pid) = std::fs::read_to_string(pid_file)
            .ok()
            .and_then(|text| text.trim().parse().ok())
        {
            return pid;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the transport helper never started"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// Whether `pid` is a live process; a zombie counts as gone.
fn process_alive(pid: i32) -> bool {
    Command::new("ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .is_ok_and(|output| {
            output.status.success()
                && !String::from_utf8_lossy(&output.stdout)
                    .trim()
                    .starts_with('Z')
        })
}

/// Waits up to ten seconds for `done`.
fn eventually(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "{what}");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// SIGTERM, which is how the app's Cancel reaches the CLI, during a clone: git's process group
/// is ended (its transport helper too), the folders the run made are removed, nothing is
/// registered, and the run reports `Cancelled`.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_cancelled_by_a_signal_puts_everything_back() {
    let home = Home::new("add-project-clone-cancel");
    let (url, pid_file) = hanging_transport(&home);
    let dest = home.path("src/new/api");
    let dest_arg = dest.to_string_lossy().into_owned();
    let args = ["add-project", &dest_arg, "--clone", &url, "--json"];
    let child = spawn_with_env(&home, &args, &[("GIT_ALLOW_PROTOCOL", OsStr::new("ext"))]);
    let helper = wait_for_pid(&pid_file);
    // SAFETY: signals the binary under test, which this test started.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    let run = finish(&args, child);
    run.assert_code(4);
    assert_eq!(run.error_kind(), "Cancelled");
    assert_eq!(run.envelope()["error"]["message"], "operation cancelled");
    clone_log(&run.stderr);
    eventually("the transport helper outlived the cancel", || {
        !process_alive(helper)
    });
    assert!(
        !home.path("src").exists(),
        "the cancelled clone left its folders"
    );
    assert_eq!(config_text(&home), "");
}

/// A clone whose registration fails, here on a config it can't read, keeps the clone and reports
/// `ConfigWriteFailed`, saying where the clone is.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_keeps_a_clone_it_cannot_register() {
    let home = Home::new("add-project-clone-unregistered");
    let origin = format!("file://{}", home.repo("origin/app").display());
    let dest = home.path("src/api");
    home.write_config("{bad");
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &dest.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(6);
    assert_eq!(run.error_kind(), "ConfigWriteFailed");
    assert_eq!(
        home.normalize(
            run.envelope()["error"]["message"]
                .as_str()
                .expect("message")
        ),
        "failed to write config: the clone is at /Users/dev/src/api but could not be registered: \
         failed to read config /Users/dev/.config/workroom/config.json: invalid character 'b' \
         looking for beginning of object key string"
    );
    assert_eq!(entries(&dest), [".git"]);
    assert_eq!(entries(&home.path("src")), ["api"], "its staging is left");
    assert_eq!(config_text(&home), "{bad");
}

/// `--create` whose `git init` fails is `VCSCommandFailed`, naming the folder, and removes the
/// folder it made; a write to a config folder it can't write to is `ConfigWriteFailed`.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_reports_a_failed_git_init_and_an_unwritable_config() {
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new("add-project-failures");
    write_file(&home.dir, "tools/git", "#!/bin/sh\nexit 1\n", 0o755);
    let path = format!(
        "{}:{}",
        home.path("tools").display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let fresh = home.path("src/new");
    let fresh_arg = fresh.to_string_lossy().into_owned();
    let run = run_with_env(
        &home,
        &["add-project", &fresh_arg, "--create", "--json"],
        &[("PATH", OsStr::new(&path))],
    );
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "VCSCommandFailed");
    assert_eq!(
        run.envelope()["error"]["message"],
        format!("version control command failed: git init {fresh_arg}: exit status 1")
    );
    assert!(!fresh.exists(), "the folder it made is left");
    assert_eq!(config_text(&home), "");

    if skip_as_root("add_project_reports_a_failed_git_init_and_an_unwritable_config") {
        return;
    }
    let project = home.repo("src/app");
    home.write_config("{}");
    let config_dir = home.path(".config/workroom");
    std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o555)).expect("chmod");
    let run = home.run(
        &home.dir,
        &["add-project", &project.to_string_lossy(), "--json"],
    );
    std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigWriteFailed");
    let message = run.envelope()["error"]["message"].to_string();
    assert!(
        message.starts_with("\"failed to write config") && message.contains("permission denied"),
        "{message}"
    );
    assert_eq!(config_text(&home), "{}");
}

/// A dead clone's staging, inside the destination and beside it, is swept before the clone, each
/// named on the log first: one with no lock whose pid is gone, one whose lock is free whatever its
/// pid, and an orphan lock file that is free. The clone then goes ahead.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_sweeps_a_dead_clones_staging() {
    let Some(host) = machine_host_or_skip("add_project_clone_sweeps_a_dead_clones_staging") else {
        return;
    };
    let home = Home::new("add-project-clone-sweep");
    let origin = format!("file://{}", home.repo("origin/app").display());
    let src = home.path("src");
    let dest = src.join("app");
    let me = std::process::id();
    let mut inside = vec![
        format!(".clone-{host}-{}-a1", dead_pid()),
        format!(".clone-{host}-{me}-b2"),
    ];
    for name in &inside {
        make_staging(&dest.join(name));
    }
    std::fs::write(dest.join(format!("{}.lock", inside[1])), "").expect("free lock");
    let beside_dir = format!(".app.clone-{host}-{}-c3", dead_pid());
    make_staging(&src.join(&beside_dir));
    let orphan = format!(".app.clone-{host}-{}-d4.lock", dead_pid());
    std::fs::write(src.join(&orphan), "").expect("orphan lock");
    inside.sort();
    let mut beside = vec![beside_dir, orphan];
    beside.sort();

    // --pretend looks past them, as the clone will, and leaves every one in place.
    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &dest.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
            "--pretend",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["would_clone"], true);
    let mut left = inside.clone();
    let locked = inside
        .iter()
        .find(|name| name.ends_with("-b2"))
        .expect("b2");
    left.push(format!("{locked}.lock"));
    left.sort();
    assert_eq!(entries(&dest), left);
    let mut around = beside.clone();
    around.push("app".to_string());
    around.sort();
    assert_eq!(entries(&src), around);

    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &dest.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(0);
    let log = clone_log(&run.stderr);
    let removed: Vec<String> = inside
        .iter()
        .chain(&beside)
        .map(|name| format!("Removing staging a crashed clone left: {name}"))
        .collect();
    assert_eq!(log[..removed.len()], removed[..], "{log:?}");
    assert!(
        log[removed.len()].starts_with(&format!("Cloning into '{}/.clone-{host}-", dest.display())),
        "{log:?}"
    );
    assert_eq!(entries(&dest), [".git"]);
    assert_eq!(entries(&src), ["app"]);
    assert_eq!(run.envelope()["path"], dest.to_string_lossy().as_ref());
}

/// What the sweep can't prove dead survives it and is named in the refusal: staging whose lock
/// a live process holds (git, after the CLI that started it died), another machine's, and one
/// with no lock whose process is running.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_keeps_staging_a_live_owner_or_another_machine_has() {
    let Some(host) =
        machine_host_or_skip("add_project_clone_keeps_staging_a_live_owner_or_another_machine_has")
    else {
        return;
    };
    let home = Home::new("add-project-clone-live");
    let origin = format!("file://{}", home.repo("origin/app").display());
    let dest = home.path("src/app");
    let other_host = if host == "0badf00d" {
        "0badf00e"
    } else {
        "0badf00d"
    };
    let held = format!(".clone-{host}-{}-held", dead_pid());
    let names = [
        held.clone(),
        format!(".clone-{other_host}-{}-x", dead_pid()),
        format!(".clone-{host}-{}-nolock", std::process::id()),
    ];
    for name in &names {
        make_staging(&dest.join(name));
    }
    let _lock = hold_lock(&dest.join(format!("{held}.lock")));
    let mut expected: Vec<String> = names.to_vec();
    expected.push(format!("{held}.lock"));
    expected.sort();

    let run = home.run(
        &home.dir,
        &[
            "add-project",
            &dest.to_string_lossy(),
            "--clone",
            &origin,
            "--json",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "DestinationNotEmpty");
    assert_eq!(
        run.envelope()["error"]["message"],
        format!(
            "the destination folder is not empty: {} (a clone's staging is in the way: {}; remove \
             it if no clone is running)",
            dest.display(),
            expected.join(", ")
        )
    );
    assert_eq!(entries(&dest), expected);
    for name in &names {
        assert!(
            dest.join(name).join(".git/HEAD").exists(),
            "{name} was emptied"
        );
    }
    assert_eq!(config_text(&home), "");
}

/// A clone whose CLI is SIGKILLed while git runs: git still holds the staging's lock it
/// inherited, so a second clone refuses and names the staging, which is this machine's and this
/// CLI's by its name. Once git is gone the lock is free, and a third clone sweeps it and clones.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn add_project_clone_keeps_a_killed_clis_staging_until_its_git_is_gone() {
    let Some(host) =
        machine_host_or_skip("add_project_clone_keeps_a_killed_clis_staging_until_its_git_is_gone")
    else {
        return;
    };
    let home = Home::new("add-project-clone-killed");
    let (url, pid_file) = hanging_transport(&home);
    let origin = format!("file://{}", home.repo("origin/app").display());
    let dest = home.path("src/app");
    std::fs::create_dir_all(&dest).expect("dest");
    let dest_arg = dest.to_string_lossy().into_owned();
    let args = ["add-project", &dest_arg, "--clone", &url, "--json"];
    let mut child = Reaped(spawn_with_env(
        &home,
        &args,
        &[("GIT_ALLOW_PROTOCOL", OsStr::new("ext"))],
    ));
    let mut helper = Helper(Some(wait_for_pid(&pid_file)));
    let cli = child.0.id();
    child.0.kill().expect("SIGKILL the CLI");
    child.0.wait().expect("reap the CLI");

    let staging = entries(&dest);
    assert_eq!(staging.len(), 2, "{staging:?}");
    assert!(
        staging[0].starts_with(&format!(".clone-{host}-{cli}-")),
        "{staging:?} isn't named for host {host} and pid {cli}"
    );
    assert_eq!(staging[1], format!("{}.lock", staging[0]));
    assert!(
        lock_is_held(&dest.join(&staging[1])),
        "git let go of the lock"
    );

    let clone = ["add-project", &dest_arg, "--clone", &origin, "--json"];
    let run = home.run(&home.dir, &clone);
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "DestinationNotEmpty");
    assert_eq!(
        run.envelope()["error"]["message"],
        format!(
            "the destination folder is not empty: {dest_arg} (a clone's staging is in the way: \
             {}; remove it if no clone is running)",
            staging.join(", ")
        )
    );
    assert_eq!(entries(&dest), staging);

    helper.kill();
    eventually("git kept the lock after its transport died", || {
        !lock_is_held(&dest.join(&staging[1]))
    });
    let run = home.run(&home.dir, &clone);
    run.assert_code(0);
    let log = clone_log(&run.stderr);
    assert_eq!(
        log[0],
        format!("Removing staging a crashed clone left: {}", staging[0])
    );
    assert_eq!(entries(&dest), [".git"]);
}

/// A spawned CLI, killed and reaped when it goes out of scope, so a failed assertion leaves no
/// process behind. Once reaped, `kill` signals nothing, so no reused pid is hit.
struct Reaped(std::process::Child);

impl Drop for Reaped {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The hanging transport helper's pid, SIGKILLed by [`Helper::kill`] or, when an assertion fails
/// first, on drop, so no `sleep 30` (and the git waiting on it) outlives the test. Killed once:
/// a second signal could hit a reused pid.
struct Helper(Option<i32>);

impl Helper {
    fn kill(&mut self) {
        if let Some(pid) = self.0.take() {
            // SAFETY: `kill(2)` takes no pointers; the pid is the transport helper this test's
            // script started, not yet signalled.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        self.kill();
    }
}

// --- delete-project ---

/// The digest of the teardown script `project_with_workroom` writes, as `workroom trust` records
/// it.
const STOPPING_SHA256: &str = "46afe9251fa214a976ea23e0094166dceb1f79f39ef879bd4cc3d59b26808059";

/// Go's `projectWithWorkroom`: a registered project with one real workroom, `calm-river`, whose
/// approved teardown script prints a line. Returns the project.
fn project_with_workroom(home: &Home, teardown: &str, digest: &str) -> PathBuf {
    let project = home.repo("src/app");
    let path = home.path("workrooms/calm-river");
    home.git(
        &project,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "workroom/calm-river",
            &path.to_string_lossy(),
        ],
    );
    write_file(
        &project,
        "scripts/workroom_teardown",
        &format!("#!/bin/sh\n{teardown}"),
        0o755,
    );
    home.write_config(&format!(
        "{{\"{project}\": {{\"trusted_scripts\": {{\"workroom_teardown\": \"{digest}\"}}, \"vcs\": \"git\", \"workrooms\": {{\"calm-river\": {{\"path\": \"{path}\"}}}}}}}}",
        project = project.display(),
        path = path.display(),
    ));
    project
}

/// The goldens Go's `TestContractDeleteProject` records, mode by mode, with what each leaves on
/// disk: the config-only mode and `--from-disk` remove no folder (the app trashes the paths it is
/// given), and `--with-workrooms` removes the worktree but keeps its branch.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_json_matches_the_goldens() {
    for (file, flags) in [
        ("delete-project.json", &[][..]),
        ("delete-project-with-workrooms.json", &["--with-workrooms"]),
        ("delete-project-from-disk.json", &["--from-disk"]),
    ] {
        let home = Home::new("delete-project-goldens");
        let project = project_with_workroom(&home, "echo stopping\n", STOPPING_SHA256);
        let project_arg = project.to_string_lossy().into_owned();
        let mut args = vec![
            "delete-project",
            &project_arg,
            "--json",
            "--confirm",
            &project_arg,
        ];
        args.extend_from_slice(flags);
        let run = home.run(&home.dir, &args);
        run.assert_code(0);
        check_golden(
            Owner::GoContractTests,
            file,
            &home.normalize(&normalize_version(&run.stdout)),
        );
        check_golden(
            Owner::GoContractTests,
            &file.replace(".json", "-events.ndjson"),
            &home.normalize(&run.stderr),
        );
        assert_eq!(config_text(&home), "{}", "{flags:?}");
        assert!(project.join("scripts").exists(), "{flags:?}");
        let worktree = home.path("workrooms/calm-river");
        assert_eq!(
            worktree.exists(),
            flags != ["--with-workrooms"],
            "{flags:?}"
        );
        assert_eq!(
            git_output(&home, &project, &["branch", "--format=%(refname:short)"]),
            "main\nworkroom/calm-river\n",
            "{flags:?}"
        );
    }
}

/// `--pretend` skips only the teardown and the worktree's removal: each mode still drops the
/// project from config, as Go's `delete-project` does.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_pretend_still_drops_the_project_as_go_does() {
    for flags in [&[][..], &["--with-workrooms"], &["--from-disk"]] {
        let home = Home::new("delete-project-pretend");
        let project = project_with_workroom(&home, "echo stopping\n", STOPPING_SHA256);
        let project_arg = project.to_string_lossy().into_owned();
        let mut args = vec![
            "delete-project",
            &project_arg,
            "--json",
            "--confirm",
            &project_arg,
            "--pretend",
        ];
        args.extend_from_slice(flags);
        let run = home.run(&home.dir, &args);
        run.assert_code(0).assert_quiet_stderr();
        assert_eq!(run.envelope()["ok"], true);
        assert_eq!(config_text(&home), "{}", "{flags:?}");
        assert!(home.path("workrooms/calm-river").exists(), "{flags:?}");
    }
}

/// A relative path and its `--confirm` resolve to the canonical project, and a project whose
/// folder is gone is still removable: only its entry goes, the rest of the config stays.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_removes_only_the_entry_by_either_form_of_its_path() {
    let home = Home::new("delete-project-forms");
    let project = home.repo("src/app");
    let gone = home.path("src/gone");
    home.write_config(&format!(
        "{{\"channel\": \"pre\", \"{}\": {{\"vcs\": \"git\", \"workrooms\": {{}}}}, \"{}\": {{\"vcs\": \"git\", \"workrooms\": {{\"w\": {{\"path\": \"/nowhere/w\"}}}}}}}}",
        project.display(),
        gone.display()
    ));
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            "src/app",
            "--json",
            "--confirm",
            "src/app",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        home.normalize(&normalize_version(&run.stdout)),
        "{\"cli_version\":\"dev\",\"command\":\"delete-project\",\"ok\":true,\"path\":\"/Users/dev/src/app\",\"schema_version\":1,\"with_workrooms\":false}\n"
    );
    let gone_arg = gone.to_string_lossy().into_owned();
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            "src/gone",
            "--json",
            "--confirm",
            &gone_arg,
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(config_text(&home), "{\n  \"channel\": \"pre\"\n}");
    assert!(project.exists());
}

/// Each refusal before anything is torn down, with the config left as it was: no `--json`, no
/// path or two, a `--confirm` that doesn't match, a project with a remote workroom or its own
/// host, and an unsafe path for `--from-disk` (the root, HOME, the workrooms folder, an ancestor
/// of it or of another project).
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_refuses_before_tearing_anything_down() {
    let home = Home::new("delete-project-refusals");
    let project = project_with_workroom(&home, "echo stopping\n", STOPPING_SHA256);
    let project_arg = project.to_string_lossy().into_owned();
    let remote = home.path("src/remote");
    let based = home.path("src/based");
    let config = format!(
        "{{\"{project}\": {{\"trusted_scripts\": {{\"workroom_teardown\": \"{STOPPING_SHA256}\"}}, \"vcs\": \"git\", \"workrooms\": {{\"calm-river\": {{\"path\": \"{path}\"}}}}}}, \"{remote}\": {{\"vcs\": \"git\", \"workrooms\": {{\"r\": {{\"host\": {{\"driver\": \"boxd\"}}, \"path\": \"/home/r\"}}, \"s\": {{\"host\": {{\"state\": \"destroyed\"}}, \"path\": \"/home/s\"}}}}}}, \"{based}\": {{\"host\": {{\"id\": \"B1\"}}, \"vcs\": \"git\", \"workrooms\": {{}}}}}}",
        project = project.display(),
        path = home.path("workrooms/calm-river").display(),
        remote = remote.display(),
        based = based.display(),
    );
    home.write_config(&config);

    let plain = home.run(&home.dir, &["delete-project", &project_arg]);
    plain.assert_code(1);
    assert_eq!(plain.stdout, "");
    assert_eq!(
        plain.stderr,
        "Error: delete-project is only available in --json mode\n"
    );

    let mismatch = "confirmation value does not match the workroom name: --confirm <path> is \
                    required and must match the project path";
    let remote_arg = remote.to_string_lossy().into_owned();
    let based_arg = based.to_string_lossy().into_owned();
    let home_arg = home.dir.to_string_lossy().into_owned();
    let src_arg = home.path("src").to_string_lossy().into_owned();
    let workrooms_arg = home.path("workrooms").to_string_lossy().into_owned();
    let unsafe_path = |path: &str| {
        format!("refusing to delete an unsafe or reserved path: refusing to delete {path:?}")
    };
    for (args, code, kind, message, command) in [
        (
            vec!["delete-project", "--json"],
            1,
            "InternalError",
            "a path argument is required".to_string(),
            true,
        ),
        (
            vec!["delete-project", &project_arg, "x", "--json"],
            1,
            "InternalError",
            "accepts at most 1 arg(s), received 2".to_string(),
            false,
        ),
        (
            vec!["delete-project", &project_arg, "--json"],
            2,
            "ConfirmationMismatch",
            mismatch.to_string(),
            true,
        ),
        (
            vec![
                "delete-project",
                &project_arg,
                "--json",
                "--confirm",
                "nope",
                "--with-workrooms",
            ],
            2,
            "ConfirmationMismatch",
            mismatch.to_string(),
            true,
        ),
        (
            vec![
                "delete-project",
                &remote_arg,
                "--json",
                "--confirm",
                &remote_arg,
            ],
            3,
            "RemoteWorkroomUnsupported",
            format!(
                "not supported for a remote workroom yet: {remote_arg} has remote workrooms: r, s"
            ),
            true,
        ),
        (
            vec![
                "delete-project",
                &based_arg,
                "--json",
                "--confirm",
                &based_arg,
                "--from-disk",
            ],
            3,
            "RemoteWorkroomUnsupported",
            format!(
                "not supported for a remote workroom yet: {based_arg} has a remote host (its base machine)"
            ),
            true,
        ),
        (
            vec![
                "delete-project",
                "/",
                "--json",
                "--confirm",
                "/",
                "--from-disk",
            ],
            2,
            "UnsafeDeletePath",
            unsafe_path("/"),
            true,
        ),
        (
            vec![
                "delete-project",
                &home_arg,
                "--json",
                "--confirm",
                &home_arg,
                "--from-disk",
            ],
            2,
            "UnsafeDeletePath",
            unsafe_path(&home_arg),
            true,
        ),
        (
            vec![
                "delete-project",
                &src_arg,
                "--json",
                "--confirm",
                &src_arg,
                "--from-disk",
            ],
            2,
            "UnsafeDeletePath",
            unsafe_path(&src_arg),
            true,
        ),
        (
            vec![
                "delete-project",
                &workrooms_arg,
                "--json",
                "--confirm",
                &workrooms_arg,
                "--from-disk",
            ],
            2,
            "UnsafeDeletePath",
            unsafe_path(&workrooms_arg),
            true,
        ),
    ] {
        let run = home.run(&home.dir, &args);
        run.assert_code(code).assert_quiet_stderr();
        assert_eq!(run.error_kind(), kind, "{args:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message.as_str(), "{args:?}");
        assert_eq!(
            envelope.get("command").is_some(),
            command,
            "{args:?}: {envelope}"
        );
        assert_eq!(config_text(&home), config, "{args:?}");
    }
    assert!(home.path("workrooms/calm-river").exists());
}

/// A teardown that fails stops the cascade with `TeardownScriptFailed`, its output streamed first,
/// and leaves the project and its workroom registered and in place, in either mode.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_keeps_the_project_when_a_teardown_fails() {
    for flag in ["--with-workrooms", "--from-disk"] {
        let home = Home::new("delete-project-teardown-fails");
        let project = project_with_workroom(
            &home,
            "echo failing\nexit 3\n",
            "6c0b3283060e825e71a20b65542912cc472c2589a65612149764cc58e7d66afc",
        );
        let before = config_text(&home);
        let project_arg = project.to_string_lossy().into_owned();
        let run = home.run(
            &home.dir,
            &[
                "delete-project",
                &project_arg,
                "--json",
                "--confirm",
                &project_arg,
                flag,
            ],
        );
        run.assert_code(5);
        assert_eq!(
            run.stderr, "{\"type\":\"log\",\"phase\":\"teardown\",\"text\":\"failing\"}\n",
            "{flag}"
        );
        assert_eq!(run.error_kind(), "TeardownScriptFailed", "{flag}");
        assert_eq!(
            run.envelope()["error"]["message"],
            format!(
                "teardown script failed: {}/scripts/workroom_teardown returned a non-zero exit code",
                project.display()
            )
        );
        assert_eq!(config_text(&home), before, "{flag}");
        assert!(home.path("workrooms/calm-river").exists(), "{flag}");
    }
}

/// A teardown script this Mac hasn't approved is refused with the script in the envelope, as the
/// app reads it to ask, and nothing is torn down; `--skip-teardown` runs none and goes ahead.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_refuses_an_unapproved_teardown_unless_skipped() {
    for flag in ["--with-workrooms", "--from-disk"] {
        let home = Home::new("delete-project-untrusted");
        let project = project_with_workroom(&home, "echo hi\n", "deadbeef");
        let before = config_text(&home);
        let project_arg = project.to_string_lossy().into_owned();
        let run = home.run(
            &home.dir,
            &[
                "delete-project",
                &project_arg,
                "--json",
                "--confirm",
                &project_arg,
                flag,
            ],
        );
        run.assert_code(3).assert_quiet_stderr();
        assert_eq!(
            normalize_version(&run.stdout),
            "{\"cli_version\":\"dev\",\"command\":\"delete-project\",\"error\":{\"kind\":\"ScriptNotTrusted\",\"message\":\"script is not trusted on this Mac: scripts/workroom_teardown in the project's root is new, or changed since it was approved. Review and approve it with `workroom trust`\"},\"ok\":false,\"schema_version\":1,\"script\":{\"bytes\":\"IyEvYmluL3NoCmVjaG8gaGkK\",\"exempt\":false,\"file\":\"scripts/workroom_teardown\",\"name\":\"workroom_teardown\",\"origin\":\"root\",\"sha256\":\"299001868fb8c02fd431c336c6d058f5558c5dff5b5af5e6fe04b870a6a9cbba\",\"text\":\"#!/bin/sh\\necho hi\\n\",\"trusted\":false}}\n",
            "{flag}"
        );
        assert_eq!(config_text(&home), before, "{flag}");
        assert!(home.path("workrooms/calm-river").exists(), "{flag}");

        let run = home.run(
            &home.dir,
            &[
                "delete-project",
                &project_arg,
                "--json",
                "--confirm",
                &project_arg,
                flag,
                "--skip-teardown",
            ],
        );
        run.assert_code(0).assert_quiet_stderr();
        assert_eq!(config_text(&home), "{}", "{flag}");
        assert_eq!(
            home.path("workrooms/calm-river").exists(),
            flag == "--from-disk",
            "{flag}"
        );
    }
}

/// A workroom's own copy of the teardown script is the one that runs, judged as the workroom's;
/// a gitignored root copy needs no approval.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_judges_the_workrooms_copy_and_exempts_an_ignored_root_copy() {
    let home = Home::new("delete-project-script-origin");
    let project = project_with_workroom(&home, "echo stopping\n", "deadbeef");
    let worktree = home.path("workrooms/calm-river");
    write_file(
        &worktree,
        "scripts/workroom_teardown",
        "#!/bin/sh\necho mine\n",
        0o755,
    );
    let project_arg = project.to_string_lossy().into_owned();
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            &project_arg,
            "--json",
            "--confirm",
            &project_arg,
            "--with-workrooms",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    let envelope = run.envelope();
    assert_eq!(envelope["script"]["origin"], "workroom");
    assert_eq!(envelope["script"]["text"], "#!/bin/sh\necho mine\n");
    assert_eq!(
        envelope["error"]["message"],
        "script is not trusted on this Mac: scripts/workroom_teardown in the workroom is new, or \
         changed since it was approved. Run the same command in a terminal to review and approve it"
    );

    std::fs::remove_file(worktree.join("scripts/workroom_teardown")).expect("remove copy");
    std::fs::write(project.join(".gitignore"), "scripts/\n").expect("gitignore");
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            &project_arg,
            "--json",
            "--confirm",
            &project_arg,
            "--with-workrooms",
        ],
    );
    run.assert_code(0);
    assert_eq!(
        run.stderr,
        "{\"type\":\"log\",\"phase\":\"teardown\",\"text\":\"stopping\"}\n"
    );
    assert!(!worktree.exists());
}

/// The teardown a delete would run is judged as `trust` judges it: a gitignored root copy that is
/// a symlink is not exempt, a link to a device (/dev/zero) is refused unread, and a workroom's
/// copy over the 1 MiB a script may be is refused. Nothing is torn down.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_refuses_a_linked_device_or_oversize_teardown() {
    let home = Home::new("delete-project-unjudged");
    let project = project_with_workroom(&home, "echo hi\n", "deadbeef");
    let worktree = home.path("workrooms/calm-river");
    let before = config_text(&home);
    let project_arg = project.to_string_lossy().into_owned();
    let delete = || {
        let run = home.run(
            &home.dir,
            &[
                "delete-project",
                &project_arg,
                "--json",
                "--confirm",
                &project_arg,
                "--with-workrooms",
            ],
        );
        run.assert_code(3).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "ScriptNotTrusted");
        assert_eq!(config_text(&home), before);
        assert!(worktree.exists());
        run.envelope()
    };
    let teardown = project.join("scripts/workroom_teardown");
    std::fs::rename(&teardown, project.join("scripts/real.sh")).expect("move teardown");
    std::os::unix::fs::symlink("real.sh", &teardown).expect("link");
    std::fs::write(project.join(".gitignore"), "scripts/workroom_teardown\n").expect("gitignore");
    let envelope = delete();
    assert_eq!(envelope["script"]["origin"], "root", "{envelope}");
    assert_eq!(envelope["script"]["exempt"], false);
    assert_eq!(envelope["script"]["text"], "#!/bin/sh\necho hi\n");

    std::fs::remove_file(&teardown).expect("remove link");
    std::os::unix::fs::symlink("/dev/zero", &teardown).expect("link");
    let envelope = delete();
    assert_eq!(
        home.normalize(envelope["error"]["message"].as_str().expect("message")),
        "script is not trusted on this Mac: /Users/dev/src/app/scripts/workroom_teardown is not a \
         regular file"
    );
    assert_eq!(envelope.get("script"), None, "{envelope}");

    write_file(
        &worktree,
        "scripts/workroom_teardown",
        &"#".repeat((1 << 20) + 1),
        0o755,
    );
    let envelope = delete();
    assert_eq!(
        home.normalize(envelope["error"]["message"].as_str().expect("message")),
        "script is not trusted on this Mac: /Users/dev/workrooms/calm-river/scripts/\
         workroom_teardown is larger than 1048576 bytes"
    );
}

/// `--with-workrooms` deletes each workroom as `delete` does: one whose folder holds no git
/// checkout is only forgotten, its folder left; a name `delete` refuses stops it with the project
/// kept.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_with_workrooms_deletes_each_as_delete_does() {
    let home = Home::new("delete-project-cascade");
    let project = home.repo("src/app");
    let real = home.path("workrooms/calm-river");
    home.git(
        &project,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "workroom/calm-river",
            &real.to_string_lossy(),
        ],
    );
    let orphan = home.path("elsewhere/orphan");
    std::fs::create_dir_all(&orphan).expect("orphan");
    std::fs::write(orphan.join("notes"), "keep").expect("notes");
    let config = |extra: &str| {
        format!(
            "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{\"calm-river\": {{\"path\": \"{}\"}}, \"orphan\": {{\"path\": \"{}\"}}{extra}}}}}}}",
            project.display(),
            real.display(),
            orphan.display()
        )
    };
    home.write_config(&config(", \"bad name\": {\"path\": \"/x\"}"));
    let project_arg = project.to_string_lossy().into_owned();
    let args = [
        "delete-project",
        &project_arg,
        "--json",
        "--confirm",
        &project_arg,
        "--with-workrooms",
    ];
    let run = home.run(&home.dir, &args);
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InvalidName");
    assert_eq!(
        run.envelope()["error"]["message"],
        "workroom name must be alphanumeric (dashes and underscores allowed), and must not start \
         or end with a dash or underscore: \"bad name\""
    );
    assert_eq!(
        config_text(&home),
        config(", \"bad name\": {\"path\": \"/x\"}")
    );

    home.write_config(&config(""));
    let run = home.run(&home.dir, &args);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(config_text(&home), "{}");
    assert!(!real.exists());
    assert_eq!(entries(&orphan), ["notes"]);

    // A project that is itself a workroom is refused, as `delete` refuses it.
    let inner = home.repo("src/inner");
    std::fs::write(inner.join(".Workroom"), "").expect(".Workroom");
    let inner_arg = inner.to_string_lossy().into_owned();
    let inner_config = format!(
        "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{\"w\": {{\"path\": \"/x/w\"}}}}}}}}",
        inner.display()
    );
    home.write_config(&inner_config);
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            &inner_arg,
            "--json",
            "--confirm",
            &inner_arg,
            "--with-workrooms",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InWorkroom");
    assert_eq!(config_text(&home), inner_config);

    // A project folder that is no repository can't have its worktrees removed.
    let plain = home.path("src/plain");
    std::fs::create_dir_all(&plain).expect("plain");
    let plain_arg = plain.to_string_lossy().into_owned();
    let plain_config = format!(
        "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{\"w\": {{\"path\": \"/x/w\"}}}}}}}}",
        plain.display()
    );
    home.write_config(&plain_config);
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            &plain_arg,
            "--json",
            "--confirm",
            &plain_arg,
            "--with-workrooms",
        ],
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "UnsupportedVCS");
    assert_eq!(config_text(&home), plain_config);
}

/// A config that can't be read fails the command and is left as it was.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_reports_an_unreadable_config() {
    let home = Home::new("delete-project-bad-config");
    let project = home.repo("src/app");
    home.write_config("{bad");
    let project_arg = project.to_string_lossy().into_owned();
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            &project_arg,
            "--json",
            "--confirm",
            &project_arg,
        ],
    );
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigReadFailed");
    assert_eq!(config_text(&home), "{bad");
}

/// `--with-workrooms` stops at a workroom git has no worktree for (`WorkspaceNotFound`) and at one
/// git won't remove (`VCSCommandFailed`, here a locked worktree), keeping the project registered
/// for a retry; a config folder it can't write to is `ConfigWriteFailed`.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn delete_project_reports_a_missing_worktree_a_failed_git_and_an_unwritable_config() {
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new("delete-project-failures");
    let project = home.repo("src/app");
    let project_arg = project.to_string_lossy().into_owned();
    let delete = [
        "delete-project",
        &project_arg,
        "--json",
        "--confirm",
        &project_arg,
        "--with-workrooms",
    ];
    let ghost =
        format!("{{\"{project_arg}\": {{\"vcs\": \"git\", \"workrooms\": {{\"ghost\": {{}}}}}}}}");
    home.write_config(&ghost);
    let run = home.run(&home.dir, &delete);
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "WorkspaceNotFound");
    assert_eq!(
        run.envelope()["error"]["message"],
        "git worktree does not exist: Git worktree 'ghost' does not exist"
    );
    assert_eq!(config_text(&home), ghost);

    let home = Home::new("delete-project-failures");
    let project = project_with_workroom(&home, "echo stopping\n", STOPPING_SHA256);
    let project_arg = project.to_string_lossy().into_owned();
    let worktree = home.path("workrooms/calm-river");
    home.git(&project, &["worktree", "lock", &worktree.to_string_lossy()]);
    let before = config_text(&home);
    let delete = [
        "delete-project",
        &project_arg,
        "--json",
        "--confirm",
        &project_arg,
        "--with-workrooms",
        "--skip-teardown",
    ];
    let run = home.run(&home.dir, &delete);
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "VCSCommandFailed");
    assert_eq!(
        run.envelope()["error"]["message"],
        "version control command failed: exit status 128"
    );
    assert!(worktree.join(".git").exists(), "the locked worktree went");
    assert_eq!(config_text(&home), before);

    if skip_as_root(
        "delete_project_reports_a_missing_worktree_a_failed_git_and_an_unwritable_config",
    ) {
        return;
    }
    let config_dir = home.path(".config/workroom");
    std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o555)).expect("chmod");
    let run = home.run(
        &home.dir,
        &[
            "delete-project",
            &project_arg,
            "--json",
            "--confirm",
            &project_arg,
        ],
    );
    std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigWriteFailed");
    let message = run.envelope()["error"]["message"].to_string();
    assert!(
        message.starts_with("\"failed to write config") && message.contains("permission denied"),
        "{message}"
    );
    assert_eq!(config_text(&home), before);
}

// --- claim-provisioned ---

/// What another build's config holds: the `dev` build made the project host of `/p/a` (in the
/// shape before a project had several bases), one of its workrooms, two of `/p/b`'s bases and the
/// workroom `/p/c` already has one of under that name.
const CLAIM_SHARED: &str = r#"{"workrooms_dir": "/w", "channel": "pre",
 "/p/a": {"vcs": "git", "host": {"provisioner": "dev", "id": "B1", "driver": "boxd"},
   "workrooms": {"r1": {"path": "/home/r1", "host": {"provisioner": "dev", "n": 1.50}},
                 "r2": {"path": "/home/r2", "host": {"provisioner": "rel"}},
                 "loc": {"path": "/x/loc"}}},
 "/p/b": {"vcs": "git", "host": {"bases": [{"provisioner": "dev", "id": "B2"}, {"provisioner": "rel", "id": "B3"}, {"provisioner": "dev", "x": 1}]},
   "workrooms": {}},
 "/p/c": {"vcs": "git", "workrooms": {"same": {"path": "/home/same", "host": {"provisioner": "dev"}}}}
}"#;

/// This build's config before the claim.
const CLAIM_MINE: &str = r#"{"/p/c": {"vcs": "git", "workrooms": {"same": {"path": "/mine/same"}}}, "/p/a": {"host": {"provisioner": "dev", "id": "B9"}}}"#;

/// The shared config after `dev`'s entries left it.
const CLAIM_SHARED_AFTER: &str = r#"{
  "/p/a": {
    "vcs": "git",
    "workrooms": {
      "loc": {
        "path": "/x/loc"
      },
      "r2": {
        "host": {
          "provisioner": "rel"
        },
        "path": "/home/r2"
      }
    }
  },
  "/p/b": {
    "host": {
      "bases": [
        {
          "id": "B3",
          "provisioner": "rel"
        }
      ]
    },
    "vcs": "git",
    "workrooms": {}
  },
  "/p/c": {
    "vcs": "git",
    "workrooms": {}
  },
  "channel": "pre",
  "workrooms_dir": "/w"
}"#;

/// This build's config after the claim: its own entries kept where names meet, the legacy host
/// turned into a list of bases now it holds two, and the workrooms folder shared.
const CLAIM_MINE_AFTER: &str = r#"{
  "/p/a": {
    "host": {
      "bases": [
        {
          "id": "B9",
          "provisioner": "dev"
        },
        {
          "driver": "boxd",
          "id": "B1",
          "provisioner": "dev"
        }
      ]
    },
    "workrooms": {
      "r1": {
        "host": {
          "n": 1.50,
          "provisioner": "dev"
        },
        "path": "/home/r1"
      }
    }
  },
  "/p/b": {
    "host": {
      "bases": [
        {
          "id": "B2",
          "provisioner": "dev"
        },
        {
          "provisioner": "dev",
          "x": 1
        }
      ]
    },
    "vcs": "git",
    "workrooms": {}
  },
  "/p/c": {
    "vcs": "git",
    "workrooms": {
      "same": {
        "path": "/mine/same"
      }
    }
  },
  "workrooms_dir": "/w"
}"#;

/// Moves what the `dev` build made out of the shared config into this one, counting each entry
/// that left, even one this config already had by that name. A second run finds nothing and
/// rewrites neither file; nor does a run with no provisioner or one naming this config itself.
/// `--pretend` is no dry run here, as in Go. Without `--json` a success prints nothing.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn claim_provisioned_moves_a_builds_entries_between_configs() {
    let home = Home::new("claim-moves");
    let shared = home.path("shared.json");
    std::fs::write(&shared, CLAIM_SHARED).expect("shared");
    home.write_config(CLAIM_MINE);
    let shared_arg = shared.to_string_lossy().into_owned();
    let run = home.run(
        &home.dir,
        &[
            "claim-provisioned",
            "--from",
            &shared_arg,
            "--provisioner",
            "dev",
            "--json",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalize_version(&run.stdout),
        "{\"cli_version\":\"dev\",\"command\":\"claim-provisioned\",\"moved\":5,\"ok\":true,\"schema_version\":1}\n"
    );
    assert_eq!(
        std::fs::read_to_string(&shared).expect("shared"),
        CLAIM_SHARED_AFTER
    );
    assert_eq!(config_text(&home), CLAIM_MINE_AFTER);

    // Nothing left to claim: neither file is rewritten.
    let marked = "{\"marked\": true,\n \"/p/a\": {\"workrooms\": {}}}";
    std::fs::write(
        &shared,
        CLAIM_SHARED_AFTER.replacen('{', "{\"marked\": true,", 1),
    )
    .expect("mark");
    home.write_config(marked);
    let config_dir = home.path(".config/workroom");
    let before = entries(&config_dir);
    for args in [
        &[
            "claim-provisioned",
            "--from",
            &shared_arg,
            "--provisioner",
            "dev",
            "--json",
        ][..],
        &[
            "claim-provisioned",
            "--from",
            &shared_arg,
            "--provisioner",
            "",
            "--json",
        ],
        &[
            "claim-provisioned",
            "--from",
            "",
            "--provisioner",
            "rel",
            "--json",
        ],
        &[
            "claim-provisioned",
            "--from",
            &home.config_path().to_string_lossy(),
            "--provisioner",
            "rel",
            "--json",
        ],
    ] {
        let run = home.run(&home.dir, args);
        run.assert_code(0).assert_quiet_stderr();
        assert_eq!(run.envelope()["moved"], 0, "{args:?}");
        assert_eq!(config_text(&home), marked, "{args:?}");
        assert!(
            std::fs::read_to_string(&shared)
                .expect("shared")
                .starts_with("{\"marked\": true,"),
            "{args:?}"
        );
    }
    assert_eq!(entries(&config_dir), before);

    let run = home.run(
        &home.dir,
        &[
            "claim-provisioned",
            "--from",
            &shared_arg,
            "--provisioner",
            "rel",
            "--pretend",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.stdout, "");
    let shared_now = std::fs::read_to_string(&shared).expect("shared");
    assert!(
        !shared_now.contains("\"rel\""),
        "--pretend kept rel's entries: {shared_now}"
    );
    assert!(
        config_text(&home).contains("\"B3\""),
        "{}",
        config_text(&home)
    );
}

/// A shared config that doesn't exist holds nothing to claim, and no file is made for it.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn claim_provisioned_from_a_missing_config_moves_nothing() {
    let home = Home::new("claim-missing");
    let missing = home.path("missing.json");
    let run = home.run(
        &home.dir,
        &[
            "claim-provisioned",
            "--from",
            &missing.to_string_lossy(),
            "--provisioner",
            "dev",
            "--json",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["moved"], 0);
    assert!(!missing.exists());
    assert!(!home.config_path().exists());
}

/// Both flags are required and it takes no argument: usage errors, so the envelope names no
/// command.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn claim_provisioned_refuses_missing_flags_and_arguments() {
    let home = Home::new("claim-usage");
    for (args, message) in [
        (
            &["claim-provisioned", "--json"][..],
            "required flag(s) \"from\", \"provisioner\" not set",
        ),
        (
            &["claim-provisioned", "--from", "x", "--json"],
            "required flag(s) \"provisioner\" not set",
        ),
        (
            &[
                "claim-provisioned",
                "--from",
                "x",
                "--provisioner",
                "p",
                "extra",
                "--json",
            ],
            "unknown command \"extra\" for \"workroom claim-provisioned\"",
        ),
    ] {
        let run = home.run(&home.dir, args);
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message, "{args:?}");
        assert!(envelope.get("command").is_none(), "{args:?}: {envelope}");
    }
}

/// A config it can't read, either one, or this one it can't write, fails the claim with the shared
/// config left as it was.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn claim_provisioned_reports_a_config_it_cant_read_or_write() {
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new("claim-config-errors");
    let shared = home.path("shared.json");
    let shared_arg = shared.to_string_lossy().into_owned();
    let claim = [
        "claim-provisioned",
        "--from",
        &shared_arg,
        "--provisioner",
        "dev",
        "--json",
    ];

    std::fs::write(&shared, "{bad").expect("shared");
    let run = home.run(&home.dir, &claim);
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigReadFailed");
    assert_eq!(
        run.envelope()["error"]["message"],
        format!(
            "failed to read config {shared_arg}: invalid character 'b' looking for beginning of \
             object key string"
        )
    );

    std::fs::write(&shared, CLAIM_SHARED).expect("shared");
    home.write_config("{bad");
    let run = home.run(&home.dir, &claim);
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigReadFailed");
    assert_eq!(
        std::fs::read_to_string(&shared).expect("shared"),
        CLAIM_SHARED
    );

    if skip_as_root("claim_provisioned_reports_a_config_it_cant_read_or_write") {
        return;
    }
    home.write_config(CLAIM_MINE);
    let config_dir = home.path(".config/workroom");
    std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o555)).expect("chmod");
    let run = home.run(&home.dir, &claim);
    std::fs::set_permissions(&config_dir, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    run.assert_code(6).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigWriteFailed");
    assert_eq!(
        std::fs::read_to_string(&shared).expect("shared"),
        CLAIM_SHARED
    );
    assert_eq!(config_text(&home), CLAIM_MINE);
}

// --- trust ---

/// SHA-256 of `#!/bin/sh\necho hi\n`, worked out apart from either binary (`shasum -a 256`).
const SHA_HI: &str = "299001868fb8c02fd431c336c6d058f5558c5dff5b5af5e6fe04b870a6a9cbba";
/// SHA-256 of `#!/bin/sh\necho hi!\n`: one byte more.
const SHA_HI_CHANGED: &str = "63e0ae522a90c0ab0e0422488d34aa93b349ca9264b27c6946db11b5bcc04802";
/// SHA-256 of `#!/bin/sh\necho host\n`.
const SHA_HOST: &str = "2a7fd7977f37f35ee10b2a63dce8e2eff7818d902791e589a196c2c090028d3f";

/// Writes `scripts/<name>` in `repo` with `text`, approving nothing.
fn write_script(repo: &Path, name: &str, text: &str) {
    write_file(repo, &format!("scripts/{name}"), text, 0o755);
}

/// Writes `scripts/<name>` in `repo` with `text` and commits it, so the base commit ships it.
fn commit_script(home: &Home, repo: &Path, name: &str, text: &str) {
    write_script(repo, name, text);
    home.git(repo, &["add", &format!("scripts/{name}")]);
    commit(home, repo, &format!("add {name}"));
}

/// Commits what is staged in `repo`.
fn commit(home: &Home, repo: &Path, message: &str) {
    home.git(
        repo,
        &["-c", "commit.gpgsign=false", "commit", "-q", "-m", message],
    );
}

/// `text` with the commit `trust status --base` reports written as Go's goldens write it.
fn normalize_start(text: &str) -> String {
    let key = "\"start\":\"";
    let Some(at) = text.find(key) else {
        return text.to_string();
    };
    let from = at + key.len();
    let hex = text[from..].find('"').filter(|&len| {
        len >= 40
            && text[from..from + len]
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
    });
    match hex {
        Some(len) => format!("{}<commit>{}", &text[..from], &text[from + len..]),
        None => text.to_string(),
    }
}

/// Go's `aheadProject`: `src/<name>`, whose origin (`<name>.git`) has `main` and whose local `main`
/// is one commit ahead of it, adding local.txt.
fn ahead_project(home: &Home, name: &str) -> PathBuf {
    let origin = format!("{name}.git");
    home.git(&home.dir, &["init", "-q", "--bare", "-b", "main", &origin]);
    let project = home.repo(&format!("src/{name}"));
    write_file(&project, "base.txt", "base\n", 0o644);
    home.git(&project, &["add", "base.txt"]);
    commit(home, &project, "base");
    let origin = home.path(&origin);
    home.git(
        &project,
        &["remote", "add", "origin", &origin.to_string_lossy()],
    );
    home.git(&project, &["push", "-q", "-u", "origin", "main"]);
    home.git(&project, &["remote", "set-head", "origin", "main"]);
    write_file(&project, "local.txt", "unpushed\n", 0o644);
    home.git(&project, &["add", "local.txt"]);
    commit(home, &project, "local");
    project
}

/// `trust status` judges the start a create would take, fetching first, and reports the local
/// work it leaves out: the project's base on the remote it names (`upstream/main`), or the global
/// base, which gives way to origin's default branch where the project lacks it (a start that
/// warns, so no local work is reported). A project's own base that the remote can't be fetched to
/// look for can't be told.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_follows_the_start_a_create_would_take() {
    let home = Home::new("trust-start");
    let project = ahead_project(&home, "app");
    let key = project.display().to_string();
    let status = || {
        let run = home.run(&project, &["trust", "status", "--json"]);
        run.assert_code(0).assert_quiet_stderr();
        run.envelope()
    };
    let upstream = home.path("app.git");
    home.git(
        &project,
        &["remote", "add", "upstream", &upstream.to_string_lossy()],
    );
    home.write_config(&format!(
        "{{\"{key}\": {{\"base_branch\": \"upstream/main\", \"vcs\": \"git\"}}}}"
    ));
    let envelope = status();
    assert_eq!(envelope["local_work"]["remote"], "upstream", "{envelope}");
    assert_eq!(envelope["local_work"]["ahead"], 1, "{envelope}");
    assert_eq!(envelope.get("start"), None, "only --base reports a start");

    home.write_config(&format!(
        "{{\"base_branch\": \"nowhere\", \"{key}\": {{\"vcs\": \"git\"}}}}"
    ));
    let envelope = status();
    assert_eq!(envelope.get("local_work"), None, "{envelope}");
    assert_eq!(envelope["trusted"], true);

    home.git(
        &project,
        &[
            "remote",
            "set-url",
            "origin",
            &home.path("gone.git").to_string_lossy(),
        ],
    );
    home.write_config(&format!(
        "{{\"{key}\": {{\"base_branch\": \"nowhere\", \"vcs\": \"git\"}}}}"
    ));
    let run = home.run(&project, &["trust", "status", "--json"]);
    run.assert_code(2).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "BaseBranchNotFound");
    assert_eq!(
        run.envelope()["error"]["message"],
        "the base branch exists neither on its remote nor locally: 'nowhere' (could not fetch \
         origin to look there)"
    );
    // Without a base, a failed fetch only warns: the last-fetched origin/main still starts it.
    home.write_config(&format!("{{\"{key}\": {{\"vcs\": \"git\"}}}}"));
    let envelope = status();
    assert_eq!(envelope.get("local_work"), None, "{envelope}");
}

/// A project as `trust status` runs: the Go contract tests' own setups, so their goldens hold
/// here. An unapproved setup script in the root (`trust-status.json`), and a project whose local
/// `main` is one commit ahead of origin's, judged at origin's default branch as a remote create
/// does (`trust-status-local-work.json`).
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_json_matches_the_goldens() {
    let home = Home::new("trust-golden");
    let project = home.repo("src/app");
    write_script(&project, "workroom_setup", "#!/bin/sh\necho installing\n");
    let run = home.run(
        &home.dir,
        &[
            "trust",
            "status",
            "--json",
            "--project",
            &project.to_string_lossy(),
        ],
    );
    run.assert_code(1).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "trust-status.json",
        &normalized_stdout(&home, &run),
    );

    let ahead = ahead_project(&home, "ahead");
    let run = home.run(
        &home.dir,
        &[
            "trust",
            "status",
            "--json",
            "--project",
            &ahead.to_string_lossy(),
            "--base",
            "",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    check_golden(
        Owner::GoContractTests,
        "trust-status-local-work.json",
        &normalize_start(&normalized_stdout(&home, &run)),
    );
}

/// `trust` approves the scripts a create would run next by their exact bytes, registering the
/// project, and `trust status` then exits 0. One changed byte needs approving again. `untrust`
/// forgets every approval and leaves the project registered. With no terminal on stdin, `trust`
/// approves without asking, as Go's does: no one is there to ask, and the caller ran it to approve.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_approves_until_the_script_changes_and_untrust_forgets() {
    let home = Home::new("trust-approve");
    let repo = home.repo("repo");
    commit_script(&home, &repo, "workroom_setup", "#!/bin/sh\necho hi\n");
    let project = repo.to_string_lossy();
    let at = |args: &[&str]| -> Vec<String> {
        args.iter()
            .map(ToString::to_string)
            .chain(["--project".to_string(), project.to_string()])
            .collect()
    };

    let run = home.run(&home.dir, &at(&["trust", "status"]));
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "scripts/workroom_setup from the base commit: not approved\nNo scripts/workroom_teardown.\n"
    );
    assert!(!home.config_path().exists(), "trust status wrote config");

    let run = home.run(&home.dir, &at(&["trust"]));
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "Approved scripts/workroom_setup from the base commit.\nNo scripts/workroom_teardown.\n"
    );
    assert_eq!(
        normalized_config(&home),
        format!(
            "{{\n  \"/Users/dev/repo\": {{\n    \"trusted_scripts\": {{\n      \"workroom_setup\": \"{SHA_HI}\"\n    }},\n    \"vcs\": \"git\",\n    \"workrooms\": {{}}\n  }}\n}}"
        )
    );
    let run = home.run(&home.dir, &at(&["trust", "status"]));
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "scripts/workroom_setup from the base commit: approved\nNo scripts/workroom_teardown.\n"
    );
    let run = home.run(&home.dir, &at(&["trust", "status", "--json"]));
    run.assert_code(0).assert_quiet_stderr();
    let envelope = run.envelope();
    assert_eq!(envelope["trusted"], true);
    assert_eq!(envelope["scripts"][0]["sha256"], SHA_HI);
    assert_eq!(envelope["scripts"][0]["trusted"], true);
    let run = home.run(&home.dir, &at(&["trust"]));
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "scripts/workroom_setup is already approved.\nNo scripts/workroom_teardown.\n"
    );

    commit_script(&home, &repo, "workroom_setup", "#!/bin/sh\necho hi!\n");
    let run = home.run(&home.dir, &at(&["trust", "status", "--json"]));
    run.assert_code(1).assert_quiet_stderr();
    let envelope = run.envelope();
    assert_eq!(envelope["trusted"], false);
    assert_eq!(envelope["scripts"][0]["sha256"], SHA_HI_CHANGED);
    assert_eq!(envelope["scripts"][0]["trusted"], false);
    let run = home.run(&home.dir, &at(&["trust", "--json"]));
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        format!(
            "{{\"cli_version\":\"dev\",\"command\":\"trust\",\"ok\":true,\"schema_version\":1,\"scripts\":[{{\"bytes\":\"IyEvYmluL3NoCmVjaG8gaGkhCg==\",\"exempt\":false,\"file\":\"scripts/workroom_setup\",\"name\":\"workroom_setup\",\"origin\":\"base\",\"sha256\":\"{SHA_HI_CHANGED}\",\"text\":\"#!/bin/sh\\necho hi!\\n\",\"trusted\":true}}]}}\n"
        )
    );
    assert!(
        normalized_config(&home).contains(&format!("\"workroom_setup\": \"{SHA_HI_CHANGED}\"")),
        "{}",
        normalized_config(&home)
    );

    let run = home.run(&home.dir, &at(&["untrust"]));
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "Forgot the approval of this project's scripts.\n"
    );
    assert_eq!(
        normalized_config(&home),
        "{\n  \"/Users/dev/repo\": {\n    \"vcs\": \"git\",\n    \"workrooms\": {}\n  }\n}"
    );
    let run = home.run(&home.dir, &at(&["untrust", "--json"]));
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"cli_version\":\"dev\",\"command\":\"untrust\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1}\n"
    );
    home.run(&home.dir, &at(&["trust", "status"]))
        .assert_code(1);
}

/// `trust status` exits 0 when every script there is approved or ignored by git (or there is
/// none), 1 when one is not, and 2 when it can't tell, with the error in an envelope that names
/// `trust status`. `trust` itself fails with the error's own exit code. Extra arguments are usage
/// errors, before either runs.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_exits_0_1_or_2() {
    let home = Home::new("trust-exits");
    let repo = home.repo("repo");
    let project = repo.to_string_lossy();
    let status = |extra: &[&str]| {
        home.run(
            &home.dir,
            &[
                &["trust", "status", "--json", "--project", &project][..],
                extra,
            ]
            .concat(),
        )
    };
    let run = status(&[]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"cli_version\":\"dev\",\"command\":\"trust status\",\"ok\":true,\"schema_version\":1,\"scripts\":[],\"trusted\":true}\n"
    );
    let run = home.run(&repo, &["trust", "status"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "No scripts/workroom_setup.\nNo scripts/workroom_teardown.\n"
    );

    // A root copy git ignores needs no approval; one it doesn't ignore does.
    write_script(&repo, "workroom_setup", "#!/bin/sh\necho local\n");
    write_script(&repo, "workroom_teardown", "#!/bin/sh\necho stop\n");
    status(&[]).assert_code(1);
    write_file(&repo, ".gitignore", "scripts/\n", 0o644);
    let run = status(&[]);
    run.assert_code(0).assert_quiet_stderr();
    let envelope = run.envelope();
    assert_eq!(envelope["trusted"], true);
    for (index, name) in ["workroom_setup", "workroom_teardown"].iter().enumerate() {
        let script = &envelope["scripts"][index];
        assert_eq!(script["name"], *name);
        assert_eq!(script["origin"], "root");
        assert_eq!(script["exempt"], true);
        assert_eq!(script["trusted"], true);
    }
    let run = home.run(&repo, &["trust", "status"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "scripts/workroom_setup in the project's root: ignored by git, needs no approval\n\
         scripts/workroom_teardown in the project's root: ignored by git, needs no approval\n"
    );
    let run = home.run(&repo, &["trust"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "scripts/workroom_setup is ignored by git, so it needs no approval.\n\
         scripts/workroom_teardown is ignored by git, so it needs no approval.\n"
    );
    assert!(
        !home.config_path().exists(),
        "trust recorded an exempt script"
    );

    // Exit 2: it can't tell.
    let plain = home.path("plain");
    std::fs::create_dir(&plain).expect("create plain");
    home.write_config(&format!(
        "{{\"{project}\": {{\"base_branch\": \"nowhere\", \"vcs\": \"git\"}}}}"
    ));
    for (extra, kind, message) in [
        (
            &[][..],
            "BaseBranchNotFound",
            "the base branch exists neither on its remote nor locally: 'nowhere'".to_string(),
        ),
        (
            &["--base", "nowhere"],
            "BaseBranchNotFound",
            "the base branch exists neither on its remote nor locally: 'nowhere'".to_string(),
        ),
        (
            &["--project", &plain.to_string_lossy()],
            "UnsupportedVCS",
            "no supported VCS detected in this directory. Workroom requires Git to manage workrooms"
                .to_string(),
        ),
        (
            &["--stdin", "bogus"],
            "InternalError",
            "--stdin takes workroom_setup, workroom_teardown or devcontainer, not \"bogus\""
                .to_string(),
        ),
        (
            &["--devcontainer"],
            "InternalError",
            "--devcontainer judges a container create's file, so it needs --base".to_string(),
        ),
    ] {
        let run = status(extra);
        run.assert_code(2).assert_quiet_stderr();
        assert_eq!(run.error_kind(), kind, "{extra:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["command"], "trust status", "{extra:?}");
        assert_eq!(envelope["error"]["message"], message.as_str(), "{extra:?}");
    }
    let run = home.run(&repo, &["trust", "status"]);
    run.assert_code(2).assert_quiet_stdout();
    assert_eq!(
        run.stderr,
        "Error: the base branch exists neither on its remote nor locally: 'nowhere'\n"
    );
    // `trust` fails as any command does: with the kind's own code.
    let run = home.run(&repo, &["trust", "--json"]);
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "BaseBranchNotFound");
    assert_eq!(run.envelope()["command"], "trust");
    home.write_config("{");
    let run = status(&[]);
    run.assert_code(2).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ConfigReadFailed");
    home.run(&repo, &["trust", "--json"]).assert_code(6);
    home.run(&repo, &["untrust", "--json"]).assert_code(6);

    for (args, message) in [
        (
            &["trust", "status", "x", "--json"][..],
            "unknown command \"x\" for \"workroom trust status\"",
        ),
        (
            &["trust", "x", "--json"],
            "unknown command \"x\" for \"workroom trust\"",
        ),
        (
            &["untrust", "x", "--json"],
            "unknown command \"x\" for \"workroom untrust\"",
        ),
    ] {
        let run = home.run(&repo, args);
        run.assert_code(1).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "InternalError", "{args:?}");
        let envelope = run.envelope();
        assert_eq!(envelope["error"]["message"], message, "{args:?}");
        assert_eq!(envelope.get("command"), None, "{args:?}");
    }
}

/// With `--stdin NAME`, the app's copy of a script (a remote host's) is judged and approved by the
/// bytes given, reading no file and needing no repository. `trust --stdin` records the approval
/// only for a project already registered: one gone meanwhile is refused, not registered again.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_stdin_judges_and_records_the_bytes_given() {
    let home = Home::new("trust-stdin");
    let dir = home.path("app");
    std::fs::create_dir(&dir).expect("create app");
    let project = dir.to_string_lossy();
    let body = b"#!/bin/sh\necho host\n";
    let run = home.run_with_stdin(
        &home.dir,
        &[
            "trust",
            "status",
            "--json",
            "--project",
            &project,
            "--stdin",
            "workroom_teardown",
        ],
        body,
    );
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        format!(
            "{{\"cli_version\":\"dev\",\"command\":\"trust status\",\"ok\":true,\"schema_version\":1,\"scripts\":[{{\"bytes\":\"IyEvYmluL3NoCmVjaG8gaG9zdAo=\",\"exempt\":false,\"file\":\"scripts/workroom_teardown\",\"name\":\"workroom_teardown\",\"origin\":\"stdin\",\"sha256\":\"{SHA_HOST}\",\"text\":\"#!/bin/sh\\necho host\\n\",\"trusted\":false}}],\"trusted\":false}}\n"
        )
    );
    // Bytes that aren't UTF-8 are shown with U+FFFD for each bad byte and kept exact in `bytes`.
    let run = home.run_with_stdin(
        &home.dir,
        &[
            "trust",
            "status",
            "--json",
            "--project",
            &project,
            "--stdin",
            "devcontainer",
        ],
        b"{\xff}\n",
    );
    run.assert_code(1).assert_quiet_stderr();
    let envelope = run.envelope();
    assert_eq!(
        envelope["scripts"][0]["file"],
        ".devcontainer/devcontainer.json"
    );
    assert_eq!(envelope["scripts"][0]["text"], "{\u{fffd}}\n");
    assert_eq!(envelope["scripts"][0]["bytes"], "e/99Cg==");

    let run = home.run_with_stdin(
        &home.dir,
        &[
            "trust",
            "--json",
            "--project",
            &project,
            "--stdin",
            "workroom_teardown",
        ],
        body,
    );
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ProjectNotFound");
    assert!(
        !home.config_path().exists(),
        "an unregistered project was registered"
    );

    home.write_config(&format!("{{\"{project}\": {{\"vcs\": \"git\"}}}}"));
    let run = home.run_with_stdin(
        &home.dir,
        &[
            "trust",
            "--project",
            &project,
            "--stdin",
            "workroom_teardown",
        ],
        body,
    );
    run.assert_code(0).assert_quiet_stderr();
    // No line for the script it wasn't given.
    assert_eq!(run.stdout, "Approved scripts/workroom_teardown as given.\n");
    assert_eq!(
        normalized_config(&home),
        format!(
            "{{\n  \"/Users/dev/app\": {{\n    \"trusted_scripts\": {{\n      \"workroom_teardown\": \"{SHA_HOST}\"\n    }},\n    \"vcs\": \"git\"\n  }}\n}}"
        )
    );
    let run = home.run_with_stdin(
        &home.dir,
        &[
            "trust",
            "status",
            "--project",
            &project,
            "--stdin",
            "workroom_teardown",
        ],
        body,
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.stdout, "scripts/workroom_teardown as given: approved\n");
}

/// Approvals are the project's: run in one of its workrooms (where every app terminal opens),
/// `trust` approves for the project and never registers the workroom. `--pretend` changes no
/// approval, either way. `untrust` needs the project registered. `--verbose` says which VCS it
/// found.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_in_a_workroom_is_the_projects_and_pretend_changes_nothing() {
    let home = Home::new("trust-workroom");
    let repo = home.repo("repo");
    commit_script(&home, &repo, "workroom_setup", "#!/bin/sh\necho hi\n");
    let workroom = home.path("workrooms/w");
    home.git(
        &repo,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "workroom/w",
            &workroom.to_string_lossy(),
        ],
    );
    home.write_config(&format!(
        "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{\"w\": {{\"path\": \"{}\"}}}}}}}}",
        repo.display(),
        workroom.display()
    ));
    let before = std::fs::read_to_string(home.config_path()).expect("read");
    let run = home.run(&workroom, &["trust", "--pretend", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["scripts"][0]["trusted"], true);
    assert_eq!(
        std::fs::read_to_string(home.config_path()).expect("read"),
        before,
        "--pretend recorded an approval"
    );
    home.run(&workroom, &["trust", "status"]).assert_code(1);

    let run = home.run(&workroom, &["trust"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_config(&home),
        format!(
            "{{\n  \"/Users/dev/repo\": {{\n    \"trusted_scripts\": {{\n      \"workroom_setup\": \"{SHA_HI}\"\n    }},\n    \"vcs\": \"git\",\n    \"workrooms\": {{\n      \"w\": {{\n        \"path\": \"/Users/dev/workrooms/w\"\n      }}\n    }}\n  }}\n}}"
        )
    );
    home.run(&repo, &["trust", "status"]).assert_code(0);
    let approved = normalized_config(&home);
    let run = home.run(&workroom, &["untrust", "-p", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        normalized_stdout(&home, &run),
        "{\"cli_version\":\"dev\",\"command\":\"untrust\",\"ok\":true,\"project\":\"/Users/dev/repo\",\"schema_version\":1}\n"
    );
    assert_eq!(
        normalized_config(&home),
        approved,
        "untrust --pretend forgot"
    );

    let run = home.run(&repo, &["-v", "trust", "status"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "        repo  Detected Git worktree\nscripts/workroom_setup from the base commit: approved\nNo scripts/workroom_teardown.\n"
    );

    let other = home.repo("other");
    let run = home.run(&other, &["untrust", "--json"]);
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ProjectNotFound");
    assert_eq!(
        home.normalize(
            run.envelope()["error"]["message"]
                .as_str()
                .expect("message")
        ),
        "project is not registered: /Users/dev/other"
    );
    assert_eq!(normalized_config(&home), approved);
}

/// `--base BRANCH` judges the setup script at the branch a remote create checks out, not the
/// project's own base, and `--devcontainer` the devcontainer.json there too. A committed setup
/// script that is a link is judged by what it points to in the commit; one pointing outside the
/// repository can't be judged from the commit, so it is left to the check before it runs.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_base_judges_that_branch_and_its_devcontainer() {
    let home = Home::new("trust-base");
    let repo = home.repo("repo");
    let project = repo.to_string_lossy();
    home.git(&repo, &["checkout", "-q", "-b", "remote-start"]);
    write_file(&repo, "real", "#!/bin/sh\necho hi\n", 0o755);
    std::fs::create_dir(repo.join("scripts")).expect("create scripts");
    std::os::unix::fs::symlink("../real", repo.join("scripts/workroom_setup")).expect("link");
    write_file(&repo, ".devcontainer/devcontainer.json", "{}\n", 0o644);
    home.git(&repo, &["add", "."]);
    commit(&home, &repo, "remote start");
    home.git(&repo, &["checkout", "-q", "main"]);

    let status = |extra: &[&str]| {
        home.run(
            &home.dir,
            &[
                &["trust", "status", "--json", "--project", &project][..],
                extra,
            ]
            .concat(),
        )
    };
    let run = status(&[]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["scripts"], serde_json::json!([]));

    let run = status(&["--base", "remote-start", "--devcontainer"]);
    run.assert_code(1).assert_quiet_stderr();
    let envelope = run.envelope();
    // A local branch names no commit a remote clone is sure to have, so no `start`.
    assert_eq!(envelope.get("start"), None);
    assert_eq!(envelope.get("local_work"), None);
    let setup = &envelope["scripts"][0];
    assert_eq!(setup["name"], "workroom_setup");
    assert_eq!(setup["origin"], "base");
    assert_eq!(setup["sha256"], SHA_HI);
    let config = &envelope["scripts"][1];
    assert_eq!(config["name"], "devcontainer");
    assert_eq!(config["file"], ".devcontainer/devcontainer.json");
    assert_eq!(config["origin"], "base");
    assert_eq!(config["text"], "{}\n");
    assert_eq!(envelope["scripts"].as_array().map(Vec::len), Some(2));
    let run = home.run(
        &home.dir,
        &[
            "trust",
            "status",
            "--project",
            &project,
            "--base",
            "remote-start",
            "--devcontainer",
        ],
    );
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(
        run.stdout,
        "scripts/workroom_setup from the base commit: not approved\n\
         .devcontainer/devcontainer.json from the base commit: not approved\n\
         No scripts/workroom_teardown.\n"
    );

    // Approving at that base approves both, by the bytes the commit holds.
    let run = home.run(
        &home.dir,
        &[
            "trust",
            "--json",
            "--project",
            &project,
            "--base",
            "remote-start",
            "--devcontainer",
        ],
    );
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["scripts"][1]["trusted"], true);
    status(&["--base", "remote-start", "--devcontainer"]).assert_code(0);

    home.git(&repo, &["checkout", "-q", "-b", "outside", "remote-start"]);
    std::fs::remove_file(repo.join("scripts/workroom_setup")).expect("remove link");
    std::os::unix::fs::symlink("/etc/hosts", repo.join("scripts/workroom_setup")).expect("link");
    home.git(&repo, &["add", "."]);
    commit(&home, &repo, "outside");
    let run = status(&["--base", "outside"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["scripts"], serde_json::json!([]));
}

/// SHA-256 of `#!/bin/sh\r\necho hi\r\n`: [`SHA_HI`]'s script with CRLF line endings.
const SHA_HI_CRLF: &str = "249dab6783d56f501eb877dc1754f48d0cfbe83a328cbbc35b7927190ddb0cab";

/// A gitignored root script that is a symlink is not exempt, since what it points to may be
/// tracked and a pull can change it; the same bytes as a plain ignored file are. Go's
/// `TestAnIgnoredSymlinkedRootScriptIsNotExempt`, through `trust status`, as `create` isn't
/// ported yet.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_does_not_exempt_an_ignored_symlinked_root_script() {
    let home = Home::new("trust-ignored-link");
    let repo = home.repo("src/app");
    commit_script(&home, &repo, "shared.sh", "#!/bin/sh\necho hi\n");
    std::os::unix::fs::symlink("shared.sh", repo.join("scripts/workroom_setup")).expect("link");
    write_file(&repo, ".gitignore", "scripts/workroom_setup\n", 0o644);
    let run = home.run(&repo, &["trust", "status", "--json"]);
    run.assert_code(1).assert_quiet_stderr();
    let envelope = run.envelope();
    let script = &envelope["scripts"][0];
    assert_eq!(script["name"], "workroom_setup", "{envelope}");
    assert_eq!(script["origin"], "root");
    assert_eq!(
        script["text"], "#!/bin/sh\necho hi\n",
        "read through the link"
    );
    assert_eq!(script["sha256"], SHA_HI);
    assert_eq!(script["exempt"], false);
    assert_eq!(script["trusted"], false);

    std::fs::remove_file(repo.join("scripts/workroom_setup")).expect("remove link");
    write_script(&repo, "workroom_setup", "#!/bin/sh\necho hi\n");
    let run = home.run(&repo, &["trust", "status", "--json"]);
    run.assert_code(0).assert_quiet_stderr();
    assert_eq!(run.envelope()["scripts"][0]["exempt"], true);
}

/// A script Workroom can't judge is refused, never judged: a link to a device (/dev/zero) unread
/// (Go's `TestADeviceScriptIsRefusedUnread`), a root copy over the 1 MiB a script may be, and a
/// base commit's before anything exists
/// (`TestAnOversizeBaseSetupScriptIsRefusedBeforeAnythingExists`), which `trust` refuses too,
/// approving nothing. A script of exactly 1 MiB is judged.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_refuses_a_device_or_oversize_script() {
    let home = Home::new("trust-unjudged");
    let repo = home.repo("src/app");
    let refused = |message: &str| {
        let run = home.run(&repo, &["trust", "status", "--json"]);
        run.assert_code(2).assert_quiet_stderr();
        assert_eq!(run.error_kind(), "ScriptNotTrusted");
        let envelope = run.envelope();
        assert_eq!(
            home.normalize(envelope["error"]["message"].as_str().expect("message")),
            message
        );
        assert_eq!(envelope.get("script"), None, "{envelope}");
    };
    // A file it can't even stat is a failure in the system's words, as Go's `*fs.PathError`.
    write_file(&repo, "scripts", "", 0o644);
    let run = home.run(&repo, &["trust", "status", "--json"]);
    run.assert_code(2).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
    assert_eq!(
        home.normalize(
            run.envelope()["error"]["message"]
                .as_str()
                .expect("message")
        ),
        "stat /Users/dev/src/app/scripts/workroom_setup: not a directory"
    );
    std::fs::remove_file(repo.join("scripts")).expect("remove scripts");

    std::fs::create_dir(repo.join("scripts")).expect("scripts");
    std::os::unix::fs::symlink("/dev/zero", repo.join("scripts/workroom_setup")).expect("link");
    refused(
        "script is not trusted on this Mac: /Users/dev/src/app/scripts/workroom_setup is not a \
         regular file",
    );
    std::fs::remove_file(repo.join("scripts/workroom_setup")).expect("remove link");

    let limit = 1 << 20;
    write_script(&repo, "workroom_teardown", &"#".repeat(limit));
    let run = home.run(&repo, &["trust", "status", "--json"]);
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.envelope()["scripts"][0]["name"], "workroom_teardown");
    write_script(&repo, "workroom_teardown", &"#".repeat(limit + 1));
    refused(
        "script is not trusted on this Mac: /Users/dev/src/app/scripts/workroom_teardown is \
         larger than 1048576 bytes",
    );
    std::fs::remove_file(repo.join("scripts/workroom_teardown")).expect("remove teardown");

    commit_script(&home, &repo, "workroom_setup", &("#".repeat(limit) + "\n"));
    let message = "script is not trusted on this Mac: scripts/workroom_setup in the base commit \
                   is larger than 1048576 bytes";
    refused(message);
    let run = home.run(&repo, &["trust", "--json"]);
    run.assert_code(3).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "ScriptNotTrusted");
    assert_eq!(run.envelope()["error"]["message"], message);
    assert!(!home.config_path().exists(), "trust recorded an approval");
}

/// The base commit's setup script is judged as a checkout of it writes it, through the line-ending
/// filters of the commit's own `.gitattributes` (`--attr-source`) and not the root checkout's, so
/// its approval matches the file that runs. Go's `TestFileAtAndIgnored` and
/// `TestFileAtUsesTheCommitsOwnAttributes`, through `trust status`.
#[test]
#[cfg_attr(
    not(target_os = "macos"),
    ignore = "Mac only: here the Rust binary is MacOnly"
)]
fn trust_status_judges_a_base_script_by_the_commits_own_line_endings() {
    let home = Home::new("trust-eol");
    let repo = home.repo("src/app");
    let setup = || {
        let run = home.run(&repo, &["trust", "status", "--json"]);
        run.assert_code(1).assert_quiet_stderr();
        let envelope = run.envelope();
        assert_eq!(envelope["scripts"][0]["origin"], "base", "{envelope}");
        envelope["scripts"][0].clone()
    };
    let attributes = |eol: &str| {
        write_file(
            &repo,
            ".gitattributes",
            &format!("scripts/workroom_setup text eol={eol}\n"),
            0o644,
        );
    };
    attributes("crlf");
    write_script(&repo, "workroom_setup", "#!/bin/sh\necho hi\n");
    home.git(&repo, &["add", ".gitattributes", "scripts/workroom_setup"]);
    commit(&home, &repo, "crlf");
    let script = setup();
    assert_eq!(script["text"], "#!/bin/sh\r\necho hi\r\n");
    assert_eq!(script["sha256"], SHA_HI_CRLF);

    attributes("lf");
    home.git(&repo, &["add", ".gitattributes"]);
    commit(&home, &repo, "lf");
    // The root's checkout has moved on to other rules than the commit judged.
    attributes("crlf");
    let script = setup();
    assert_eq!(script["text"], "#!/bin/sh\necho hi\n");
    assert_eq!(script["sha256"], SHA_HI);
}

// --- completion ---

/// The variables a run adds to its environment, by name.
type Env = &'static [(&'static str, &'static str)];

/// The command lines `completion-protocol.txt` records, each with the environment it adds: what a
/// cobra completion script asks on a Tab (`__complete <args…> <word>`, or `__completeNoDesc`). They
/// cover the top level, a partial word, each command with subcommands (`base`, `host` and `trust`,
/// hidden `host` included), the flags (inherited, local, shorthand, hidden, required, already set,
/// after `--`, taking a value), `help` and `completion` themselves, and the errors.
const COMPLETION_CASES: &[(Env, &[&str])] = &[
    (&[], &["__complete", ""]),
    (&[], &["__completeNoDesc", ""]),
    (&[], &["__complete", "b"]),
    (&[], &["__complete", "co"]),
    (&[], &["__complete", "h"]),
    (&[], &["__complete", "base", ""]),
    (&[], &["__completeNoDesc", "base", ""]),
    (&[], &["__complete", "base", "x"]),
    (&[], &["__complete", "base", "--"]),
    (&[], &["__complete", "base", "set", "--"]),
    (&[], &["__complete", "base", "set", ""]),
    (&[], &["__complete", "base", "set", "main", "--"]),
    (&[], &["__complete", "base", "set", "--global", "--"]),
    (&[], &["__complete", "base", "--global", ""]),
    (&[], &["__complete", "base", "--global", "set", ""]),
    (&[], &["__complete", "base", "--global=true", "set", ""]),
    (&[], &["__complete", "base", "-h", "set", ""]),
    (&[], &["__complete", "host", ""]),
    (&[], &["__complete", "host", "set", "--"]),
    (&[], &["__complete", "host", "set", ""]),
    (&[], &["__complete", "trust", ""]),
    (&[], &["__complete", "trust", "-"]),
    (&[], &["__complete", "trust", "status", ""]),
    (&[], &["__complete", "trust", "status", "-"]),
    (&[], &["__complete", "untrust", "--"]),
    (&[], &["__complete", "-"]),
    (&[], &["__complete", "-p", ""]),
    (&[], &["__complete", "--json", ""]),
    (&[], &["__complete", "--", ""]),
    (&[], &["__complete", "-h", ""]),
    (&[], &["__complete", "-h", "bogus", ""]),
    (&[], &["__complete", "list", "-"]),
    (&[], &["__complete", "list", "--json", "-"]),
    (&[], &["__complete", "list", "-p", "-"]),
    (&[], &["__complete", "list", "-vp", "-"]),
    (&[], &["__complete", "list", "--warnings=none", "--"]),
    (&[], &["__complete", "list", "--warnings"]),
    (&[], &["__complete", "list", "--warnings", ""]),
    (&[], &["__complete", "list", "--project="]),
    (&[], &["__complete", "list", "--project", "x", ""]),
    (&[], &["__complete", "list", "--project", "x", "--project"]),
    (&[], &["__complete", "list", "--help", ""]),
    (&[], &["__complete", "list", "x", ""]),
    (&[], &["__complete", "list", "--", ""]),
    (&[], &["__complete", "list", "--", "-"]),
    (&[], &["__complete", "list", "--", "--bogus", ""]),
    (&[], &["__complete", "list", "-x"]),
    (&[], &["__complete", "list", "-p=1", ""]),
    (&[], &["__complete", "ls", "--"]),
    (&[], &["__complete", "c", "--"]),
    (&[], &["__complete", "d", "-"]),
    (&[], &["__complete", "create", "--start", ""]),
    (&[], &["__complete", "create", "--start="]),
    (&[], &["__complete", "delete", ""]),
    (&[], &["__complete", "delete", "--confirm"]),
    (&[], &["__complete", "delete-project", "-"]),
    (&[], &["__complete", "add-project", "--"]),
    (&[], &["__complete", "claim-provisioned", ""]),
    (&[], &["__complete", "claim-provisioned", "-"]),
    (&[], &["__complete", "claim-provisioned", "--from", "x", ""]),
    (&[], &["__complete", "include-archive", ""]),
    (
        &[],
        &["__complete", "include-archive", "--output", "x", "--"],
    ),
    (&[], &["__complete", "update", "-"]),
    (&[], &["__complete", "update", "-c"]),
    (&[], &["__complete", "update", "-c", "-"]),
    (&[], &["__complete", "update", "--check=false", "-"]),
    (&[], &["__complete", "update", "-c="]),
    (&[], &["__complete", "version", ""]),
    (&[], &["__complete", "version", "-"]),
    (&[], &["__complete", "help", ""]),
    (&[], &["__complete", "help", "b"]),
    (&[], &["__complete", "help", "base", ""]),
    (&[], &["__complete", "help", "base", "set", ""]),
    (&[], &["__complete", "help", "bogus", ""]),
    (&[], &["__complete", "help", "-"]),
    (&[], &["__complete", "completion", ""]),
    (&[], &["__complete", "completion", "-"]),
    (&[], &["__complete", "completion", "zsh", ""]),
    (&[], &["__complete", "completion", "zsh", "-"]),
    (
        &[],
        &["__complete", "completion", "zsh", "--no-descriptions", "-"],
    ),
    (&[], &["__complete", "completion", "bash", "x", ""]),
    (&[], &["__complete", "bogus", ""]),
    (&[], &["__complete", "bogus", "x", ""]),
    (&[], &["__complete", "", ""]),
    (&[], &["__complete", "list", "--bogus", ""]),
    (&[], &["__complete", "list", "--bogus=x"]),
    (&[], &["__complete", "--pretend=x", ""]),
    (&[], &["--json", "__complete", ""]),
    (&[], &["__complete"]),
    (
        &[("WORKROOM_COMPLETION_DESCRIPTIONS", "false")],
        &["__complete", "b"],
    ),
    (
        &[("WORKROOM_COMPLETION_DESCRIPTIONS", "bogus")],
        &["__complete", "b"],
    ),
    (
        &[("COBRA_COMPLETION_DESCRIPTIONS", "0")],
        &["__complete", "b"],
    ),
    (
        &[
            ("WORKROOM_COMPLETION_DESCRIPTIONS", "true"),
            ("COBRA_COMPLETION_DESCRIPTIONS", "false"),
        ],
        &["__complete", "b"],
    ),
];

/// `arg` as a shell would need it written, for the transcript.
fn shell_word(arg: &str) -> String {
    let plain = !arg.is_empty()
        && arg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_-=./".contains(c));
    if plain {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', r"'\''"))
    }
}

/// The commands the Rust CLI has and Go's doesn't: `api` (#685), `capture` (#686) and `sessions`
/// (#683), born in Rust for the terminal API. Completion offers each beside Go's commands,
/// wherever it lists them (`''`, `help ''`, after a global flag), which Go's cobra, who wrote the
/// golden, never did.
const RUST_ONLY_COMMANDS: &[&str] = &["api", "capture", "sessions"];

/// `stdout` without the candidates `RUST_ONLY_COMMANDS` name, with or without a description, so
/// the Rust binary matches the transcript Go wrote in all else. Against Go it changes nothing.
fn without_rust_only_commands(stdout: &str) -> String {
    stdout
        .split_inclusive('\n')
        .filter(|line| {
            let candidate = line.trim_end_matches('\n').split('\t').next();
            !candidate.is_some_and(|word| RUST_ONLY_COMMANDS.contains(&word))
        })
        .collect()
}

/// Every case of `COMPLETION_CASES`, as Go's cobra answers them: each command line, then its
/// stdout, its stderr and its exit code. The golden was written from the Go CLI, so this holds the
/// binary under test to cobra's protocol byte for byte, which every script a user saved from the
/// Go CLI speaks, but for the candidates of `RUST_ONLY_COMMANDS`.
#[test]
fn completion_protocol_matches_the_golden() {
    let home = Home::new("completion-protocol");
    let mut transcript = String::new();
    for (env, args) in COMPLETION_CASES {
        let output = home
            .command(binary(), &home.dir)
            .envs(env.iter().copied())
            .args(*args)
            .output()
            .expect("run");
        let line: Vec<String> = env
            .iter()
            .map(|(name, value)| format!("{name}={}", shell_word(value)))
            .chain(std::iter::once("workroom".to_string()))
            .chain(args.iter().map(|arg| shell_word(arg)))
            .collect();
        transcript += &format!(
            "$ {}\n{}--- stderr\n{}--- exit {}\n\n",
            line.join(" "),
            without_rust_only_commands(&String::from_utf8(output.stdout).expect("stdout is UTF-8")),
            String::from_utf8(output.stderr).expect("stderr is UTF-8"),
            output.status.code().expect("exited")
        );
    }
    // Recorded from the Go CLI, so never rewritten by a run against Rust.
    check_golden(Owner::GoCli, "completion-protocol.txt", &transcript);
}

/// `completion` is one of `--help`'s commands, and runs anywhere, so it is not marked Mac-only.
#[test]
fn completion_is_in_help_and_not_mac_only() {
    let home = Home::new("completion-help");
    let run = home.run(&home.dir, &["--help"]);
    run.assert_code(0).assert_quiet_stderr();
    assert!(
        run.stdout.contains(
            "\n  completion        Generate the autocompletion script for the specified shell\n"
        ),
        "{}",
        run.stdout
    );
}

/// The shells `completion` writes a script for, each with the Go-generated script kept as a
/// fixture in `testdata/contracts/completion/`.
const COMPLETION_SHELLS: &[(&str, &str)] = &[
    ("bash", "workroom.bash"),
    ("zsh", "_workroom"),
    ("fish", "workroom.fish"),
    ("powershell", "workroom.ps1"),
];

/// `completion <shell>` writes the script the Go CLI wrote, and `--no-descriptions` the same one
/// asking `__completeNoDesc`, so a script saved from either binary is the other's. `completion`
/// alone is its help; an extra argument is a usage error.
#[test]
fn completion_writes_each_shells_script_as_go_does() {
    let home = Home::new("completion-scripts");
    for (shell, fixture) in COMPLETION_SHELLS {
        let run = home.run(&home.dir, &["completion", shell]);
        run.assert_code(0).assert_quiet_stderr();
        let file = format!("completion/{fixture}");
        check_golden(Owner::GoCli, &file, &run.stdout);
        let want = std::fs::read_to_string(golden_path(&file)).expect("read fixture");
        assert_eq!(want.matches(" __complete ").count(), 1, "{file}");
        let bare = home.run(&home.dir, &["completion", shell, "--no-descriptions"]);
        bare.assert_code(0).assert_quiet_stderr();
        assert_eq!(
            bare.stdout,
            want.replacen(" __complete ", " __completeNoDesc ", 1),
            "{shell} --no-descriptions"
        );
    }
    let help = home.run(&home.dir, &["completion"]);
    help.assert_code(0).assert_quiet_stderr();
    assert!(
        help.stdout
            .contains("  zsh         Generate the autocompletion script for zsh\n"),
        "{}",
        help.stdout
    );
    let extra = home.run(&home.dir, &["completion", "zsh", "extra"]);
    extra.assert_code(1);
    assert_eq!(extra.stdout, "");
    assert_eq!(
        extra.stderr,
        "Error: unknown command \"extra\" for \"workroom completion zsh\"\n"
    );
}

/// The shell `name` on PATH, or None (with a note that the test skips it) when it isn't installed.
fn installed_shell(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let found = std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|shell| shell.is_file());
    if found.is_none() {
        eprintln!("skipped {name}: not installed");
    }
    found
}

/// What `shell` offers for the command line `workroom b` once it has sourced `script`, one
/// candidate per line as the shell holds them (a description may follow the word), with the
/// binary under test as the `workroom` on PATH. None when the shell isn't installed.
///
/// bash's script wants the bash-completion package's `_init_completion`, which macOS's bash 3.2
/// lacks, so the harness defines one from `COMP_WORDS`; and `compopt`, a builtin from bash 4 that
/// works only inside a real completion, is a no-op function, so bash 3.2 and 5 take the same path
/// through the script. zsh's script runs inside zsh's completion
/// system, so `compdef` and `_describe` (which would hand the candidates to the line editor) are
/// stubbed to print them. fish completes a command line itself, with `complete -C`.
fn complete_b(home: &Home, shell: &str, script: &Path) -> Option<String> {
    let program = installed_shell(shell)?;
    let bin = home.path("bin");
    if !bin.exists() {
        std::fs::create_dir(&bin).expect("create bin");
        std::os::unix::fs::symlink(binary(), bin.join("workroom")).expect("link workroom");
    }
    let harness = match shell {
        "bash" => {
            r#"compopt() { :; }
_init_completion() {
    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
}
source "$1"
COMP_WORDS=(workroom b)
COMP_CWORD=1
COMP_LINE="workroom b"
COMP_POINT=${#COMP_LINE}
__start_workroom
printf '%s\n' "${COMPREPLY[@]}"
"#
        }
        "zsh" => {
            r#"compdef() { : }
_describe() {
    [[ $1 == -V ]] && shift
    print -rl -- "${(@P)2}"
}
source "$1"
words=(workroom b)
CURRENT=2
_workroom
"#
        }
        "fish" => "source $argv[1]\ncomplete -C 'workroom b'\n",
        _ => unreachable!("no harness for {shell}"),
    };
    let harness_path = home.path(&format!("harness.{shell}"));
    std::fs::write(&harness_path, harness).expect("write harness");
    let mut search = vec![bin];
    search.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    let mut command = home.command(&program, &home.dir);
    command.env("PATH", std::env::join_paths(search).expect("PATH"));
    match shell {
        "bash" => command.args(["--norc", "--noprofile"]),
        "zsh" => command.arg("-f"),
        _ => command.arg("--no-config"),
    };
    let output = command
        .arg(&harness_path)
        .arg(script)
        .output()
        .expect("run the shell");
    assert!(
        output.status.success(),
        "{shell} harness failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Some(String::from_utf8(output.stdout).expect("UTF-8"))
}

/// Whether `offered` (what `complete_b` printed) offers `base`: a line that is the word, or the
/// word then the shell's description separator.
fn offers_base(offered: &str) -> bool {
    offered
        .lines()
        .any(|line| line == "base" || line.starts_with("base:") || line.starts_with("base\t"))
}

/// The script `completion <shell>` writes, sourced in that shell, completes `workroom b` to `base`
/// by asking the binary, with descriptions and without. Each shell that isn't installed is skipped.
#[test]
fn completion_scripts_complete_in_their_shells() {
    let home = Home::new("completion-shells");
    for shell in ["bash", "zsh", "fish"] {
        for flags in [&[][..], &["--no-descriptions"]] {
            let run = home.run(&home.dir, &[&["completion", shell][..], flags].concat());
            run.assert_code(0).assert_quiet_stderr();
            let script = home.path(&format!("script.{shell}"));
            std::fs::write(&script, &run.stdout).expect("write script");
            let Some(offered) = complete_b(&home, shell, &script) else {
                break;
            };
            assert!(
                offers_base(&offered),
                "{shell} {flags:?} offered {offered:?}"
            );
        }
    }
}

/// A script saved from the Go CLI keeps working once this binary is `workroom`: each sourceable
/// shell's fixture completes `workroom b` to `base` against the binary under test.
#[test]
fn completion_a_go_generated_script_completes_against_the_binary() {
    let home = Home::new("completion-go-script");
    for (shell, fixture) in &COMPLETION_SHELLS[..3] {
        let script = golden_path(&format!("completion/{fixture}"));
        if let Some(offered) = complete_b(&home, shell, &script) {
            assert!(offers_base(&offered), "{shell} offered {offered:?}");
        }
    }
}
