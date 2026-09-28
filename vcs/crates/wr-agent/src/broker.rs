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

const STATE_FILE: &str = "broker.json";
const TOKEN_FILE: &str = "broker-token.json";
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
    fn is_final(&self) -> bool {
        matches!(self, BrokerError::Refused { status, .. } if (400..500).contains(status) && *status != 429)
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
    let loopback = broker == "http://127.0.0.1" || broker.starts_with("http://127.0.0.1:");
    if !broker.starts_with("https://") && !loopback {
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
    call(
        &state,
        "POST",
        "/broker/enrolments",
        Some(json!({ "code": code.trim(), "workroom_id": workroom_id })),
        0,
    )?;
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
    let cached: Option<Token> = load(dir, TOKEN_FILE)?;
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
        Err(error) => match cached.filter(|t| t.expires_at > now) {
            Some(mut cached) if !error.is_final() => {
                cached.retry_after = now + RETRY_BACKOFF;
                save(dir, TOKEN_FILE, &cached)?;
                Ok(cached)
            }
            _ => Err(error),
        },
    }
}

fn mint(state: &State, skew: i64) -> Result<Token, BrokerError> {
    let (body, skew) = call(state, "POST", "/broker/tokens", None, skew)?;
    let token = body["token"].as_str().unwrap_or_default().to_string();
    let expires_at = body["expires_at"].as_str().and_then(parse_iso8601);
    match (token.is_empty(), expires_at) {
        (false, Some(expires_at)) => Ok(Token {
            token,
            expires_at,
            skew,
            retry_after: 0,
        }),
        _ => Err(BrokerError::Invalid(
            "the broker's token response is malformed".into(),
        )),
    }
}

/// `wr-agent credential <get|store|erase>`: git's credential helper protocol. Only `get` for
/// `https://github.com` answers; `store` and `erase` have nothing to do, because the token is the
/// broker's to issue and expires by itself.
pub fn credential(
    dir: &Path,
    action: &str,
    input: impl BufRead,
    mut output: impl Write,
) -> Result<(), BrokerError> {
    let mut protocol = String::new();
    let mut host = String::new();
    for line in input.lines() {
        let line = line?;
        if line.is_empty() {
            break;
        }
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "protocol" => protocol = value.to_string(),
                "host" => host = value.to_string(),
                _ => {}
            }
        }
    }
    if action != "get" || protocol != "https" || host != "github.com" {
        return Ok(());
    }
    let token = token(dir)?;
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

/// One signed JSON request, its proof dated `skew` seconds from this machine's clock and retried
/// once with a corrected clock on `stale_proof`. Returns the answer and the skew that worked.
fn call(
    state: &State,
    method: &str,
    path: &str,
    body: Option<Value>,
    mut skew: i64,
) -> Result<(Value, i64), BrokerError> {
    let key = key_pair(&state.key)?;
    let url = format!("{}{}", state.broker, path);
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(TIMEOUT))
        .build()
        .into();
    for attempt in 0..2 {
        let proof = proof(&key, method, &url, unix_now() + skew)?;
        let request = agent
            .post(&url)
            .header("DPoP", &proof)
            .header("Accept", "application/json");
        let result = match (method, &body) {
            ("POST", Some(body)) => request
                .header("Content-Type", "application/json")
                .send(body.to_string()),
            ("POST", None) => request.send_empty(),
            _ => return Err(BrokerError::Invalid(format!("unsupported method {method}"))),
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

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn unix(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) -> Option<i64> {
    let valid = (1..=12).contains(&month)
        && (1..=31).contains(&day)
        && (0..24).contains(&hour)
        && (0..60).contains(&minute)
        && (0..=60).contains(&second);
    valid.then(|| days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second)
}

/// `2026-09-28T13:00:00Z` or with a `±HH:MM` offset, as Rails' `iso8601` writes it.
fn parse_iso8601(text: &str) -> Option<i64> {
    let number = |range: std::ops::Range<usize>| text.get(range)?.parse::<i64>().ok();
    let base = unix(
        number(0..4)?,
        number(5..7)?,
        number(8..10)?,
        number(11..13)?,
        number(14..16)?,
        number(17..19)?,
    )?;
    let zone = text
        .get(19..)?
        .trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    match zone {
        "Z" => Some(base),
        offset if offset.len() == 6 => {
            let sign = match &offset[..1] {
                "+" => 1,
                "-" => -1,
                _ => return None,
            };
            let hours = offset.get(1..3)?.parse::<i64>().ok()?;
            let minutes = offset.get(4..6)?.parse::<i64>().ok()?;
            Some(base - sign * (hours * 3600 + minutes * 60))
        }
        _ => None,
    }
}

/// An HTTP `Date` (IMF-fixdate): `Sun, 28 Sep 2026 13:00:00 GMT`.
fn parse_http_date(text: &str) -> Option<i64> {
    let parts: Vec<&str> = text.split_whitespace().collect();
    let [_, day, month, year, time, "GMT"] = parts.as_slice() else {
        return None;
    };
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let month = MONTHS.iter().position(|m| m == month)? as i64 + 1;
    let mut clock = time.split(':').map(|p| p.parse::<i64>().ok());
    let (hour, minute, second) = (clock.next()??, clock.next()??, clock.next()??);
    unix(
        year.parse().ok()?,
        month,
        day.parse().ok()?,
        hour,
        minute,
        second,
    )
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
