//! `workroom update`: replaces this binary with the newest build on its release channel, from
//! GitHub Releases, as the Go CLI's `internal/updater` did.
//!
//! - **Channels** (`channel.rs`): stable asks for GitHub's `/releases/latest`; pre lists
//!   `/releases` and takes the newest stable or prerelease by SemVer precedence; nightly reads the
//!   fixed `nightly` release, whose name carries `X.Y.Z-nightly.<count>`, ordered by the count.
//!   `--channel stable|pre` switches (installing that channel's newest even when it is older) and
//!   is remembered in config.json; the Nightly build (`workroom-nightly`) always tracks nightly.
//! - **Verified:** the archive must match its line in the release's `checksums.txt`, and a
//!   release without one is refused before anything is downloaded (Go installed it with a
//!   warning). `--check` still reports it, saying it can't be installed.
//! - **Over https only,** each redirect included, with certificates checked as the system checks
//!   them, as Go's `crypto/tls` did: the keychain on macOS, the CA bundle on Linux
//!   (rustls-platform-verifier). A Linux host with no CA bundle fails closed (`Web::get`).
//! - **Swapped atomically:** the new binary is written beside the file this one resolves to
//!   through any symlinks, given its mode, and renamed over it. A process running the old file,
//!   a daemon (`workroom serve`) included, keeps running it: nothing is handed off or signalled.
//! - **Managed installs are refused** (`ManagedInstall`): a copy inside an app bundle is the
//!   app's, which Sparkle updates, and a daemon in a host's daemon directory is the app's
//!   bootstrap's, which pushes it. `--check` only reads, so it runs anywhere, as Go's does.
//!
//! As in Go, what `update` prints is text, `--json` or not.

use std::fmt::Display;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Deserialize;

use super::channel::{self, Channel};
use super::config::Config;
use super::kind::{CliError, Kind};
use super::{Args, Context, Flag, Outcome};

/// `update`'s own flags, in `--help`'s order.
pub(super) const FLAGS: &[Flag] = &[
    Flag {
        name: "channel",
        short: None,
        takes_value: true,
        usage: "Release channel: stable or pre (remembered for next time)",
        default: "",
        hidden: false,
        required: false,
    },
    Flag {
        name: "check",
        short: Some('c'),
        takes_value: false,
        usage: "Only check if an update is available",
        default: "",
        hidden: false,
        required: false,
    },
];

/// What `update --help` says first: Go's text.
pub(super) const LONG: &str =
    "Check for and install the latest version of workroom from GitHub Releases.

Use --channel to choose a release channel for this (main) binary:
  stable   GA releases only (default)
  pre      betas / release candidates, plus stable

Passing --channel switches you to that channel (installing its latest build even if that
means a downgrade) and remembers it. Nightly is not a channel switch \u{2014} it's a separate
side-by-side install (a `workroom-nightly` binary); see the install script's WORKROOM_CHANNEL.";

/// Where the releases are.
const RELEASES_API: &str = "https://api.github.com/repos/joelmoss/workroom/releases";

/// The release asset that lists each archive's SHA-256 (goreleaser's `checksum.name_template`).
const CHECKSUMS_ASSET: &str = "checksums.txt";

/// The binary inside each release archive.
const ARCHIVE_BINARY: &str = "workroom";

/// The most of one response read: an archive is tens of MB.
const MAX_BODY: u64 = 1 << 30;

/// The most redirects one GET follows (ureq's own default).
const MAX_REDIRECTS: usize = 10;

/// The installed daemon's file name on a host (ADR 0057), which bootstrap stages as
/// `workroomd.new.*` first.
const DAEMON_FILE: &str = "workroomd";

/// The daemon's socket, which bootstrap installs the daemon beside (`DaemonInstall.binary`).
const DAEMON_SOCKET: &str = "workroomd.sock";

const NIGHTLY_SEPARATE_INSTALL: &str = "nightly is a separate install, not a channel switch \u{2014} install it alongside this binary with:
  WORKROOM_CHANNEL=nightly curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
that installs a `workroom-nightly` binary next to `workroom`";

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    // As Go's `config.New("")`, before anything else: no HOME, and `update` does nothing.
    let config = match Config::new(context) {
        Ok(config) => config,
        Err(error) => return Outcome::Failed(error),
    };
    let request = Request {
        check: args.is_set("check"),
        channel: args.value("channel"),
    };
    let updater = Updater {
        releases: RELEASES_API.to_string(),
        version: super::VERSION,
        baked: super::BAKED_CHANNEL,
        target: Target::current(),
        executable: std::env::current_exe(),
        config,
        pretend: context.pretend,
        verbose: context.verbose,
    };
    updater.run(&request)
}

/// What was asked for.
struct Request<'a> {
    check: bool,
    /// `--channel`'s value, when it was given.
    channel: Option<&'a str>,
}

/// The os and arch in a release archive's name, as Go names them.
#[derive(Clone, Copy)]
struct Target {
    os: &'static str,
    arch: &'static str,
}

impl Target {
    fn current() -> Target {
        Target {
            os: match std::env::consts::OS {
                "macos" => "darwin",
                os => os,
            },
            arch: match std::env::consts::ARCH {
                "x86_64" => "amd64",
                "aarch64" => "arm64",
                arch => arch,
            },
        }
    }
}

/// One run of `update`, with everything it depends on outside itself, so a test can point it at a
/// fake releases server and a binary of its own.
struct Updater<'a> {
    /// The releases API: `RELEASES_API`, but for a test, whose plain-http origin is then the one
    /// that isn't https `update` may reach (`Web`).
    releases: String,
    /// This binary's version.
    version: &'a str,
    /// The channel baked in at build time (`nightly` for the Nightly build).
    baked: Option<&'a str>,
    target: Target,
    /// This binary, as the OS reports it (before symlinks are resolved).
    executable: io::Result<PathBuf>,
    /// config.json, which holds the remembered channel.
    config: Config,
    pretend: bool,
    verbose: bool,
}

impl Updater<'_> {
    fn run(&self, request: &Request) -> Outcome {
        let mut out = String::new();
        match self.update(request, &mut out) {
            Ok(()) => Outcome::Printed(out),
            Err(error) if out.is_empty() => Outcome::Failed(error),
            Err(error) => Outcome::PrintedThenFailed(out, error),
        }
    }

    fn update(&self, request: &Request, out: &mut String) -> Result<(), CliError> {
        let configured = self.config.channel();
        let (channel, explicit) = resolve_channel(self.baked, request.channel, &configured)
            .map_err(CliError::internal)?;

        // --check never installs and never writes config.
        if request.check {
            return self.check(channel, out);
        }

        let binary = resolve_self(&self.executable)?;
        if let Some(manager) = managed(&binary) {
            return Err(CliError::new(Kind::ManagedInstall, manager.message()));
        }
        if self.version == "dev" {
            return Err(CliError::internal(
                "cannot update a dev build \u{2014} install from a release instead",
            ));
        }

        out.push_str(&format!("Checking the {} channel...\n", channel.as_str()));
        let release = self.latest(channel)?;
        let current = self.version;
        if is_newer_in_channel(channel, current, &release.version) {
            out.push_str(&format!(
                "Update available: {current} \u{2192} {}\n",
                release.version
            ));
        } else if explicit && release.version != current {
            out.push_str(&format!(
                "Switching to the {} channel: {current} \u{2192} {} (downgrade)\n",
                channel.as_str(),
                release.version
            ));
        } else {
            out.push_str(&format!("Already up-to-date ({current})\n"));
            return self.remember(channel, explicit, &configured);
        }

        let checksums = release.checksum_url.as_deref().ok_or_else(|| {
            CliError::internal(format!(
                "release {} has no checksums.txt, so its archive can't be verified \u{2014} \
                 not installing it",
                release.tag
            ))
        })?;
        if self.pretend {
            out.push_str(&format!(
                "(pretend) Would download and install {}\n",
                release.version
            ));
            return Ok(());
        }
        if self.verbose {
            out.push_str(&format!("Downloading {}\n", release.asset_url));
        }
        let archive = self
            .get(&release.asset_url, None)
            .and_then(|response| response.ok("download returned status"))
            .map_err(|error| CliError::internal(format!("failed to download update: {error}")))?;
        self.verify(&archive, &release, checksums, out)?;
        swap(&binary, &archive)?;
        out.push_str(&format!(
            "Updated workroom {current} \u{2192} {}\n",
            release.version
        ));
        self.remember(channel, explicit, &configured)
    }

    fn check(&self, channel: Channel, out: &mut String) -> Result<(), CliError> {
        if self.version == "dev" {
            out.push_str("Running dev build \u{2014} cannot check for updates\n");
            return Ok(());
        }
        out.push_str(&format!("Checking the {} channel...\n", channel.as_str()));
        let release = self.latest(channel)?;
        if is_newer_in_channel(channel, self.version, &release.version) {
            out.push_str(&format!(
                "Update available: {} \u{2192} {}\n",
                self.version, release.version
            ));
            out.push_str(if release.checksum_url.is_some() {
                "Run 'workroom update' to install\n"
            } else {
                "It can't be verified (its release has no checksums.txt), so 'workroom update' \
                 won't install it\n"
            });
        } else {
            out.push_str(&format!("Already up-to-date ({})\n", self.version));
        }
        Ok(())
    }

    /// Records an explicit switch once it has worked, and only when it changes config, so config
    /// never names a channel the binary didn't move onto.
    fn remember(&self, channel: Channel, explicit: bool, configured: &str) -> Result<(), CliError> {
        if explicit && !self.pretend && channel.as_str() != configured {
            self.config.set_channel(channel.as_str())?;
        }
        Ok(())
    }

    /// The newest release on `channel` for this os and arch.
    fn latest(&self, channel: Channel) -> Result<Release, CliError> {
        match channel {
            Channel::Stable => {
                self.release_archive(self.get_json(&format!("{}/latest", self.releases))?)
            }
            Channel::Pre => {
                let releases: Vec<GithubRelease> =
                    self.get_json(&format!("{}?per_page=100", self.releases))?;
                let best = releases
                    .into_iter()
                    .filter(|release| !release.draft)
                    .filter(|release| {
                        channel::classify(&release.tag_name)
                            .is_some_and(|tag| channel::accepts(Channel::Pre, tag))
                    })
                    .fold(None::<GithubRelease>, |best, release| match best {
                        Some(best) if !is_newer(&best.tag_name, &release.tag_name) => Some(best),
                        _ => Some(release),
                    })
                    .ok_or_else(|| {
                        CliError::internal(format!("no release found for channel {:?}", "pre"))
                    })?;
                self.release_archive(best)
            }
            Channel::Nightly => self.release_archive(self.get_json(&format!(
                "{}/tags/{}",
                self.releases,
                channel::NIGHTLY_TAG
            ))?),
        }
    }

    /// GETs `url` as [`Web::get`] does, reaching plain http only at a test's releases server.
    fn get(&self, url: &str, accept: Option<&str>) -> Result<Response, String> {
        Web::for_releases(&self.releases).get(url, accept)
    }

    fn get_json<T: for<'de> Deserialize<'de>>(&self, url: &str) -> Result<T, CliError> {
        let response = self
            .get(url, Some("application/vnd.github.v3+json"))
            .map_err(|error| CliError::internal(format!("failed to check for updates: {error}")))?;
        let body = response
            .ok("GitHub API returned status")
            .map_err(CliError::internal)?;
        serde_json::from_slice(&body)
            .map_err(|error| CliError::internal(format!("failed to parse release info: {error}")))
    }

    /// `release`'s archive for this os and arch. Its version is the release's name when it has one
    /// (the nightly's `X.Y.Z-nightly.<count>`), else its tag.
    fn release_archive(&self, release: GithubRelease) -> Result<Release, CliError> {
        let fragment = format!("_{}_{}.", self.target.os, self.target.arch);
        let asset = release
            .assets
            .iter()
            .find(|asset| asset.name.contains(&fragment))
            .ok_or_else(|| {
                CliError::internal(format!(
                    "no {}/{} asset in release {:?}",
                    self.target.os, self.target.arch, release.tag_name
                ))
            })?;
        let checksum_url = release
            .assets
            .iter()
            .find(|asset| asset.name == CHECKSUMS_ASSET)
            .map(|asset| asset.browser_download_url.clone());
        Ok(Release {
            version: match release.name.as_deref() {
                Some(name) if !name.is_empty() => name.to_string(),
                _ => release.tag_name.clone(),
            },
            asset_name: asset.name.clone(),
            asset_url: asset.browser_download_url.clone(),
            checksum_url,
            tag: release.tag_name,
        })
    }

    /// Checks `archive` against the release's `checksums.txt`, at `checksums`.
    fn verify(
        &self,
        archive: &[u8],
        release: &Release,
        checksums: &str,
        out: &mut String,
    ) -> Result<(), CliError> {
        let sums = self
            .get(checksums, None)
            .map_err(|error| CliError::internal(format!("failed to download checksums: {error}")))?
            .ok("checksums download returned status")
            .map_err(CliError::internal)?;
        let want = checksum_for(&String::from_utf8_lossy(&sums), &release.asset_name).ok_or_else(
            || CliError::internal(format!("no checksum entry for {}", release.asset_name)),
        )?;
        let got = crate::util::sha256_hex(archive);
        if !got.eq_ignore_ascii_case(&want) {
            return Err(CliError::internal(format!(
                "checksum mismatch for {} (expected {want}, got {got})",
                release.asset_name
            )));
        }
        if self.verbose {
            out.push_str(&format!("Checksum verified ({})\n", release.asset_name));
        }
        Ok(())
    }
}

/// Which channel `update` acts on, and whether the user chose it (`--channel`), which lets it
/// install an older build and is then remembered.
///
/// The Nightly build always tracks nightly and refuses `--channel`. The main binary takes
/// `--channel stable|pre`; without it, config's channel, with anything else there (a `nightly`
/// an older CLI wrote included) read as stable, so a plain `update` never breaks.
fn resolve_channel(
    baked: Option<&str>,
    flag: Option<&str>,
    configured: &str,
) -> Result<(Channel, bool), String> {
    if baked == Some(Channel::Nightly.as_str()) {
        if flag.is_some() {
            return Err(
                "workroom-nightly always tracks the nightly channel; --channel does not apply"
                    .to_string(),
            );
        }
        return Ok((Channel::Nightly, false));
    }
    if let Some(flag) = flag {
        return match Channel::parse(flag) {
            Some(Channel::Nightly) => Err(NIGHTLY_SEPARATE_INSTALL.to_string()),
            Some(channel) => Ok((channel, true)),
            None => Err(format!("invalid channel {flag:?} (want stable or pre)")),
        };
    }
    match Channel::parse(configured) {
        Some(Channel::Nightly) | None => Ok((Channel::Stable, false)),
        Some(channel) => Ok((channel, false)),
    }
}

/// What owns an install `update` must not replace.
#[derive(Debug, PartialEq, Eq)]
enum Manager {
    /// The Workroom app bundles it, and Sparkle updates the bundle.
    AppBundle,
    /// The app's daemon bootstrap installed it on a host, and pushes each newer one.
    DaemonDirectory,
}

impl Manager {
    fn message(&self) -> &'static str {
        match self {
            Manager::AppBundle => {
                "this workroom is bundled inside the Workroom app and is managed by it \u{2014} \
                 update via the app's \"Check for Updates\u{2026}\" instead"
            }
            Manager::DaemonDirectory => {
                "this workroom is the daemon the Workroom app installed on this host and is \
                 managed by it \u{2014} the app installs each newer build when it connects"
            }
        }
    }
}

/// Who manages the install at `binary` (symlinks resolved), if anyone does.
///
/// - The app bundle: anything inside `<name>.app/Contents/`, as Go's `inAppBundle` tests.
/// - A host's daemon directory: bootstrap installs the daemon as `workroomd` (ADR 0057; staged as
///   `workroomd.new.*`) beside its socket (`DaemonInstall.binary`), and the `workroom` link
///   beside it resolves to that file. A container's daemon folder has no socket in it, hence
///   the name too.
fn managed(binary: &Path) -> Option<Manager> {
    if binary.to_string_lossy().contains(".app/Contents/") {
        return Some(Manager::AppBundle);
    }
    let name = binary.file_name()?.to_string_lossy();
    let staged = name
        .strip_prefix(DAEMON_FILE)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with(".new."));
    let beside_socket = binary
        .parent()
        .is_some_and(|dir| dir.join(DAEMON_SOCKET).exists());
    (staged || beside_socket).then_some(Manager::DaemonDirectory)
}

/// This binary's own file, through any symlinks.
fn resolve_self(executable: &io::Result<PathBuf>) -> Result<PathBuf, CliError> {
    let executable = executable
        .as_ref()
        .map_err(|error| CliError::internal(format!("failed to find current binary: {error}")))?;
    fs::canonicalize(executable)
        .map_err(|error| CliError::internal(format!("failed to resolve binary path: {error}")))
}

/// Puts `archive`'s binary in place of `binary`: written beside it under a name of its own, given
/// its mode, and renamed over it, so `binary` is always one whole file, the old or the new, and a
/// process running the old one keeps its file. On any failure `binary` is left as it was.
///
/// The staged file is removed on failure only once this run has created it (`create_new`): a
/// file already at that name (another run's, or anyone's) is never this run's to delete.
fn swap(binary: &Path, archive: &[u8]) -> Result<(), CliError> {
    let mode = fs::metadata(binary)
        .map_err(|error| CliError::internal(format!("failed to stat current binary: {error}")))?
        .permissions()
        .mode();
    let dir = binary.parent().unwrap_or(Path::new("/"));
    let name = binary.file_name().unwrap_or_default().to_string_lossy();
    let staged = dir.join(format!(".{name}.update-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o700)
        .open(&staged)
        .map_err(|error| {
            CliError::internal(format!(
                "failed to replace binary: cannot write in {}: {error}",
                dir.display()
            ))
        })?;
    let result = (|| {
        extract(archive, &mut file)
            .map_err(|error| CliError::internal(format!("failed to extract update: {error}")))?;
        let replace =
            |error: io::Error| CliError::internal(format!("failed to replace binary: {error}"));
        file.sync_all().map_err(replace)?;
        drop(file);
        fs::set_permissions(&staged, fs::Permissions::from_mode(mode))
            .map_err(|error| CliError::internal(format!("failed to set permissions: {error}")))?;
        fs::rename(&staged, binary).map_err(replace)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&staged);
    }
    result
}

/// Copies the `workroom` file in the gzipped tar `archive` to `out`.
fn extract(archive: &[u8], out: &mut impl Write) -> io::Result<()> {
    let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
    for entry in tar.entries()? {
        let mut entry = entry?;
        let path = entry.path()?;
        if path.file_name().is_some_and(|name| name == ARCHIVE_BINARY)
            && entry.header().entry_type().is_file()
        {
            io::copy(&mut entry, out)?;
            return Ok(());
        }
    }
    Err(io::Error::other(format!(
        "binary {ARCHIVE_BINARY:?} not found in archive"
    )))
}

/// The SHA-256 `checksums.txt` gives for `asset`: its lines are `<sha256>  <file>`, the file
/// written bare (goreleaser, and the nightly workflow now) or as `./<file>` (that workflow's
/// earlier `sha256sum ./*`, still in a nightly published before it changed).
fn checksum_for(sums: &str, asset: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        match fields.as_slice() {
            [sum, file] if file.strip_prefix("./").unwrap_or(file) == asset => {
                Some(sum.to_string())
            }
            _ => None,
        }
    })
}

/// A finished HTTP exchange.
struct Response {
    status: u16,
    body: Vec<u8>,
}

impl Response {
    /// The body of a 200, else `<what> <status>`.
    fn ok(self, what: &str) -> Result<Vec<u8>, String> {
        if self.status == 200 {
            Ok(self.body)
        } else {
            Err(format!("{what} {}", self.status))
        }
    }
}

/// How `update` reaches GitHub: over https only, each redirect included, with the system's
/// certificates.
struct Web {
    agent: ureq::Agent,
    /// The one origin (`http://host:port`) reachable without https: the releases URL's own, when
    /// a test injects a plain-http one. Never in production, whose `RELEASES_API` is https.
    http_origin: Option<String>,
}

impl Web {
    fn for_releases(releases: &str) -> Web {
        let http_origin = releases
            .strip_prefix("http://")
            .and_then(|_| origin(releases))
            .map(str::to_string);
        let tls = ureq::tls::TlsConfig::builder()
            .root_certs(ureq::tls::RootCerts::PlatformVerifier)
            .unversioned_rustls_crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .build();
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            // Redirects are followed in `get`, which checks each hop.
            .max_redirects(0)
            .https_only(http_origin.is_none())
            .tls_config(tls)
            .build()
            .into();
        Web { agent, http_origin }
    }

    /// Whether `url` may be requested: https, or a test's releases server.
    fn allows(&self, url: &str) -> bool {
        url.get(.."https://".len())
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("https://"))
            || self
                .http_origin
                .as_deref()
                .is_some_and(|allowed| origin(url) == Some(allowed))
    }

    /// GETs `url`, following redirects (GitHub's downloads redirect to its CDN), each of which
    /// must be https too.
    ///
    /// On Linux the system's CA bundle is read when the first https connection is made; a host
    /// without one fails that request ("No CA certificates were loaded from the system") and
    /// nothing is installed.
    fn get(&self, url: &str, accept: Option<&str>) -> Result<Response, String> {
        if !self.allows(url) {
            return Err(describe(url, "refused: not an https URL"));
        }
        let mut url = url.to_string();
        for _ in 0..=MAX_REDIRECTS {
            let mut request = self.agent.get(&url);
            if let Some(accept) = accept {
                request = request.header("Accept", accept);
            }
            let mut response = request.call().map_err(|error| describe(&url, error))?;
            let status = response.status().as_u16();
            if matches!(status, 301 | 302 | 303 | 307 | 308) {
                let location = response
                    .headers()
                    .get("location")
                    .and_then(|value| value.to_str().ok())
                    .ok_or_else(|| describe(&url, format!("{status} without a Location")))?;
                let next = redirect_target(&url, location)
                    .ok_or_else(|| describe(&url, format!("unusable redirect to {location:?}")))?;
                if !self.allows(&next) {
                    return Err(describe(
                        &url,
                        format!("refused a redirect to {next:?}: not an https URL"),
                    ));
                }
                url = next;
                continue;
            }
            let body = response
                .body_mut()
                .with_config()
                .limit(MAX_BODY)
                .read_to_vec()
                .map_err(|error| describe(&url, error))?;
            return Ok(Response { status, body });
        }
        Err(describe(
            &url,
            format!("stopped after {MAX_REDIRECTS} redirects"),
        ))
    }
}

/// `url`'s `scheme://authority`, the authority ending at the first `/`, `?` or `#`; `None` for
/// what isn't an absolute URL.
fn origin(url: &str) -> Option<&str> {
    let scheme = &url[..url.find("://")?];
    if scheme.is_empty()
        || !scheme
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(&b))
    {
        return None;
    }
    let after_scheme = scheme.len() + "://".len();
    let end = url[after_scheme..]
        .find(['/', '?', '#'])
        .map_or(url.len(), |at| after_scheme + at);
    (end > after_scheme).then(|| &url[..end])
}

/// Where a redirect from `from` to `location` goes: an absolute URL, or a path on `from`'s
/// origin. A relative path (which GitHub never sends) isn't followed.
fn redirect_target(from: &str, location: &str) -> Option<String> {
    if origin(location).is_some() {
        return Some(location.to_string());
    }
    if let Some(rest) = location.strip_prefix("//") {
        let scheme = &from[..from.find("://")?];
        return Some(format!("{scheme}://{rest}"));
    }
    location
        .starts_with('/')
        .then(|| Some(format!("{}{location}", origin(from)?)))
        .flatten()
}

fn describe(url: &str, error: impl Display) -> String {
    format!("Get {url:?}: {error}")
}

/// A release as GitHub's API describes it. GitHub's own `prerelease` flag is deliberately not
/// read: the tag's channel (`channel::classify`) decides.
#[derive(Deserialize)]
struct GithubRelease {
    #[serde(default)]
    tag_name: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<GithubAsset>,
}

#[derive(Deserialize)]
struct GithubAsset {
    #[serde(default)]
    name: String,
    #[serde(default)]
    browser_download_url: String,
}

/// The release to install, and how to check it.
struct Release {
    tag: String,
    version: String,
    asset_name: String,
    asset_url: String,
    checksum_url: Option<String>,
}

/// Whether `candidate` is a newer build than `current` on `channel`: by SemVer precedence, but
/// for nightly by the commit count in `X.Y.Z-nightly.<count>`, which stays right when the
/// nightly's base version moves. A current that isn't a nightly (just switched onto it) is older
/// than any nightly.
fn is_newer_in_channel(channel: Channel, current: &str, candidate: &str) -> bool {
    if channel == Channel::Nightly {
        return match (nightly_build(current), nightly_build(candidate)) {
            (Some(current), Some(candidate)) => candidate > current,
            (_, candidate) => candidate.is_some(),
        };
    }
    is_newer(current, candidate)
}

/// The commit count of a nightly version, `X.Y.Z-nightly.<count>`.
fn nightly_build(version: &str) -> Option<i64> {
    let at = version.rfind("-nightly.")?;
    version[at + "-nightly.".len()..].parse().ok()
}

/// Whether `latest` has higher SemVer 2.0 precedence than `current` (either may omit the `v`), as
/// Go's `golang.org/x/mod/semver` compares; false when either doesn't parse.
fn is_newer(current: &str, latest: &str) -> bool {
    match (SemVer::parse(current), SemVer::parse(latest)) {
        (Some(current), Some(latest)) => current.precedence(&latest) == std::cmp::Ordering::Less,
        _ => false,
    }
}

/// A version as `golang.org/x/mod/semver` reads it: `v1`, `v1.2` and `v1.2.3`, the short forms
/// only without a prerelease or build.
struct SemVer<'a> {
    core: [&'a str; 3],
    prerelease: Option<&'a str>,
}

impl<'a> SemVer<'a> {
    fn parse(version: &'a str) -> Option<SemVer<'a>> {
        let v = version.strip_prefix('v').unwrap_or(version);
        let (v, build) = match v.split_once('+') {
            Some((v, build)) => (v, Some(build)),
            None => (v, None),
        };
        let (core, prerelease) = match v.split_once('-') {
            Some((core, prerelease)) => (core, Some(prerelease)),
            None => (v, None),
        };
        let parts: Vec<&str> = core.split('.').collect();
        if parts.is_empty()
            || parts.len() > 3
            || (parts.len() < 3 && (prerelease.is_some() || build.is_some()))
            || !parts.iter().all(|part| numeric(part))
        {
            return None;
        }
        let identifiers_ok = |text: &str, strict_numbers: bool| {
            text.split('.').all(|id| {
                !id.is_empty()
                    && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                    && (!strict_numbers || !id.bytes().all(|b| b.is_ascii_digit()) || numeric(id))
            })
        };
        if !prerelease.is_none_or(|pre| identifiers_ok(pre, true))
            || !build.is_none_or(|build| identifiers_ok(build, false))
        {
            return None;
        }
        let mut full = ["0"; 3];
        full[..parts.len()].copy_from_slice(&parts);
        Some(SemVer {
            core: full,
            prerelease,
        })
    }

    fn precedence(&self, other: &SemVer) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        for (a, b) in self.core.iter().zip(other.core.iter()) {
            match compare_numbers(a, b) {
                Ordering::Equal => continue,
                order => return order,
            }
        }
        match (self.prerelease, other.prerelease) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(a), Some(b)) => {
                let mut a = a.split('.');
                let mut b = b.split('.');
                loop {
                    match (a.next(), b.next()) {
                        (None, None) => return Ordering::Equal,
                        (None, Some(_)) => return Ordering::Less,
                        (Some(_), None) => return Ordering::Greater,
                        (Some(x), Some(y)) => {
                            let order = match (all_digits(x), all_digits(y)) {
                                (true, true) => compare_numbers(x, y),
                                (true, false) => Ordering::Less,
                                (false, true) => Ordering::Greater,
                                (false, false) => x.cmp(y),
                            };
                            if order != Ordering::Equal {
                                return order;
                            }
                        }
                    }
                }
            }
        }
    }
}

fn all_digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

/// A SemVer number: digits, with no leading zero unless it is `0`.
fn numeric(text: &str) -> bool {
    all_digits(text) && (text == "0" || !text.starts_with('0'))
}

/// Two numbers without leading zeros, compared without parsing (so of any length).
fn compare_numbers(a: &str, b: &str) -> std::cmp::Ordering {
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

#[cfg(test)]
mod tests;
