//! `update` against a fake releases server on 127.0.0.1 and a binary in a temporary install
//! folder: never GitHub, and never an installed workroom.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use super::*;

/// Each path's status and body.
type Routes = HashMap<String, (u16, Vec<u8>)>;

/// (baked channel, `--channel`, config's channel, what `update` acts on and whether by choice).
type Case = (
    Option<&'static str>,
    Option<&'static str>,
    &'static str,
    Option<(Channel, bool)>,
);

/// A releases server: each path (query included) answers with a status and a body, and every
/// request's path is recorded.
struct Server {
    base: String,
    routes: Arc<Mutex<Routes>>,
    hits: Arc<Mutex<Vec<String>>>,
}

impl Server {
    fn start() -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let base = format!("http://{}", listener.local_addr().expect("addr"));
        let routes: Arc<Mutex<Routes>> = Arc::default();
        let hits: Arc<Mutex<Vec<String>>> = Arc::default();
        let (served, recorded) = (routes.clone(), hits.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { break };
                answer(stream, &served, &recorded);
            }
        });
        Server { base, routes, hits }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }

    fn route(&self, path: &str, status: u16, body: impl Into<Vec<u8>>) {
        self.routes
            .lock()
            .unwrap()
            .insert(path.to_string(), (status, body.into()));
    }

    fn hits(&self) -> Vec<String> {
        self.hits.lock().unwrap().clone()
    }

    /// The releases API this server stands in for.
    fn releases(&self) -> String {
        self.url("/repos/joelmoss/workroom/releases")
    }
}

fn answer(stream: TcpStream, routes: &Mutex<Routes>, hits: &Mutex<Vec<String>>) {
    let mut reader = BufReader::new(stream);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() {
        return;
    }
    loop {
        let mut header = String::new();
        match reader.read_line(&mut header) {
            Ok(0) | Err(_) => break,
            Ok(_) if header == "\r\n" => break,
            Ok(_) => {}
        }
    }
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_string();
    hits.lock().unwrap().push(path.clone());
    let (status, body) = routes
        .lock()
        .unwrap()
        .get(&path)
        .cloned()
        .unwrap_or((404, b"not found".to_vec()));
    let mut stream = reader.into_inner();
    // A redirect's body is where it points, as GitHub's downloads redirect to its CDN.
    if (300..400).contains(&status) {
        let _ = write!(
            stream,
            "HTTP/1.1 {status} X\r\nLocation: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            String::from_utf8_lossy(&body)
        );
        return;
    }
    let _ = write!(
        stream,
        "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(&body);
}

/// A gzipped tar holding `workroom` with `contents`, beside a README, as goreleaser packs one.
fn archive(contents: &[u8]) -> Vec<u8> {
    let mut tar = tar::Builder::new(flate2::write::GzEncoder::new(
        Vec::new(),
        flate2::Compression::fast(),
    ));
    for (name, data) in [("README.md", b"readme".as_slice()), ("workroom", contents)] {
        let mut header = tar::Header::new_gnu();
        header.set_size(data.len() as u64);
        header.set_mode(0o755);
        header.set_cksum();
        tar.append_data(&mut header, name, data).unwrap();
    }
    tar.into_inner().unwrap().finish().unwrap()
}

/// A release's JSON as GitHub writes it, with an asset for each (name, url).
fn release(tag: &str, name: &str, draft: bool, assets: &[(&str, String)]) -> serde_json::Value {
    serde_json::json!({
        "tag_name": tag,
        "name": name,
        "draft": draft,
        "prerelease": tag.contains('-'),
        "assets": assets
            .iter()
            .map(|(name, url)| serde_json::json!({"name": name, "browser_download_url": url}))
            .collect::<Vec<_>>(),
    })
}

/// Publishes `version`'s archive (holding `contents`) and its checksums.txt on `server`, as a
/// release tagged `tag`, and returns the release's JSON.
fn publish(server: &Server, tag: &str, version: &str, contents: &[u8]) -> serde_json::Value {
    let asset = format!("workroom_{version}_linux_arm64.tar.gz");
    let bytes = archive(contents);
    let sums = format!(
        "{}  workroom_{version}_darwin_arm64.tar.gz\n{}  {asset}\n",
        "0".repeat(64),
        sha256_hex(&bytes)
    );
    server.route(&format!("/download/{tag}/{asset}"), 200, bytes);
    server.route(&format!("/download/{tag}/checksums.txt"), 200, sums);
    release(
        tag,
        "",
        false,
        &[
            (
                &format!("workroom_{version}_darwin_arm64.tar.gz"),
                server.url(&format!("/download/{tag}/other")),
            ),
            (&asset, server.url(&format!("/download/{tag}/{asset}"))),
            (
                "checksums.txt",
                server.url(&format!("/download/{tag}/checksums.txt")),
            ),
        ],
    )
}

/// A throwaway install: `bin/workroom`, a symlink to `libexec/workroom-real`, as an install
/// through a link has it, and the config.json beside them.
struct Install {
    dir: PathBuf,
}

impl Install {
    /// A directory this run made itself: `create_dir` fails on any existing path, so a killed
    /// run's leftovers or another run's live install are skipped, never reused or removed, and
    /// `Drop` removes only what this call created (AGENTS.md's deletion rule).
    fn new(name: &str) -> Install {
        let parent = std::env::temp_dir();
        let pid = std::process::id();
        let dir = (0u32..)
            .map(|attempt| parent.join(format!("workroom-update-{name}-{pid}-{attempt}")))
            .find(|dir| match fs::create_dir(dir) {
                Ok(()) => true,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => false,
                Err(error) => panic!("create {}: {error}", dir.display()),
            })
            .expect("a free name");
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::create_dir_all(dir.join("libexec")).unwrap();
        let dir = dir.canonicalize().unwrap();
        let real = dir.join("libexec/workroom-real");
        fs::write(&real, b"old binary").unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o751)).unwrap();
        symlink("../libexec/workroom-real", dir.join("bin/workroom")).unwrap();
        Install { dir }
    }

    fn link(&self) -> PathBuf {
        self.dir.join("bin/workroom")
    }

    fn real(&self) -> PathBuf {
        self.dir.join("libexec/workroom-real")
    }

    fn config(&self) -> PathBuf {
        self.dir.join("config.json")
    }

    fn installed(&self) -> Vec<u8> {
        fs::read(self.real()).unwrap()
    }

    /// Every file in the install's folders, so a test can tell nothing was left behind.
    fn files(&self) -> Vec<String> {
        let mut files = Vec::new();
        for dir in ["bin", "libexec"] {
            for entry in fs::read_dir(self.dir.join(dir)).unwrap() {
                files.push(format!(
                    "{dir}/{}",
                    entry.unwrap().file_name().to_string_lossy()
                ));
            }
        }
        files.sort();
        files
    }

    fn updater<'a>(&self, server: &Server, version: &'a str) -> Updater<'a> {
        Updater {
            releases: server.releases(),
            version,
            baked: None,
            target: Target {
                os: "linux",
                arch: "arm64",
            },
            executable: Ok(self.link()),
            config: Config::at(self.config()),
            pretend: false,
            verbose: false,
        }
    }
}

impl Drop for Install {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn plain(check: bool) -> Request<'static> {
    Request {
        check,
        channel: None,
    }
}

/// What a run printed, or its error.
fn printed(outcome: Outcome) -> Result<String, (String, CliError)> {
    match outcome {
        Outcome::Printed(text) => Ok(text),
        Outcome::Failed(error) => Err((String::new(), error)),
        Outcome::PrintedThenFailed(text, error) => Err((text, error)),
        Outcome::Success(_) => panic!("update prints text, never an envelope"),
        Outcome::PrintedWithWarnings { .. } => panic!("update prints no warnings beside its text"),
        Outcome::Usage(_) => panic!("update's arguments are checked before it runs"),
    }
}

#[test]
fn stable_installs_githubs_latest_release_through_the_symlink() {
    let server = Server::start();
    let latest = publish(&server, "v1.4.0", "1.4.0", b"new binary");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("stable");
    // A process running the old binary holds its file open; the swap must not change what it
    // reads (a rename, not a rewrite in place).
    let mut running = fs::File::open(install.real()).unwrap();

    let out = printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap();

    assert_eq!(
        out,
        "Checking the stable channel...\nUpdate available: v1.3.0 \u{2192} v1.4.0\n\
         Updated workroom v1.3.0 \u{2192} v1.4.0\n"
    );
    assert_eq!(install.installed(), b"new binary");
    assert!(fs::symlink_metadata(install.link()).unwrap().is_symlink());
    assert_eq!(
        fs::metadata(install.real()).unwrap().permissions().mode() & 0o777,
        0o751
    );
    assert_eq!(install.files(), ["bin/workroom", "libexec/workroom-real"]);
    let mut old = String::new();
    running.read_to_string(&mut old).unwrap();
    assert_eq!(old, "old binary");
    assert_eq!(server.hits()[0], "/repos/joelmoss/workroom/releases/latest");
    // An implicit channel is never written to config.
    assert!(!install.config().exists());
}

/// The latest release as `publish` makes it on `cdn`, but with each asset's download URL on
/// `server`, answered with a redirect to `cdn`, as GitHub redirects to its CDN.
fn redirected_through(server: &Server, cdn: &Server, contents: &[u8]) {
    let latest = publish(cdn, "v1.4.0", "1.4.0", contents);
    let mut on_github = latest.clone();
    for asset in on_github["assets"].as_array_mut().unwrap() {
        let at_cdn = asset["browser_download_url"].as_str().unwrap().to_string();
        let path = at_cdn.strip_prefix(&cdn.base).unwrap().to_string();
        server.route(&format!("/github{path}"), 302, at_cdn);
        asset["browser_download_url"] = server.url(&format!("/github{path}")).into();
    }
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        on_github.to_string(),
    );
}

/// GitHub answers each asset's download URL with a redirect, which is followed. (Here to the same
/// fake server, the one plain-http origin a test may reach.)
#[test]
fn downloads_follow_redirects() {
    let server = Server::start();
    redirected_through(&server, &server, b"redirected");
    let install = Install::new("redirect");

    printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap();

    assert_eq!(install.installed(), b"redirected");
    let hits = server.hits();
    for path in [
        "/github/download/v1.4.0/checksums.txt",
        "/download/v1.4.0/checksums.txt",
        "/download/v1.4.0/workroom_1.4.0_linux_arm64.tar.gz",
    ] {
        assert!(hits.contains(&path.to_string()), "{path}: {hits:?}");
    }
}

/// A redirect that leaves https (here: to plain http anywhere but the test's releases server) is
/// refused, and nothing is fetched from where it points.
#[test]
fn a_redirect_to_plain_http_is_refused() {
    let server = Server::start();
    let cdn = Server::start();
    redirected_through(&server, &cdn, b"from the cdn");
    let install = Install::new("redirect-http");

    let (_, error) = printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap_err();

    assert_eq!(error.kind, Kind::InternalError);
    assert!(
        error.message.starts_with("failed to download update: Get ")
            && error.message.contains(&format!(
                "refused a redirect to \"{}/download/v1.4.0/",
                cdn.base
            ))
            && error.message.ends_with("not an https URL"),
        "{}",
        error.message
    );
    assert_eq!(cdn.hits(), Vec::<String>::new());
    assert_eq!(install.installed(), b"old binary");
    assert_eq!(install.files(), ["bin/workroom", "libexec/workroom-real"]);
}

/// Production reaches nothing but https; only a test's own plain-http releases origin is exempt.
#[test]
fn only_https_is_reachable_in_production() {
    let production = Web::for_releases(RELEASES_API);
    assert_eq!(production.http_origin, None);
    assert!(production.allows("https://objects.githubusercontent.com/x"));
    assert!(production.allows("HTTPS://api.github.com/"));
    assert!(!production.allows("http://api.github.com/repos/joelmoss/workroom/releases"));
    assert!(!production.allows("ftp://api.github.com/"));
    let error = production
        .get("http://127.0.0.1:9/", None)
        .err()
        .expect("refused");
    assert_eq!(
        error,
        "Get \"http://127.0.0.1:9/\": refused: not an https URL"
    );

    let test = Web::for_releases("http://127.0.0.1:4000/repos/joelmoss/workroom/releases");
    assert_eq!(test.http_origin.as_deref(), Some("http://127.0.0.1:4000"));
    assert!(test.allows("http://127.0.0.1:4000/download/x"));
    assert!(!test.allows("http://127.0.0.1:4001/download/x"));
    assert!(!test.allows("http://127.0.0.1:4000@evil.example/x"));
}

#[test]
fn a_redirect_is_absolute_or_a_path_on_the_same_origin() {
    let from = "https://github.com/joelmoss/workroom/releases/download/v1/a.tar.gz?x=1";
    for (location, want) in [
        (
            "https://cdn.example/a?sig=http://x",
            Some("https://cdn.example/a?sig=http://x"),
        ),
        ("//cdn.example/a", Some("https://cdn.example/a")),
        (
            "/other?x=http://y",
            Some("https://github.com/other?x=http://y"),
        ),
        ("relative/a", None),
    ] {
        assert_eq!(
            redirect_target(from, location).as_deref(),
            want,
            "{location}"
        );
    }
    assert_eq!(
        origin("https://a.example:8443"),
        Some("https://a.example:8443")
    );
    assert_eq!(origin("/path?u=http://x"), None);
    assert_eq!(origin("https:///path"), None);
}

/// The https client is wired up (ring as rustls's provider, the platform's verifier): it sends a
/// TLS ClientHello, which takes both, and a server that then hangs up fails the request as an
/// error, not a panic. On a Linux host with no CA bundle the verifier can't be built, so no hello
/// is sent and the request fails closed, saying so.
#[test]
fn an_https_request_reaches_the_tls_handshake() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("addr");
    // The first byte of the first TLS record the client sends, then a hang-up.
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .expect("timeout");
        let mut header = [0u8; 5];
        stream.read_exact(&mut header).ok()?;
        let mut record = vec![0u8; usize::from(u16::from_be_bytes([header[3], header[4]]))];
        stream.read_exact(&mut record).ok()?;
        Some(header[0])
    });

    let error = Web::for_releases(RELEASES_API)
        .get(&format!("https://{address}/"), None)
        .err()
        .expect("a server that hangs up fails the request");

    let first_record = server.join().unwrap();
    assert!(
        error.starts_with(&format!("Get \"https://{address}/\": ")),
        "{error}"
    );
    // 0x16: a handshake record, the ClientHello.
    assert!(
        first_record == Some(0x16)
            || (cfg!(target_os = "linux")
                && error.contains("No CA certificates were loaded from the system")),
        "{first_record:?}: {error}"
    );
}

#[test]
fn an_up_to_date_install_is_left_alone() {
    let server = Server::start();
    let latest = publish(&server, "v1.3.0", "1.3.0", b"same");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("current");
    let out = printed(install.updater(&server, "1.3.0").run(&plain(false))).unwrap();
    assert_eq!(
        out,
        "Checking the stable channel...\nAlready up-to-date (1.3.0)\n"
    );
    assert_eq!(install.installed(), b"old binary");
}

#[test]
fn pre_installs_the_newest_stable_or_prerelease_and_is_remembered() {
    let server = Server::start();
    let list = serde_json::json!([
        release(
            "nightly",
            "2.1.0-nightly.99",
            false,
            &[("workroom_nightly_linux_arm64.tar.gz", server.url("/n"))]
        ),
        release("appcast", "", false, &[]),
        publish(&server, "v2.0.0-beta.21", "2.0.0-beta.21", b"beta 21"),
        publish(&server, "v1.3.0", "1.3.0", b"stable"),
        publish(&server, "v2.0.0-beta.5", "2.0.0-beta.5", b"beta 5"),
        release(
            "v2.0.0-draft",
            "",
            true,
            &[("workroom_2.0.0-draft_linux_arm64.tar.gz", server.url("/d"))]
        ),
    ]);
    server.route(
        "/repos/joelmoss/workroom/releases?per_page=100",
        200,
        list.to_string(),
    );
    let install = Install::new("pre");
    fs::write(install.config(), r#"{"channel":"stable","other":1.50}"#).unwrap();

    let out = printed(install.updater(&server, "v1.3.0").run(&Request {
        check: false,
        channel: Some("pre"),
    }))
    .unwrap();

    assert!(out.contains("v1.3.0 \u{2192} v2.0.0-beta.21\n"), "{out}");
    assert_eq!(install.installed(), b"beta 21");
    assert_eq!(
        fs::read_to_string(install.config()).unwrap(),
        "{\n  \"channel\": \"pre\",\n  \"other\": 1.50\n}"
    );
}

#[test]
fn an_explicit_switch_may_downgrade() {
    let server = Server::start();
    let latest = publish(&server, "v1.3.0", "1.3.0", b"stable");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("downgrade");
    fs::write(install.config(), r#"{"channel":"pre"}"#).unwrap();

    let out = printed(install.updater(&server, "v2.0.0-beta.21").run(&Request {
        check: false,
        channel: Some("stable"),
    }))
    .unwrap();

    assert!(
        out.contains(
            "Switching to the stable channel: v2.0.0-beta.21 \u{2192} v1.3.0 (downgrade)\n"
        ),
        "{out}"
    );
    assert_eq!(install.installed(), b"stable");
    assert_eq!(
        fs::read_to_string(install.config()).unwrap(),
        "{\n  \"channel\": \"stable\"\n}"
    );
}

#[test]
fn nightly_follows_the_fixed_release_by_its_commit_count() {
    let server = Server::start();
    let asset = "workroom_nightly_linux_arm64.tar.gz";
    let bytes = archive(b"nightly 941");
    // A nightly published by the workflow's earlier `sha256sum ./*` names each file with `./`.
    let sums = format!("{}  ./{asset}\n", sha256_hex(&bytes));
    server.route("/nightly/archive", 200, bytes);
    server.route("/nightly/checksums.txt", 200, sums);
    let nightly = release(
        "nightly",
        "2.0.0-nightly.941",
        false,
        &[
            (asset, server.url("/nightly/archive")),
            ("checksums.txt", server.url("/nightly/checksums.txt")),
        ],
    );
    server.route(
        "/repos/joelmoss/workroom/releases/tags/nightly",
        200,
        nightly.to_string(),
    );
    let install = Install::new("nightly");
    // A higher base but a lower count is older.
    let mut updater = install.updater(&server, "2.1.0-nightly.940");
    updater.baked = Some("nightly");

    let out = printed(updater.run(&plain(false))).unwrap();

    assert_eq!(
        out,
        "Checking the nightly channel...\nUpdate available: 2.1.0-nightly.940 \u{2192} 2.0.0-nightly.941\n\
         Updated workroom 2.1.0-nightly.940 \u{2192} 2.0.0-nightly.941\n"
    );
    assert_eq!(install.installed(), b"nightly 941");
    // The Nightly build's channel is its own; nothing is remembered.
    assert!(!install.config().exists());
    // And it refuses a switch.
    let (_, error) = printed(updater.run(&Request {
        check: false,
        channel: Some("pre"),
    }))
    .unwrap_err();
    assert!(
        error.message.contains("always tracks the nightly channel"),
        "{error:?}"
    );
}

#[test]
fn a_checksum_mismatch_installs_nothing() {
    let server = Server::start();
    let latest = publish(&server, "v1.4.0", "1.4.0", b"new binary");
    // The archive served is not the one checksums.txt describes.
    server.route(
        "/download/v1.4.0/workroom_1.4.0_linux_arm64.tar.gz",
        200,
        archive(b"tampered"),
    );
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("mismatch");

    let (out, error) = printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap_err();

    assert_eq!(error.kind, Kind::InternalError);
    assert!(
        error
            .message
            .starts_with("checksum mismatch for workroom_1.4.0_linux_arm64.tar.gz (expected "),
        "{}",
        error.message
    );
    assert!(
        out.ends_with("Update available: v1.3.0 \u{2192} v1.4.0\n"),
        "{out}"
    );
    assert_eq!(install.installed(), b"old binary");
    assert_eq!(install.files(), ["bin/workroom", "libexec/workroom-real"]);
}

#[test]
fn an_archive_without_the_binary_installs_nothing() {
    let server = Server::start();
    let latest = publish(&server, "v1.4.0", "1.4.0", b"x");
    // Verified, but with no binary in it.
    let asset = "workroom_1.4.0_linux_arm64.tar.gz";
    let bytes = {
        let mut tar = tar::Builder::new(flate2::write::GzEncoder::new(
            Vec::new(),
            flate2::Compression::fast(),
        ));
        let mut header = tar::Header::new_gnu();
        header.set_size(1);
        header.set_cksum();
        tar.append_data(&mut header, "README.md", b"x".as_slice())
            .unwrap();
        tar.into_inner().unwrap().finish().unwrap()
    };
    server.route(
        "/download/v1.4.0/checksums.txt",
        200,
        format!("{}  {asset}\n", sha256_hex(&bytes)),
    );
    server.route(&format!("/download/v1.4.0/{asset}"), 200, bytes);
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("no-binary");

    let (_, error) = printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap_err();

    assert_eq!(
        error.message,
        "failed to extract update: binary \"workroom\" not found in archive"
    );
    assert_eq!(install.installed(), b"old binary");
    assert_eq!(install.files(), ["bin/workroom", "libexec/workroom-real"]);
}

/// The latest release, `v1.4.0`, published without its checksums.txt.
fn publish_unverifiable(server: &Server) {
    let mut latest = publish(server, "v1.4.0", "1.4.0", b"unverified");
    latest["assets"]
        .as_array_mut()
        .unwrap()
        .retain(|asset| asset["name"] != "checksums.txt");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
}

/// A release without checksums.txt is refused before its archive is downloaded (Go installed it
/// with a warning), under `--pretend` too, and an explicit switch to it isn't remembered.
#[test]
fn a_release_without_checksums_is_not_installed() {
    let server = Server::start();
    publish_unverifiable(&server);
    let install = Install::new("unverifiable");
    fs::write(install.config(), r#"{"channel":"pre"}"#).unwrap();

    for pretend in [false, true] {
        let mut updater = install.updater(&server, "v1.3.0");
        updater.pretend = pretend;
        let (out, error) = printed(updater.run(&Request {
            check: false,
            channel: Some("stable"),
        }))
        .unwrap_err();

        assert_eq!(
            out,
            "Checking the stable channel...\nUpdate available: v1.3.0 \u{2192} v1.4.0\n"
        );
        assert_eq!(
            (error.kind, error.message.as_str()),
            (
                Kind::InternalError,
                "release v1.4.0 has no checksums.txt, so its archive can't be verified \
                 \u{2014} not installing it"
            )
        );
    }
    assert_eq!(
        server.hits(),
        ["/repos/joelmoss/workroom/releases/latest"; 2]
    );
    assert_eq!(install.installed(), b"old binary");
    assert_eq!(install.files(), ["bin/workroom", "libexec/workroom-real"]);
    assert_eq!(
        fs::read_to_string(install.config()).unwrap(),
        r#"{"channel":"pre"}"#
    );
}

/// `--check` still reports a newer release that has no checksums.txt, saying `update` won't
/// install it.
#[test]
fn check_says_an_unverifiable_release_cant_be_installed() {
    let server = Server::start();
    publish_unverifiable(&server);
    let install = Install::new("check-unverifiable");

    let out = printed(install.updater(&server, "v1.3.0").run(&plain(true))).unwrap();

    assert_eq!(
        out,
        "Checking the stable channel...\nUpdate available: v1.3.0 \u{2192} v1.4.0\n\
         It can't be verified (its release has no checksums.txt), so 'workroom update' won't \
         install it\n"
    );
}

/// A file already at the staged name (a crashed run's of the same pid, or anyone's) isn't this
/// run's: the update fails and leaves it, and the binary, as they were.
#[test]
fn a_file_at_the_staged_name_survives_a_failed_update() {
    let server = Server::start();
    let latest = publish(&server, "v1.4.0", "1.4.0", b"new binary");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("staged");
    let foreign = install.dir.join(format!(
        "libexec/.workroom-real.update-{}",
        std::process::id()
    ));
    fs::write(&foreign, b"not update's").unwrap();

    let (_, error) = printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap_err();

    assert!(
        error.message.starts_with(&format!(
            "failed to replace binary: cannot write in {}: ",
            install.dir.join("libexec").display()
        )),
        "{}",
        error.message
    );
    assert_eq!(fs::read(&foreign).unwrap(), b"not update's");
    assert_eq!(install.installed(), b"old binary");
}

#[test]
fn check_reports_without_installing_or_writing_config() {
    let server = Server::start();
    let latest = publish(&server, "v1.4.0", "1.4.0", b"new");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("check");

    let out = printed(install.updater(&server, "v1.3.0").run(&Request {
        check: true,
        channel: Some("stable"),
    }))
    .unwrap();

    assert_eq!(
        out,
        "Checking the stable channel...\nUpdate available: v1.3.0 \u{2192} v1.4.0\n\
         Run 'workroom update' to install\n"
    );
    assert_eq!(install.installed(), b"old binary");
    assert!(!install.config().exists());
    let dev = printed(install.updater(&server, "dev").run(&plain(true))).unwrap();
    assert_eq!(dev, "Running dev build \u{2014} cannot check for updates\n");
}

#[test]
fn pretend_installs_and_remembers_nothing() {
    let server = Server::start();
    let latest = publish(&server, "v1.4.0", "1.4.0", b"new");
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        200,
        latest.to_string(),
    );
    let install = Install::new("pretend");
    let mut updater = install.updater(&server, "v1.3.0");
    updater.pretend = true;
    let out = printed(updater.run(&Request {
        check: false,
        channel: Some("stable"),
    }))
    .unwrap();
    assert!(
        out.ends_with("(pretend) Would download and install v1.4.0\n"),
        "{out}"
    );
    assert_eq!(install.installed(), b"old binary");
    assert!(!install.config().exists());
}

#[test]
fn a_failing_api_is_an_internal_error() {
    let server = Server::start();
    server.route(
        "/repos/joelmoss/workroom/releases/latest",
        403,
        "rate limited",
    );
    let install = Install::new("api-error");
    let (out, error) = printed(install.updater(&server, "v1.3.0").run(&plain(false))).unwrap_err();
    assert_eq!(out, "Checking the stable channel...\n");
    assert_eq!(
        (error.kind, error.message.as_str()),
        (Kind::InternalError, "GitHub API returned status 403")
    );
}

/// Inside an app bundle and in a host's daemon directory, `update` refuses before it asks the
/// network anything, dev build or not.
#[test]
fn a_managed_install_is_refused_with_managed_install() {
    let server = Server::start();
    for (layout, sentence) in [
        (
            "Workroom.app/Contents/Resources/workroom",
            "bundled inside the Workroom app",
        ),
        (
            ".local/state/workroom/daemon/workroomd",
            "the daemon the Workroom app installed",
        ),
        (
            "bin/workroomd.new.1a2b3c4d",
            "the daemon the Workroom app installed",
        ),
    ] {
        for version in ["v1.3.0", "dev"] {
            let install = Install::new("managed");
            let binary = install.dir.join(layout);
            fs::create_dir_all(binary.parent().unwrap()).unwrap();
            fs::write(&binary, b"managed").unwrap();
            // Reached through a link elsewhere, as the app's /usr/local/bin link reaches it.
            let link = install.dir.join("bin/linked");
            let _ = fs::remove_file(&link);
            symlink(&binary, &link).unwrap();
            let mut updater = install.updater(&server, version);
            updater.executable = Ok(link);

            let (out, error) = printed(updater.run(&plain(false))).unwrap_err();

            assert_eq!(out, "", "{layout}");
            assert_eq!(error.kind, Kind::ManagedInstall, "{layout}");
            assert!(
                error.message.contains(sentence),
                "{layout}: {}",
                error.message
            );
            assert_eq!(fs::read(&binary).unwrap(), b"managed");
        }
    }
    assert_eq!(server.hits(), Vec::<String>::new());
}

#[test]
fn a_binary_beside_the_daemons_socket_is_managed() {
    let install = Install::new("socket");
    assert_eq!(managed(&install.real()), None);
    fs::write(install.dir.join("libexec/workroomd.sock"), b"").unwrap();
    assert_eq!(managed(&install.real()), Some(Manager::DaemonDirectory));
    // A standalone install's names aren't.
    assert_eq!(
        managed(Path::new("/home/me/.local/bin/workroom-nightly")),
        None
    );
    assert_eq!(managed(Path::new("/home/me/.local/bin/workroomdx")), None);
}

#[test]
fn a_dev_build_is_not_updated() {
    let server = Server::start();
    let install = Install::new("dev");
    let (_, error) = printed(install.updater(&server, "dev").run(&plain(false))).unwrap_err();
    assert_eq!(
        error.message,
        "cannot update a dev build \u{2014} install from a release instead"
    );
    assert_eq!(server.hits(), Vec::<String>::new());
}

// --- Go's tables (`cmd/update_channel_test.go`, `internal/updater/updater_test.go`) ---

#[test]
fn resolve_channel_follows_the_binarys_identity() {
    use Channel::{Nightly, Pre, Stable};
    let cases: &[Case] = &[
        (Some("nightly"), None, "", Some((Nightly, false))),
        (Some("nightly"), Some("stable"), "", None),
        (None, Some("stable"), "", Some((Stable, true))),
        (None, Some("pre"), "", Some((Pre, true))),
        (None, Some("nightly"), "", None),
        (None, Some("bogus"), "", None),
        (None, Some(""), "", None),
        (None, None, "stable", Some((Stable, false))),
        (None, None, "pre", Some((Pre, false))),
        (None, None, "nightly", Some((Stable, false))),
        (None, None, "", Some((Stable, false))),
        (None, None, "bogus", Some((Stable, false))),
    ];
    for (baked, flag, configured, want) in cases {
        let got = resolve_channel(*baked, *flag, configured).ok();
        assert_eq!(
            got, *want,
            "baked {baked:?} flag {flag:?} config {configured:?}"
        );
    }
    assert_eq!(
        resolve_channel(None, Some("nightly"), "").unwrap_err(),
        NIGHTLY_SEPARATE_INSTALL
    );
}

#[test]
fn is_newer_is_semver_precedence() {
    for (current, latest, want) in [
        ("1.0.0", "1.0.1", true),
        ("1.0.0", "1.1.0", true),
        ("1.0.0", "2.0.0", true),
        ("1.2.3", "1.2.3", false),
        ("2.0.0", "1.0.0", false),
        ("v1.0.0", "1.0.1", true),
        ("v1.0.0", "v1.0.1", true),
        ("v1.0.0", "v1.0.0", false),
        ("dev", "1.0.0", false),
        ("1.0.0", "bad", false),
        ("1.0.0-rc.1", "1.0.0", true),
        ("1.0.0", "1.0.0-rc.1", false),
        ("1.0.0-beta.2", "1.0.0-rc.1", true),
        ("2.0.0-beta.1", "2.0.0-beta.2", true),
        ("2.0.0-nightly.10", "2.0.0-nightly.11", true),
        ("2.0.0-beta.1", "2.0.1", true),
        // x/mod/semver's own rules.
        ("v1", "v1.0.1", true),
        ("v1.2", "v1.2.0", false),
        ("1.0.0-beta.9", "1.0.0-beta.10", true),
        ("1.0.0-beta", "1.0.0-beta.1", true),
        ("1.0.0-1", "1.0.0-alpha", true),
        ("1.0.0+build.1", "1.0.0+build.2", false),
        ("1.0.0", "01.0.1", false),
        ("1.0.0", "1.0.1-01", false),
        ("1.0.0", "1.0.1-", false),
        // `21-5-gabc1234` is alphanumeric, so it sorts after any number.
        ("v2.0.0-beta.21-5-gabc1234", "v2.0.0-beta.22", false),
    ] {
        assert_eq!(
            is_newer(current, latest),
            want,
            "is_newer({current:?}, {latest:?})"
        );
    }
}

#[test]
fn nightly_orders_by_commit_count() {
    for (current, candidate, want) in [
        ("2.0.0-nightly.900", "2.0.0-nightly.901", true),
        ("2.0.0-nightly.900", "2.0.0-nightly.900", false),
        ("2.1.0-nightly.900", "2.0.0-nightly.901", true),
        ("1.3.0", "2.0.0-nightly.5", true),
    ] {
        assert_eq!(
            is_newer_in_channel(Channel::Nightly, current, candidate),
            want
        );
    }
    assert!(is_newer_in_channel(Channel::Stable, "1.0.0", "1.0.1"));
    assert!(is_newer_in_channel(
        Channel::Pre,
        "2.0.0-beta.2",
        "2.0.0-rc.1"
    ));
    for (version, want) in [
        ("2.0.0-nightly.941", Some(941)),
        ("v2.0.0-nightly.1", Some(1)),
        ("2.0.0-beta.1", None),
        ("1.3.0", None),
        ("2.0.0-nightly.x", None),
    ] {
        assert_eq!(nightly_build(version), want, "{version}");
    }
}

#[test]
fn checksums_name_each_file_bare_or_with_dot_slash() {
    let sums = "aaa  workroom_1_linux_arm64.tar.gz\nbbb  ./workroom_nightly_linux_arm64.tar.gz\nccc  other\n";
    assert_eq!(
        checksum_for(sums, "workroom_1_linux_arm64.tar.gz").as_deref(),
        Some("aaa")
    );
    assert_eq!(
        checksum_for(sums, "workroom_nightly_linux_arm64.tar.gz").as_deref(),
        Some("bbb")
    );
    assert_eq!(checksum_for(sums, "missing"), None);
}

#[test]
fn the_archive_names_os_and_arch_as_go_does() {
    let target = Target::current();
    assert!(["darwin", "linux"].contains(&target.os), "{}", target.os);
    assert!(["amd64", "arm64"].contains(&target.arch), "{}", target.arch);
}
