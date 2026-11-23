//! `workroom skill install|remove` (#697, hidden): the Workroom skill for Claude Code and Codex,
//! which teaches them the terminal API (`help agents`). The app runs it on the Mac when Settings ▸
//! AI Agents turns the skill on or off, and on each host as its bootstrap connects, so one
//! implementation decides what is Workroom's to write and to delete, everywhere.
//!
//! **Where it goes.** Each coding agent's own personal skills folder, and only when that agent is
//! set up on this machine:
//! - Claude Code: `$CLAUDE_CONFIG_DIR/skills/workroom` when `CLAUDE_CONFIG_DIR` is set, else
//!   `~/.claude/skills/workroom`; set up when that config folder is there.
//! - Codex: `~/.agents/skills/workroom`, the user skills folder Codex documents (it still reads its
//!   deprecated `$CODEX_HOME/skills` too, so the skill goes in one of the two, never both); set up
//!   when `$CODEX_HOME`, else `~/.codex`, is there. Workroom makes `~/.agents` and its `skills`
//!   folder when they aren't there, and says so in the marker.
//!
//! The variables come from the user's login environment: the app passes them from its shell probe,
//! and a host's bootstrap asks for the host's (`--login-environment`). A home given on its own, as
//! every test gives one, uses neither. Every folder a skill went into is recorded
//! (`~/.local/state/workroom/skills.json`), so a removal finds it even once the variables change.
//!
//! **What proves a skill is Workroom's.** Workroom builds the whole folder, its marker
//! (`.workroom-skill`, holding the SHA-256 of each `SKILL.md` it wrote and the folders it made)
//! first and `SKILL.md` after, in a staging folder of its own beside it
//! (`.workroom-skill-new.<pid>.<n>`), and renames that into place, so a skill's folder is never
//! there without its marker. An update builds the new folder the same way, moves the old one aside
//! (`.workroom-skill-old.<pid>.<n>`, marked as ever), renames the new one into place and removes
//! the old. A staging or old folder a crash left is removed by the next install or removal, once
//! the process its name names is gone, and only as far as its marker proves it Workroom's (an
//! unmarked one only with `rmdir`, which keeps anything in it).
//!
//! A folder without the marker is never written into or removed, whatever its name: it is the
//! user's own skill. Every path in the skill's folder is judged with `lstat`, never followed: a
//! link where the skill's folder, its marker or its `SKILL.md` should be is not Workroom's. Only a
//! plain file is ever opened, so a FIFO never blocks a read. The folders above it (`~/.claude`,
//! `skills`, `~/.agents`) are followed when they are links, since the user's config may live in a
//! dotfiles repository. A `SKILL.md` whose bytes are not one Workroom wrote is the user's edit:
//! install leaves it as it is, and remove keeps it and gives the folder up (the marker goes).
//! Remove deletes only the files Workroom wrote, then the folder with `rmdir`, which fails, and
//! keeps it, if anything else is in it; then each folder the marker says Workroom made, again only
//! when it is a real folder and empty.

use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::kind::CliError;
use super::{Args, Context, Flag, Outcome};
use crate::util::sha256_hex;

/// The skill's folder name, and its `name` in `SKILL.md`.
pub(super) const SKILL: &str = "workroom";
/// The marker that makes a skill folder Workroom's.
pub(super) const MARKER: &str = ".workroom-skill";
const SKILL_FILE: &str = "SKILL.md";
/// What a marker says it was made by, so a file of the same name the user made is not taken for one.
const MADE_BY: &str = "workroom";
/// The most of a `SKILL.md` or marker read to judge it. Workroom's are a few KiB; anything larger
/// is not one it wrote.
const READ_LIMIT: u64 = 1 << 20;
/// How a staging or old folder's name starts, beside the skill's folder.
const LEFTOVER: &str = ".workroom-skill-";
/// Where under the home the folders a skill went into are recorded. The bootstrap's probe reads it
/// to tell whether a host may hold a Workroom skill to remove (`probe.sh`).
pub(super) const RECORD: &str = ".local/state/workroom/skills.json";

/// `skill install` and `skill remove` take it: read `CLAUDE_CONFIG_DIR` and `CODEX_HOME` from the
/// login environment, as a host's bootstrap asks, rather than this process's.
pub(super) const FLAGS: &[Flag] = &[Flag {
    name: "login-environment",
    usage: "Read CLAUDE_CONFIG_DIR and CODEX_HOME from the login shell's environment",
    hidden: true,
    ..Flag::BOOL
}];

/// What `skill install` and `remove` reply, one entry per skill folder.
#[derive(Serialize, Debug)]
struct Payload {
    skills: Vec<Report>,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub(super) struct Report {
    agent: String,
    /// The skill's folder.
    path: String,
    state: State,
    /// Why, for `failed`.
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub(super) enum State {
    /// Install: written where there was none.
    Installed,
    /// Install: Workroom's, rewritten with this build's text.
    Updated,
    /// Install: Workroom's, already this build's text.
    Current,
    /// Remove: Workroom's files are gone.
    Removed,
    /// Remove: nothing there.
    Absent,
    /// The coding agent isn't set up here, so nothing was written.
    NoAgent,
    /// A skill of that name that Workroom didn't make, left as it is.
    NotOurs,
    /// Workroom's skill, whose `SKILL.md` the user changed: install leaves it; remove keeps it and
    /// gives the folder up.
    Edited,
    /// Something could not be read or written; `message` says what.
    Failed,
}

/// The marker's contents.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
struct Marker {
    made_by: String,
    skill: String,
    /// The SHA-256 of the `SKILL.md` Workroom wrote here.
    sha256: Vec<String>,
    /// The folders above the skill Workroom made for it, outermost first, which remove takes away
    /// again when they are empty.
    made: Vec<PathBuf>,
}

/// The variables that move a coding agent's folders, from its environment.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(super) struct Places {
    claude_config_dir: Option<PathBuf>,
    codex_home: Option<PathBuf>,
}

impl Places {
    /// The places `get` names: each variable when it is an absolute path, else none.
    fn from_env(get: impl Fn(&str) -> Option<String>) -> Places {
        let absolute = |name: &str| {
            get(name)
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
        };
        Places {
            claude_config_dir: absolute("CLAUDE_CONFIG_DIR"),
            codex_home: absolute("CODEX_HOME"),
        }
    }
}

/// One coding agent's skill: the folder that says it is set up, the folder its `skills` folder is
/// in, and the skill's own folder.
struct Target {
    agent: &'static str,
    signal: PathBuf,
    base: PathBuf,
    skill: PathBuf,
}

fn targets(home: &Path, places: &Places) -> [Target; 2] {
    let claude = places
        .claude_config_dir
        .clone()
        .unwrap_or_else(|| home.join(".claude"));
    let agents = home.join(".agents");
    [
        Target {
            agent: "claude",
            skill: claude.join("skills").join(SKILL),
            signal: claude.clone(),
            base: claude,
        },
        Target {
            agent: "codex",
            signal: places
                .codex_home
                .clone()
                .unwrap_or_else(|| home.join(".codex")),
            skill: agents.join("skills").join(SKILL),
            base: agents,
        },
    ]
}

/// A step after which a test stops an install, as a kill there would.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    /// The new folder is built beside the skill's.
    Staged,
    /// An update moved the old folder aside, before the new one is in place.
    MovedAside,
}

/// The process an install runs as, which names its staging folders, and where a test stops it.
struct Run {
    pid: u32,
    stop: Option<Step>,
}

impl Run {
    fn this() -> Run {
        Run {
            pid: std::process::id(),
            stop: None,
        }
    }

    fn reached(&self, step: Step) -> Result<(), String> {
        match self.stop {
            Some(stop) if stop == step => Err(format!("stopped after {step:?}")),
            _ => Ok(()),
        }
    }
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let (name, install) = match args.positional.as_slice() {
        [action] if action == "install" => ("skill install", true),
        [action] if action == "remove" => ("skill remove", false),
        _ => {
            return Outcome::Usage(CliError::internal(
                "`workroom skill` takes install or remove",
            ));
        }
    };
    // Only the HOME this process was given, never a passwd lookup: the app runs it with a
    // throwaway HOME in its tests, and that must be the only home it can reach.
    let home = match context
        .env("HOME")
        .filter(|home| Path::new(home).is_absolute())
    {
        Some(home) => PathBuf::from(home),
        None => {
            return Outcome::FailedIn(
                name,
                CliError::internal(
                    "HOME is not set to a folder, so no coding agent's skills can be found",
                ),
            );
        }
    };
    let places = if args.is_set("login-environment") {
        let shell = login_shell(context.env("SHELL"), crate::terminal::shell::user_shell);
        let login = crate::host::environment::login_environment(
            &shell,
            &home,
            crate::host::environment::PROBE_TIMEOUT,
            |_| {},
        );
        Places::from_env(|name| login.get(name).cloned())
    } else {
        Places::from_env(|name| context.env(name))
    };
    let skills = if install {
        self::install(&home, &places, &skill_text())
    } else {
        remove(&home, &places)
    };
    if context.json {
        return Outcome::Success(super::envelope::success(name, &Payload { skills }));
    }
    Outcome::Printed(
        skills
            .iter()
            .map(|report| {
                let said = match report.state {
                    State::Installed => "installed",
                    State::Updated => "updated",
                    State::Current => "already current",
                    State::Removed => "removed",
                    State::Absent => "not installed",
                    State::NoAgent => "not set up on this machine, so nothing was written",
                    State::NotOurs => "a skill Workroom didn't make is there, so it was left alone",
                    State::Edited => "edited by you, so it was left as it is",
                    State::Failed => "failed",
                };
                let why = report
                    .message
                    .as_deref()
                    .map_or(String::new(), |message| format!(": {message}"));
                format!("{} {}: {said}{why}\n", report.agent, report.path)
            })
            .collect(),
    )
}

/// The shell whose login environment says where the coding agents' folders are: the user's
/// shell as their terminals get it (`resolve`, `terminal::shell::user_shell`): `SHELL` when it
/// names one, else the passwd database's, since a container's `docker exec` sets no `SHELL`;
/// `/bin/sh` when neither says.
fn login_shell(
    env_shell: Option<String>,
    resolve: impl FnOnce(Option<std::ffi::OsString>) -> String,
) -> String {
    let shell = resolve(env_shell.map(Into::into));
    if shell.is_empty() {
        "/bin/sh".into()
    } else {
        shell
    }
}

/// The skill's `SKILL.md`: its front matter, then `help agents`.
pub(super) fn skill_text() -> String {
    format!(
        // No ": " in the description, which YAML would read as another key.
        "---\nname: {SKILL}\ndescription: Drive Workroom's terminals with the workroom command, \
         to list the other terminals, read their screens, run a shell command in one and get its \
         exit code and output, wait for output or a coding agent's turn, type keys, prompt the \
         coding agent in another terminal, and open or close terminals. Use it in a Workroom \
         terminal (WORKROOM_PANE is set) whenever a task involves another terminal, a dev \
         server, or another agent, and before approving a project's setup script or deleting a \
         workroom, which are the user's to do.\n---\n\n<!-- Installed by Workroom, from Settings > AI \
         Agents. Workroom updates it and removes it when the setting is turned off; once you \
         edit this file, Workroom leaves it as it is. -->\n\n{}\nRun `workroom help agents` for \
         this guide as the `workroom` you have explains it.\n",
        super::agents::text()
    )
}

fn report(agent: &str, skill: &Path, result: Result<State, String>) -> Report {
    let (state, message) = match result {
        Ok(state) => (state, None),
        Err(error) => (State::Failed, Some(error)),
    };
    Report {
        agent: agent.to_string(),
        path: skill.to_string_lossy().into_owned(),
        state,
        message,
    }
}

/// Installs `text` as each coding agent's Workroom skill, and records where.
pub(super) fn install(home: &Path, places: &Places, text: &str) -> Vec<Report> {
    install_as(home, places, text, &Run::this())
}

fn install_as(home: &Path, places: &Places, text: &str, run: &Run) -> Vec<Report> {
    let reports: Vec<Report> = targets(home, places)
        .iter()
        .map(|target| report(target.agent, &target.skill, install_one(target, text, run)))
        .collect();
    let mut record = read_record(home);
    for report in &reports {
        if matches!(
            report.state,
            State::Installed | State::Updated | State::Current
        ) && !record.iter().any(|entry| entry.path == report.path)
        {
            record.push(Recorded {
                agent: report.agent.clone(),
                path: report.path.clone(),
            });
        }
    }
    write_record(home, &record);
    reports
}

/// Removes each coding agent's Workroom skill, where it would go now and wherever one was
/// recorded, as far as it is Workroom's.
pub(super) fn remove(home: &Path, places: &Places) -> Vec<Report> {
    let mut places_to_look: Vec<Recorded> = targets(home, places)
        .iter()
        .map(|target| Recorded {
            agent: target.agent.to_string(),
            path: target.skill.to_string_lossy().into_owned(),
        })
        .collect();
    for entry in read_record(home) {
        if !places_to_look.iter().any(|known| known.path == entry.path) {
            places_to_look.push(entry);
        }
    }
    let reports: Vec<Report> = places_to_look
        .iter()
        .map(|entry| {
            let skill = PathBuf::from(&entry.path);
            report(&entry.agent, &skill, remove_one(&skill))
        })
        .collect();
    // Only a removal that failed is left to try again.
    let left: Vec<Recorded> = places_to_look
        .into_iter()
        .zip(&reports)
        .filter(|(_, report)| report.state == State::Failed)
        .map(|(entry, _)| entry)
        .collect();
    write_record(home, &left);
    reports
}

/// Whether `path` is a folder, following a link to one.
fn is_folder(path: &Path) -> Result<bool, String> {
    match fs::metadata(path) {
        Ok(meta) => Ok(meta.is_dir()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("{}: {error}", path.display())),
    }
}

fn install_one(target: &Target, text: &str, run: &Run) -> Result<State, String> {
    if !is_folder(&target.signal)? {
        return Ok(State::NoAgent);
    }
    let skills = target
        .skill
        .parent()
        .expect("a skill is in a skills folder");
    // The folders above the skill may be links the user made to their dotfiles: what the agent
    // reads is what they point at. Those Workroom makes are recorded, to take away again.
    let mut made = Vec::new();
    for folder in [target.base.as_path(), skills] {
        match fs::create_dir(folder) {
            Ok(()) => made.push(folder.to_path_buf()),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                if !is_folder(folder)? {
                    return Ok(State::NotOurs);
                }
            }
            Err(error) => return Err(format!("{}: {error}", folder.display())),
        }
    }
    sweep(skills);
    match fs::symlink_metadata(&target.skill) {
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let staged = stage(skills, text, &made, run)?;
            run.reached(Step::Staged)?;
            if let Err(error) = fs::rename(&staged, &target.skill) {
                let _ = remove_owned(&staged);
                return Err(format!("{}: {error}", target.skill.display()));
            }
            Ok(State::Installed)
        }
        Err(error) => Err(format!("{}: {error}", target.skill.display())),
        Ok(_) => {
            let Some(marker) = read_marker(&target.skill)? else {
                return Ok(State::NotOurs);
            };
            match judge_skill_file(&target.skill, &marker)? {
                SkillFile::Theirs => Ok(State::Edited),
                SkillFile::Ours(bytes) if bytes == text.as_bytes() => Ok(State::Current),
                SkillFile::Ours(_) | SkillFile::Missing => {
                    let staged = stage(skills, text, &marker.made, run)?;
                    run.reached(Step::Staged)?;
                    let aside = skills.join(leftover_name("old", run.pid));
                    fs::rename(&target.skill, &aside)
                        .map_err(|error| format!("{}: {error}", target.skill.display()))?;
                    run.reached(Step::MovedAside)?;
                    fs::rename(&staged, &target.skill)
                        .map_err(|error| format!("{}: {error}", target.skill.display()))?;
                    // Left behind on a failure, marked, for the next run's sweep.
                    let _ = remove_owned(&aside);
                    Ok(State::Updated)
                }
            }
        }
    }
}

/// A new skill folder, whole, under a name of this run's own in `skills`: its marker first, then
/// `SKILL.md`. Removed again when it can't be finished.
fn stage(skills: &Path, text: &str, made: &[PathBuf], run: &Run) -> Result<PathBuf, String> {
    let staged = skills.join(leftover_name("new", run.pid));
    fs::create_dir(&staged).map_err(|error| format!("{}: {error}", staged.display()))?;
    let marker = Marker {
        made_by: MADE_BY.into(),
        skill: SKILL.into(),
        sha256: vec![sha256_hex(text.as_bytes())],
        made: made.to_vec(),
    };
    let mut bytes = serde_json::to_vec_pretty(&marker).expect("a marker is JSON");
    bytes.push(b'\n');
    let written = write_new(&staged.join(MARKER), &bytes)
        .and_then(|()| write_new(&staged.join(SKILL_FILE), text.as_bytes()));
    if let Err(error) = written {
        let _ = remove_owned(&staged);
        let _ = fs::remove_dir(&staged);
        return Err(error);
    }
    Ok(staged)
}

/// `.workroom-skill-<kind>.<pid>.<nanoseconds>`: unique to this run, and naming its process.
fn leftover_name(kind: &str, pid: u32) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    format!("{LEFTOVER}{kind}.{pid}.{nanos}")
}

/// The staging and old folders in `skills` a run that is gone left behind, each removed as far as
/// its marker proves it Workroom's; one with no marker only by `rmdir`, which keeps anything in
/// it. One whose process is still running is another run's, under way, and is left alone.
fn sweep(skills: &Path) {
    let Ok(entries) = fs::read_dir(skills) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str().filter(|name| name.starts_with(LEFTOVER)) else {
            continue;
        };
        let Some(pid) = name
            .split('.')
            .nth(2)
            .and_then(|pid| pid.parse::<u32>().ok())
        else {
            continue;
        };
        if process_alive(pid) {
            continue;
        }
        let path = entry.path();
        if !fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_dir()) {
            continue;
        }
        match read_marker(&path) {
            Ok(Some(_)) => {
                let _ = remove_owned(&path);
            }
            _ => {
                let _ = fs::remove_dir(&path);
            }
        }
    }
}

/// Whether the process `pid` runs: `kill(pid, 0)` finds it, or may not signal it. A pid no
/// process can have counts as running, so nothing is ever removed for it.
fn process_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return true;
    };
    if pid <= 0 {
        return true;
    }
    // SAFETY: `kill` with signal 0 sends nothing; it only checks that the process exists.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

fn remove_one(skill: &Path) -> Result<State, String> {
    let skills = skill.parent().expect("a skill is in a skills folder");
    sweep(skills);
    match fs::symlink_metadata(skill) {
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(State::Absent),
        Err(error) => return Err(format!("{}: {error}", skill.display())),
        Ok(_) => {}
    }
    let Some((state, marker)) = remove_owned(skill)? else {
        return Ok(State::NotOurs);
    };
    if state == State::Removed {
        for folder in marker.made.iter().rev() {
            if fs::symlink_metadata(folder).is_ok_and(|meta| meta.is_dir()) {
                let _ = fs::remove_dir(folder);
            }
        }
    }
    Ok(state)
}

/// Removes what Workroom wrote in the folder `dir` and then the folder, when it is empty; None when
/// the folder isn't Workroom's. A `SKILL.md` it didn't write is kept, and the folder given up.
fn remove_owned(dir: &Path) -> Result<Option<(State, Marker)>, String> {
    let Some(marker) = read_marker(dir)? else {
        return Ok(None);
    };
    let state = match judge_skill_file(dir, &marker)? {
        SkillFile::Theirs => State::Edited,
        SkillFile::Ours(_) => {
            remove_file(&dir.join(SKILL_FILE))?;
            State::Removed
        }
        SkillFile::Missing => State::Removed,
    };
    // The marker last: until it goes, the folder is still provably Workroom's to finish removing.
    remove_file(&dir.join(MARKER))?;
    if state == State::Removed {
        // Fails, keeping the folder, when anything else is in it.
        let _ = fs::remove_dir(dir);
    }
    Ok(Some((state, marker)))
}

/// The marker of the skill folder at `skill`, when that is a plain folder (not a link) holding a
/// plain-file marker Workroom wrote; None when it isn't Workroom's.
fn read_marker(skill: &Path) -> Result<Option<Marker>, String> {
    if !fs::symlink_metadata(skill).is_ok_and(|meta| meta.is_dir()) {
        return Ok(None);
    }
    let Some(bytes) = read_plain_file(&skill.join(MARKER))? else {
        return Ok(None);
    };
    Ok(serde_json::from_slice::<Marker>(&bytes)
        .ok()
        .filter(|marker| marker.made_by == MADE_BY && marker.skill == SKILL))
}

enum SkillFile {
    /// Bytes Workroom wrote, as the marker records them.
    Ours(Vec<u8>),
    /// Something else: other bytes, a link, a folder, a FIFO.
    Theirs,
    Missing,
}

fn judge_skill_file(skill: &Path, marker: &Marker) -> Result<SkillFile, String> {
    let path = skill.join(SKILL_FILE);
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(SkillFile::Missing),
        Err(error) => return Err(format!("{}: {error}", path.display())),
        Ok(_) => {}
    }
    Ok(match read_plain_file(&path)? {
        Some(bytes) if marker.sha256.contains(&sha256_hex(&bytes)) => SkillFile::Ours(bytes),
        _ => SkillFile::Theirs,
    })
}

/// The bytes of `path` when it is a plain file (judged without following a link, so a FIFO or a
/// link is never opened) of at most [`READ_LIMIT`]; None for anything else, or nothing there.
fn read_plain_file(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() && meta.len() <= READ_LIMIT => {}
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .and_then(|file| file.take(READ_LIMIT + 1).read_to_end(&mut bytes))
        .map_err(|error| format!("{}: {error}", path.display()))?;
    Ok(Some(bytes))
}

/// Writes a file that must not be there yet, in a folder of this run's own.
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .and_then(|mut file| file.write_all(bytes).and_then(|()| file.sync_all()))
        .map_err(|error| format!("{}: {error}", path.display()))
}

fn remove_file(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("{}: {error}", path.display())),
    }
}

/// A skill folder Workroom installed into, as the record keeps it.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
struct Recorded {
    agent: String,
    path: String,
}

#[derive(Serialize, Deserialize, Default)]
struct RecordFile {
    skills: Vec<Recorded>,
}

/// The skill folders recorded under `home`; none when there is no readable record.
fn read_record(home: &Path) -> Vec<Recorded> {
    read_plain_file(&home.join(RECORD))
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice::<RecordFile>(&bytes).ok())
        .map(|record| record.skills)
        .unwrap_or_default()
}

/// Records `skills` under `home`, whole or not at all: a file of this run's own, renamed over the
/// record. A record that can't be written leaves the last one; only a removal after a variable
/// moved a skill would miss it.
fn write_record(home: &Path, skills: &[Recorded]) {
    let path = home.join(RECORD);
    let Some(folder) = path.parent() else {
        return;
    };
    if read_record(home) == skills && path.exists() {
        return;
    }
    if skills.is_empty() && !path.exists() {
        return;
    }
    if fs::create_dir_all(folder).is_err() {
        return;
    }
    let staged = folder.join(format!(
        ".skills.json.{}.{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_nanos())
    ));
    let mut bytes = serde_json::to_vec_pretty(&RecordFile {
        skills: skills.to_vec(),
    })
    .expect("a record is JSON");
    bytes.push(b'\n');
    if write_new(&staged, &bytes).is_err() || fs::rename(&staged, &path).is_err() {
        // Only the file this call made, which `create_new` proves.
        let _ = fs::remove_file(&staged);
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::FileTypeExt;

    use super::super::Scratch;
    use super::*;

    fn states(reports: &[Report]) -> Vec<State> {
        reports.iter().map(|report| report.state).collect()
    }

    /// No variables: the test's home alone, never the developer's own config.
    fn none() -> Places {
        Places::default()
    }

    fn claude(home: &Path) -> PathBuf {
        home.join(".claude/skills").join(SKILL)
    }

    fn codex(home: &Path) -> PathBuf {
        home.join(".agents/skills").join(SKILL)
    }

    /// A pid no process has: one that ran and was reaped.
    fn dead_pid() -> u32 {
        let mut child = std::process::Command::new("/usr/bin/true")
            .spawn()
            .expect("run true");
        let pid = child.id();
        child.wait().expect("wait for true");
        pid
    }

    fn leftovers(skills: &Path) -> Vec<String> {
        fs::read_dir(skills)
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .filter(|name| name.starts_with(LEFTOVER))
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn install_writes_only_for_a_coding_agent_that_is_set_up() {
        let home = Scratch::new("skill-no-agent");
        assert_eq!(
            states(&install(&home, &none(), "one")),
            [State::NoAgent, State::NoAgent]
        );
        assert!(!home.join(".claude").exists() && !home.join(".agents").exists());

        fs::create_dir(home.join(".claude")).unwrap();
        assert_eq!(
            states(&install(&home, &none(), "one")),
            [State::Installed, State::NoAgent]
        );
        assert_eq!(
            fs::read_to_string(claude(&home).join(SKILL_FILE)).unwrap(),
            "one"
        );
        assert!(!home.join(".agents").exists() && !home.join(".codex").exists());
    }

    /// Codex's goes in `~/.agents/skills`, never `~/.codex/skills`, and the folders Workroom made
    /// for it go again with it; Claude Code's `skills` folder it made goes too, its own stays.
    #[test]
    fn install_is_current_then_updated_and_remove_takes_exactly_what_it_wrote() {
        let home = Scratch::new("skill-cycle");
        fs::create_dir(home.join(".claude")).unwrap();
        fs::create_dir(home.join(".codex")).unwrap();

        let places = none();
        assert_eq!(
            states(&install(&home, &places, "one")),
            [State::Installed, State::Installed]
        );
        assert!(!home.join(".codex/skills").exists());
        assert_eq!(
            states(&install(&home, &places, "one")),
            [State::Current, State::Current]
        );
        assert_eq!(
            states(&install(&home, &places, "two")),
            [State::Updated, State::Updated]
        );
        assert_eq!(
            fs::read_to_string(codex(&home).join(SKILL_FILE)).unwrap(),
            "two"
        );
        let marker = read_marker(&codex(&home)).unwrap().unwrap();
        assert_eq!(marker.sha256, [sha256_hex(b"two")]);
        assert_eq!(
            marker.made,
            [home.join(".agents"), home.join(".agents/skills")]
        );
        assert!(leftovers(&home.join(".agents/skills")).is_empty());

        assert_eq!(
            states(&remove(&home, &places)),
            [State::Removed, State::Removed]
        );
        assert!(!home.join(".claude/skills").exists() && home.join(".claude").is_dir());
        assert!(!home.join(".agents").exists() && home.join(".codex").is_dir());
        assert_eq!(
            states(&remove(&home, &places)),
            [State::Absent, State::Absent]
        );
    }

    /// `CLAUDE_CONFIG_DIR` moves Claude Code's skill, and `CODEX_HOME` only says Codex is set up;
    /// a removal after the variable moved again still finds where it went, from the record.
    #[test]
    fn the_variables_move_the_skill_and_the_record_finds_it_after() {
        let home = Scratch::new("skill-places");
        let config = Scratch::new("skill-places-config");
        let codex_home = Scratch::new("skill-places-codex");
        let places = Places::from_env(|name| match name {
            "CLAUDE_CONFIG_DIR" => Some(config.to_string_lossy().into_owned()),
            "CODEX_HOME" => Some(codex_home.to_string_lossy().into_owned()),
            _ => None,
        });
        assert_eq!(
            states(&install(&home, &places, "one")),
            [State::Installed, State::Installed]
        );
        assert!(config.join("skills/workroom").join(SKILL_FILE).is_file());
        assert!(codex(&home).join(SKILL_FILE).is_file());
        assert!(!codex_home.join("skills").exists());
        assert!(!home.join(".claude").exists());
        assert!(home.join(RECORD).is_file());

        // The variables gone: the record still names where they were.
        let reports = remove(&home, &none());
        assert!(
            reports.iter().any(|report| report.path
                == config.join("skills/workroom").to_string_lossy()
                && report.state == State::Removed),
            "{reports:?}"
        );
        assert!(!config.join("skills").exists() && config.is_dir());
        assert!(!home.join(".agents").exists());
        assert_eq!(read_record(&home), []);

        // A relative variable is no place.
        let relative = Places::from_env(|_| Some("relative/dir".into()));
        assert_eq!(relative, none());
    }

    #[test]
    fn a_skill_folder_workroom_did_not_make_is_never_written_or_removed() {
        let home = Scratch::new("skill-not-ours");
        fs::create_dir(home.join(".codex")).unwrap();
        let theirs = claude(&home);
        fs::create_dir_all(&theirs).unwrap();
        fs::write(theirs.join(SKILL_FILE), "the user's own").unwrap();
        // A marker that isn't Workroom's: the wrong maker, or no JSON at all.
        fs::write(
            theirs.join(MARKER),
            r#"{"made_by":"someone","skill":"workroom","sha256":[],"made":[]}"#,
        )
        .unwrap();
        fs::create_dir_all(codex(&home)).unwrap();
        fs::write(codex(&home).join(MARKER), "not json").unwrap();

        assert_eq!(
            states(&install(&home, &none(), "one")),
            [State::NotOurs, State::NotOurs]
        );
        assert_eq!(
            states(&remove(&home, &none())),
            [State::NotOurs, State::NotOurs]
        );
        assert_eq!(
            fs::read_to_string(theirs.join(SKILL_FILE)).unwrap(),
            "the user's own"
        );
        assert!(theirs.join(MARKER).exists());
        assert!(codex(&home).join(MARKER).exists());
    }

    #[test]
    fn an_edited_skill_is_left_by_install_and_kept_by_remove() {
        let home = Scratch::new("skill-edited");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, &none(), "one");
        let file = claude(&home).join(SKILL_FILE);
        fs::write(&file, "one, with my notes").unwrap();

        assert_eq!(install(&home, &none(), "two")[0].state, State::Edited);
        assert_eq!(fs::read_to_string(&file).unwrap(), "one, with my notes");
        assert_eq!(remove(&home, &none())[0].state, State::Edited);
        assert_eq!(fs::read_to_string(&file).unwrap(), "one, with my notes");
        // The folder is the user's now: no marker, so a later install leaves it alone.
        assert!(!claude(&home).join(MARKER).exists());
        assert_eq!(install(&home, &none(), "two")[0].state, State::NotOurs);
    }

    /// The skill's own folder is never followed: a link there is not Workroom's, even to a folder
    /// Workroom made. Nor is a link as its `SKILL.md`.
    #[test]
    fn links_in_the_skills_own_folder_are_judged_without_following_them() {
        let home = Scratch::new("skill-links");
        let elsewhere = Scratch::new("skill-links-elsewhere");
        fs::create_dir(home.join(".claude")).unwrap();
        fs::create_dir(home.join(".claude/skills")).unwrap();
        fs::create_dir(elsewhere.join(".claude")).unwrap();
        install(&elsewhere, &none(), "one");
        std::os::unix::fs::symlink(claude(&elsewhere), claude(&home)).unwrap();
        assert_eq!(install(&home, &none(), "two")[0].state, State::NotOurs);
        assert_eq!(remove(&home, &none())[0].state, State::NotOurs);
        assert_eq!(
            fs::read_to_string(claude(&elsewhere).join(SKILL_FILE)).unwrap(),
            "one"
        );

        fs::create_dir(home.join(".codex")).unwrap();
        install(&home, &none(), "one");
        let file = codex(&home).join(SKILL_FILE);
        fs::remove_file(&file).unwrap();
        std::os::unix::fs::symlink(claude(&elsewhere).join(SKILL_FILE), &file).unwrap();
        assert_eq!(remove(&home, &none())[1].state, State::Edited);
        assert!(
            fs::symlink_metadata(&file)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(claude(&elsewhere).join(SKILL_FILE).exists());
    }

    /// The folders above the skill (`~/.claude`, `skills`, `~/.agents`) may be the user's links to
    /// their dotfiles: the skill goes in what they point at, and remove leaves the links.
    #[test]
    fn linked_folders_above_the_skill_get_it_and_keep_their_links() {
        let home = Scratch::new("skill-linked");
        let dotfiles = Scratch::new("skill-linked-dotfiles");
        fs::create_dir(dotfiles.join("claude")).unwrap();
        fs::create_dir(dotfiles.join("agents")).unwrap();
        std::os::unix::fs::symlink(dotfiles.join("claude"), home.join(".claude")).unwrap();
        std::os::unix::fs::symlink(dotfiles.join("agents"), home.join(".agents")).unwrap();
        fs::create_dir(home.join(".codex")).unwrap();
        assert_eq!(
            states(&install(&home, &none(), "one")),
            [State::Installed, State::Installed]
        );
        assert!(
            dotfiles
                .join("claude/skills/workroom")
                .join(SKILL_FILE)
                .is_file()
        );
        assert!(
            dotfiles
                .join("agents/skills/workroom")
                .join(SKILL_FILE)
                .is_file()
        );
        assert_eq!(
            states(&remove(&home, &none())),
            [State::Removed, State::Removed]
        );
        for link in [".claude", ".agents"] {
            assert!(
                fs::symlink_metadata(home.join(link))
                    .unwrap()
                    .file_type()
                    .is_symlink()
            );
        }
        assert!(dotfiles.join("claude").is_dir() && dotfiles.join("agents").is_dir());
    }

    #[test]
    fn a_fifo_in_place_of_the_skill_file_is_never_opened() {
        let home = Scratch::new("skill-fifo");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, &none(), "one");
        let file = claude(&home).join(SKILL_FILE);
        fs::remove_file(&file).unwrap();
        let path = std::ffi::CString::new(file.to_string_lossy().as_bytes()).unwrap();
        // SAFETY: `mkfifo` reads the NUL-terminated path it is given and keeps no pointer.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        assert_eq!(install(&home, &none(), "two")[0].state, State::Edited);
        assert_eq!(remove(&home, &none())[0].state, State::Edited);
        assert!(fs::symlink_metadata(&file).unwrap().file_type().is_fifo());
    }

    /// A run killed once its new folder is built leaves only that, marked, never an unmarked skill
    /// folder; the next install removes it and installs. One killed mid-update, its old folder
    /// moved aside, leaves no skill folder and two marked ones, which the next install removes.
    #[test]
    fn a_kill_between_the_steps_leaves_nothing_unmarked_and_the_next_run_cleans_up() {
        let home = Scratch::new("skill-kill");
        fs::create_dir(home.join(".claude")).unwrap();
        let skills = home.join(".claude/skills");
        let killed = |stop| Run {
            pid: dead_pid(),
            stop: Some(stop),
        };

        let reports = install_as(&home, &none(), "one", &killed(Step::Staged));
        assert_eq!(reports[0].state, State::Failed);
        assert!(!claude(&home).exists());
        let left = leftovers(&skills);
        assert_eq!(left.len(), 1, "{left:?}");
        assert!(read_marker(&skills.join(&left[0])).unwrap().is_some());
        assert_eq!(install(&home, &none(), "one")[0].state, State::Installed);
        assert!(leftovers(&skills).is_empty());

        let reports = install_as(&home, &none(), "two", &killed(Step::MovedAside));
        assert_eq!(reports[0].state, State::Failed);
        assert!(!claude(&home).exists());
        let left = leftovers(&skills);
        assert_eq!(left.len(), 2, "{left:?}");
        for name in &left {
            assert!(read_marker(&skills.join(name)).unwrap().is_some(), "{name}");
        }
        assert_eq!(install(&home, &none(), "two")[0].state, State::Installed);
        assert_eq!(
            fs::read_to_string(claude(&home).join(SKILL_FILE)).unwrap(),
            "two"
        );
        assert!(leftovers(&skills).is_empty());

        // A removal cleans up after a kill too.
        install_as(&home, &none(), "three", &killed(Step::Staged));
        assert_eq!(remove(&home, &none())[0].state, State::Removed);
        assert!(!claude(&home).exists());
        assert!(leftovers(&skills).is_empty());
    }

    /// Another run's staging folder, its process still running, is left alone, as is an unmarked
    /// folder with that shape that holds anything.
    #[test]
    fn a_live_runs_staging_folder_and_an_unmarked_one_with_files_are_left() {
        let home = Scratch::new("skill-live");
        fs::create_dir(home.join(".claude")).unwrap();
        let skills = home.join(".claude/skills");
        let live = Run {
            pid: std::process::id(),
            stop: Some(Step::Staged),
        };
        install_as(&home, &none(), "one", &live);
        let theirs = skills.join(format!("{LEFTOVER}new.{}.1", dead_pid()));
        fs::create_dir(&theirs).unwrap();
        fs::write(theirs.join("notes.md"), "mine").unwrap();
        assert_eq!(install(&home, &none(), "one")[0].state, State::Installed);
        assert_eq!(leftovers(&skills).len(), 2);
        assert_eq!(fs::read_to_string(theirs.join("notes.md")).unwrap(), "mine");
    }

    #[test]
    fn remove_keeps_a_folder_that_holds_the_users_files() {
        let home = Scratch::new("skill-extra");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, &none(), "one");
        let folder = claude(&home);
        fs::write(folder.join("notes.md"), "mine").unwrap();
        assert_eq!(remove(&home, &none())[0].state, State::Removed);
        assert_eq!(fs::read_to_string(folder.join("notes.md")).unwrap(), "mine");
        assert!(!folder.join(SKILL_FILE).exists() && !folder.join(MARKER).exists());
        assert!(home.join(".claude/skills").is_dir());
    }

    /// With no `SHELL`, as in a container's exec, the login environment is read with the passwd
    /// database's shell, so a variable a bash or zsh startup file exports is found; `SHELL` wins
    /// when it names one, and `/bin/sh` is the last resort.
    #[test]
    fn the_login_shell_is_the_users_as_their_terminals_get_it() {
        // A passwd database whose user's shell is zsh, as the terminals' resolver reads it.
        let passwd_zsh = |env: Option<std::ffi::OsString>| {
            env.filter(|shell| !shell.is_empty())
                .map_or("/usr/bin/zsh".to_string(), |shell| {
                    shell.to_string_lossy().into_owned()
                })
        };
        assert_eq!(login_shell(None, passwd_zsh), "/usr/bin/zsh");
        assert_eq!(login_shell(Some(String::new()), passwd_zsh), "/usr/bin/zsh");
        assert_eq!(
            login_shell(Some("/bin/bash".into()), passwd_zsh),
            "/bin/bash"
        );
        assert_eq!(login_shell(None, |_| String::new()), "/bin/sh");
        // The real resolver, with no `SHELL`, names this user's passwd shell, never nothing.
        let real = login_shell(None, crate::terminal::shell::user_shell);
        assert!(real.starts_with('/'), "{real}");
        assert_eq!(
            real,
            Some(crate::terminal::shell::user_shell(None))
                .filter(|shell| !shell.is_empty())
                .unwrap_or_else(|| "/bin/sh".into())
        );
    }

    #[test]
    fn the_skill_is_the_agents_guide_under_front_matter() {
        let text = skill_text();
        assert!(
            text.starts_with("---\nname: workroom\ndescription: "),
            "{text}"
        );
        let description = text.lines().nth(2).unwrap();
        assert!(description.len() < 1024, "{}", description.len());
        assert!(text.contains(&super::super::agents::text()));
        assert!(
            !description["description: ".len()..].contains(": "),
            "{description}"
        );
    }
}
