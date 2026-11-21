//! A project's setup and teardown scripts, and a container workroom's devcontainer.json, judged
//! against this Mac's approvals as Go's `internal/workroom` judges them (#363): Workroom runs one
//! only once its exact bytes are approved, by their SHA-256, in config's `trusted_scripts`. A
//! root copy git ignores needs no approval, since no pull ever brought it.
//!
//! This is only the judging: running a script is [`crate::script`]'s (#676).

use std::io::Read;
use std::path::Path;

use serde::Serialize;

use super::config::{self, Config};
use super::git::{self, FileAtError};
use super::kind::{CliError, Kind};
use super::start::{self, LocalWork};

/// The scripts Workroom runs only once this Mac has approved their exact bytes.
pub(super) const SETUP_SCRIPT: &str = "workroom_setup";
pub(super) const TEARDOWN_SCRIPT: &str = "workroom_teardown";
/// A container workroom's devcontainer.json (#308): repository code too, since it tells the Mac's
/// container runtime what to mount and run, so it is approved by its bytes under this name.
pub(super) const DEV_CONTAINER: &str = "devcontainer";

/// Where the Development Containers spec looks for devcontainer.json, in its order.
const DEV_CONTAINER_PATHS: [&str; 2] = [".devcontainer/devcontainer.json", ".devcontainer.json"];

/// The largest script Workroom will read to judge: a setup or teardown script is a short program,
/// and one that is a link to a device (/dev/zero) or a huge file must not be read without end.
const MAX_SCRIPT_BYTES: u64 = 1 << 20;

/// Where a script's bytes came from.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Origin {
    /// The base commit, read from git: what a new workroom's checkout will hold.
    Base,
    /// The file in the project's root checkout.
    Root,
    /// The file in a workroom.
    Workroom,
    /// Bytes a caller handed over, such as the app with a remote host's copy.
    Stdin,
}

impl Origin {
    fn as_str(self) -> &'static str {
        match self {
            Origin::Base => "base",
            Origin::Root => "root",
            Origin::Workroom => "workroom",
            Origin::Stdin => "stdin",
        }
    }

    /// Where the bytes came from, for a person.
    pub(super) fn label(self) -> &'static str {
        match self {
            Origin::Base => "from the base commit",
            Origin::Root => "in the project's root",
            Origin::Workroom => "in the workroom",
            Origin::Stdin => "as given",
        }
    }
}

/// A setup or teardown script's bytes as Workroom would run them, judged against the project's
/// approvals.
pub(super) struct Script {
    pub(super) name: &'static str,
    /// The repository path the bytes are, or would be, at: `scripts/<name>`, or where the
    /// devcontainer.json was found.
    pub(super) file: String,
    pub(super) origin: Origin,
    pub(super) text: Vec<u8>,
    pub(super) sha256: String,
    /// The bytes are the root's copy and git ignores it there, so they need no approval.
    pub(super) exempt: bool,
    /// Approved, or exempt.
    pub(super) trusted: bool,
}

impl Script {
    /// The script as an envelope reports it: `text` to show, with U+FFFD for each byte that isn't
    /// UTF-8 as Go writes it, and `bytes`, the exact bytes in base64, to approve.
    pub(super) fn payload(&self) -> ScriptPayload {
        ScriptPayload {
            bytes: crate::util::base64(&self.text),
            exempt: self.exempt,
            file: self.file.clone(),
            name: self.name,
            origin: self.origin.as_str(),
            sha256: self.sha256.clone(),
            text: super::log::go_lossy(&self.text),
            trusted: self.trusted,
        }
    }

    /// The refusal of this script, which this Mac has not approved, carrying it for the app to
    /// show and approve. Go's `UntrustedScriptError`.
    pub(super) fn untrusted(&self) -> CliError {
        // `workroom trust` judges the base commit's and the root's copies, never a workroom's own.
        let how = if self.origin == Origin::Workroom {
            "Run the same command in a terminal to review and approve it"
        } else {
            "Review and approve it with `workroom trust`"
        };
        let mut error = not_trusted(&format!(
            "{} {} is new, or changed since it was approved. {how}",
            self.file,
            self.origin.label()
        ));
        error.script = Some(Box::new(self.payload()));
        error
    }
}

/// A judged script in an envelope (`trust`'s, `trust status`'s, and a `ScriptNotTrusted`
/// refusal's `script`), in Go's key order: Go's `scriptPayload`.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct ScriptPayload {
    bytes: String,
    exempt: bool,
    file: String,
    name: &'static str,
    origin: &'static str,
    sha256: String,
    text: String,
    trusted: bool,
}

/// The repository path of the file a judged name stands for: a devcontainer.json judged without
/// a place (bytes on stdin) is shown at the spec's first.
fn script_file(name: &str) -> String {
    if name == DEV_CONTAINER {
        DEV_CONTAINER_PATHS[0].to_string()
    } else {
        format!("scripts/{name}")
    }
}

/// The name `--stdin` gives, as one of the names a script is approved under.
pub(super) fn known_name(name: &str) -> Option<&'static str> {
    [SETUP_SCRIPT, TEARDOWN_SCRIPT, DEV_CONTAINER]
        .into_iter()
        .find(|known| *known == name)
}

/// The project's scripts and its devcontainer.json, judged against `config`'s approvals for the
/// project at `dir`.
pub(super) struct Judge<'a> {
    pub(super) config: &'a Config,
    pub(super) dir: &'a str,
    /// Says what the judging found, as Go's `Service.Status` does under `--verbose`.
    pub(super) say: &'a dyn Fn(&str, &str),
}

impl Judge<'_> {
    /// Hashes `text`, the project's script `name` from `origin`, and says whether it may run:
    /// approved for the project, or the root's gitignored copy. An unreadable config is an error,
    /// so nothing runs on a guess. Go's `JudgeScript`.
    pub(super) fn judge(
        &self,
        name: &'static str,
        origin: Origin,
        text: Vec<u8>,
    ) -> Result<Script, CliError> {
        self.judge_file(name, script_file(name), origin, text)
    }

    /// [`Judge::judge`] for the bytes of `file`, the repository path `name` stands for.
    fn judge_file(
        &self,
        name: &'static str,
        file: String,
        origin: Origin,
        text: Vec<u8>,
    ) -> Result<Script, CliError> {
        let sha256 = crate::util::sha256_hex(&text);
        let projects = config::all_projects(&self.config.read()?);
        let exempt = ignored_root_copy(self.dir, &file, &sha256);
        let approved = projects
            .get(self.dir)
            .and_then(|project| project.trusted_scripts.get(name))
            .is_some_and(|digest| *digest == sha256);
        Ok(Script {
            name,
            file,
            origin,
            text,
            trusted: exempt || approved,
            exempt,
            sha256,
        })
    }

    /// Judges the script file at `path`, or none when there is none. Go's `fileScript`.
    fn file_script(
        &self,
        name: &'static str,
        origin: Origin,
        path: &Path,
    ) -> Result<Option<Script>, CliError> {
        match read_script(path)? {
            Some(text) => self.judge(name, origin, text).map(Some),
            None => Ok(None),
        }
    }

    /// Judges the root's copy of script `name`, or none when it has none.
    pub(super) fn root_script(&self, name: &'static str) -> Result<Option<Script>, CliError> {
        let path = Path::new(self.dir).join("scripts").join(name);
        self.file_script(name, Origin::Root, &path)
    }

    /// Judges `path`, the copy of script `name` that is about to run in the workroom at
    /// `workroom`: the workroom's own (`<workroom>/scripts/<name>`) or else the root's, as a
    /// teardown finds it. Go's `foundScript`.
    pub(super) fn found_script(
        &self,
        name: &'static str,
        workroom: &Path,
        path: &Path,
    ) -> Result<Option<Script>, CliError> {
        let origin = if path.parent().and_then(Path::parent) == Some(workroom) {
            Origin::Workroom
        } else {
            Origin::Root
        };
        self.file_script(name, origin, path)
    }

    /// Judges the setup script a create starting from `start` ("" is HEAD) would run: the base
    /// commit's, which the new checkout holds, else the root's copy. None when neither has one.
    pub(super) fn setup_script_at(&self, start: &str) -> Result<Option<Script>, CliError> {
        let file = format!("scripts/{SETUP_SCRIPT}");
        match git::file_at(Path::new(self.dir), start, &file) {
            // Its bytes can't be known until the checkout exists: the check just before it runs
            // judges them.
            Err(FileAtError::LinkOutside) => Ok(None),
            Err(FileAtError::Git(error)) => Err(CliError::vcs_failed(&error)),
            Ok(Some(text)) => {
                // As the read before it runs refuses it, before anything exists rather than after.
                if text.len() as u64 > MAX_SCRIPT_BYTES {
                    return Err(not_trusted(&format!(
                        "{file} in the base commit is larger than {MAX_SCRIPT_BYTES} bytes"
                    )));
                }
                self.judge(SETUP_SCRIPT, Origin::Base, text).map(Some)
            }
            Ok(None) => self.root_script(SETUP_SCRIPT),
        }
    }

    /// Judges the devcontainer.json a container create starting from `start` ("" is HEAD) would
    /// use: the first of the spec's paths the base commit has, else the first the root has. None
    /// when neither has one.
    fn devcontainer_at(&self, start: &str) -> Result<Option<Script>, CliError> {
        for file in DEV_CONTAINER_PATHS {
            let text = match git::file_at(Path::new(self.dir), start, file) {
                Err(FileAtError::LinkOutside) | Ok(None) => continue,
                Err(FileAtError::Git(error)) => return Err(CliError::vcs_failed(&error)),
                Ok(Some(text)) => text,
            };
            if text.len() as u64 > MAX_SCRIPT_BYTES {
                return Err(not_trusted(&format!(
                    "{file} in the base commit is larger than {MAX_SCRIPT_BYTES} bytes"
                )));
            }
            return self
                .judge_file(DEV_CONTAINER, file.to_string(), Origin::Base, text)
                .map(Some);
        }
        for file in DEV_CONTAINER_PATHS {
            if let Some(text) = read_script(&Path::new(self.dir).join(file))? {
                return self
                    .judge_file(DEV_CONTAINER, file.to_string(), Origin::Root, text)
                    .map(Some);
            }
        }
        Ok(None)
    }

    /// Judges the scripts the project would run next: the setup script a create would run, at
    /// the base it resolves and fetches as a create does, and the root's teardown copy. A script
    /// that is nowhere is left out. Returns them with the local work a create from that start
    /// leaves out, and the start. Go's `projectScripts`.
    fn project_scripts(
        &self,
        base: &str,
        global: bool,
    ) -> Result<(Vec<Script>, LocalWork, String), CliError> {
        if !git::is_git_repo(Path::new(self.dir)) {
            return Err(CliError::unsupported_vcs());
        }
        (self.say)("repo", "Detected Git worktree");
        let (start, warning) = start::start_point(Path::new(self.dir), base, global)?;
        // As a create does: not against a start that already warns.
        let work = if warning.is_empty() {
            start::local_work(Path::new(self.dir), &start)
        } else {
            LocalWork::default()
        };
        let mut scripts = Vec::new();
        scripts.extend(self.setup_script_at(&start)?);
        scripts.extend(self.root_script(TEARDOWN_SCRIPT)?);
        Ok((scripts, work, start))
    }

    /// The scripts the project would run next, at the project's own base, else the global one.
    /// Go's `ProjectScripts`.
    pub(super) fn scripts(&self) -> Result<(Vec<Script>, LocalWork), CliError> {
        let data = self.config.read()?;
        let own = config::all_projects(&data)
            .get(self.dir)
            .map(|project| project.base_branch.clone())
            .unwrap_or_default();
        let (base, global) = if own.is_empty() {
            (config::base_branch(&data), true)
        } else {
            (own, false)
        };
        let (scripts, work, _) = self.project_scripts(&base, global)?;
        Ok((scripts, work))
    }

    /// [`Judge::scripts`] with new workrooms starting from `base` ("" is origin's default branch)
    /// rather than the project's: what a remote create checks out, which may differ. With
    /// `devcontainer`, the devcontainer.json a container create would use is judged too. Returns
    /// the commit the start names now, when it is a remote's ref, so a remote create checks out
    /// exactly what was judged (#308); else "". Go's `ProjectScriptsFrom`.
    pub(super) fn scripts_from(
        &self,
        base: &str,
        devcontainer: bool,
    ) -> Result<(Vec<Script>, LocalWork, String), CliError> {
        let (mut scripts, work, start) = self.project_scripts(base, false)?;
        // Only a remote's ref: a local branch or HEAD can name a commit the remote clone lacks.
        let commit = if start.starts_with("refs/remotes/") {
            git::commit_at(Path::new(self.dir), &start).unwrap_or_default()
        } else {
            String::new()
        };
        if devcontainer {
            scripts.extend(self.devcontainer_at(&start)?);
        }
        Ok((scripts, work, commit))
    }
}

/// Go's `ErrScriptNotTrusted`, with why.
fn not_trusted(detail: &str) -> CliError {
    CliError::new(
        Kind::ScriptNotTrusted,
        format!("script is not trusted on this Mac: {detail}"),
    )
}

/// Whether the root's file at `file` is a gitignored regular file holding the bytes whose SHA-256
/// is `digest`. A workroom's copy can hold them too: the include step copies ignored files into a
/// new workroom before its setup script runs. An ignored symlink is not exempt: what it points to
/// may be tracked, and a pull can change it.
fn ignored_root_copy(dir: &str, file: &str, digest: &str) -> bool {
    let path = Path::new(dir).join(file);
    if !std::fs::symlink_metadata(&path).is_ok_and(|info| info.is_file()) {
        return false;
    }
    match read_script(&path) {
        Ok(Some(text)) => {
            crate::util::sha256_hex(&text) == digest && git::ignored(Path::new(dir), file)
        }
        _ => false,
    }
}

/// The regular file at `path`, following a symlink, or none when there is nothing there. Anything
/// but a regular file, or one over [`MAX_SCRIPT_BYTES`], is refused unread. Any other failure is
/// worded as Go's `*fs.PathError` (`stat <path>: …`). Go's `readScript`.
fn read_script(path: &Path) -> Result<Option<Vec<u8>>, CliError> {
    let failed = |step: &str, error: &std::io::Error| {
        CliError::internal(format!(
            "{step} {}: {}",
            path.display(),
            config::os_error(error)
        ))
    };
    let info = match std::fs::metadata(path) {
        Ok(info) => info,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(failed("stat", &error)),
    };
    if !info.is_file() {
        return Err(not_trusted(&format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    let too_large = || {
        not_trusted(&format!(
            "{} is larger than {MAX_SCRIPT_BYTES} bytes",
            path.display()
        ))
    };
    if info.len() > MAX_SCRIPT_BYTES {
        return Err(too_large());
    }
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(failed("open", &error)),
    };
    let mut text = Vec::new();
    file.take(MAX_SCRIPT_BYTES + 1)
        .read_to_end(&mut text)
        .map_err(|error| failed("read", &error))?;
    if text.len() as u64 > MAX_SCRIPT_BYTES {
        return Err(too_large());
    }
    Ok(Some(text))
}
