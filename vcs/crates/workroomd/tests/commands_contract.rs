//! The `workroom` CLI's contract (ADR 0013), run as a black box against whatever binary
//! `WORKROOM_BIN` names: the Go CLI today, and the Rust `workroom` as each command group is ported
//! (ADR 0078, #667). A run checks what a caller sees: the one JSON envelope on stdout, stderr, the
//! exit code and `kind`, and the config.json the command leaves behind.
//!
//! Without `WORKROOM_BIN` the binary under test is this crate's own `workroom`. A group's tests
//! are `#[ignore]`d until its commands are ported to Rust, so a plain `cargo test` runs only the
//! ported groups (`version_`, `list_`, `config_` and `include_archive_` today). `make
//! contract-test` builds the Go CLI and runs every test against it with `--include-ignored`.
//!
//! The Mac-only commands' groups (`list_`, `config_`, `include_archive_`) are ignored off the Mac
//! too, where the Rust binary answers them with `MacOnly` (ADR 0078): a plain `cargo test` on
//! Linux runs `version_` alone, and `--include-ignored` against the Go CLI still runs everything.
//!
//! Tests are named for their command group (`version_`, `list_`, `config_`, `include_archive_`),
//! so a port can run only its own group's names against Rust.
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
        let output = self
            .command(binary(), cwd)
            .args(args)
            .output()
            .unwrap_or_else(|error| panic!("run {}: {error}", binary().display()));
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

/// Who writes a golden: this suite, or Go's contract tests, whose goldens this suite only reads.
#[derive(Clone, Copy, PartialEq)]
enum Owner {
    ThisSuite,
    GoContractTests,
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
