//! `~/.config/workroom/config.json`, or `$WORKROOM_CONFIG`: the Mac's record of its projects and
//! workrooms, read and written as the Go CLI does (ADR 0078), so either binary can follow the
//! other.
//!
//! The file is untyped JSON (`json`): a write keeps every key neither binary knows, and the app's
//! opaque `host` descriptors, exactly as written, and lays the file out as Go's `MarshalIndent`
//! does. Its schema stays version 2 (`version` reports it).
//!
//! Each read-modify-write holds `<path>.lock` with `flock(2)`, the lock Go takes through
//! gofrs/flock, so the Rust and Go binaries and the app's bundled CLI serialise against each other.
//! The lock is best-effort, as Go's is: trouble taking it, or a holder that keeps it past 30
//! seconds, and the change goes ahead unlocked rather than failing or hanging. Each write goes to a
//! temporary file that is renamed over the config, so a reader never sees half a file.

mod json;

use std::collections::BTreeMap;
use std::ffi::CString;
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub(crate) use json::Json;
use json::Object;

use super::Context;
use super::kind::{CliError, Kind};

/// The variable naming a config file to use in place of the default: a Dev build of the app keeps
/// its own, so what it creates never shows in a Release or Nightly build.
const CONFIG_ENV: &str = "WORKROOM_CONFIG";

/// Where workrooms go when config names no `workrooms_dir`.
const DEFAULT_WORKROOMS_DIR: &str = "~/workrooms";

/// How long a write waits for another process's lock before going ahead without it: a backstop for
/// a wedged holder, not a throttle, since a config read-modify-write takes milliseconds.
const LOCK_BACKSTOP: Duration = Duration::from_secs(30);

/// How often a write waiting for the lock tries again, as Go's does.
const LOCK_RETRY: Duration = Duration::from_millis(10);

/// The config file one run reads and writes.
pub(crate) struct Config {
    path: PathBuf,
}

impl Config {
    /// `$WORKROOM_CONFIG` when set, else `~/.config/workroom/config.json`, as Go's `config.New("")`
    /// finds it.
    pub(crate) fn new(context: &Context) -> Result<Config, CliError> {
        if let Some(path) = context.env(CONFIG_ENV).filter(|path| !path.is_empty()) {
            return Ok(Config {
                path: PathBuf::from(path),
            });
        }
        let home = home_dir(context)
            .map_err(|error| CliError::internal(format!("determine home directory: {error}")))?;
        Ok(Config {
            path: Path::new(&home).join(".config/workroom/config.json"),
        })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// The config: an object, or `null` as Go reads that, or an empty object when there is no file.
    pub(crate) fn read(&self) -> Result<Json, CliError> {
        let failed = |detail: String| {
            CliError::new(
                Kind::ConfigReadFailed,
                format!("failed to read config {}: {detail}", self.path.display()),
            )
        };
        let bytes = match std::fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(Json::Object(Object::new()));
            }
            Err(error) => {
                return Err(failed(format!(
                    "open {}: {}",
                    self.path.display(),
                    os_error(&error)
                )));
            }
        };
        json::parse_config(&bytes).map_err(failed)
    }

    /// Writes `data` as Go would, atomically: to a temporary file beside the config, flushed to
    /// disk, then renamed over it.
    fn write(&self, data: &Json) -> Result<(), CliError> {
        let failed = |detail: String| {
            CliError::new(
                Kind::ConfigWriteFailed,
                format!("failed to write config{detail}"),
            )
        };
        let dir = self.path.parent().unwrap_or(Path::new("."));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o755)
            .create(dir)
            .map_err(|error| {
                failed(format!(
                    ": create config directory {}: {}",
                    dir.display(),
                    os_error(&error)
                ))
            })?;
        let text = json::write_indented(data);
        let (tmp, mut file) = create_temp(dir)
            .map_err(|error| failed(format!(": create temp file: {}", os_error(&error))))?;
        let at = |error: io::Error| failed(format!(" {}: {}", tmp.display(), os_error(&error)));
        let written = file
            .write_all(text.as_bytes())
            .and_then(|()| file.sync_all())
            .map_err(at);
        drop(file);
        let result = written
            .and_then(|()| {
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644)).map_err(at)
            })
            .and_then(|()| {
                std::fs::rename(&tmp, &self.path).map_err(|error| {
                    failed(format!(" {}: {}", self.path.display(), os_error(&error)))
                })
            });
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result
    }

    /// Reads the config, lets `change` edit it, and writes it back when `change` says to, all
    /// under the config's lock.
    fn update(
        &self,
        change: impl FnOnce(&mut Json) -> Result<bool, CliError>,
    ) -> Result<(), CliError> {
        let _lock = Lock::take(&self.path);
        let mut data = self.read()?;
        if change(&mut data)? {
            self.write(&data)?;
        }
        Ok(())
    }

    /// Stores `vcs` as an already registered project's type, and does nothing for a project that
    /// isn't registered: it never creates one.
    pub(crate) fn set_project_vcs(&self, project: &str, vcs: &str) -> Result<(), CliError> {
        self.update(|data| {
            let Some(entry) = top_level(data)
                .get_mut(project)
                .and_then(Json::as_object_mut)
            else {
                return Ok(false);
            };
            entry.insert("vcs".to_string(), Json::String(vcs.to_string()));
            Ok(true)
        })
    }

    /// Stores the branch new workrooms start from in a project that names none; "" removes it.
    pub(crate) fn set_global_base_branch(&self, branch: &str) -> Result<(), CliError> {
        self.update(|data| {
            if branch.is_empty() {
                if let Json::Object(top) = data {
                    top.remove("base_branch");
                }
            } else {
                top_level(data).insert("base_branch".to_string(), Json::String(branch.to_string()));
            }
            Ok(true)
        })
    }
}

/// The top level as an object to change. A `null` config becomes an empty object first, where Go
/// would panic writing into its nil map.
fn top_level(data: &mut Json) -> &mut Object {
    if !matches!(data, Json::Object(_)) {
        *data = Json::Object(Object::new());
    }
    data.as_object_mut().expect("just made an object")
}

/// A new, empty `.config-*.json.tmp` in `dir`, readable only by its owner, as Go's
/// `os.CreateTemp` makes one.
fn create_temp(dir: &Path) -> io::Result<(PathBuf, File)> {
    use std::hash::{BuildHasher, RandomState};
    let state = RandomState::new();
    let mut last = io::Error::other("no temporary file name was free");
    for attempt in 0u32..10_000 {
        let random = state.hash_one((std::process::id(), Instant::now(), attempt)) as u32;
        let path = dir.join(format!(".config-{random}.json.tmp"));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
        {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => last = error,
            Err(error) => return Err(error),
        }
    }
    Err(last)
}

/// `<config>.lock`, held exclusively with `flock(2)` until dropped. Never deleted, as Go never
/// deletes it: another process may be waiting on that very file.
struct Lock {
    /// The open lock file, or none when the lock couldn't be taken and the change goes ahead
    /// without it.
    _file: Option<File>,
}

impl Lock {
    fn take(config: &Path) -> Lock {
        let mut path = config.as_os_str().to_owned();
        path.push(".lock");
        Lock {
            _file: Self::acquire(Path::new(&path)),
        }
    }

    fn acquire(path: &Path) -> Option<File> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o755)
            .create(path.parent()?)
            .ok()?;
        // Created if missing and opened read-only, mode 0600, as gofrs/flock opens it. std's
        // OpenOptions can't create a file it opens read-only.
        let name = CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: `name` is a NUL-terminated path that lives across the call, and open(2) takes the
        // flags and mode as plain integers.
        let fd = unsafe {
            libc::open(
                name.as_ptr(),
                libc::O_CREAT | libc::O_RDONLY | libc::O_CLOEXEC,
                0o600 as libc::c_uint,
            )
        };
        if fd < 0 {
            return None;
        }
        // SAFETY: `fd` was just opened and nothing else owns it, so the File may close it.
        let file = unsafe { File::from_raw_fd(fd) };
        let deadline = Instant::now() + LOCK_BACKSTOP;
        loop {
            // SAFETY: the descriptor belongs to `file`, which is open for the call.
            let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if rc == 0 {
                return Some(file);
            }
            let held = io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK);
            if !held || Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(LOCK_RETRY);
        }
    }
}

/// One workroom entry under a project's `workrooms`.
pub(crate) struct Workroom {
    pub(crate) path: String,
    /// The entry's `host` descriptor, or none for a workroom on this Mac. The app owns its schema;
    /// any value but `null` counts as present, so a malformed one still keeps a remote workroom
    /// away from every local-path operation.
    pub(crate) host: Option<Json>,
}

impl Workroom {
    pub(crate) fn is_remote(&self) -> bool {
        self.host.is_some()
    }

    /// Whether the provider destroyed the workroom's host, as its descriptor's `state` records.
    pub(crate) fn host_destroyed(&self) -> bool {
        self.host
            .as_ref()
            .and_then(Json::as_object)
            .and_then(|host| host.get("state"))
            .and_then(Json::as_str)
            == Some("destroyed")
    }
}

/// One project entry, read-only. A value of the wrong type reads as missing, so a hand-edited
/// entry degrades rather than failing.
pub(crate) struct Project {
    pub(crate) vcs: String,
    /// The project's `host` descriptor, verbatim and interpreted nowhere.
    pub(crate) host: Option<Json>,
    /// The branch new workrooms start from; "" for origin's default branch.
    pub(crate) base_branch: String,
    pub(crate) workrooms: BTreeMap<String, Workroom>,
    /// How many entries `workrooms` holds, of any type: what Go's "has workrooms" counts.
    pub(crate) entries: usize,
}

impl Project {
    fn decode(raw: &Object) -> Project {
        let text = |key: &str| {
            raw.get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_string()
        };
        let host = |entry: &Object| {
            entry
                .get("host")
                .filter(|host| **host != Json::Null)
                .cloned()
        };
        let listed = raw.get("workrooms").and_then(Json::as_object);
        let workrooms = listed
            .into_iter()
            .flatten()
            .filter_map(|(name, entry)| {
                let entry = entry.as_object()?;
                let path = entry.get("path").and_then(Json::as_str).unwrap_or_default();
                Some((
                    name.clone(),
                    Workroom {
                        path: path.to_string(),
                        host: host(entry),
                    },
                ))
            })
            .collect();
        Project {
            vcs: text("vcs"),
            host: host(raw),
            base_branch: text("base_branch"),
            workrooms,
            entries: listed.map_or(0, BTreeMap::len),
        }
    }
}

/// Every registered project by path, those with no workrooms too. The scalar settings at the top
/// level (`workrooms_dir`, `channel`, `base_branch`) aren't objects, so they are never projects.
pub(crate) fn all_projects(data: &Json) -> BTreeMap<String, Project> {
    data.as_object()
        .into_iter()
        .flatten()
        .filter_map(|(path, entry)| Some((path.clone(), Project::decode(entry.as_object()?))))
        .collect()
}

/// Where `dir` is: the project it is the root of, or the project one of whose workrooms is at
/// `dir`, with that project's path.
pub(crate) fn find_current_project(data: &Json, dir: &str) -> Option<(String, Project)> {
    let top = data.as_object()?;
    if let Some(entry) = top.get(dir).and_then(Json::as_object) {
        return Some((dir.to_string(), Project::decode(entry)));
    }
    top.iter().find_map(|(path, entry)| {
        let entry = entry.as_object()?;
        let workrooms = entry.get("workrooms")?.as_object()?;
        workrooms
            .values()
            .any(|info| {
                info.as_object()
                    .and_then(|info| info.get("path"))
                    .and_then(Json::as_str)
                    == Some(dir)
            })
            .then(|| (path.clone(), Project::decode(entry)))
    })
}

/// The configured workrooms directory with `~` expanded, else `~/workrooms`'s.
pub(crate) fn workrooms_dir(data: &Json, context: &Context) -> Result<String, String> {
    let configured = data
        .as_object()
        .and_then(|top| top.get("workrooms_dir"))
        .and_then(Json::as_str)
        .filter(|dir| !dir.is_empty());
    expand_path(configured.unwrap_or(DEFAULT_WORKROOMS_DIR), context)
}

/// The global base branch, for projects that name none; "" for origin's default branch.
pub(crate) fn base_branch(data: &Json) -> String {
    setting(data, "base_branch").unwrap_or_default().to_string()
}

/// A top-level string setting, such as `channel`.
pub(crate) fn setting<'a>(data: &'a Json, key: &str) -> Option<&'a str> {
    data.as_object()?.get(key)?.as_str()
}

/// `$HOME`, as Go's `os.UserHomeDir` reads it.
pub(crate) fn home_dir(context: &Context) -> Result<String, String> {
    context
        .env("HOME")
        .filter(|home| !home.is_empty())
        .ok_or_else(|| "$HOME is not defined".to_string())
}

/// `path` with a leading `~` replaced by the home directory, as Go's `expandPath` does it.
fn expand_path(path: &str, context: &Context) -> Result<String, String> {
    if path == "~" || path.starts_with("~/") {
        let home =
            home_dir(context).map_err(|error| format!("determine home directory: {error}"))?;
        return Ok(join(&home, &path[1..]));
    }
    Ok(path.to_string())
}

/// `path` absolute and symlink-resolved, so a project named through a symlink or with a trailing
/// slash is one key, as Go's `CanonicalPath` makes it. A leading `~` or `~/` is the home directory
/// (the app passes a path typed into its New Project dialog raw); a path that doesn't exist is
/// only made absolute.
pub(crate) fn canonical_path(path: &str, context: &Context) -> Result<String, String> {
    let expanded = if path == "~" || path.starts_with("~/") {
        let home = home_dir(context)?;
        if path == "~" {
            home
        } else {
            join(&home, &path[2..])
        }
    } else {
        path.to_string()
    };
    let absolute = if expanded.starts_with('/') {
        clean(&expanded)
    } else {
        join(&getwd(context)?, &expanded)
    };
    Ok(match std::fs::canonicalize(&absolute) {
        Ok(resolved) => resolved.to_string_lossy().into_owned(),
        Err(_) => absolute,
    })
}

/// The current directory as Go's `os.Getwd` names it: `$PWD` when that is absolute and is this
/// directory, so a directory reached through a symlink keeps the name the shell gave it.
pub(crate) fn getwd(context: &Context) -> Result<String, String> {
    if let Some(pwd) = context.env("PWD").filter(|pwd| pwd.starts_with('/')) {
        let dot =
            std::fs::metadata(".").map_err(|error| format!("stat .: {}", os_error(&error)))?;
        if std::fs::metadata(&pwd)
            .is_ok_and(|named| named.dev() == dot.dev() && named.ino() == dot.ino())
        {
            return Ok(pwd);
        }
    }
    std::env::current_dir()
        .map(|dir| dir.to_string_lossy().into_owned())
        .map_err(|error| format!("getwd: {}", os_error(&error)))
}

/// Go's `filepath.Join` of two paths: joined, then cleaned. An empty part is left out.
fn join(base: &str, rest: &str) -> String {
    match (base.is_empty(), rest.is_empty()) {
        (true, true) => String::new(),
        (true, false) => clean(rest),
        (false, true) => clean(base),
        (false, false) => clean(&format!("{base}/{rest}")),
    }
}

/// Go's `filepath.Clean`: the shortest path naming the same file by lexical processing alone.
fn clean(path: &str) -> String {
    if path.is_empty() {
        return ".".to_string();
    }
    let rooted = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => match parts.last() {
                Some(&last) if last != ".." => {
                    parts.pop();
                }
                _ if rooted => {}
                _ => parts.push(".."),
            },
            _ => parts.push(part),
        }
    }
    let joined = parts.join("/");
    match (rooted, joined.is_empty()) {
        (true, _) => format!("/{joined}"),
        (false, true) => ".".to_string(),
        (false, false) => joined,
    }
}

/// An OS error as Go words one: "permission denied", without Rust's "(os error 13)".
fn os_error(error: &io::Error) -> String {
    let text = error.to_string();
    let text = match text.rfind(" (os error ") {
        Some(end) if error.raw_os_error().is_some() => text[..end].to_string(),
        _ => text,
    };
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => text,
    }
}

#[cfg(test)]
mod tests;
