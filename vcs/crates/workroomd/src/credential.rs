//! git's GitHub credentials for a local container workroom (#309), relayed from the Mac.
//!
//! A remote provider's host gets git credentials from the provider itself (boxd's git integration,
//! exe.dev's GitHub integration), so the daemon there configures nothing. A container workroom on
//! the Mac has no provider: the app relays its own `gh` instead. `workroomd credential relay`
//! records where to ask and makes `workroomd credential` git's helper for `https://github.com`;
//! `workroomd credential get` then asks the Mac, through a port on this box's loopback that the app
//! carries back to itself over its own connection (a reverse forward).
//!
//! **What is on disk**, in the daemon's own directory (the socket's 0700 one, `DaemonBootstrap`):
//! `relay.json` (the port and the secret that tells the app which workroom is asking), 0600.

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// Where the Mac relays a container workroom's git credentials. See `relay`.
const RELAY_FILE: &str = "relay.json";
/// The most a relayed answer may be: git's credential protocol is a handful of short lines.
const RELAY_MAX: u64 = 16 * 1024;
/// How long a relayed request may take to connect, send or answer.
const TIMEOUT: Duration = Duration::from_secs(15);
/// The credential git config entry the daemon owns. Scoped to github.com over HTTPS: the relay
/// answers for nothing else.
const HELPER_KEY: &str = "credential.https://github.com.helper";
/// Rewrites ssh-form GitHub remotes to HTTPS, so a clone of the Mac's origin as-is, and a submodule
/// or dependency written either ssh way, reaches the helper: git never asks a credential helper
/// over ssh. boxd ships the scp-form line in system config.
const INSTEAD_OF_KEY: &str = "url.https://github.com/.insteadOf";
/// Each value the daemon owns, with the pattern that matches only it, so a reinstall replaces it in
/// place and leaves any rewrite of the user's own under the same key alone.
const INSTEAD_OF: [(&str, &str); 2] = [
    ("git@github.com:", r"^git@github\.com:$"),
    ("ssh://git@github.com/", r"^ssh://git@github\.com/$"),
];

#[derive(Debug, thiserror::Error)]
pub enum CredentialError {
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("{0}")]
    Unreachable(String),
    #[error("this workroom has no credential relay")]
    NoRelay,
    #[error("{0}")]
    Invalid(String),
}

/// `workroomd credential <get|store|erase>`: git's credential helper protocol, for
/// `https://github.com` only. `get` answers with what the Mac relays; `store` and `erase` have
/// nothing to do, because the credential is the Mac's `gh`'s to keep.
pub fn credential(
    dir: &Path,
    action: &str,
    input: impl BufRead,
    mut output: impl Write,
) -> Result<(), CredentialError> {
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
    if protocol != "https" || host != "github.com" || action != "get" {
        return Ok(());
    }
    relay(dir, &mut output)
}

/// Where a container workroom asks the Mac for git's credentials (#309), and the secret that tells
/// the app which workroom is asking. Anything in the workroom can read it and ask, which is the
/// accepted trade: such a workroom gets the GitHub access the user's own `gh` has, as a workroom on
/// the Mac itself does.
#[derive(Serialize, Deserialize)]
struct Relay {
    port: u16,
    secret: String,
}

/// Records the relay for `credential get` (`workroomd credential relay`).
pub fn install_relay(dir: &Path, port: u16, secret: &str) -> Result<(), CredentialError> {
    let secret = secret.trim();
    if port == 0 || secret.is_empty() || secret.contains(char::is_whitespace) {
        return Err(CredentialError::Invalid(
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
fn relay(dir: &Path, output: &mut impl Write) -> Result<(), CredentialError> {
    use std::io::Read;
    use std::net::{Ipv4Addr, SocketAddr, TcpStream};
    let Some(relay) = load::<Relay>(dir, RELAY_FILE)? else {
        return Err(CredentialError::NoRelay);
    };
    let unreachable = |e: io::Error| {
        CredentialError::Unreachable(format!(
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
    let mut username = None;
    let mut password = None;
    for (key, value) in answer.lines().filter_map(|line| line.split_once('=')) {
        match key {
            "username" => username = Some(value),
            "password" => password = Some(value),
            "error" => return Err(CredentialError::Invalid(value.to_string())),
            _ => {}
        }
    }
    let (Some(username), Some(password)) = (username, password) else {
        return Err(CredentialError::Invalid(
            "the Workroom app had no GitHub credentials to give: sign in with `gh auth login`"
                .into(),
        ));
    };
    write!(output, "username={username}\npassword={password}\n")?;
    Ok(())
}

/// Makes `helper` git's only credential helper for `https://github.com`, in global config, and
/// rewrites ssh-form GitHub remotes to HTTPS so they reach it, keeping the user's own rewrites.
///
/// The empty entry first resets the list inherited from system config, so an image that ships its
/// own helper (boxd's does) never answers before the relay (measured on git 2.55.0, design doc
/// OQ20). `git` builds the base command, so a test can point it at its own config files.
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
    run(&["--add", HELPER_KEY, helper], &[])?;
    for (value, own) in INSTEAD_OF {
        run(&["--replace-all", INSTEAD_OF_KEY, value, own], &[])?;
    }
    Ok(())
}

/// The helper string git runs for `binary`: `!` makes git run it with the shell, so a path with
/// spaces survives, and git appends `get`, `store` or `erase`.
pub fn helper_command(binary: &Path) -> String {
    let path = binary.to_string_lossy().replace('\'', r"'\''");
    format!("!'{path}' credential")
}

/// Where the daemon keeps its relay file: beside its own binary, in the socket's 0700 directory.
pub fn directory() -> io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    exe.parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| io::Error::other("the daemon's binary has no directory"))
}

// MARK: - Files

fn load<T: for<'de> Deserialize<'de>>(
    dir: &Path,
    name: &str,
) -> Result<Option<T>, CredentialError> {
    match std::fs::read(dir.join(name)) {
        // A file that does not parse is treated as absent: the next connect replaces it.
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).ok()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Writes `value` to `dir/name`, 0600, through a temporary file so a crash never leaves half a
/// secret.
fn save<T: Serialize>(dir: &Path, name: &str, value: &T) -> Result<(), CredentialError> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_helper_command_survives_spaces_and_quotes_in_the_path() {
        assert_eq!(
            helper_command(Path::new("/home/me/.workroom/workroomd")),
            "!'/home/me/.workroom/workroomd' credential"
        );
        assert_eq!(
            helper_command(Path::new("/a b/it's/workroomd")),
            r"!'/a b/it'\''s/workroomd' credential"
        );
    }
}
