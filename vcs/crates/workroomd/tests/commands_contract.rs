//! The `workroom` CLI's contract (ADR 0013), run as a black box against whatever binary
//! `WORKROOM_BIN` names: the Go CLI today, and the Rust `workroom` as each command group is ported
//! (ADR 0078, #667). A run checks what a caller sees: the one JSON envelope on stdout, stderr, the
//! exit code and `kind`, and the config.json the command leaves behind.
//!
//! Every test is `#[ignore]`d, because the daemon this crate builds has no CLI commands yet.
//! `make contract-test` builds the Go CLI and runs them against it.
//!
//! Tests are named for their command group (`version_`, `list_`, `config_`), so a port can run
//! only its own group's names against Rust.
//!
//! The JSON goldens are `testdata/contracts`, the files Go's contract tests
//! (`cmd/contract_test.go`) and the app's `CLIContractTests.swift` check too, with the temporary
//! HOME written as `/Users/dev`. `WORKROOM_CONTRACT_UPDATE=1` rewrites the goldens this suite owns
//! from the binary under test; it never rewrites the ones Go's tests own.
//!
//! Each run gets a cleared environment: only `PATH`, its own HOME and `WORKROOM_CONFIG`, and git
//! with no global or system config. Nothing a run does can reach the real home or config.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The temporary HOME's stand-in in every golden.
const GOLDEN_HOME: &str = "/Users/dev";

/// The binary under test, by an absolute path, since each run starts in its own directory. Running
/// these tests without one is a mistake, not a skip.
fn binary() -> PathBuf {
    match std::env::var_os("WORKROOM_BIN") {
        Some(path) if !path.is_empty() => PathBuf::from(&path)
            .canonicalize()
            .unwrap_or_else(|error| panic!("WORKROOM_BIN {path:?}: {error}")),
        _ => panic!("WORKROOM_BIN must name the workroom binary under test"),
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

    /// Runs the binary under test with `args`, from `cwd`.
    fn run(&self, cwd: &Path, args: &[&str]) -> Run {
        let output = self
            .command(binary(), cwd)
            .args(args)
            .output()
            .unwrap_or_else(|error| panic!("run {}: {error}", binary().display()));
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
#[ignore = "needs WORKROOM_BIN"]
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
#[ignore = "needs WORKROOM_BIN"]
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
#[ignore = "needs WORKROOM_BIN"]
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
#[ignore = "needs WORKROOM_BIN"]
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
#[ignore = "needs WORKROOM_BIN"]
fn list_json_reports_a_bad_flag_value_as_an_error_envelope() {
    let home = Home::new("list-bad-warnings");
    let run = home.run(&home.dir, &["list", "--json", "--warnings=bad"]);
    run.assert_code(1).assert_quiet_stderr();
    assert_eq!(run.error_kind(), "InternalError");
    assert_eq!(run.envelope()["command"], "list");
}

#[test]
#[ignore = "needs WORKROOM_BIN"]
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
#[ignore = "needs WORKROOM_BIN"]
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
