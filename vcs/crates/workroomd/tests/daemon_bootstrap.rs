//! The app's far-side bootstrap scripts (`macapp/Resources/daemon-bootstrap`) against a real daemon
//! on this machine (#680): an install pushes the binary whenever the app sends it, and the running
//! daemon is handed off only when the binary is another daemon build. The app's own tests
//! (`DaemonBootstrapScriptTests`) run these scripts against stand-ins, which answer whatever they
//! are told; here the daemon decides. The ssh fixture does the same on a real Linux host
//! (`remote_transport.rs`).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[allow(dead_code)] // not every helper is used here
mod common;
use common::*;

/// One of the bootstrap scripts, run as `DaemonBootstrap` runs it, `sh -c '<script>' <name>
/// <args>`, with `stdin` piped in. Returns what it printed.
fn bootstrap(name: &str, args: &[&Path], stdin: Option<&Path>) -> String {
    let script = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../macapp/Resources/daemon-bootstrap")
            .join(format!("{name}.sh")),
    )
    .expect("the app's bootstrap script");
    let mut command = Command::new("sh");
    command.arg("-c").arg(script).arg(name).args(args);
    match stdin {
        Some(path) => command.stdin(std::fs::File::open(path).expect("open stdin")),
        None => command.stdin(Stdio::null()),
    };
    let output = command.output().expect("run the script");
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// The value of a `WRB <key> …` line.
fn reported(output: &str, key: &str) -> Option<String> {
    output
        .lines()
        .filter_map(|line| line.strip_prefix("WRB "))
        .find_map(|line| line.strip_prefix(key)?.strip_prefix(' '))
        .map(str::to_string)
}

/// SHA-256 as `sha256sum` prints it, which is what install.sh checks the push against.
fn sha256_hex(path: &Path) -> String {
    let output = Command::new("sh")
        .args([
            "-c",
            "sha256sum < \"$1\" 2>/dev/null || shasum -a 256 < \"$1\"",
            "sha",
        ])
        .arg(path)
        .output()
        .expect("hash");
    String::from_utf8_lossy(&output.stdout)[..64].to_string()
}

fn alive(pid: i32) -> bool {
    // SAFETY: `kill` takes no pointers, and signal 0 delivers nothing.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// A host with a daemon serving one session: the daemon's directory, its socket, the session's
/// shell, and the daemon.
struct Host {
    workspace: Workspace,
    daemon: Spawned,
    shell: i32,
}

const SESSION: &str = "5b5b5b5b-0000-4000-8000-000000000001";

impl Host {
    /// `name` is short: the socket's path must fit in `sun_path` (104 bytes on macOS).
    fn new(name: &str) -> Host {
        let workspace = Workspace::new(name);
        let socket = workspace.socket();
        let daemon = start_daemon(&socket);
        let mut client = attach(&socket, SESSION);
        std::thread::sleep(std::time::Duration::from_millis(400));
        let stdin = client.stdin.as_mut().expect("stdin");
        std::io::Write::write_all(stdin, b"echo \"PID=$$=\"\"\"\n").expect("type");
        let mut reader = ClientReader::new(&mut client);
        let seen = reader.read_until("=\r\n", std::time::Duration::from_secs(10));
        let shell = seen
            .rsplit("PID=")
            .next()
            .and_then(|rest| rest.split('=').next())
            .and_then(|pid| pid.trim().parse::<i32>().ok())
            .unwrap_or_else(|| panic!("no pid in {seen:?}"));
        Host {
            workspace,
            daemon,
            shell,
        }
    }

    fn socket(&self) -> PathBuf {
        self.workspace.socket()
    }

    /// Where the app installs the daemon: beside the socket (#231).
    fn installed(&self) -> PathBuf {
        self.workspace.dir.join("workroomd")
    }

    /// install.sh with `binary` pushed on its stdin, hand-off on.
    fn install(&self, binary: &Path) -> String {
        let sha = sha256_hex(binary);
        bootstrap(
            "install",
            &[
                &self.installed(),
                &self.socket(),
                Path::new("1"),
                Path::new(&sha),
            ],
            Some(binary),
        )
    }

    /// The daemon still runs, as the same process, with the same session and its shell.
    fn assert_sessions_kept(&mut self, why: &str) {
        assert!(
            self.daemon.try_wait().expect("wait").is_none(),
            "{why}: the daemon exited"
        );
        assert!(alive(self.shell), "{why}: the shell did not survive");
        assert!(
            list_sessions(&self.socket()).contains(SESSION),
            "{why}: the session is gone"
        );
    }
}

/// A push whose CLI commands alone changed is installed, so the next `workroom <command>` on the
/// host runs it, and the daemon is not handed off: it answers `current` without running it.
#[test]
fn a_push_that_changes_only_cli_commands_is_installed_and_not_handed_off() {
    let mut host = Host::new("wrb-cli");
    let cli_only = daemon_script(
        &host.workspace.dir.join("cli-only"),
        Some(&stated_daemon_build()),
    );

    let output = host.install(&cli_only);
    assert_eq!(
        reported(&output, "outcome").as_deref(),
        Some("current"),
        "{output}"
    );
    assert_eq!(sha256_hex(&host.installed()), sha256_hex(&cli_only));
    let runs = daemon_script_runs(&cli_only);
    assert!(
        !runs.contains("handoff-check") && !runs.contains("serve"),
        "the daemon was handed to it: {runs:?}"
    );
    host.assert_sessions_kept("a CLI-only push");
}

/// A push that changes the daemon is installed and handed off, and the daemon keeps every session;
/// so is one from before daemon builds, which states none.
#[test]
fn a_push_that_changes_the_daemon_or_states_no_daemon_build_is_handed_off() {
    let mut host = Host::new("wrb-daemon");
    for (name, build) in [
        ("daemon-change", Some(another_daemon_build())),
        ("no-daemon-build", None),
    ] {
        let binary = daemon_script(&host.workspace.dir.join(name), build.as_deref());
        let output = host.install(&binary);
        assert_eq!(
            reported(&output, "outcome").as_deref(),
            Some("handed-off"),
            "{name}: {output}"
        );
        assert_eq!(sha256_hex(&host.installed()), sha256_hex(&binary), "{name}");
        assert!(
            daemon_script_runs(&binary).contains("serve"),
            "{name}: the daemon was not handed to it"
        );
        host.assert_sessions_kept(name);
    }
}

/// A container's daemon, placed by its driver (#308): placed.sh asks the same hand-off, so a
/// placed binary whose CLI commands alone changed is current too.
#[test]
fn a_placed_binary_that_changes_only_cli_commands_is_not_handed_off() {
    let mut host = Host::new("wrb-placed");
    let placed = daemon_script(
        &host.workspace.dir.join("placed"),
        Some(&stated_daemon_build()),
    );
    let output = bootstrap("placed", &[&placed, &host.socket(), Path::new("1")], None);
    assert_eq!(
        reported(&output, "outcome").as_deref(),
        Some("current"),
        "{output}"
    );
    host.assert_sessions_kept("a CLI-only placement");
}
