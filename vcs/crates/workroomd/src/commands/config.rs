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
use super::channel::Channel;
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
    /// The run's coding agent above it (`Context::coding_agent_above`): under one, no approval is
    /// recorded and no project removed, whatever command asks (#793).
    coding_agent_above: fn() -> Option<String>,
}

impl Config {
    /// `$WORKROOM_CONFIG` when set, else `~/.config/workroom/config.json`, as Go's `config.New("")`
    /// finds it.
    pub(crate) fn new(context: &Context) -> Result<Config, CliError> {
        let coding_agent_above = context.coding_agent_above;
        if let Some(path) = context.env(CONFIG_ENV).filter(|path| !path.is_empty()) {
            return Ok(Config {
                path: PathBuf::from(path),
                coding_agent_above,
            });
        }
        let home = home_dir(context)
            .map_err(|error| CliError::internal(format!("determine home directory: {error}")))?;
        Ok(Config {
            path: Path::new(&home).join(".config/workroom/config.json"),
            coding_agent_above,
        })
    }

    /// The config file at `path`, as Go's `config.New(path)` names one: "" is [`Config::new`]'s.
    pub(crate) fn named(path: &str, context: &Context) -> Result<Config, CliError> {
        if path.is_empty() {
            return Config::new(context);
        }
        Ok(Config {
            path: PathBuf::from(path),
            coding_agent_above: context.coding_agent_above,
        })
    }

    /// The config file at `path`, for a test that keeps its own, with no coding agent above.
    #[cfg(test)]
    pub(crate) fn at(path: PathBuf) -> Config {
        Config {
            path,
            coding_agent_above: || None,
        }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// The release channel config names: `channel` when it is a non-empty string, else `stable`.
    /// A config that can't be read or parsed names none, as Go's `Config.Channel` reads it.
    pub(crate) fn channel(&self) -> String {
        match self
            .read()
            .as_ref()
            .ok()
            .and_then(|data| setting(data, "channel"))
        {
            Some(channel) if !channel.is_empty() => channel.to_string(),
            _ => Channel::Stable.as_str().to_string(),
        }
    }

    /// The config: an object, or `null` as Go reads that, or an empty object when there is no file.
    pub(crate) fn read(&self) -> Result<Json, CliError> {
        let failed = |detail: String| {
            CliError::new(
                Kind::ConfigReadFailed,
                format!("failed to read config {}: {detail}", self.path.display()),
            )
        };
        // Go's `os.ReadFile`, whose error names the step that failed: `open`, or `read` (a
        // directory opens but can't be read).
        let at = |step: &str, error: io::Error| {
            failed(format!(
                "{step} {}: {}",
                self.path.display(),
                os_error(&error)
            ))
        };
        let mut file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(Json::Object(Object::new()));
            }
            Err(error) => return Err(at("open", error)),
        };
        let mut bytes = Vec::new();
        io::Read::read_to_end(&mut file, &mut bytes).map_err(|error| at("read", error))?;
        json::parse_config(&bytes).map_err(failed)
    }

    /// Writes `data` as Go would, atomically: to a temporary file beside the config, flushed to
    /// disk, then renamed over it. Each failure is worded as Go's `Write` wraps it: the step's own
    /// error (`write <tmp>: …`) after the file it was writing.
    fn write(&self, data: &Json) -> Result<(), CliError> {
        let failed = |detail: String| {
            CliError::new(
                Kind::ConfigWriteFailed,
                format!("failed to write config{detail}"),
            )
        };
        // Go's `filepath.Dir`: the parent, cleaned, or "." for a bare file name.
        let dir = clean(
            &self
                .path
                .parent()
                .map(|dir| dir.to_string_lossy().into_owned())
                .unwrap_or_default(),
        );
        mkdir_all(&dir)
            .map_err(|error| failed(format!(": create config directory {dir}: {error}")))?;
        let text = json::write_indented(data);
        let (tmp, mut file) =
            create_temp(&dir).map_err(|error| failed(format!(": create temp file: {error}")))?;
        let tmp_name = tmp.display().to_string();
        let at = |step: &str, error: io::Error| {
            failed(format!(
                " {tmp_name}: {step} {tmp_name}: {}",
                os_error(&error)
            ))
        };
        let result = file
            .write_all(text.as_bytes())
            .map_err(|error| at("write", error))
            .and_then(|()| file.sync_all().map_err(|error| at("sync", error)))
            .and_then(|()| close(file).map_err(|error| at("close", error)))
            .and_then(|()| {
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644))
                    .map_err(|error| at("chmod", error))
            })
            .and_then(|()| {
                std::fs::rename(&tmp, &self.path).map_err(|error| {
                    let path = self.path.display();
                    failed(format!(
                        " {path}: rename {tmp_name} {path}: {}",
                        os_error(&error)
                    ))
                })
            });
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result
    }

    /// The config, read under its lock, as a read that must not see another process's write half
    /// done takes it.
    pub(crate) fn read_locked(&self) -> Result<Json, CliError> {
        let _lock = Lock::take(&self.path);
        self.read()
    }

    /// Reads the config, lets `change` edit it, and writes it back when `change` says to, all
    /// under the config's lock.
    pub(crate) fn update(
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

    /// Drops workroom `name`'s entry from `project`, and does nothing when either isn't there.
    pub(crate) fn remove_workroom(&self, project: &str, name: &str) -> Result<(), CliError> {
        self.update(|data| {
            let Some(workrooms) = data
                .as_object_mut()
                .and_then(|top| top.get_mut(project))
                .and_then(Json::as_object_mut)
                .and_then(|entry| entry.get_mut("workrooms"))
                .and_then(Json::as_object_mut)
            else {
                return Ok(false);
            };
            workrooms.remove(name);
            Ok(true)
        })
    }

    /// Drops `project`'s entry, touching nothing on disk; a scalar setting's key is never one. A
    /// project with a host descriptor, its own or a workroom's, is refused, checked again here
    /// under the lock: a descriptor written since the caller looked is the only record of a
    /// remote machine.
    pub(crate) fn remove_project(&self, project: &str) -> Result<(), CliError> {
        if let Some(error) = super::needs_the_user::deletion_refusal(true, self.coding_agent_above)
        {
            return Err(error);
        }
        self.update(|data| {
            if is_reserved(project) {
                return Ok(false);
            }
            if let Some(entry) = data
                .as_object()
                .and_then(|top| top.get(project))
                .and_then(Json::as_object)
            {
                let decoded = Project::decode(entry);
                if decoded.host.is_some() || decoded.workrooms.values().any(Workroom::is_remote) {
                    return Err(CliError::new(
                        Kind::RemoteWorkroomUnsupported,
                        format!(
                            "not supported for a remote workroom yet: {project} has a remote host"
                        ),
                    ));
                }
            }
            if let Json::Object(top) = data {
                top.remove(project);
            }
            // Go writes the file back even when the key wasn't there.
            Ok(true)
        })
    }

    /// Stores the release channel `update` switched to.
    pub(crate) fn set_channel(&self, channel: &str) -> Result<(), CliError> {
        self.update(|data| {
            top_level(data).insert("channel".to_string(), Json::String(channel.to_string()));
            Ok(true)
        })
    }

    /// Registers `project` with no workrooms, as Go's `AddProject` does: an entry that exists keeps
    /// everything but its `vcs`, which is refreshed, and gains an empty `workrooms` if it has none
    /// that is an object.
    pub(crate) fn add_project(&self, project: &str, vcs: &str) -> Result<(), CliError> {
        self.update(|data| {
            let top = top_level(data);
            let vcs = Json::String(vcs.to_string());
            match top.get_mut(project).and_then(Json::as_object_mut) {
                Some(entry) => {
                    entry.insert("vcs".to_string(), vcs);
                    if !entry
                        .get("workrooms")
                        .is_some_and(|w| w.as_object().is_some())
                    {
                        entry.insert("workrooms".to_string(), Json::Object(Object::new()));
                    }
                }
                None => {
                    let mut entry = Object::new();
                    entry.insert("vcs".to_string(), vcs);
                    entry.insert("workrooms".to_string(), Json::Object(Object::new()));
                    top.insert(project.to_string(), Json::Object(entry));
                }
            }
            Ok(true)
        })
    }

    /// Records workroom `name` of `project` at `path`, as Go's `AddWorkroom` does: the project's
    /// entry is made if it has none, its `vcs` refreshed, and an entry of the same name replaced
    /// whole.
    pub(crate) fn add_workroom(
        &self,
        project: &str,
        name: &str,
        path: &str,
        vcs: &str,
    ) -> Result<(), CliError> {
        self.update(|data| {
            let top = top_level(data);
            if !top
                .get(project)
                .is_some_and(|entry| entry.as_object().is_some())
            {
                let mut entry = Object::new();
                entry.insert("workrooms".to_string(), Json::Object(Object::new()));
                top.insert(project.to_string(), Json::Object(entry));
            }
            let entry = top
                .get_mut(project)
                .and_then(Json::as_object_mut)
                .expect("just made an object");
            entry.insert("vcs".to_string(), Json::String(vcs.to_string()));
            if !entry
                .get("workrooms")
                .is_some_and(|w| w.as_object().is_some())
            {
                entry.insert("workrooms".to_string(), Json::Object(Object::new()));
            }
            let mut workroom = Object::new();
            workroom.insert("path".to_string(), Json::String(path.to_string()));
            entry
                .get_mut("workrooms")
                .and_then(Json::as_object_mut)
                .expect("just made an object")
                .insert(name.to_string(), Json::Object(workroom));
            Ok(true)
        })
    }

    /// Records workroom `name` of a registered `project` as one on another host (#253), at `path`
    /// there, with its `host` descriptor, in one write: Go's `AddRemoteWorkroom`. An entry of the
    /// same name is refused rather than replaced, since its descriptor may be the only record of a
    /// remote machine.
    pub(crate) fn add_remote_workroom(
        &self,
        project: &str,
        name: &str,
        path: &str,
        host: Json,
    ) -> Result<(), CliError> {
        self.update(|data| {
            let entry = project_entry(data, project)?;
            if !entry
                .get("workrooms")
                .is_some_and(|w| w.as_object().is_some())
            {
                entry.insert("workrooms".to_string(), Json::Object(Object::new()));
            }
            let workrooms = entry
                .get_mut("workrooms")
                .and_then(Json::as_object_mut)
                .expect("just made an object");
            if workrooms.contains_key(name) {
                return Err(CliError::new(
                    Kind::WorkroomExists,
                    format!("a workroom of that name is already registered: '{name}' in {project}"),
                ));
            }
            let mut workroom = Object::new();
            workroom.insert("host".to_string(), host);
            workroom.insert("path".to_string(), Json::String(path.to_string()));
            workrooms.insert(name.to_string(), Json::Object(workroom));
            Ok(true)
        })
    }

    /// Stores the branch a registered project's new workrooms start from; "" removes it, so they
    /// start from the global base, else origin's default branch.
    pub(crate) fn set_base_branch(&self, project: &str, branch: &str) -> Result<(), CliError> {
        self.update(|data| {
            let entry = project_entry(data, project)?;
            if branch.is_empty() {
                entry.remove("base_branch");
            } else {
                entry.insert("base_branch".to_string(), Json::String(branch.to_string()));
            }
            Ok(true)
        })
    }

    /// Stores `host` verbatim as the `host` descriptor of a registered project (`workroom` "") or
    /// of one of its workrooms; none removes it, which turns a workroom local again. A descriptor
    /// alone is never a new entry, so the project, and the workroom, must be registered.
    pub(crate) fn set_host(
        &self,
        project: &str,
        workroom: &str,
        host: Option<Json>,
    ) -> Result<(), CliError> {
        self.update(|data| {
            let mut entry = project_entry(data, project)?;
            if !workroom.is_empty() {
                entry = entry
                    .get_mut("workrooms")
                    .and_then(Json::as_object_mut)
                    .and_then(|workrooms| workrooms.get_mut(workroom))
                    .and_then(Json::as_object_mut)
                    .ok_or_else(|| workroom_not_found(project, workroom))?;
            }
            match host {
                Some(host) => entry.insert("host".to_string(), host),
                None => entry.remove("host"),
            };
            Ok(true)
        })
    }

    /// Records `digest`, the SHA-256 (hex) of a script's exact bytes, as a registered project's
    /// approval of the script `name` (#363); "" forgets it. `trusted_scripts` holds them, and goes
    /// once it holds none; a value of the wrong type approves nothing, so it is replaced. Go's
    /// `SetTrustedScript`.
    pub(crate) fn set_trusted_script(
        &self,
        project: &str,
        name: &str,
        digest: &str,
    ) -> Result<(), CliError> {
        // Every approval comes through here (`trust`, a create's or a delete's prompt): none is
        // recorded under a coding agent. Forgetting one ("") is anyone's.
        if !digest.is_empty()
            && let Some(error) = super::needs_the_user::approval_refusal(self.coding_agent_above)
        {
            return Err(error);
        }
        self.forget_or_trust(project, &[(name, digest)])
    }

    /// Forgets every approval in `names` of a registered project's scripts, as Go's `Untrust`
    /// does with one `SetTrustedScript` for each, in one write.
    pub(crate) fn untrust(&self, project: &str, names: &[&str]) -> Result<(), CliError> {
        let changes: Vec<(&str, &str)> = names.iter().map(|name| (*name, "")).collect();
        self.forget_or_trust(project, &changes)
    }

    /// Each `(name, digest)` of `changes` recorded as [`Config::set_trusted_script`] records one.
    fn forget_or_trust(&self, project: &str, changes: &[(&str, &str)]) -> Result<(), CliError> {
        self.update(|data| {
            let entry = project_entry(data, project)?;
            let mut trusted = match entry.remove("trusted_scripts") {
                Some(Json::Object(trusted)) => trusted,
                _ => Object::new(),
            };
            for (name, digest) in changes {
                if digest.is_empty() {
                    trusted.remove(*name);
                } else {
                    trusted.insert((*name).to_string(), Json::String((*digest).to_string()));
                }
            }
            if !trusted.is_empty() {
                entry.insert("trusted_scripts".to_string(), Json::Object(trusted));
            }
            Ok(true)
        })
    }
}

/// The top-level settings that aren't projects, which no project edit may treat as one.
const RESERVED_KEYS: [&str; 3] = ["workrooms_dir", "channel", "base_branch"];

/// A registered project's entry to edit, else `ProjectNotFound`.
fn project_entry<'a>(data: &'a mut Json, project: &str) -> Result<&'a mut Object, CliError> {
    data.as_object_mut()
        .filter(|_| !is_reserved(project))
        .and_then(|top| top.get_mut(project))
        .and_then(Json::as_object_mut)
        .ok_or_else(|| project_not_found(project))
}

/// Go's `ErrProjectNotFound`, naming `project`.
pub(crate) fn project_not_found(project: &str) -> CliError {
    CliError::new(
        Kind::ProjectNotFound,
        format!("project is not registered: {project}"),
    )
}

/// Go's `ErrWorkroomNotFound`, naming `workroom` in `project`.
pub(crate) fn workroom_not_found(project: &str, workroom: &str) -> CliError {
    CliError::new(
        Kind::WorkroomNotFound,
        format!("workroom is not registered: '{workroom}' in {project}"),
    )
}

/// `text` as a host descriptor, read as Go's `decodeHost` reads one: exactly one JSON object,
/// numbers kept as written. `null` (which would clear the descriptor), any other value, trailing
/// data and what isn't JSON are none.
pub(crate) fn host_descriptor(text: &str) -> Option<Json> {
    json::parse_config(text.as_bytes())
        .ok()
        .filter(|host| *host != Json::Null)
}

/// Whether `key` is a scalar setting's at the top level rather than a project path (Go's
/// `reservedKeys`).
pub(crate) fn is_reserved(key: &str) -> bool {
    RESERVED_KEYS.contains(&key)
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
/// `os.CreateTemp` makes one, failing with Go's words: the failed open's, or `createtemp` when
/// every name tried was taken.
fn create_temp(dir: &str) -> Result<(PathBuf, File), String> {
    use std::hash::{BuildHasher, RandomState};
    let prefix = if dir.ends_with('/') {
        format!("{dir}.config-")
    } else {
        format!("{dir}/.config-")
    };
    let state = RandomState::new();
    for attempt in 0u32..10_000 {
        let random = state.hash_one((std::process::id(), Instant::now(), attempt)) as u32;
        let path = PathBuf::from(format!("{prefix}{random}.json.tmp"));
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
        {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(format!("open {}: {}", path.display(), os_error(&error))),
        }
    }
    Err(format!(
        "createtemp {prefix}*.json.tmp: file already exists"
    ))
}

/// Closes `file`, reporting the error close(2) gives, which dropping a `File` ignores.
fn close(file: File) -> io::Result<()> {
    use std::os::fd::IntoRawFd;
    let fd = file.into_raw_fd();
    // SAFETY: `fd` came from `file`, which gave up ownership of it, so it is closed exactly once.
    if unsafe { libc::close(fd) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Go's `os.MkdirAll` with mode 0755: `path` and any parents it lacks, failing with Go's words for
/// the directory that couldn't be made (`mkdir <dir>: …`).
fn mkdir_all(path: &str) -> Result<(), String> {
    make_dir_all(path).map_err(|error| error.to_string())
}

/// The directory Go's `os.MkdirAll` couldn't make, and why: `mkdir <dir>: …` as Go's `PathError`
/// words it, with the OS error kept for a caller that asks which one it was (`ENOTDIR`).
pub(crate) struct MkdirError {
    pub(crate) path: String,
    pub(crate) error: io::Error,
}

impl std::fmt::Display for MkdirError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "mkdir {}: {}", self.path, os_error(&self.error))
    }
}

/// [`mkdir_all`] with the failure as a [`MkdirError`].
pub(crate) fn make_dir_all(path: &str) -> Result<(), MkdirError> {
    let refused = |at: &str, error: io::Error| MkdirError {
        path: at.to_string(),
        error,
    };
    if let Ok(info) = std::fs::metadata(path) {
        if info.is_dir() {
            return Ok(());
        }
        return Err(refused(path, io::Error::from_raw_os_error(libc::ENOTDIR)));
    }
    let trimmed = path.trim_end_matches('/');
    let parent = trimmed.rfind('/').map_or("", |slash| &path[..slash]);
    if !parent.is_empty() {
        make_dir_all(parent)?;
    }
    match std::fs::DirBuilder::new().mode(0o755).create(path) {
        Ok(()) => Ok(()),
        // An argument like "foo/." already exists once its parent does.
        Err(_) if std::fs::symlink_metadata(path).is_ok_and(|info| info.is_dir()) => Ok(()),
        Err(error) => Err(refused(path, error)),
    }
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
    /// The approved SHA-256 (hex) of each script by name, such as `workroom_setup`: the exact
    /// bytes this Mac has agreed to run (#363). A value that isn't a string is left out.
    pub(crate) trusted_scripts: BTreeMap<String, String>,
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
            trusted_scripts: raw
                .get("trusted_scripts")
                .and_then(Json::as_object)
                .into_iter()
                .flatten()
                .filter_map(|(name, digest)| Some((name.clone(), digest.as_str()?.to_string())))
                .collect(),
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
    expand_tilde(configured.unwrap_or(DEFAULT_WORKROOMS_DIR), context)
        .map_err(|error| format!("determine home directory: {error}"))
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

/// `path` with `home`, when there is one, written as `~`, as Go's `ui.DisplayPath` shows it: a
/// plain prefix, as Go's `strings.HasPrefix` takes it.
pub(crate) fn display_path(home: Option<&str>, path: &str) -> String {
    match home.and_then(|home| path.strip_prefix(home)) {
        Some(rest) => format!("~{rest}"),
        None => path.to_string(),
    }
}

/// `path` with a leading `~` or `~/` replaced by the home directory, then cleaned; any other path,
/// `~user` too, as given. Go has two of these (`expandPath`, `expandTilde`) that differ only in
/// cleaning a bare `~`, which every caller here cleans anyway, and in their error's wording, which
/// each caller adds.
fn expand_tilde(path: &str, context: &Context) -> Result<String, String> {
    if path == "~" || path.starts_with("~/") {
        return Ok(join(&home_dir(context)?, &path[1..]));
    }
    Ok(path.to_string())
}

/// `path` absolute and symlink-resolved, so a project named through a symlink or with a trailing
/// slash is one key, as Go's `CanonicalPath` makes it. A leading `~` or `~/` is the home directory
/// (the app passes a path typed into its New Project dialog raw); a path that doesn't exist is
/// only made absolute. Each name keeps the case it was given, as Go keeps it: only symlinks are
/// resolved (`eval_symlinks`), where realpath would rewrite each name to its case on disk.
pub(crate) fn canonical_path(path: &str, context: &Context) -> Result<String, String> {
    let expanded = expand_tilde(path, context)?;
    let absolute = if expanded.starts_with('/') {
        clean(&expanded)
    } else {
        join(&getwd(context)?, &expanded)
    };
    Ok(eval_symlinks(&absolute).unwrap_or(absolute))
}

/// Go's `filepath.EvalSymlinks` on Unix, step for step: `path` with every symlink in it resolved,
/// one component at a time (a relative link against the directory holding it), then cleaned.
/// Unlike realpath it keeps each component's case as written, and backs up over `..` through what
/// it has walked so far. It fails as Go's does: on a missing component, a file with more path after
/// it, or more than 255 links.
fn eval_symlinks(path: &str) -> io::Result<String> {
    /// The index of the last `/` in `dest` at or after `from`.
    fn last_slash(dest: &str, from: usize) -> Option<usize> {
        dest.get(from..)?.rfind('/').map(|index| index + from)
    }
    let mut path = path.to_string();
    let mut vol_len = usize::from(path.starts_with('/'));
    let mut vol = path[..vol_len].to_string();
    let mut dest = vol.clone();
    let mut links_walked = 0;
    let mut start = vol_len;
    while start < path.len() {
        while path.as_bytes().get(start) == Some(&b'/') {
            start += 1;
        }
        let mut end = start;
        while end < path.len() && path.as_bytes()[end] != b'/' {
            end += 1;
        }
        let component = &path[start..end];
        if component.is_empty() {
            break;
        }
        if component == "." {
            start = end;
            continue;
        }
        if component == ".." {
            match last_slash(&dest, vol_len) {
                Some(slash) if &dest[slash + 1..] != ".." => dest.truncate(slash),
                // No slash to back up to, or a ".." that had to be kept: keep this one too.
                _ => {
                    if dest.len() > vol_len {
                        dest.push('/');
                    }
                    dest.push_str("..");
                }
            }
            start = end;
            continue;
        }
        if !dest.is_empty() && !dest.ends_with('/') {
            dest.push('/');
        }
        dest.push_str(component);
        let info = std::fs::symlink_metadata(&dest)?;
        if !info.file_type().is_symlink() {
            if !info.is_dir() && end < path.len() {
                return Err(io::Error::from_raw_os_error(libc::ENOTDIR));
            }
            start = end;
            continue;
        }
        links_walked += 1;
        if links_walked > 255 {
            return Err(io::Error::other("EvalSymlinks: too many links"));
        }
        let link = std::fs::read_link(&dest)?.to_string_lossy().into_owned();
        path = format!("{link}{}", &path[end..]);
        if link.starts_with('/') {
            dest = "/".to_string();
            vol = "/".to_string();
            vol_len = 1;
            start = 1;
        } else {
            // Relative: it replaces the last component of `dest`, the link itself.
            match last_slash(&dest, vol_len) {
                Some(slash) => dest.truncate(slash),
                None => dest.clone_from(&vol),
            }
            start = 0;
        }
    }
    Ok(clean(&dest))
}

/// The project a command's `--project` names, canonical, else the current directory as it is
/// named (not canonicalized): Go's `resolveProject`. An empty `--project` is none.
pub(crate) fn resolve_project(flag: Option<&str>, context: &Context) -> Result<String, CliError> {
    match flag.filter(|project| !project.is_empty()) {
        Some(project) => canonical_path(project, context),
        None => getwd(context),
    }
    .map_err(CliError::internal)
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
pub(crate) fn join(base: &str, rest: &str) -> String {
    match (base.is_empty(), rest.is_empty()) {
        (true, true) => String::new(),
        (true, false) => clean(rest),
        (false, true) => clean(base),
        (false, false) => clean(&format!("{base}/{rest}")),
    }
}

/// Go's `filepath.Clean`: the shortest path naming the same file by lexical processing alone.
pub(crate) fn clean(path: &str) -> String {
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
pub(crate) fn os_error(error: &io::Error) -> String {
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
