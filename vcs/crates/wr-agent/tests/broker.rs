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
/// file, and fails rather than failing to start).
fn date(unix: i64, format: &str) -> String {
    let run = |args: &[&str]| Command::new("date").args(args).output().ok();
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
fn enrolment_registers_a_new_key_with_the_code_and_is_idempotent() {
    let workspace = Workspace::new("broker-enrol");
    let broker = Broker::start(vec![(201, vec![], r#"{"grant_id":"g"}"#.into())]);

    enrolled(&workspace, &broker, "wr-1");
    enrolled(&workspace, &broker, "wr-1");

    let received = broker.received();
    assert_eq!(received.len(), 1, "enrolling again is a no-op");
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

#[test]
fn a_key_made_for_another_workroom_is_replaced_along_with_its_token() {
    let workspace = Workspace::new("broker-other-workroom");
    let expires = iso8601(now() + 3600);
    let broker = Broker::start(vec![
        (201, vec![], "{}".into()),
        ok(&format!(
            r#"{{"token":"base-token","expires_at":"{expires}"}}"#
        )),
        (201, vec![], "{}".into()),
    ]);

    enrolled(&workspace, &broker, "the-base");
    broker::token(&workspace.dir).unwrap();
    assert!(workspace.dir.join("broker-token.json").exists());

    enrolled(&workspace, &broker, "the-fork");

    let received = broker.received();
    assert_eq!(received.len(), 3, "the fork enrols afresh");
    assert_ne!(received[0].jwk(), received[2].jwk(), "with a new key");
    assert!(
        !workspace.dir.join("broker-token.json").exists(),
        "the other workroom's token is gone"
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
        (201, vec![], "{}".into()),
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

#[test]
fn a_stale_proof_is_retried_once_with_the_brokers_clock() {
    let workspace = Workspace::new("broker-skew");
    let server_now = now() + 600;
    let date = date(server_now, "+%a, %d %b %Y %H:%M:%S GMT");
    let broker = Broker::start(vec![
        (201, vec![], "{}".into()),
        (
            401,
            vec![("Date", date)],
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
}

#[test]
fn a_cached_token_outlives_a_broker_outage_but_not_a_refusal() {
    let workspace = Workspace::new("broker-outage");
    // Inside the refresh margin, so the next call asks the broker first.
    let expires_at = now() + 120;
    let broker = Broker::start(vec![
        (201, vec![], "{}".into()),
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
        "so does a rate limit"
    );
    match broker::token(&workspace.dir) {
        Err(BrokerError::Refused { code, .. }) => assert_eq!(code, "grant_ended"),
        other => panic!("a refusal is final, got {other:?}"),
    }
}

#[test]
fn the_credential_helper_answers_github_over_https_and_nothing_else() {
    let workspace = Workspace::new("broker-credential");
    let broker = Broker::start(vec![
        (201, vec![], "{}".into()),
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
