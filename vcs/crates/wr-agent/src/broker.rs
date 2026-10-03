//! A remote workroom's side of the Workroom credential broker (#250, #251).
//!
//! The Mac asks the broker (Codaset) for a one-time enrolment code bound to one workroom and one
//! repository, and runs `wr-agent enrol` on the instance with it. The agent generates its own P-256
//! key there, bound to the workroom's ID, and registers the public half with that code. From then
//! on git asks `wr-agent credential get` for a password, and the agent answers with a one-hour
//! installation token it mints from the broker, signing each request with its key. None of this
//! needs the Mac: a closed laptop still pushes.
//!
//! **Every request carries a proof**: a DPoP-shaped ES256 JWT (RFC 9449) with the public key in its
//! header, bound to the method and URL, with a fresh `jti` and an `iat` the broker accepts within
//! 60 s. A `stale_proof` refusal carries the broker's `Date`, so a skewed clock is corrected and the
//! request retried once.
//!
//! **What is on disk**, in the agent's own directory (the socket's 0700 one, `AgentBootstrap`):
//! `broker.json` (the key, the workroom it was made for, the broker's URL) and `broker-token.json`
//! (the last token and when it expires), both 0600. The token is kept until it expires, so a broker
//! outage stops new mints, not work in progress. It adds nothing to what the key already exposes:
//! the key mints tokens.
//!
//! **Every enrolment makes a new key.** Every fork copies whatever the base holds, in memory or on
//! disk, so a key found on the instance may be another workroom's. And the broker refuses a key it
//! has seen before (any grant, cancelled ones included), so a key from an enrolment that failed
//! halfway, registered or not, can never enrol again. A fresh key per code covers both.
//!
//! **Clock skew is remembered with the token.** The skew learned from a `stale_proof` is stored
//! beside the token, so its expiry is judged on the broker's clock and the expiry git is told is on
//! this machine's.

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::{
    Buffers, ConnectProxyConnector, ConnectionDetails, Connector, NextTimeout, RustlsConnector,
    TcpConnector, Transport,
};

const STATE_FILE: &str = "broker.json";
const TOKEN_FILE: &str = "broker-token.json";
/// Where the Mac relays a workroom that never enrolled (#309): a local container workroom whose
/// user is signed in to `gh` but not to Codaset. See `relay`.
const RELAY_FILE: &str = "relay.json";
/// The most a relayed answer may be: git's credential protocol is a handful of short lines.
const RELAY_MAX: u64 = 16 * 1024;
/// A cached token with less than this left is replaced, so git never starts a long push with a
/// token about to die. If the broker cannot be reached it is still used until it expires.
const REFRESH_MARGIN: i64 = 300;
/// Short enough that `wr-agent enrol`, a request and its one stale-proof retry, stays inside the
/// Mac's 60 s silence bound on the exec (`AgentEnrolment`).
const TIMEOUT: Duration = Duration::from_secs(15);
/// After a failed mint that fell back to the cached token, how long git uses that token without
/// asking the broker again: a hung broker stalls one git operation, not every one.
const RETRY_BACKOFF: i64 = 60;
/// The credential git config entry the agent owns. Scoped to github.com over HTTPS: broker tokens
/// are GitHub installation tokens, and remotes use HTTPS.
const HELPER_KEY: &str = "credential.https://github.com.helper";

#[derive(Debug, thiserror::Error)]
pub enum BrokerError {
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("could not reach the Workroom broker: {0}")]
    Transport(String),
    /// A typed refusal. `code` is the broker's contract (`Broker::Refusal` in Codaset).
    #[error("{message} ({code})")]
    Refused {
        status: u16,
        code: String,
        message: String,
    },
    #[error("this workroom has not enrolled with the Workroom broker")]
    NotEnrolled,
    #[error("{0}")]
    Invalid(String),
}

impl BrokerError {
    /// The broker's decision about this workroom (a cancelled or withdrawn grant, an unknown key,
    /// no access): a 4xx other than 429. Everything else, GitHub or the broker being unavailable
    /// included, is an outage the cached token outlasts.
    ///
    /// Decided by the broker's refusal code, not the HTTP status: a proxy's 403, an edge 404 during
    /// a deploy or a rejected proof is not the broker's decision, and must not take away a token
    /// that still works.
    fn is_final(&self) -> bool {
        const FINAL: [&str; 7] = [
            "grant_ended",
            "unknown_key",
            "no_push_access",
            "no_read_access",
            "sign_in_required",
            "app_not_installed",
            "ip_allow_list",
        ];
        matches!(self, BrokerError::Refused { code, .. } if FINAL.contains(&code.as_str()))
    }
}

/// `broker.json`: the enrolment key and what it is for.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct State {
    workroom_id: String,
    broker: String,
    /// The private key as PKCS#8, base64url.
    key: String,
    enrolled: bool,
}

/// `broker-token.json`: the last installation token.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Token {
    pub token: String,
    /// Unix seconds, on the broker's clock.
    pub expires_at: i64,
    /// The broker's clock minus this machine's, as learned from a `stale_proof`.
    #[serde(default)]
    pub skew: i64,
    /// Broker clock: until then a failed mint's fallback is reused without asking again.
    #[serde(default)]
    pub retry_after: i64,
    /// The enrolment key it was minted for (its JWK `x`). A token cached for another key, written
    /// by a mint that was still in flight when the workroom enrolled again, is never served.
    #[serde(default)]
    pub key: String,
}

impl Token {
    /// When it expires on this machine's clock, which is what git compares.
    pub fn local_expiry(&self) -> i64 {
        self.expires_at - self.skew
    }
}

/// Enrols this workroom with a new key and `code`. Replaces any key and token already here, so
/// running it again with a fresh code recovers from an enrolment that failed at any point.
pub fn enrol(dir: &Path, workroom_id: &str, broker: &str, code: &str) -> Result<(), BrokerError> {
    if workroom_id.trim().is_empty() || code.trim().is_empty() {
        return Err(BrokerError::Invalid(
            "enrolment needs a workroom ID and a code".into(),
        ));
    }
    let broker = broker.trim_end_matches('/');
    if !acceptable_broker(broker) {
        return Err(BrokerError::Invalid(format!(
            "the broker must be an https URL, not {broker:?}"
        )));
    }

    let _ = std::fs::remove_file(dir.join(TOKEN_FILE));
    let mut state = State {
        workroom_id: workroom_id.to_string(),
        broker: broker.to_string(),
        key: URL_SAFE_NO_PAD.encode(generate_key()?),
        enrolled: false,
    };
    // Written before the request: if the broker registers the key and the answer is lost, the
    // key is still here, and not enrolled, so the helper refuses rather than guessing.
    save(dir, STATE_FILE, &state)?;
    let (answer, _) = call(
        &state,
        "/broker/enrolments",
        Some(json!({ "code": code.trim(), "workroom_id": workroom_id })),
        0,
    )?;
    // A 2xx that is not the broker's answer (a maintenance page) is not an enrolment.
    if answer["grant_id"].as_str().is_none_or(str::is_empty) {
        return Err(BrokerError::Invalid(
            "the broker's enrolment response is malformed".into(),
        ));
    }
    state.enrolled = true;
    save(dir, STATE_FILE, &state)
}

/// A token for git: the cached one while it has more than `REFRESH_MARGIN` left, otherwise a new
/// one from the broker, falling back to the cached one until it expires if the broker fails.
pub fn token(dir: &Path) -> Result<Token, BrokerError> {
    let state = match load_state(dir)? {
        Some(state) if state.enrolled => state,
        _ => return Err(BrokerError::NotEnrolled),
    };
    let key = key_id(&state)?;
    let cached: Option<Token> = load::<Token>(dir, TOKEN_FILE)?.filter(|t| t.key == key);
    let skew = cached.as_ref().map_or(0, |t| t.skew);
    let now = unix_now() + skew;
    let fresh = |t: &&Token| {
        t.expires_at - now > REFRESH_MARGIN || (t.retry_after > now && t.expires_at > now)
    };
    if let Some(cached) = cached.as_ref().filter(fresh) {
        return Ok(cached.clone());
    }
    match mint(&state, skew) {
        Ok(token) => {
            save(dir, TOKEN_FILE, &token)?;
            Ok(token)
        }
        Err(error) if error.is_final() => {
            // The broker said no: a later outage must not bring this token back.
            let _ = std::fs::remove_file(dir.join(TOKEN_FILE));
            Err(error)
        }
        Err(error) => {
            // The clock again: the requests may have outlived what was left of the token.
            let now = unix_now() + skew;
            match cached.filter(|t| t.expires_at > now) {
                Some(mut cached) => {
                    cached.retry_after = now + RETRY_BACKOFF;
                    save(dir, TOKEN_FILE, &cached)?;
                    Ok(cached)
                }
                None => Err(error),
            }
        }
    }
}

fn mint(state: &State, skew: i64) -> Result<Token, BrokerError> {
    let (body, skew) = call(state, "/broker/tokens", None, skew)?;
    let token = body["token"].as_str().unwrap_or_default().to_string();
    let expires_at = body["expires_at"].as_str().and_then(parse_iso8601);
    match (token.is_empty(), expires_at) {
        (false, Some(expires_at)) if expires_at > unix_now() + skew => Ok(Token {
            token,
            expires_at,
            skew,
            retry_after: 0,
            key: key_id(state)?,
        }),
        _ => Err(BrokerError::Invalid(
            "the broker's token response is malformed or already expired".into(),
        )),
    }
}

/// Which enrolment key a token belongs to: the public key's `x`, which is not secret.
fn key_id(state: &State) -> Result<String, BrokerError> {
    let jwk = public_jwk(&key_pair(&state.key)?);
    Ok(jwk["x"].as_str().unwrap_or_default().to_string())
}

/// An https broker, or plain http to 127.0.0.1 for tests and a local Codaset. Parsed, so
/// `http://127.0.0.1:@elsewhere` (whose host is `elsewhere`) is refused.
fn acceptable_broker(broker: &str) -> bool {
    let Ok(uri) = broker.parse::<ureq::http::Uri>() else {
        return false;
    };
    let plain_path = uri.path_and_query().is_none_or(|p| p.as_str() == "/");
    let host = uri.host().unwrap_or_default();
    let has_userinfo = uri.authority().is_some_and(|a| a.as_str().contains('@'));
    match uri.scheme_str() {
        Some("https") => !host.is_empty() && !has_userinfo && plain_path,
        Some("http") => host == "127.0.0.1" && !has_userinfo && plain_path,
        _ => false,
    }
}

/// `wr-agent credential <get|store|erase>`: git's credential helper protocol, for
/// `https://github.com` only. `get` answers with a token; `erase` (git's "this was rejected")
/// drops the cached one; `store` has nothing to do, because the token is the broker's to issue.
pub fn credential(
    dir: &Path,
    action: &str,
    input: impl BufRead,
    mut output: impl Write,
) -> Result<(), BrokerError> {
    let mut protocol = String::new();
    let mut host = String::new();
    let mut password = String::new();
    for line in input.lines() {
        let line = line?;
        if line.is_empty() {
            break;
        }
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "protocol" => protocol = value.to_string(),
                "host" => host = value.to_string(),
                "password" => password = value.to_string(),
                _ => {}
            }
        }
    }
    if protocol != "https" || host != "github.com" {
        return Ok(());
    }
    if action == "erase" {
        // GitHub rejected it (revoked, or expired on GitHub's clock): drop it, so the next
        // request mints rather than serving it again. Only if it is still the cached one, so a
        // late rejection cannot remove a newer token.
        let cached: Option<Token> = load(dir, TOKEN_FILE)?;
        if cached.is_some_and(|t| !password.is_empty() && t.token == password) {
            let _ = std::fs::remove_file(dir.join(TOKEN_FILE));
        }
        return Ok(());
    }
    if action != "get" {
        return Ok(());
    }
    // An enrolled workroom always mints its own; only one that never enrolled is relayed.
    let token = match token(dir) {
        Err(BrokerError::NotEnrolled) if load::<Relay>(dir, RELAY_FILE)?.is_some() => {
            return relay(dir, &mut output);
        }
        result => result?,
    };
    // `x-access-token` is the username GitHub documents for installation tokens over HTTPS.
    // `password_expiry_utc` (git 2.41+) stops git reusing it past its expiry; older gits ignore it.
    write!(
        output,
        "username=x-access-token\npassword={}\npassword_expiry_utc={}\n",
        token.token,
        token.local_expiry()
    )?;
    Ok(())
}

/// Where a workroom that never enrolled asks the Mac for git's credentials (#309): a port on this
/// box's loopback that the app carries back to itself over its own connection (a reverse
/// forward), and the secret that tells the app which workroom is asking. Anything in the workroom
/// can read it and ask, which is the accepted trade: such a workroom gets the GitHub access the
/// user's own `gh` has, as a workroom on the Mac itself does.
#[derive(Serialize, Deserialize)]
struct Relay {
    port: u16,
    secret: String,
}

/// Records the relay for `credential get` (`wr-agent credential relay`).
pub fn install_relay(dir: &Path, port: u16, secret: &str) -> Result<(), BrokerError> {
    let secret = secret.trim();
    if port == 0 || secret.is_empty() || secret.contains(char::is_whitespace) {
        return Err(BrokerError::Invalid(
            "a relay needs a port and a one-word secret".into(),
        ));
    }
    save(
        dir,
        RELAY_FILE,
        &Relay {
            port,
            secret: secret.to_string(),
        },
    )
}

/// `get` through the Mac: sends the secret, then the request (only ever github.com over HTTPS,
/// which `credential` checked), and copies back the answer's `username` and `password`. Nothing
/// else in the answer reaches git.
fn relay(dir: &Path, output: &mut impl Write) -> Result<(), BrokerError> {
    use std::io::Read;
    use std::net::{Ipv4Addr, SocketAddr, TcpStream};
    let Some(relay) = load::<Relay>(dir, RELAY_FILE)? else {
        return Err(BrokerError::NotEnrolled);
    };
    let unreachable = |e: io::Error| {
        BrokerError::Transport(format!(
            "the Workroom app isn't connected to this workroom, so git has no GitHub credentials. \
             Open the workroom in Workroom. ({e})"
        ))
    };
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, relay.port));
    let mut stream = TcpStream::connect_timeout(&address, TIMEOUT).map_err(unreachable)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    write!(
        stream,
        "{}\nprotocol=https\nhost=github.com\n\n",
        relay.secret
    )
    .map_err(unreachable)?;
    let mut answer = String::new();
    stream
        .take(RELAY_MAX)
        .read_to_string(&mut answer)
        .map_err(unreachable)?;
    let mut fields = answer.lines().filter_map(|line| line.split_once('='));
    let mut username = None;
    let mut password = None;
    for (key, value) in fields.by_ref() {
        match key {
            "username" => username = Some(value),
            "password" => password = Some(value),
            "error" => return Err(BrokerError::Invalid(value.to_string())),
            _ => {}
        }
    }
    let (Some(username), Some(password)) = (username, password) else {
        return Err(BrokerError::Invalid(
            "the Workroom app had no GitHub credentials to give: sign in with `gh auth login`"
                .into(),
        ));
    };
    write!(output, "username={username}\npassword={password}\n")?;
    Ok(())
}

/// Makes `helper` git's only credential helper for `https://github.com`, in global config.
///
/// The empty entry first resets the list inherited from system config, where boxd installs its
/// own helper; without it boxd's answers first (measured on git 2.55.0, design doc OQ20).
/// `git` builds the base command, so a test can point it at its own config files.
pub fn configure_git(git: impl Fn() -> Command, helper: &str) -> io::Result<()> {
    let run = |args: &[&str], allowed: &[i32]| -> io::Result<()> {
        let status = git().args(["config", "--global"]).args(args).status()?;
        match status.code() {
            Some(code) if code == 0 || allowed.contains(&code) => Ok(()),
            _ => Err(io::Error::other(format!(
                "git config {args:?} failed: {status}"
            ))),
        }
    };
    // Exit 5: there was nothing to unset.
    run(&["--unset-all", HELPER_KEY], &[5])?;
    run(&["--add", HELPER_KEY, ""], &[])?;
    run(&["--add", HELPER_KEY, helper], &[])
}

/// The helper string git runs for `binary`: `!` makes git run it with the shell, so a path with
/// spaces survives, and git appends `get`, `store` or `erase`.
pub fn helper_command(binary: &Path) -> String {
    let path = binary.to_string_lossy().replace('\'', r"'\''");
    format!("!'{path}' credential")
}

/// Where the agent keeps its broker files: beside its own binary, in the socket's 0700 directory.
pub fn directory() -> io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    exe.parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| io::Error::other("the agent's binary has no directory"))
}

// MARK: - Requests

/// Retries a read that a signal interrupted (#301). On Linux a read from a socket with a timeout,
/// as `call`'s `timeout_global` gives each of its sockets, fails with EINTR when any handled signal
/// arrives, `SA_RESTART` or not, and even with no handler after a stop and continue (signal(7));
/// ureq 3.4.2 hands that straight back as an error. The read failed before taking anything, so it
/// is safe to repeat. Repeating the whole request is not: the broker may already have spent an
/// enrolment's code.
#[derive(Debug)]
struct RetryInterrupted<T>(T);

impl<In: Transport, C: Connector<In>> Connector<In> for RetryInterrupted<C> {
    type Out = RetryInterrupted<C::Out>;

    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        Ok(self.0.connect(details, chained)?.map(RetryInterrupted))
    }
}

impl<T: Transport> Transport for RetryInterrupted<T> {
    fn buffers(&mut self) -> &mut dyn Buffers {
        self.0.buffers()
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        self.0.transmit_output(amount, timeout)
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        let start = std::time::Instant::now();
        let mut next = timeout;
        let mut last = false;
        loop {
            match self.0.await_input(next) {
                Err(ureq::Error::Io(e)) if e.kind() == io::ErrorKind::Interrupted => {}
                result => return result,
            }
            if last {
                return Err(ureq::Error::Timeout(timeout.reason));
            }
            // A retry restarts the socket's timeout, so it gets only what is left of this one:
            // otherwise a steady stream of signals holds the read open past `TIMEOUT`.
            if !timeout.after.is_not_happening() {
                match timeout.after.checked_sub(start.elapsed()) {
                    Some(left) if !left.is_zero() => next.after = left.into(),
                    // Out of time: one last read, which the socket times at a second
                    // (`NextTimeout::not_zero`), so an answer that arrived while the process was
                    // stopped is still taken. ureq itself refuses an expired read
                    // (`Connection::maybe_await_input`), so this goes further, deliberately: an
                    // enrolment's code is already spent. An answer split across reads still times
                    // out on the next one.
                    _ => {
                        next.after = Duration::ZERO.into();
                        last = true;
                    }
                }
            }
        }
    }

    fn is_open(&mut self) -> bool {
        self.0.is_open()
    }

    fn is_tls(&self) -> bool {
        self.0.is_tls()
    }
}

/// One signed JSON POST (every agent request is one), its proof dated `skew` seconds from this
/// machine's clock and retried once with a corrected clock on `stale_proof`. Returns the answer
/// and the skew that worked.
fn call(
    state: &State,
    path: &str,
    body: Option<Value>,
    mut skew: i64,
) -> Result<(Value, i64), BrokerError> {
    let key = key_pair(&state.key)?;
    let url = format!("{}{}", state.broker, path);
    let config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        // A redirect would carry the proof to wherever it points, and `/broker/tokens` has no
        // body to tie it to one host. The broker never redirects; a 3xx is an outage.
        .max_redirects(0)
        .timeout_global(Some(TIMEOUT))
        .build();
    // ureq's default chain less the warnings it keeps private (SOCKS without the feature, a
    // missing TLS provider), with interrupted reads retried beneath TLS so the handshake is
    // covered too.
    let connector =
        ().chain(ConnectProxyConnector::default())
            .chain(RetryInterrupted(TcpConnector::default()))
            .chain(RustlsConnector::default());
    let agent = ureq::Agent::with_parts(config, connector, DefaultResolver::default());
    for attempt in 0..2 {
        let proof = proof(&key, "POST", &url, unix_now() + skew)?;
        let request = agent
            .post(&url)
            .header("DPoP", &proof)
            .header("Accept", "application/json");
        let result = match &body {
            Some(body) => request
                .header("Content-Type", "application/json")
                .send(body.to_string()),
            None => request.send_empty(),
        };
        let mut response = result.map_err(|e| BrokerError::Transport(e.to_string()))?;
        let status = response.status().as_u16();
        let date = response
            .headers()
            .get("date")
            .and_then(|v| v.to_str().ok())
            .and_then(parse_http_date);
        let text = response
            .body_mut()
            .read_to_string()
            .map_err(|e| BrokerError::Transport(e.to_string()))?;
        let json: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        if (200..300).contains(&status) {
            return Ok((json, skew));
        }
        let code = json["error"].as_str().unwrap_or("unknown").to_string();
        if attempt == 0 && status == 401 && code == "stale_proof" {
            if let Some(server) = date {
                skew = server - unix_now();
                continue;
            }
        }
        return Err(BrokerError::Refused {
            status,
            message: json["message"].as_str().unwrap_or(&code).to_string(),
            code,
        });
    }
    unreachable!("the loop returns on its second attempt")
}

/// A DPoP proof (RFC 9449) for one request.
fn proof(key: &EcdsaKeyPair, method: &str, url: &str, iat: i64) -> Result<String, BrokerError> {
    let rng = SystemRandom::new();
    let mut jti = [0u8; 16];
    rng.fill(&mut jti)
        .map_err(|_| BrokerError::Invalid("no randomness for the proof".into()))?;
    let header = json!({ "typ": "dpop+jwt", "alg": "ES256", "jwk": public_jwk(key) });
    let claims = json!({
        "htm": method, "htu": url, "iat": iat, "jti": URL_SAFE_NO_PAD.encode(jti),
    });
    let input = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(header.to_string()),
        URL_SAFE_NO_PAD.encode(claims.to_string())
    );
    let signature = key
        .sign(&rng, input.as_bytes())
        .map_err(|_| BrokerError::Invalid("could not sign the proof".into()))?;
    // FIXED signing is r || s, 64 bytes: exactly JWS's ES256 encoding.
    Ok(format!(
        "{input}.{}",
        URL_SAFE_NO_PAD.encode(signature.as_ref())
    ))
}

/// The public half as a JWK. ring's public key is the uncompressed point: 0x04 || x || y.
fn public_jwk(key: &EcdsaKeyPair) -> Value {
    let point = key.public_key().as_ref();
    json!({
        "kty": "EC", "crv": "P-256",
        "x": URL_SAFE_NO_PAD.encode(&point[1..33]),
        "y": URL_SAFE_NO_PAD.encode(&point[33..65]),
    })
}

fn generate_key() -> Result<Vec<u8>, BrokerError> {
    let rng = SystemRandom::new();
    EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
        .map(|doc| doc.as_ref().to_vec())
        .map_err(|_| BrokerError::Invalid("could not generate a key".into()))
}

fn key_pair(encoded: &str) -> Result<EcdsaKeyPair, BrokerError> {
    let pkcs8 = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| BrokerError::Invalid("the stored key is not base64url".into()))?;
    EcdsaKeyPair::from_pkcs8(
        &ECDSA_P256_SHA256_FIXED_SIGNING,
        &pkcs8,
        &SystemRandom::new(),
    )
    .map_err(|_| BrokerError::Invalid("the stored key is not a P-256 key".into()))
}

// MARK: - Files

fn load_state(dir: &Path) -> Result<Option<State>, BrokerError> {
    load(dir, STATE_FILE)
}

fn load<T: for<'de> Deserialize<'de>>(dir: &Path, name: &str) -> Result<Option<T>, BrokerError> {
    match std::fs::read(dir.join(name)) {
        // A file that does not parse is treated as absent: enrolment replaces it.
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).ok()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Writes `value` to `dir/name`, 0600, through a temporary file so a crash never leaves half a key.
fn save<T: Serialize>(dir: &Path, name: &str, value: &T) -> Result<(), BrokerError> {
    use std::os::unix::fs::OpenOptionsExt;
    let temporary = dir.join(format!(".{name}.{}", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec(value).map_err(io::Error::other)?)?;
    file.sync_all()?;
    std::fs::rename(&temporary, dir.join(name))?;
    Ok(())
}

// MARK: - Time

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `2026-09-28T13:00:00Z`, or with an offset, as Rails' `iso8601` writes it.
fn parse_iso8601(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|t| t.timestamp())
}

/// An HTTP `Date` (IMF-fixdate): `Mon, 28 Sep 2026 13:00:00 GMT`.
fn parse_http_date(text: &str) -> Option<i64> {
    chrono::NaiveDateTime::parse_from_str(text, "%a, %d %b %Y %H:%M:%S GMT")
        .ok()
        .map(|t| t.and_utc().timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_parse_as_rails_and_http_write_them() {
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso8601("2026-09-28T13:00:00Z"), Some(1_790_600_400));
        assert_eq!(
            parse_iso8601("2026-09-28T14:00:00+01:00"),
            Some(1_790_600_400)
        );
        assert_eq!(
            parse_iso8601("2026-09-28T13:00:00.123Z"),
            Some(1_790_600_400)
        );
        assert_eq!(parse_iso8601("2026-09-28 13:00"), None);
        assert_eq!(
            parse_http_date("Mon, 28 Sep 2026 13:00:00 GMT"),
            Some(1_790_600_400)
        );
        assert_eq!(parse_http_date("Mon, 28 Sep 2026 13:00:00 PST"), None);
        assert_eq!(parse_http_date("yesterday"), None);
    }

    /// The proof is a JWT whose header carries the public key and whose signature verifies with
    /// it: the shape `Broker::Proof` checks.
    #[test]
    fn a_proof_is_an_es256_dpop_jwt_that_verifies_with_its_own_jwk() {
        let key = key_pair(&URL_SAFE_NO_PAD.encode(generate_key().unwrap())).unwrap();
        let proof = proof(&key, "POST", "https://codaset.dev/broker/tokens", 1000).unwrap();
        let parts: Vec<&str> = proof.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(header["typ"], "dpop+jwt");
        assert_eq!(header["alg"], "ES256");
        assert!(header["jwk"].get("d").is_none(), "never the private half");
        assert_eq!(claims["htm"], "POST");
        assert_eq!(claims["htu"], "https://codaset.dev/broker/tokens");
        assert_eq!(claims["iat"], 1000);
        assert!(claims["jti"].as_str().unwrap().len() >= 16);

        let x = URL_SAFE_NO_PAD
            .decode(header["jwk"]["x"].as_str().unwrap())
            .unwrap();
        let y = URL_SAFE_NO_PAD
            .decode(header["jwk"]["y"].as_str().unwrap())
            .unwrap();
        let point = [&[4u8][..], &x, &y].concat();
        let verifier = ring::signature::UnparsedPublicKey::new(
            &ring::signature::ECDSA_P256_SHA256_FIXED,
            point,
        );
        let signature = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        let input = format!("{}.{}", parts[0], parts[1]);
        assert!(verifier.verify(input.as_bytes(), &signature).is_ok());
    }

    /// Answers `Interrupted` to its first `interruptions` reads, 5ms apart, then `Ok(true)`, and
    /// records the timeout each read was given.
    #[derive(Debug)]
    struct Interrupting {
        interruptions: usize,
        timeouts: Vec<Duration>,
        buffers: ureq::unversioned::transport::LazyBuffers,
    }

    impl Transport for Interrupting {
        fn buffers(&mut self) -> &mut dyn Buffers {
            &mut self.buffers
        }

        fn transmit_output(&mut self, _: usize, _: NextTimeout) -> Result<(), ureq::Error> {
            Ok(())
        }

        fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
            self.timeouts.push(*timeout.after);
            if self.interruptions == 0 {
                return Ok(true);
            }
            self.interruptions -= 1;
            std::thread::sleep(Duration::from_millis(5));
            Err(io::Error::from(io::ErrorKind::Interrupted).into())
        }

        fn is_open(&mut self) -> bool {
            true
        }
    }

    #[test]
    fn interrupted_reads_are_retried_only_until_the_timeout() {
        let transport = |interruptions| {
            RetryInterrupted(Interrupting {
                interruptions,
                timeouts: Vec::new(),
                buffers: ureq::unversioned::transport::LazyBuffers::new(1, 1),
            })
        };
        let timeout = |millis| NextTimeout {
            after: Duration::from_millis(millis).into(),
            reason: ureq::Timeout::RecvResponse,
        };

        // Each retry is given only what is left of the deadline.
        let mut retried = transport(3);
        assert!(matches!(retried.await_input(timeout(5000)), Ok(true)));
        let given = &retried.0.timeouts;
        assert_eq!(given.len(), 4);
        assert_eq!(given[0], Duration::from_millis(5000));
        assert!(given.windows(2).all(|pair| pair[1] < pair[0]), "{given:?}");

        // An answer waiting when the time runs out is still read, given ureq's last-read timeout.
        let mut late = transport(1);
        assert!(matches!(late.await_input(timeout(1)), Ok(true)));
        assert_eq!(late.0.timeouts, [Duration::from_millis(1), Duration::ZERO]);

        // 100 interruptions take 500ms, five times the timeout.
        assert!(matches!(
            transport(100).await_input(timeout(100)),
            Err(ureq::Error::Timeout(ureq::Timeout::RecvResponse))
        ));
    }

    #[test]
    fn the_helper_command_survives_spaces_and_quotes_in_the_path() {
        assert_eq!(
            helper_command(Path::new("/home/me/.workroom/wr-agent")),
            "!'/home/me/.workroom/wr-agent' credential"
        );
        assert_eq!(
            helper_command(Path::new("/a b/it's/wr-agent")),
            r"!'/a b/it'\''s/wr-agent' credential"
        );
    }
}
