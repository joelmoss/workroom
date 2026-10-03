//! The agent's credential broker client (#251) against a stand-in broker on loopback, and its git
//! configuration against real git.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde_json::Value;
use wr_agent::broker::{self, BrokerError};

/// A temporary directory standing in for the agent's own, removed when the test ends.
struct Workspace {
    dir: std::path::PathBuf,
}

impl Workspace {
    fn new(name: &str) -> Workspace {
        let dir = std::env::temp_dir().join(format!("wr-agent-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Workspace { dir }
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// One request the stand-in broker received.
#[derive(Debug, Clone)]
struct Received {
    path: String,
    proof: String,
    body: String,
}

impl Received {
    fn claims(&self) -> Value {
        part(&self.proof, 1)
    }

    fn jwk(&self) -> Value {
        part(&self.proof, 0)["jwk"].clone()
    }

    /// Verifies the proof's signature with the key in its own header, as `Broker::Proof` does.
    fn proof_verifies(&self) -> bool {
        let jwk = self.jwk();
        let coordinate = |name: &str| URL_SAFE_NO_PAD.decode(jwk[name].as_str().unwrap()).unwrap();
        let point = [&[4u8][..], &coordinate("x"), &coordinate("y")].concat();
        let key = ring::signature::UnparsedPublicKey::new(
            &ring::signature::ECDSA_P256_SHA256_FIXED,
            point,
        );
        let (input, signature) = self.proof.rsplit_once('.').unwrap();
        key.verify(
            input.as_bytes(),
            &URL_SAFE_NO_PAD.decode(signature).unwrap(),
        )
        .is_ok()
    }
}

/// A scripted answer: status, extra headers, JSON body.
type Response = (u16, Vec<(&'static str, String)>, String);

fn part(jwt: &str, index: usize) -> Value {
    let segment = jwt.split('.').nth(index).unwrap();
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(segment).unwrap()).unwrap()
}

/// A broker on 127.0.0.1 that answers each request with the next scripted response and records
/// what it was sent. `Connection: close` on every answer, so each request is its own connection.
struct Broker {
    url: String,
    received: Arc<Mutex<Vec<Received>>>,
}

impl Broker {
    fn start(responses: Vec<Response>) -> Broker {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let received = Arc::new(Mutex::new(Vec::new()));
        let log = received.clone();
        std::thread::spawn(move || {
            for (response, stream) in responses.into_iter().zip(listener.incoming()) {
                let mut stream = stream.unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request_line = String::new();
                reader.read_line(&mut request_line).unwrap();
                let path = request_line.split_whitespace().nth(1).unwrap().to_string();
                let (mut proof, mut length) = (String::new(), 0);
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let line = line.trim_end();
                    if line.is_empty() {
                        break;
                    }
                    let (name, value) = line.split_once(": ").unwrap();
                    match name.to_ascii_lowercase().as_str() {
                        "dpop" => proof = value.to_string(),
                        "content-length" => length = value.parse().unwrap(),
                        _ => {}
                    }
                }
                let mut body = vec![0; length];
                reader.read_exact(&mut body).unwrap();
                log.lock().unwrap().push(Received {
                    path,
                    proof,
                    body: String::from_utf8(body).unwrap(),
                });

                let (status, headers, body) = response;
                let mut answer = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n",
                    body.len()
                );
                for (name, value) in headers {
                    answer.push_str(&format!("{name}: {value}\r\n"));
                }
                answer.push_str("\r\n");
                answer.push_str(&body);
                stream.write_all(answer.as_bytes()).unwrap();
            }
        });
        Broker { url, received }
    }

    fn received(&self) -> Vec<Received> {
        self.received.lock().unwrap().clone()
    }
}

/// The broker's answer to an enrolment.
fn enrolled_answer() -> Response {
    (201, vec![], r#"{"grant_id":"g","repository_id":1}"#.into())
}

fn ok(body: &str) -> Response {
    (200, vec![], body.to_string())
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

/// `date -u` for a unix time: BSD's `-r <seconds>`, else GNU's `-d @<seconds>` (GNU's `-r` names a
/// file, and fails rather than failing to start). In the C locale, since an HTTP `Date` uses the
/// English day and month names whatever the machine's `LC_TIME`.
fn date(unix: i64, format: &str) -> String {
    let run = |args: &[&str]| {
        Command::new("date")
            .env("LC_ALL", "C")
            .args(args)
            .output()
            .ok()
    };
    let seconds = unix.to_string();
    let gnu = format!("@{unix}");
    let output = run(&["-u", "-r", &seconds, format])
        .filter(|o| o.status.success())
        .or_else(|| run(&["-u", "-d", &gnu, format]))
        .unwrap();
    assert!(output.status.success(), "date failed");
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

/// Rails' `iso8601` for a unix time, in UTC.
fn iso8601(unix: i64) -> String {
    date(unix, "+%Y-%m-%dT%H:%M:%SZ")
}

fn enrolled(workspace: &Workspace, broker: &Broker, workroom: &str) {
    broker::enrol(&workspace.dir, workroom, &broker.url, "the-code\n").unwrap();
}

#[test]
fn enrolment_registers_a_new_key_with_the_code() {
    let workspace = Workspace::new("broker-enrol");
    let broker = Broker::start(vec![enrolled_answer()]);

    enrolled(&workspace, &broker, "wr-1");

    let received = broker.received();
    assert_eq!(received.len(), 1);
    let request = &received[0];
    assert_eq!(request.path, "/broker/enrolments");
    assert!(request.proof_verifies());
    assert_eq!(
        request.claims()["htu"],
        format!("{}/broker/enrolments", broker.url)
    );
    assert_eq!(request.claims()["htm"], "POST");
    let body: Value = serde_json::from_str(&request.body).unwrap();
    assert_eq!(body["code"], "the-code");
    assert_eq!(body["workroom_id"], "wr-1");

    let mode = std::fs::metadata(workspace.dir.join("broker.json")).unwrap();
    assert_eq!(
        std::os::unix::fs::PermissionsExt::mode(&mode.permissions()) & 0o777,
        0o600
    );
}

/// The broker refuses any key it has seen (`AgentsController#enrol`: "This key is already
/// enrolled", cancelled grants included). An enrolment whose answer was lost after the broker
/// registered its key must still recover when the Mac retries with a new code.
#[test]
fn a_retried_enrolment_uses_a_new_key_whatever_happened_to_the_last() {
    let workspace = Workspace::new("broker-retry");
    let broker = Broker::start(vec![
        (503, vec![], r#"{"error":"broker_unavailable"}"#.into()),
        enrolled_answer(),
    ]);

    assert!(broker::enrol(&workspace.dir, "wr-1", &broker.url, "first").is_err());
    assert!(
        matches!(broker::token(&workspace.dir), Err(BrokerError::NotEnrolled)),
        "a half-finished enrolment is not an enrolment"
    );
    broker::enrol(&workspace.dir, "wr-1", &broker.url, "second").unwrap();

    let received = broker.received();
    assert_ne!(received[0].jwk(), received[1].jwk());
}

#[test]
fn enrolling_again_replaces_the_key_and_its_token() {
    let workspace = Workspace::new("broker-re-enrol");
    let expires = iso8601(now() + 3600);
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"old-token","expires_at":"{expires}"}}"#
        )),
        enrolled_answer(),
    ]);

    enrolled(&workspace, &broker, "the-base");
    broker::token(&workspace.dir).unwrap();
    assert!(workspace.dir.join("broker-token.json").exists());

    enrolled(&workspace, &broker, "the-fork");

    let received = broker.received();
    assert_eq!(received.len(), 3, "the second enrolment asked the broker");
    assert_ne!(received[0].jwk(), received[2].jwk(), "with a new key");
    assert!(
        !workspace.dir.join("broker-token.json").exists(),
        "the old key's token is gone"
    );
}

#[test]
fn a_refused_enrolment_reports_the_brokers_code() {
    let workspace = Workspace::new("broker-refused");
    let broker = Broker::start(vec![(
        401,
        vec![],
        r#"{"error":"invalid_code","message":"The enrolment code is unknown, used or expired"}"#
            .into(),
    )]);

    let error = broker::enrol(&workspace.dir, "wr-1", &broker.url, "old").unwrap_err();
    match error {
        BrokerError::Refused { status, code, .. } => {
            assert_eq!((status, code.as_str()), (401, "invalid_code"))
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
    assert!(matches!(
        broker::token(&workspace.dir),
        Err(BrokerError::NotEnrolled)
    ));
}

#[test]
fn a_token_is_minted_once_and_then_served_from_the_cache() {
    let workspace = Workspace::new("broker-token");
    let expires_at = now() + 3600;
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_one","expires_at":"{}"}}"#,
            iso8601(expires_at)
        )),
    ]);
    enrolled(&workspace, &broker, "wr-1");

    let first = broker::token(&workspace.dir).unwrap();
    let second = broker::token(&workspace.dir).unwrap();

    assert_eq!(first.token, "ghs_one");
    assert_eq!(first.expires_at, expires_at);
    assert_eq!(first, second);
    let received = broker.received();
    assert_eq!(received.len(), 2, "the second answer came from the cache");
    assert_eq!(received[1].path, "/broker/tokens");
    assert_eq!(
        received[1].jwk(),
        received[0].jwk(),
        "signed with the enrolled key"
    );
    assert!(received[1].proof_verifies());
}

/// A clock an hour fast: the retry is dated on the broker's clock, and the skew is kept with the
/// token, so it is not judged expired the moment it arrives and git is told a local expiry.
#[test]
fn a_stale_proof_is_retried_once_and_its_skew_kept_with_the_token() {
    let workspace = Workspace::new("broker-skew");
    let server_now = now() - 3700;
    let broker = Broker::start(vec![
        enrolled_answer(),
        (
            401,
            vec![("Date", date(server_now, "+%a, %d %b %Y %H:%M:%S GMT"))],
            r#"{"error":"stale_proof","message":"proof iat is outside the 60 s window"}"#.into(),
        ),
        ok(&format!(
            r#"{{"token":"ghs_skewed","expires_at":"{}"}}"#,
            iso8601(server_now + 3600)
        )),
    ]);
    enrolled(&workspace, &broker, "wr-1");

    assert_eq!(broker::token(&workspace.dir).unwrap().token, "ghs_skewed");
    let received = broker.received();
    let retried = received[2].claims()["iat"].as_i64().unwrap();
    assert!(
        (retried - server_now).abs() <= 2,
        "the retry's iat ({retried}) follows the broker's clock ({server_now})"
    );
    assert_ne!(received[1].claims()["jti"], received[2].claims()["jti"]);

    let mut output = Vec::new();
    broker::credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\n\n"[..],
        &mut output,
    )
    .unwrap();
    assert_eq!(
        broker.received().len(),
        3,
        "served from the cache, not re-minted"
    );
    let text = String::from_utf8(output).unwrap();
    let expiry: i64 = text
        .lines()
        .find_map(|l| l.strip_prefix("password_expiry_utc="))
        .unwrap()
        .parse()
        .unwrap();
    assert!(
        (expiry - (now() + 3600)).abs() <= 3,
        "git is told the expiry on this machine's clock"
    );
}

/// Lets the next `token()` ask the broker again, as it would once the backoff has passed.
fn end_backoff(workspace: &Workspace) {
    let path = workspace.dir.join("broker-token.json");
    let mut token: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    token["retry_after"] = 0.into();
    std::fs::write(&path, token.to_string()).unwrap();
}

#[test]
fn a_cached_token_outlives_a_broker_outage_but_not_a_refusal() {
    let workspace = Workspace::new("broker-outage");
    // Inside the refresh margin, so the next call asks the broker first.
    let expires_at = now() + 120;
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_cached","expires_at":"{}"}}"#,
            iso8601(expires_at)
        )),
        (503, vec![], r#"{"error":"github_unavailable"}"#.into()),
        (429, vec![], r#"{"error":"rate_limited"}"#.into()),
        (
            410,
            vec![],
            r#"{"error":"grant_ended","message":"This workroom's grant has ended"}"#.into(),
        ),
    ]);
    enrolled(&workspace, &broker, "wr-1");
    broker::token(&workspace.dir).unwrap();

    assert_eq!(
        broker::token(&workspace.dir).unwrap().token,
        "ghs_cached",
        "an outage falls back to the token still in date"
    );
    assert_eq!(
        broker::token(&workspace.dir).unwrap().token,
        "ghs_cached",
        "and backs off"
    );
    assert_eq!(broker.received().len(), 3, "the backoff asked nobody");

    end_backoff(&workspace);
    assert_eq!(
        broker::token(&workspace.dir).unwrap().token,
        "ghs_cached",
        "so does a rate limit"
    );
    end_backoff(&workspace);
    match broker::token(&workspace.dir) {
        Err(BrokerError::Refused { code, .. }) => assert_eq!(code, "grant_ended"),
        other => panic!("a refusal is final, got {other:?}"),
    }
}

#[test]
fn the_credential_helper_answers_github_over_https_and_nothing_else() {
    let workspace = Workspace::new("broker-credential");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_helper","expires_at":"{}"}}"#,
            iso8601(now() + 3600)
        )),
    ]);
    enrolled(&workspace, &broker, "wr-1");

    let mut output = Vec::new();
    broker::credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\npath=joelmoss/workroom.git\n\n"[..],
        &mut output,
    )
    .unwrap();
    let text = String::from_utf8(output).unwrap();
    assert!(
        text.starts_with("username=x-access-token\npassword=ghs_helper\n"),
        "{text}"
    );
    assert!(text.contains("password_expiry_utc="));

    for (action, input) in [
        ("get", &b"protocol=https\nhost=gitlab.com\n\n"[..]),
        ("get", &b"protocol=http\nhost=github.com\n\n"[..]),
        (
            "store",
            &b"protocol=https\nhost=github.com\npassword=x\n\n"[..],
        ),
        ("erase", &b"protocol=https\nhost=github.com\n\n"[..]),
    ] {
        let mut output = Vec::new();
        broker::credential(&workspace.dir, action, input, &mut output).unwrap();
        assert!(
            output.is_empty(),
            "{action} {:?}",
            String::from_utf8_lossy(input)
        );
    }
    assert_eq!(
        broker.received().len(),
        2,
        "only the one get asked the broker"
    );
}

/// boxd's two lines as system config, and a stand-in for its helper on PATH (design doc,
/// Phase 0 item 4). Returns what `git credential fill` answers for github.com.
fn fill(workspace: &Path, configure: bool) -> String {
    let system = workspace.join("system.gitconfig");
    std::fs::write(
        &system,
        "[credential \"https://github.com\"]\n\thelper = boxd\n\
         [url \"https://github.com/\"]\n\tinsteadof = git@github.com:\n",
    )
    .unwrap();
    let global = workspace.join("global.gitconfig");
    let _ = std::fs::remove_file(&global);
    std::fs::write(&global, "").unwrap();
    let helper = |name: &str, password: &str| {
        let path = workspace.join(name);
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\ntest \"$1\" = get && printf 'username=u\\npassword={password}\\n'\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        path
    };
    helper("git-credential-boxd", "boxd");
    let workroom = helper("workroom helper", "workroom");

    let path = format!(
        "{}:{}",
        workspace.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let git = || {
        let mut command = Command::new("git");
        command
            .env("GIT_CONFIG_SYSTEM", &system)
            .env("GIT_CONFIG_GLOBAL", &global)
            .env("PATH", &path)
            .env("GIT_TERMINAL_PROMPT", "0");
        command
    };
    if configure {
        let command = broker::helper_command(&workroom).replace(" credential", "");
        broker::configure_git(git, &command).unwrap();
        // Idempotent: a second enrolment leaves one reset and one helper, not two of each.
        broker::configure_git(git, &command).unwrap();
        let listed = git()
            .args([
                "config",
                "--global",
                "--get-all",
                "credential.https://github.com.helper",
            ])
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8(listed.stdout).unwrap().lines().count(),
            2,
            "the reset and the helper"
        );
    }
    let mut child = git()
        .args(["credential", "fill"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"protocol=https\nhost=github.com\n\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn the_agents_helper_beats_a_providers_system_helper() {
    let workspace = Workspace::new("broker-git-config");
    assert!(
        fill(&workspace.dir, false).contains("password=boxd"),
        "the control: boxd's helper answers when nothing is configured"
    );
    let answer = fill(&workspace.dir, true);
    assert!(answer.contains("password=workroom"), "{answer}");
}

#[test]
fn enrolment_refuses_a_broker_that_is_not_https_or_loopback_and_empty_inputs() {
    let workspace = Workspace::new("broker-bad-input");
    for broker_url in [
        "http://codaset.dev",
        "http://127.0.0.1:@evil.example",
        "http://127.0.0.1.evil.example",
        "https://user@codaset.dev",
        "https://codaset.dev/elsewhere",
        "ftp://codaset.dev",
        "codaset.dev",
    ] {
        assert!(
            matches!(
                broker::enrol(&workspace.dir, "wr-1", broker_url, "code"),
                Err(BrokerError::Invalid(_))
            ),
            "{broker_url}"
        );
    }
    for (workroom, code) in [("", "code"), ("wr-1", " \n")] {
        assert!(matches!(
            broker::enrol(&workspace.dir, workroom, "https://codaset.dev", code),
            Err(BrokerError::Invalid(_))
        ));
    }
    assert!(
        !workspace.dir.join("broker.json").exists(),
        "nothing written"
    );
}

#[test]
fn a_success_status_that_is_not_the_brokers_answer_is_not_an_enrolment() {
    let workspace = Workspace::new("broker-maintenance");
    let broker = Broker::start(vec![(200, vec![], "<html>Maintenance</html>".into())]);

    assert!(matches!(
        broker::enrol(&workspace.dir, "wr-1", &broker.url, "code"),
        Err(BrokerError::Invalid(_))
    ));
    assert!(matches!(
        broker::token(&workspace.dir),
        Err(BrokerError::NotEnrolled)
    ));
}

#[test]
fn a_malformed_or_expired_token_answer_is_refused() {
    let workspace = Workspace::new("broker-bad-token");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(r#"{"token":"","expires_at":"2099-01-01T00:00:00Z"}"#),
        ok(r#"{"token":"ghs_x","expires_at":"soon"}"#),
        ok(r#"{"token":"ghs_x","expires_at":"2001-01-01T00:00:00Z"}"#),
    ]);
    enrolled(&workspace, &broker, "wr-1");

    for _ in 0..3 {
        assert!(matches!(
            broker::token(&workspace.dir),
            Err(BrokerError::Invalid(_))
        ));
    }
}

/// A final refusal removes the cached token, so a later outage cannot bring it back.
#[test]
fn a_final_refusal_forgets_the_cached_token() {
    let workspace = Workspace::new("broker-refusal-forgets");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_denied","expires_at":"{}"}}"#,
            iso8601(now() + 120)
        )),
        (410, vec![], r#"{"error":"grant_ended"}"#.into()),
        (503, vec![], r#"{"error":"github_unavailable"}"#.into()),
    ]);
    enrolled(&workspace, &broker, "wr-1");
    broker::token(&workspace.dir).unwrap();

    assert!(broker::token(&workspace.dir).is_err());
    match broker::token(&workspace.dir) {
        Err(BrokerError::Refused { code, .. }) => assert_eq!(code, "github_unavailable"),
        other => panic!("the refused token came back: {other:?}"),
    }
}

/// A proxy's 403 or a rejected proof is not the broker's decision: the token that still works
/// is served.
#[test]
fn a_4xx_without_a_final_code_is_an_outage() {
    let workspace = Workspace::new("broker-proxy-403");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_ok","expires_at":"{}"}}"#,
            iso8601(now() + 120)
        )),
        (403, vec![], "<html>Forbidden</html>".into()),
    ]);
    enrolled(&workspace, &broker, "wr-1");
    broker::token(&workspace.dir).unwrap();

    assert_eq!(broker::token(&workspace.dir).unwrap().token, "ghs_ok");
}

#[test]
fn erase_drops_the_rejected_token_and_only_that_one() {
    let workspace = Workspace::new("broker-erase");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_revoked","expires_at":"{}"}}"#,
            iso8601(now() + 3600)
        )),
    ]);
    enrolled(&workspace, &broker, "wr-1");
    broker::token(&workspace.dir).unwrap();
    let erase = |password: &str| {
        let input = format!("protocol=https\nhost=github.com\npassword={password}\n\n");
        broker::credential(&workspace.dir, "erase", input.as_bytes(), Vec::new()).unwrap();
    };

    erase("some-older-token");
    assert!(
        workspace.dir.join("broker-token.json").exists(),
        "not the cached one"
    );
    erase("ghs_revoked");
    assert!(!workspace.dir.join("broker-token.json").exists());
}

/// A mint still in flight when the workroom enrolled again writes the old key's token; the new
/// key never serves it.
#[test]
fn a_token_cached_for_another_key_is_never_served() {
    let workspace = Workspace::new("broker-other-key");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_old","expires_at":"{}"}}"#,
            iso8601(now() + 3600)
        )),
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_new","expires_at":"{}"}}"#,
            iso8601(now() + 3600)
        )),
    ]);
    enrolled(&workspace, &broker, "wr-a");
    broker::token(&workspace.dir).unwrap();
    let stale = std::fs::read(workspace.dir.join("broker-token.json")).unwrap();
    enrolled(&workspace, &broker, "wr-b");
    std::fs::write(workspace.dir.join("broker-token.json"), stale).unwrap();

    assert_eq!(broker::token(&workspace.dir).unwrap().token, "ghs_new");
}

#[test]
fn an_unreadable_state_file_is_not_an_enrolment() {
    let workspace = Workspace::new("broker-corrupt");
    std::fs::write(workspace.dir.join("broker.json"), "{not json").unwrap();

    assert!(matches!(
        broker::token(&workspace.dir),
        Err(BrokerError::NotEnrolled)
    ));
}

/// A stand-in for the Mac's end of a relay (#309): takes one connection, records what was sent,
/// and answers with `answer`.
fn relay_listener(answer: &'static str) -> (u16, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut sent = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 || line == "\n" {
                break;
            }
            sent.push_str(&line);
        }
        let mut stream = stream;
        stream.write_all(answer.as_bytes()).unwrap();
        sent
    });
    (port, thread)
}

#[test]
fn a_workroom_that_never_enrolled_is_answered_through_the_relay() {
    let workspace = Workspace::new("broker-relay");
    let (port, mac) = relay_listener(
        "protocol=https\nhost=github.com\nusername=joel\npassword=gho_mac\nextra=dropped\n",
    );
    broker::install_relay(&workspace.dir, port, "s3cret\n").unwrap();

    let mut output = Vec::new();
    broker::credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\npath=joelmoss/workroom.git\n\n"[..],
        &mut output,
    )
    .unwrap();
    // Only the credential reaches git, and the Mac gets the secret and a github.com request only.
    assert_eq!(
        String::from_utf8(output).unwrap(),
        "username=joel\npassword=gho_mac\n"
    );
    assert_eq!(
        mac.join().unwrap(),
        "s3cret\nprotocol=https\nhost=github.com\n"
    );

    // Nothing but github.com over HTTPS is ever relayed, and `store`/`erase` ask nothing.
    for (action, input) in [
        ("get", &b"protocol=https\nhost=gitlab.com\n\n"[..]),
        (
            "store",
            &b"protocol=https\nhost=github.com\npassword=x\n\n"[..],
        ),
        ("erase", &b"protocol=https\nhost=github.com\n\n"[..]),
    ] {
        let mut output = Vec::new();
        broker::credential(&workspace.dir, action, input, &mut output).unwrap();
        assert!(output.is_empty(), "{action}");
    }
}

#[test]
fn an_enrolled_workroom_mints_its_own_and_never_asks_the_relay() {
    let workspace = Workspace::new("broker-relay-enrolled");
    let broker = Broker::start(vec![
        enrolled_answer(),
        ok(&format!(
            r#"{{"token":"ghs_own","expires_at":"{}"}}"#,
            iso8601(now() + 3600)
        )),
    ]);
    enrolled(&workspace, &broker, "wr-1");
    // A port nothing listens on: a relay asked would fail the get.
    let unused = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    broker::install_relay(&workspace.dir, unused, "s3cret").unwrap();

    let mut output = Vec::new();
    broker::credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\n\n"[..],
        &mut output,
    )
    .unwrap();
    assert!(String::from_utf8(output)
        .unwrap()
        .starts_with("username=x-access-token\npassword=ghs_own\n"));
}

#[test]
fn a_relay_the_mac_is_not_listening_on_says_to_open_the_workroom() {
    let workspace = Workspace::new("broker-relay-closed");
    let unused = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    broker::install_relay(&workspace.dir, unused, "s3cret").unwrap();
    let mut output = Vec::new();
    match broker::credential(
        &workspace.dir,
        "get",
        &b"protocol=https\nhost=github.com\n\n"[..],
        &mut output,
    ) {
        Err(BrokerError::Transport(message)) => {
            assert!(
                message.contains("isn't connected to this workroom"),
                "{message}"
            )
        }
        other => panic!("expected a transport error, got {other:?}"),
    }
    assert!(output.is_empty());

    // Neither is a workroom with no relay and no enrolment.
    let bare = Workspace::new("broker-relay-none");
    assert!(matches!(
        broker::credential(
            &bare.dir,
            "get",
            &b"protocol=https\nhost=github.com\n\n"[..],
            Vec::new()
        ),
        Err(BrokerError::NotEnrolled)
    ));
}

#[test]
fn a_relay_needs_a_port_and_a_one_word_secret() {
    let workspace = Workspace::new("broker-relay-install");
    for (port, secret) in [(0, "s"), (1, ""), (1, "two words"), (1, "  \n")] {
        assert!(
            broker::install_relay(&workspace.dir, port, secret).is_err(),
            "{port} {secret:?}"
        );
    }
}
