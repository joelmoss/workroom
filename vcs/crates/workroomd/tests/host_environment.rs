//! A real daemon whose inherited PATH has no git. Remote writes, diffs and the file listing must
//! all find the host profile's git, while a local exec still gets only the client's environment.
//! A daemon started as the Mac starts its own must never probe the profile for ordinary reads.
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};

struct Workspace(PathBuf);

impl Workspace {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("wrhe-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

fn executable(path: &Path, script: &str) {
    // As run_script's script helper: forked tests must not inherit a writable executable fd.
    let draft = path.with_extension("draft");
    std::fs::write(&draft, script).unwrap();
    assert!(
        Command::new("cp")
            .arg(&draft)
            .arg(path)
            .status()
            .unwrap()
            .success()
    );
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn git(root: &Path, args: &[&str]) -> String {
    let output = Command::new("/usr/bin/git")
        .current_dir(root)
        .args(args)
        .env_clear()
        .envs([
            ("PATH", "/usr/bin:/bin"),
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_CONFIG_SYSTEM", "/dev/null"),
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output.stderr);
    String::from_utf8(output.stdout).unwrap()
}

fn request(socket: &Path, service: Service, request: Value) -> Value {
    let mut stream = UnixStream::connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();
    stream
        .write_all(&Hello::current("host-environment-test").encode())
        .unwrap();
    let mut greeting = Vec::new();
    while Hello::decode(&greeting).unwrap().is_none() {
        let mut byte = [0];
        stream.read_exact(&mut byte).unwrap();
        greeting.push(byte[0]);
    }
    stream
        .write_all(&Envelope::new(service, 1, serde_json::to_vec(&request).unwrap()).encode())
        .unwrap();
    let mut decoder = EnvelopeDecoder::new();
    let mut assembled = Vec::new();
    loop {
        while let Some(envelope) = decoder.next_envelope().unwrap() {
            let (last, body) = envelope.payload.split_first().unwrap();
            assembled.extend_from_slice(body);
            if *last == 1 {
                let reply: Value = serde_json::from_slice(&assembled).unwrap();
                assert!(reply.get("error").is_none(), "{reply}");
                return reply["result"].clone();
            }
        }
        let mut buffer = [0; 65536];
        let count = stream.read(&mut buffer).unwrap();
        assert!(count > 0, "daemon closed without a reply");
        decoder.push(&buffer[..count]);
    }
}

#[test]
fn host_profile_git_reaches_exec_diffs_and_file_listing_and_is_read_only_once() {
    let workspace = Workspace::new("remote");
    let root = workspace.0.join("repo");
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    std::fs::write(root.join("tracked"), "before\n").unwrap();
    git(&root, &["add", "tracked"]);
    git(
        &root,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=t@example.com",
            "commit",
            "-qm",
            "first",
        ],
    );
    let revision = git(&root, &["rev-parse", "HEAD"]).trim().to_string();
    std::fs::write(root.join("tracked"), "after\n").unwrap();
    let bin = workspace.0.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let shell = workspace.0.join("bash");
    let count = workspace.0.join("probes");
    executable(
        &shell,
        &format!(
            "#!/bin/sh\necho probe >> {}\nexport FROM_PROFILE=host\nexport PATH={}:$PATH\nexport GIT_DIR=/wrong/repo\nexport GIT_CONFIG_GLOBAL=/dev/null\nexport GIT_CONFIG_SYSTEM=/dev/null\nexec /bin/sh -c \"$2\"\n",
            quote(&count),
            quote(&bin),
        ),
    );
    executable(
        &bin.join("git"),
        "#!/bin/sh\ntest \"$FROM_PROFILE\" = host || exit 91\ntest \"${GIT_DIR-unset}\" = unset || exit 92\ntest \"$GIT_TERMINAL_PROMPT\" = 0 || exit 93\nexec /usr/bin/git \"$@\"\n",
    );
    let socket = workspace.0.join("d.sock");
    let binary = std::env::var_os("WORKROOMD_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_workroomd")));
    let _daemon = Daemon(
        Command::new(binary)
            .args(["serve", "--socket"])
            .arg(&socket)
            .args(["--idle-timeout", "never"])
            .env_clear()
            .env("HOME", &workspace.0)
            .env("SHELL", &shell)
            .env("PATH", "/does-not-have-git")
            .env("USER", "fixture")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(socket.exists());
    let alias = "alias.profile=!printf '%s' \"$FROM_PROFILE\"";
    let local = request(
        &socket,
        Service::Vcs,
        json!({
            "version":1, "kind":"exec", "executable":"git", "args":["-c",alias,"profile"],
            "dir":root, "timeout_ms":5000, "env":{"PATH":"/usr/bin:/bin","FROM_PROFILE":"client"},
        }),
    );
    assert_eq!(local["stdout"], "client");
    assert!(!count.exists(), "local exec must not read a host profile");
    let remote = request(
        &socket,
        Service::Vcs,
        json!({
            "version":1, "kind":"exec", "executable":"git", "args":["-c",alias,"profile"],
            "dir":root, "timeout_ms":5000, "host_environment":true, "env":{},
        }),
    );
    assert_eq!(remote["exit_code"], 0);
    assert_eq!(remote["stdout"], "host");
    // Subsequent reads cannot obtain a fresh profile; they must reuse the exec's successful read.
    std::fs::remove_file(&shell).unwrap();
    for (method, extra) in [
        ("working_status", json!({})),
        ("working_file_diff", json!({"path":"tracked"})),
        ("changeset", json!({"revision":revision})),
        ("file_diff", json!({"revision":revision,"path":"tracked"})),
    ] {
        let mut read = json!({"version":1,"method":method,"backend":"git","root":root});
        read.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let result = request(&socket, Service::Vcs, read);
        assert!(
            result.to_string().contains("tracked") || result.to_string().contains("after"),
            "{method}: {result}"
        );
    }
    let listing = request(
        &socket,
        Service::File,
        json!({"version":1,"method":"list","backend":"git","root":root}),
    );
    assert!(listing.to_string().contains("tracked"), "{listing}");
    assert_eq!(std::fs::read_to_string(count).unwrap(), "probe\n");
}

#[test]
fn local_daemon_reads_and_file_listing_keep_the_apps_environment_without_probing_a_profile() {
    let workspace = Workspace::new("local");
    let root = workspace.0.join("repo");
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    std::fs::write(root.join("tracked"), "before\n").unwrap();
    git(&root, &["add", "tracked"]);
    git(
        &root,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=t@example.com",
            "commit",
            "-qm",
            "first",
        ],
    );
    std::fs::write(root.join("tracked"), "after\n").unwrap();
    let bin = workspace.0.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let shell = workspace.0.join("bash");
    let sentinel = workspace.0.join("profile-was-launched");
    executable(
        &shell,
        &format!("#!/bin/sh\necho probed > {}\nexit 17\n", quote(&sentinel)),
    );
    // A profile failure would fall back to this same environment. The sentinel below must still
    // catch that redundant probe, rather than only asserting that the eventual listing worked.
    executable(
        &bin.join("git"),
        "#!/bin/sh\ntest \"$FROM_APP\" = inherited || exit 91\ntest \"$GIT_TERMINAL_PROMPT\" = 0 || exit 92\ntest \"$LC_ALL\" = C || exit 93\nexec /usr/bin/git \"$@\"\n",
    );
    let socket = workspace.0.join("d.sock");
    let binary = std::env::var_os("WORKROOMD_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_workroomd")));
    let _daemon = Daemon(
        Command::new(binary)
            // Exactly the local app's lifetime: it supplies no --idle-timeout flag.
            .args(["serve", "--socket"])
            .arg(&socket)
            .env_clear()
            .env("HOME", &workspace.0)
            .env("SHELL", &shell)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("USER", "fixture")
            .env("FROM_APP", "inherited")
            .env("GIT_TERMINAL_PROMPT", "1")
            .env("LC_ALL", "C.UTF-8")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(socket.exists());
    for method in ["log", "working_status", "working_file_diff"] {
        let result = request(
            &socket,
            Service::Vcs,
            json!({
                "version":1,"method":method,"backend":"git","root":root,"path":"tracked",
            }),
        );
        assert!(!result.is_null(), "{method}: {result}");
    }
    let listing = request(
        &socket,
        Service::File,
        json!({
            "version":1,"method":"list","backend":"git","root":root,
        }),
    );
    assert!(listing.to_string().contains("tracked"), "{listing}");
    assert!(
        !sentinel.exists(),
        "an ordinary local read launched the login profile"
    );
}
