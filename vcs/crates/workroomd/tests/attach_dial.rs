//! A remote pane attached from the Mac (ADR 0074): `workroomd attach --dial <command…>` speaks the
//! daemon's framed protocol over the command's stdio, which on a real host is
//! `ssh -T <host> <binary> relay --socket <path>`. Here the command is a local `workroomd relay`, or
//! a script standing in for a host, so all of it runs over pipes with no ssh, as the
//! remote-transport tests do.

#[allow(dead_code)] // not every helper is used here
mod common;
use common::{ClientReader, Spawned, daemon_binary};

use std::ffi::{OsStr, OsString};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use workroomd::testing::{
    HostOrigin, KEEPALIVE_PROBE, KEEPALIVE_VARIABLE, Screens, SessionId, SessionStore,
    handle_connection,
};
use wr_protocol::envelope::Service;
use wr_protocol::frame::{Frame, FrameKind};
use wr_protocol::terminal::{AttachRequest, parse_session_id};

const SESSION: &str = "6B9B968D-0BD7-4172-850A-A373DA73BC70";

/// Runs a dial-mode attach to `dialed` with only `env` and the session id, and returns its
/// stdout, its stderr and its exit status.
fn dial(dialed: &[&str], env: &[(&str, &str)]) -> (String, String, Option<i32>) {
    let mut command = Command::new(daemon_binary());
    command
        .arg("attach")
        .arg("--dial")
        .args(dialed)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("WORKROOM_SESSION_ID", SESSION)
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn attach");
    let mut out = String::new();
    let mut err = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut out)
        .unwrap();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut err)
        .unwrap();
    let status = child.wait().expect("wait");
    (out, err, status.code())
}

/// A host that ends the dialed command before its daemon greets: ssh's own failure (255), a host
/// with no daemon binary yet (127 from the remote shell, or the 255 a guard script exits), and
/// `relay`'s daemon-unavailable status (92) are all a lost link the app keeps retrying.
#[test]
fn a_host_that_cannot_reach_its_daemon_yet_exits_with_the_retry_status() {
    for status in ["255", "127", "92"] {
        let (_, _, code) = dial(&["/bin/sh", "-c", &format!("exit {status}")], &[]);
        assert_eq!(code, Some(255), "a dialed command that exited {status}");
    }
}

/// A host that refuses for good says why on stderr and exits non-zero, as a host with only the
/// former `wr-agent` layout does, and the pane stops rather than retrying.
#[test]
fn a_host_that_refuses_says_why_and_does_not_ask_for_a_retry() {
    let (_, err, code) = dial(
        &[
            "/bin/sh",
            "-c",
            "echo 'workroom: this host has the former layout' >&2; exit 1",
        ],
        &[],
    );
    assert_eq!(code, Some(1));
    assert!(err.contains("former layout"), "stderr: {err:?}");
}

/// A daemon older than this client is one the app has not updated yet: retry (ADR 0037), never a
/// session it would build the wrong way.
#[test]
fn a_daemon_with_an_older_protocol_exits_with_the_retry_status() {
    // A protocol-10 greeting, `WRA1 | 00 0a | 00`, then a daemon that waits.
    let (out, _, code) = dial(
        &[
            "/bin/sh",
            "-c",
            "printf 'WRA1\\000\\012\\000'; cat >/dev/null",
        ],
        &[],
    );
    assert_eq!(code, Some(255));
    assert!(out.is_empty(), "nothing reaches the pane: {out:?}");
}

/// A short directory: a unix socket address is capped at 104 bytes and cargo's target dir is long.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = PathBuf::from(format!("/tmp/wr-dial-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("home")).expect("scratch dir");
        Scratch(dir)
    }

    fn home(&self) -> PathBuf {
        self.0.join("home")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A daemon served in this process on a real socket, so a real `relay` reaches it, and the test
/// says what the host's environment and account are (`SessionStore::set_host_origin`): never the
/// developer's own shell, profile or home.
struct Host {
    store: SessionStore,
    socket: PathBuf,
    /// The connections the daemon is serving.
    connections: Arc<AtomicUsize>,
    /// The home of the ssh login `relay` runs in.
    home: PathBuf,
}

impl Host {
    fn serve(scratch: &Scratch, store: SessionStore, environment: &[(&str, &str)]) -> Host {
        Host::serve_as(
            scratch,
            store,
            HostOrigin {
                environment: environment
                    .iter()
                    .map(|(k, v)| (OsString::from(k), OsString::from(v)))
                    .collect(),
                shell: "/bin/sh".into(),
                home: scratch.home(),
                user: "fixture".into(),
            },
        )
    }

    /// As `serve`, with the daemon's environment and account entry both `origin`.
    fn serve_as(scratch: &Scratch, store: SessionStore, origin: HostOrigin) -> Host {
        store.set_host_origin(origin);
        store.keep_host_resources(scratch.0.join("ghostty"));
        let socket = scratch.0.join("d.sock");
        let listener = UnixListener::bind(&socket).expect("bind");
        let served = store.clone();
        let connections = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&connections);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let sessions = served.clone();
                let counted = Arc::clone(&counted);
                counted.fetch_add(1, Ordering::SeqCst);
                std::thread::spawn(move || {
                    let _ = handle_connection(stream, sessions);
                    counted.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });
        Host {
            store,
            socket,
            connections,
            home: scratch.home(),
        }
    }

    /// What a pane on the Mac runs: `attach --dial` to this host's `relay`, which has the
    /// environment of the ssh login it runs in (`LOGIN`, with the scratch home), never the Mac's.
    fn dial(&self, env: &[(&str, &str)]) -> Command {
        self.dial_with(&[], env)
    }

    /// As `dial`, with `flags` for the attach.
    fn dial_with(&self, flags: &[&str], env: &[(&str, &str)]) -> Command {
        let mut command = Command::new(daemon_binary());
        command
            .arg("attach")
            .args(flags)
            .args(["--dial", "/usr/bin/env", "-i"])
            .arg(format!("HOME={}", self.home.display()))
            .args(LOGIN.iter().map(|(key, value)| format!("{key}={value}")))
            .arg(daemon_binary())
            .args(["relay", "--socket"])
            .arg(&self.socket)
            .env_clear()
            .env("WORKROOM_SESSION_ID", SESSION)
            .envs(env.iter().copied())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        self.store.kill_all();
    }
}

const CLEAR_WAITING_LINE: &str = "\x1b8\x1b[J";
const SSH_CONNECTION: &str = "10.0.0.1 51234 10.0.0.2 22";
const SSH_CLIENT: &str = "10.0.0.1 51234 22";

/// What the ssh login `relay` runs in has, besides its `HOME`: what sshd and the user's account
/// gave it, and a terminal of its own that must not reach the session.
const LOGIN: [(&str, &str); 9] = [
    ("PATH", "/login/bin:/usr/bin:/bin"),
    ("SHELL", "/bin/sh"),
    ("USER", "login"),
    ("LOGNAME", "login"),
    ("FROM_LOGIN", "yes"),
    ("SSH_CONNECTION", SSH_CONNECTION),
    ("SSH_CLIENT", SSH_CLIENT),
    ("SSH_TTY", "/dev/pts/4"),
    ("TERM", "dumb"),
];

/// What the Mac's pane has in its environment, much of which must never reach the host.
const MAC: [(&str, &str); 14] = [
    ("PATH", "/opt/homebrew/bin:/usr/bin:/bin"),
    ("HOME", "/Users/mac"),
    ("SHELL", "/bin/zsh"),
    ("USER", "mac"),
    ("SECRET", "from-the-mac"),
    ("SSH_TTY", "/dev/ttys004"),
    (
        "WORKROOM_SESSION_RESOURCES",
        "/Applications/Workroom.app/ghostty",
    ),
    ("WORKROOM_SESSION_SHELL", "/bin/zsh"),
    ("TERM", "xterm-ghostty"),
    ("COLORTERM", "truecolor"),
    ("TERM_PROGRAM", "ghostty"),
    ("TERM_PROGRAM_VERSION", "1.2.3"),
    ("LANG", "en_GB.UTF-8"),
    ("LC_CTYPE", "UTF-8"),
];

/// What the host's daemon has: some of it stale from the ssh login that started it.
const DAEMON: [(&str, &str); 7] = [
    ("PATH", "/host/bin:/usr/bin:/bin"),
    ("FROM_DAEMON", "yes"),
    ("HOME", "/wrong/home"),
    ("SSH_CONNECTION", "192.0.2.9 1 192.0.2.10 22"),
    ("SSH_CLIENT", "192.0.2.9 1 22"),
    ("SSH_TTY", "/dev/pts/9"),
    ("TERM", "dumb"),
];

/// The session's environment, one variable per line, from a session that runs `env`.
fn session_environment(host: &Host) -> Vec<String> {
    let mut env: Vec<(&str, &str)> = MAC.to_vec();
    // A line first, so a new session's repaint (with `terminal-state`) is a line of its own.
    env.push(("WORKROOM_SESSION_COMMAND", "/bin/sh -c 'echo; exec env'"));
    let output = host.dial(&env).output().expect("attach");
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let seen = String::from_utf8_lossy(&output.stdout);
    // The attach wrapper's "waiting for this terminal's host" line, cleared once the host's daemon
    // has greeted: back to the cursor it saved (DECRC), and erased from there (ED).
    let seen = seen
        .strip_prefix(CLEAR_WAITING_LINE)
        .unwrap_or_else(|| panic!("the waiting line was not cleared first: {seen:?}"));
    seen.split(['\r', '\n'])
        .map(str::to_string)
        .filter(|line| !line.is_empty() && !line.contains('\x1b'))
        .collect()
}

fn names(lines: &[String]) -> Vec<&str> {
    lines
        .iter()
        .filter_map(|line| line.split('=').next())
        .collect()
}

fn contains(lines: &[String], entry: &str) -> bool {
    lines.iter().any(|line| line == entry)
}

/// The host builds the session (ADR 0074): the environment of the ssh login `relay` runs in, and
/// from the Mac only the terminal and locale. Not the daemon's own, which is whatever started it.
#[test]
fn a_dialed_session_gets_the_ssh_logins_environment_and_only_the_terminal_and_locale_from_the_mac()
{
    let scratch = Scratch::new("env");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let lines = session_environment(&host);
    assert_login_environment(&lines, &scratch);
}

/// A host whose users come from a directory service: the daemon's static lookup finds no entry,
/// so its account is a synthetic one with `/` for a home and no shell. The ssh login had the real
/// ones, and the session gets them.
#[test]
fn a_dialed_session_on_a_host_without_a_passwd_entry_gets_the_ssh_logins_home_and_shell() {
    let scratch = Scratch::new("nss");
    let host = Host::serve_as(
        &scratch,
        SessionStore::new(),
        HostOrigin {
            environment: vec![(OsString::from("PATH"), OsString::from("/daemon/bin"))],
            shell: String::new(),
            home: PathBuf::from("/"),
            user: String::new(),
        },
    );
    let lines = session_environment(&host);
    assert_login_environment(&lines, &scratch);
    assert!(!contains(&lines, "HOME=/"), "{lines:?}");
}

fn assert_login_environment(lines: &[String], scratch: &Scratch) {
    let home = format!("HOME={}", scratch.home().display());
    let ssh_connection = format!("SSH_CONNECTION={SSH_CONNECTION}");
    let ssh_client = format!("SSH_CLIENT={SSH_CLIENT}");
    for entry in [
        home.as_str(),
        "SHELL=/bin/sh",
        "USER=login",
        "LOGNAME=login",
        "PATH=/login/bin:/usr/bin:/bin",
        "FROM_LOGIN=yes",
        "COLORTERM=truecolor",
        "TERM_PROGRAM=ghostty",
        "TERM_PROGRAM_VERSION=1.2.3",
        "LANG=en_GB.UTF-8",
        "LC_CTYPE=UTF-8",
        ssh_connection.as_str(),
        ssh_client.as_str(),
    ] {
        assert!(contains(lines, entry), "{entry} in {lines:?}");
    }
    assert!(!contains(lines, "TERM=dumb"), "{lines:?}");
    let names = names(lines);
    for absent in [
        "SECRET",
        "SSH_TTY",
        "FROM_DAEMON",
        "WORKROOM_SESSION_RESOURCES",
        "WORKROOM_SESSION_SHELL",
    ] {
        assert!(
            !names.contains(&absent),
            "{absent} reached the session: {lines:?}"
        );
    }
    assert!(
        !lines.iter().any(|line| line.contains("/Users/mac")),
        "{lines:?}"
    );
}

/// No terminfo at the daemon's resources (a tmpfs `/run` lost it on reboot): a plain terminal
/// type, and no shell integration that would need Ghostty's files.
#[test]
fn without_ghosttys_terminfo_on_the_host_the_session_is_xterm_256color_without_integration() {
    let scratch = Scratch::new("plain");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let lines = session_environment(&host);
    assert!(contains(&lines, "TERM=xterm-256color"), "{lines:?}");
    let names = names(&lines);
    for absent in [
        "TERMINFO",
        "GHOSTTY_SHELL_FEATURES",
        "GHOSTTY_RESOURCES_DIR",
    ] {
        assert!(
            !names.contains(&absent),
            "{absent} without terminfo: {lines:?}"
        );
    }
}

/// The bootstrap's terminfo is at the daemon's resources: Ghostty's terminal type, its terminfo
/// and its shell integration.
#[test]
fn with_ghosttys_terminfo_on_the_host_the_session_is_xterm_ghostty_with_integration() {
    let scratch = Scratch::new("ghostty");
    let resources = scratch.0.join("ghostty");
    std::fs::create_dir_all(resources.join("terminfo/x")).unwrap();
    std::fs::write(resources.join("terminfo/x/xterm-ghostty"), b"compiled").unwrap();
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let lines = session_environment(&host);
    for entry in [
        "TERM=xterm-ghostty".to_string(),
        format!("TERMINFO={}/terminfo", resources.display()),
        "GHOSTTY_SHELL_FEATURES=cursor,sudo,title".to_string(),
        format!("GHOSTTY_RESOURCES_DIR={}", resources.display()),
    ] {
        assert!(contains(&lines, &entry), "{entry} in {lines:?}");
    }
}

/// The account's shell starts as a login shell, so its profile runs as an ssh login's did.
#[test]
fn a_dialed_shell_is_the_accounts_login_shell_and_runs_its_profile() {
    let scratch = Scratch::new("login");
    std::fs::write(scratch.home().join(".profile"), "echo PROFILE-RAN\n").unwrap();
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let mut child = host.dial(&MAC).spawn().expect("attach");
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"echo LOGIN=$0\nexit\n").unwrap();
    let output = child.wait_with_output().expect("attach");
    let seen = String::from_utf8_lossy(&output.stdout);
    assert!(seen.contains("PROFILE-RAN"), "{seen:?}");
    assert!(seen.contains("LOGIN=-sh"), "{seen:?}");
}

/// A pty standing in for libghostty's, at `rows` x `columns`: (the side the test types into, the
/// side the client's stdin is).
fn pty(rows: u16, columns: u16) -> (OwnedFd, OwnedFd) {
    let (mut primary, mut secondary) = (-1, -1);
    let mut size = libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: every pointer is to a live local; openpty writes the two descriptors.
    let rc = unsafe {
        libc::openpty(
            &mut primary,
            &mut secondary,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    assert_eq!(rc, 0, "openpty: {}", std::io::Error::last_os_error());
    // SAFETY: openpty succeeded, so both are open descriptors this test now owns.
    unsafe {
        (
            OwnedFd::from_raw_fd(primary),
            OwnedFd::from_raw_fd(secondary),
        )
    }
}

fn resize(primary: &OwnedFd, rows: u16, columns: u16) {
    let size = libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ reads one `winsize` through the pointer, which is a live local.
    let rc = unsafe { libc::ioctl(primary.as_raw_fd(), libc::TIOCSWINSZ, &size) };
    assert_eq!(rc, 0, "TIOCSWINSZ: {}", std::io::Error::last_os_error());
}

/// The session is created at the pane's size, and a resized pane resizes it, as `Resize` frames
/// through the dialed link.
#[test]
fn a_resized_pane_resizes_the_dialed_session() {
    let scratch = Scratch::new("resize");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let (primary, secondary) = pty(30, 100);
    let mut command = host.dial(&MAC);
    command.stdin(Stdio::from(secondary));
    let mut child = Spawned(command.spawn().expect("attach"));
    let mut output = ClientReader::new(&mut child);
    let mut typing = std::fs::File::from(primary.try_clone().unwrap());

    typing.write_all(b"stty size\n").unwrap();
    let seen = output
        .read_until("30 100", Duration::from_secs(10))
        .to_string();
    assert!(
        seen.contains("30 100"),
        "created at the pane's size: {seen:?}"
    );

    resize(&primary, 40, 120);
    let resized = common::wait_for(Duration::from_secs(10), || {
        typing.write_all(b"stty size\n").unwrap();
        output
            .read_until("40 120", Duration::from_millis(300))
            .contains("40 120")
    });
    assert!(resized, "{:?}", output.read_until("", Duration::ZERO));
}

/// ADR 0070's probe passes through the dialed client to the pane's terminal, whose answer comes
/// back as input the daemon takes out, so a pane that answers stays attached.
#[test]
fn the_keepalive_probe_passes_through_a_dialed_client_and_its_answer_keeps_it_attached() {
    if !common::has_terminal_state() {
        return;
    }
    let scratch = Scratch::new("probe");
    let store = SessionStore::with_keepalive_interval(Duration::from_millis(100));
    let host = Host::serve(&scratch, store.clone(), &DAEMON);
    let mut env = MAC.to_vec();
    env.push((KEEPALIVE_VARIABLE, "1"));
    let mut child = Spawned(host.dial(&env).spawn().expect("attach"));
    let mut output = ClientReader::new(&mut child);
    let mut answers = child.stdin.take().unwrap();
    let probe = String::from_utf8(KEEPALIVE_PROBE.to_vec()).unwrap();

    let mut probes = 0;
    let deadline = Instant::now() + Duration::from_secs(10);
    while probes < 5 && Instant::now() < deadline {
        // Reads for the whole wait: `read_until` stops at a needle already seen.
        let seen = output.read_until("\0never", Duration::from_millis(200));
        probes = seen.matches(probe.as_str()).count();
        answers.write_all(b"\x1b[?25930;0$y").unwrap();
    }
    assert!(probes >= 5, "the probe reached the pane {probes} times");
    let id = parse_session_id(OsStr::new(SESSION)).unwrap();
    let attached = store
        .list()
        .iter()
        .any(|info| info.id == SessionId(id.0) && info.attached);
    assert!(attached, "an answering pane counts as attached");
}

/// A session that ends with 255 must not read as a dropped link, which the app retries.
#[test]
fn a_dialed_session_that_exits_255_ends_with_254() {
    let scratch = Scratch::new("exit");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let mut env = MAC.to_vec();
    env.push(("WORKROOM_SESSION_COMMAND", "/bin/sh -c 'exit 255'"));
    let output = host.dial(&env).output().expect("attach");
    assert_eq!(output.status.code(), Some(254));
}

/// The link drops mid-session: the client exits 255 for the app to attach again, and the session
/// carries on on the host.
#[test]
fn a_dialed_link_that_drops_exits_255_and_leaves_the_session_running() {
    let scratch = Scratch::new("drop");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let pid = scratch.0.join("relay.pid");
    // `<&0`: a non-interactive shell gives a background command /dev/null for stdin otherwise.
    let relay = format!(
        "/usr/bin/env -i HOME='{}' SHELL=/bin/sh PATH=/usr/bin:/bin '{}' relay --socket '{}' <&0 & echo $! > '{}'; wait",
        scratch.home().display(),
        daemon_binary().display(),
        host.socket.display(),
        pid.display()
    );
    let mut child = Spawned(
        Command::new(daemon_binary())
            .args(["attach", "--dial", "/bin/sh", "-c", &relay])
            .env_clear()
            .envs(MAC)
            .env("WORKROOM_SESSION_ID", SESSION)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("attach"),
    );
    let mut output = ClientReader::new(&mut child);
    let mut typing = child.stdin.take().unwrap();
    typing.write_all(b"echo READY\n").unwrap();
    let seen = output
        .read_until("READY", Duration::from_secs(10))
        .to_string();
    assert!(seen.contains("READY"), "{seen:?}");

    let pid: i32 = std::fs::read_to_string(&pid)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // SAFETY: kill only signals; the pid is this test's relay.
    unsafe { libc::kill(pid, libc::SIGKILL) };
    let status = child.wait().expect("wait");
    assert_eq!(status.code(), Some(255));
    assert_eq!(host.store.list().len(), 1, "the session outlives its link");
}

/// A local pane is unchanged: it hands its whole environment to the session.
#[test]
fn a_local_attach_still_hands_the_session_its_whole_environment() {
    let scratch = Scratch::new("local");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let output = Command::new(daemon_binary())
        .args(["attach", "--socket"])
        .arg(&host.socket)
        .env_clear()
        .envs(MAC)
        .env("WORKROOM_SESSION_ID", SESSION)
        .env("WORKROOM_SESSION_SHELL", "/bin/sh")
        .env("WORKROOM_SESSION_COMMAND", "env")
        .stdin(Stdio::null())
        .output()
        .expect("attach");
    let seen = String::from_utf8_lossy(&output.stdout);
    for entry in [
        "SECRET=from-the-mac",
        "HOME=/Users/mac",
        "SSH_TTY=/dev/ttys004",
    ] {
        assert!(seen.contains(entry), "{entry} in {seen:?}");
    }
}

/// The daemon holds the Mac's variables to the allowlist itself, whatever a client sends.
#[test]
fn a_host_attach_that_sends_more_than_the_allowlist_still_reaches_the_shell_with_only_it() {
    let scratch = Scratch::new("raw");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let stream = std::os::unix::net::UnixStream::connect(&host.socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let mut client = common::RpcClient::over(stream.try_clone().unwrap(), stream);
    client.handshake();
    let entry = |key: &str, value: &str| (OsString::from(key), OsString::from(value));
    let request = AttachRequest {
        id: parse_session_id(OsStr::new(SESSION)),
        command: Some("/bin/sh -c 'echo; env; echo END-OF-ENV'".into()),
        env: vec![
            entry("SECRET", "from-the-mac"),
            entry("PATH", "/opt/homebrew/bin"),
            entry("LANG", "en_GB.UTF-8"),
        ],
        host_environment: true,
        ..Default::default()
    };
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, request.encode()),
    );
    let seen = client.read_until("END-OF-ENV", Duration::from_secs(10));
    assert!(seen.contains("LANG=en_GB.UTF-8"), "{seen:?}");
    assert!(seen.contains("PATH=/host/bin:/usr/bin:/bin"), "{seen:?}");
    assert!(!seen.contains("SECRET"), "{seen:?}");
    assert!(!seen.contains("/opt/homebrew/bin"), "{seen:?}");
}

/// This process's own account entry, as `getpwuid` gives it: (home, shell).
fn own_account() -> (String, String) {
    // SAFETY: getpwuid returns a pointer into static storage, read at once on this thread.
    unsafe {
        let entry = libc::getpwuid(libc::geteuid());
        assert!(!entry.is_null(), "no passwd entry for this user");
        let text =
            |p: *const libc::c_char| std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
        (text((*entry).pw_dir), text((*entry).pw_shell))
    }
}

/// A real `workroomd serve`, as a host runs it, reached by a relay with no login environment to
/// pass on: the session's `HOME` and `SHELL` come from the account entry, not the daemon's
/// environment, and Ghostty's resources are beside its socket. A command session, so no shell or
/// profile of the developer's runs.
#[test]
fn a_served_daemon_takes_home_and_shell_from_the_account_and_resources_beside_its_socket() {
    let scratch = Scratch::new("served");
    let socket = scratch.0.join("d.sock");
    let resources = scratch.0.join("ghostty");
    std::fs::create_dir_all(resources.join("terminfo/x")).unwrap();
    std::fs::write(resources.join("terminfo/x/xterm-ghostty"), b"compiled").unwrap();
    let _daemon = Spawned(
        Command::new(daemon_binary())
            .args(["serve", "--socket"])
            .arg(&socket)
            .args(["--idle-timeout", "never"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", "/wrong/home")
            .env("SHELL", "/wrong/shell")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("serve"),
    );
    assert!(common::wait_for(Duration::from_secs(5), || socket.exists()));
    let mut env = MAC.to_vec();
    env.push(("WORKROOM_SESSION_COMMAND", "/bin/sh -c 'echo; exec env'"));
    let cwd = scratch.0.to_string_lossy().into_owned();
    env.push(("WORKROOM_SESSION_CWD", cwd.as_str()));
    let output = Command::new(daemon_binary())
        .args(["attach", "--dial", "/usr/bin/env", "-i"])
        .arg(daemon_binary())
        .args(["relay", "--socket"])
        .arg(&socket)
        .env_clear()
        .env("WORKROOM_SESSION_ID", SESSION)
        .envs(env)
        .stdin(Stdio::null())
        .output()
        .expect("attach");
    let seen = String::from_utf8_lossy(&output.stdout);
    let (home, shell) = own_account();
    for entry in [
        format!("HOME={home}\r"),
        format!("SHELL={shell}\r"),
        format!("TERMINFO={}/terminfo\r", resources.display()),
    ] {
        assert!(seen.contains(&entry), "{entry:?} in {seen:?}");
    }
    // Ended by this test, not left running: the daemon never idles out.
    let _ = common::control(&socket, Frame::control(FrameKind::KillAll));
}

/// A restored remote pane whose session has ended, attached with its stdin held open as a pane's
/// is: what it shows by the time the daemon has closed its connection (so its `relay` has exited),
/// which it must do while the pane still shows it. A pane with no keepalive and no deadline
/// otherwise kept a relay and a daemon connection for as long as it stayed open.
fn ended_pane_closes_its_connection(host: &Host) -> String {
    let mut child = Spawned(
        host.dial_with(&["--no-create"], &MAC)
            .spawn()
            .expect("attach"),
    );
    let mut output = ClientReader::new(&mut child);
    let _stdin = child.stdin.take().unwrap();
    // Shown first, so the connection has been made and answered before it is counted.
    output.read_until("Close it to start again", Duration::from_secs(10));
    let closed = common::wait_for(Duration::from_secs(5), || {
        host.connections.load(Ordering::SeqCst) == 0
    });
    let seen = output
        .read_until("\0never", Duration::from_millis(300))
        .to_string();
    assert!(seen.contains("Close it to start again"), "{seen:?}");
    assert!(closed, "the ended pane's connection stayed open: {seen:?}");
    assert!(
        child.try_wait().unwrap().is_none(),
        "the pane stopped showing its end: {seen:?}"
    );
    seen
}

/// A restored remote pane whose session ended and left no record is refused, and the daemon then
/// closes the connection: the pane says so and holds, with no relay behind it.
#[test]
fn a_refused_restored_remote_pane_has_its_connection_closed() {
    let scratch = Scratch::new("refused");
    let host = Host::serve(&scratch, SessionStore::new(), &DAEMON);
    let seen = ended_pane_closes_its_connection(&host);
    assert_eq!(
        seen.matches("Close it to start again").count(),
        1,
        "{seen:?}"
    );
}

/// A restored remote pane shown the record of a session that ended with its host (#232): once
/// the screen is out, the daemon closes the connection, and the pane keeps the screen with its one
/// notice, rather than reading the close as a lost link to attach again.
#[test]
fn a_restored_remote_pane_shown_its_record_has_its_connection_closed() {
    if !cfg!(feature = "terminal-state") {
        eprintln!("skipping: built without the terminal-state feature, so no record repaints");
        return;
    }
    let scratch = Scratch::new("record");
    let store = SessionStore::new();
    store
        .hooks()
        .screens
        .keep(Screens::open(&scratch.0.join("screens")).expect("records"));
    let id = parse_session_id(OsStr::new(SESSION)).unwrap();
    store
        .hooks()
        .screens
        .get()
        .expect("screens")
        .save(SessionId(id.0), 80, 24, b"RECORD-MARK\r\n$ ")
        .expect("record");
    let host = Host::serve(&scratch, store, &DAEMON);
    let seen = ended_pane_closes_its_connection(&host);
    assert!(seen.contains("RECORD-MARK"), "{seen:?}");
    assert_eq!(
        seen.matches("Close it to start again").count(),
        1,
        "{seen:?}"
    );
}
