//! `workroom agent-skill install|remove` (#697, hidden): the Workroom skill for Claude Code and
//! Codex, which teaches them the terminal API (`help agents`). The app runs it on the Mac when
//! Settings ▸ AI Agents turns the skill on or off, and on each host as its bootstrap connects, so
//! one implementation decides what is Workroom's to write and to delete, everywhere.
//!
//! It writes only into an agent's own folder that is already there (`~/.claude`, `~/.codex`): a
//! machine without Codex gets no `~/.codex`. The skill is `<agent>/skills/workroom/SKILL.md`.
//!
//! **What proves a skill is Workroom's.** Workroom makes the skill's folder itself (`create_dir`,
//! which fails on anything already there), and writes a marker in it before anything else,
//! `.workroom-skill`, holding the SHA-256 of each `SKILL.md` it wrote. A folder without that
//! marker is never written into or removed, whatever its name: it is the user's own skill. Every
//! path is judged with `lstat`, never followed: a symlink or anything else that isn't a plain
//! folder or file where a skill's folder, its marker or its `SKILL.md` should be is not
//! Workroom's. Only a plain file is ever opened, so a FIFO never blocks a read. A `SKILL.md` whose
//! bytes are not one Workroom wrote is the user's edit: install leaves it as it is, and remove
//! keeps it and gives the folder up (the marker goes). Remove deletes only the files Workroom
//! wrote, then the folder with `rmdir`, which fails, and keeps it, if anything else is in it; and
//! the `skills` folder too when the marker says Workroom made it, again only when empty.

use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::kind::CliError;
use super::{Args, Context, Outcome};
use crate::util::sha256_hex;

/// The skill's folder name, and its `name` in `SKILL.md`.
pub(super) const SKILL: &str = "workroom";
/// The marker that makes a skill folder Workroom's. The bootstrap's probe looks for it by name to
/// tell whether a host may hold a Workroom skill to remove (`probe.sh`).
pub(super) const MARKER: &str = ".workroom-skill";
const SKILL_FILE: &str = "SKILL.md";
/// What a marker says it was made by, so a file of the same name the user made is not taken for one.
const MADE_BY: &str = "workroom";
/// The most of a `SKILL.md` or marker read to judge it. Workroom's are a few KiB; anything larger
/// is not one it wrote.
const READ_LIMIT: u64 = 1 << 20;

/// The coding agents whose skills Workroom installs: a name for the reply, and their folder in the
/// home folder.
const AGENTS: &[(&str, &str)] = &[("claude", ".claude"), ("codex", ".codex")];

/// What `agent-skill install` and `remove` reply, one entry per agent.
#[derive(Serialize, Debug)]
struct Payload {
    skills: Vec<Report>,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub(super) struct Report {
    agent: &'static str,
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
    /// The agent's own folder isn't there, so nothing was written.
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
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
struct Marker {
    made_by: String,
    skill: String,
    /// The SHA-256 of each `SKILL.md` Workroom wrote here and may still be there: the current one,
    /// and the one before it while it is replaced, so a crash between the two writes still proves
    /// either.
    sha256: Vec<String>,
    /// Whether Workroom made the agent's `skills` folder, which remove then takes away too if it is
    /// empty.
    made_skills_folder: bool,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let (name, install) = match args.positional.as_slice() {
        [action] if action == "install" => ("agent-skill install", true),
        [action] if action == "remove" => ("agent-skill remove", false),
        _ => {
            return Outcome::Usage(CliError::internal(
                "`workroom agent-skill` takes install or remove",
            ));
        }
    };
    // Only the HOME this process was given, never a passwd lookup: the app runs it with a
    // throwaway HOME in its UI tests, and that must be the only home it can reach.
    let home = match context
        .env("HOME")
        .filter(|home| Path::new(home).is_absolute())
    {
        Some(home) => PathBuf::from(home),
        None => {
            return Outcome::FailedIn(
                name,
                CliError::internal(
                    "HOME is not set to a folder, so no agent's skills can be found",
                ),
            );
        }
    };
    let skills = if install {
        self::install(&home, &skill_text())
    } else {
        remove(&home)
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

/// The skill's `SKILL.md`: its front matter, then `help agents`.
pub(super) fn skill_text() -> String {
    format!(
        // No ": " in the description, which YAML would read as another key.
        "---\nname: {SKILL}\ndescription: Drive Workroom's terminals with the workroom command, \
         to list the other terminals, read their screens, run a shell command in one and get its \
         exit code and output, wait for output or a coding agent's turn, type keys, prompt the \
         coding agent in another terminal, and open or close terminals. Use it in a Workroom \
         terminal (WORKROOM_PANE is set) whenever a task involves another terminal, a dev \
         server, or another agent.\n---\n\n<!-- Installed by Workroom, from Settings > AI \
         Agents. Workroom updates it and removes it when the setting is turned off; once you \
         edit this file, Workroom leaves it as it is. -->\n\n{}\nRun `workroom help agents` for \
         this guide as the `workroom` you have explains it.\n",
        super::agents::text()
    )
}

/// Installs `text` as each agent's Workroom skill under `home`.
pub(super) fn install(home: &Path, text: &str) -> Vec<Report> {
    AGENTS
        .iter()
        .map(|(agent, folder)| {
            let skill = home.join(folder).join("skills").join(SKILL);
            let (state, message) = match install_one(&home.join(folder), &skill, text) {
                Ok(state) => (state, None),
                Err(error) => (State::Failed, Some(error)),
            };
            Report {
                agent,
                path: skill.to_string_lossy().into_owned(),
                state,
                message,
            }
        })
        .collect()
}

/// Removes each agent's Workroom skill under `home`, as far as it is Workroom's.
pub(super) fn remove(home: &Path) -> Vec<Report> {
    AGENTS
        .iter()
        .map(|(agent, folder)| {
            let skill = home.join(folder).join("skills").join(SKILL);
            let (state, message) = match remove_one(&skill) {
                Ok(state) => (state, None),
                Err(error) => (State::Failed, Some(error)),
            };
            Report {
                agent,
                path: skill.to_string_lossy().into_owned(),
                state,
                message,
            }
        })
        .collect()
}

fn install_one(agent: &Path, skill: &Path, text: &str) -> Result<State, String> {
    // The agent's folder may be a link the user made to their dotfiles: what the agent reads is
    // what it points at. Only the skill's own folder must be Workroom's.
    match fs::metadata(agent) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => return Ok(State::NoAgent),
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(State::NoAgent),
        Err(error) => return Err(format!("{}: {error}", agent.display())),
    }
    let skills = skill.parent().expect("a skill is in a skills folder");
    let made_skills_folder = match fs::create_dir(skills) {
        Ok(()) => true,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if !fs::metadata(skills).is_ok_and(|meta| meta.is_dir()) {
                return Ok(State::NotOurs);
            }
            false
        }
        Err(error) => return Err(format!("{}: {error}", skills.display())),
    };
    let digest = sha256_hex(text.as_bytes());
    match fs::create_dir(skill) {
        Ok(()) => {
            // The marker first, so the folder is provably Workroom's before it holds anything.
            write_marker(skill, std::slice::from_ref(&digest), made_skills_folder)?;
            write_file(skill, SKILL_FILE, text.as_bytes())?;
            Ok(State::Installed)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            let Some(marker) = read_marker(skill)? else {
                return Ok(State::NotOurs);
            };
            match judge_skill_file(skill, &marker)? {
                SkillFile::Theirs => Ok(State::Edited),
                SkillFile::Ours(bytes) if bytes == text.as_bytes() => {
                    if marker.sha256.as_slice() != std::slice::from_ref(&digest) {
                        write_marker(skill, &[digest], marker.made_skills_folder)?;
                    }
                    Ok(State::Current)
                }
                SkillFile::Ours(bytes) => {
                    // Both hashes while the file is replaced, then only the new one.
                    let before = sha256_hex(&bytes);
                    write_marker(skill, &[before, digest.clone()], marker.made_skills_folder)?;
                    write_file(skill, SKILL_FILE, text.as_bytes())?;
                    write_marker(skill, &[digest], marker.made_skills_folder)?;
                    Ok(State::Updated)
                }
                SkillFile::Missing => {
                    write_marker(skill, &[digest], marker.made_skills_folder)?;
                    write_file(skill, SKILL_FILE, text.as_bytes())?;
                    Ok(State::Updated)
                }
            }
        }
        Err(error) => Err(format!("{}: {error}", skill.display())),
    }
}

fn remove_one(skill: &Path) -> Result<State, String> {
    match fs::symlink_metadata(skill) {
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(State::Absent),
        Err(error) => return Err(format!("{}: {error}", skill.display())),
        Ok(_) => {}
    }
    let Some(marker) = read_marker(skill)? else {
        return Ok(State::NotOurs);
    };
    let state = match judge_skill_file(skill, &marker)? {
        SkillFile::Theirs => State::Edited,
        SkillFile::Ours(_) => {
            remove_file(&skill.join(SKILL_FILE))?;
            State::Removed
        }
        SkillFile::Missing => State::Removed,
    };
    // The marker last: until it goes, the folder is still provably Workroom's to finish removing.
    remove_file(&skill.join(MARKER))?;
    if state == State::Removed {
        // Fails, keeping the folder, when anything else is in it.
        let _ = fs::remove_dir(skill);
        if marker.made_skills_folder {
            let skills = skill.parent().expect("a skill is in a skills folder");
            if fs::symlink_metadata(skills).is_ok_and(|meta| meta.is_dir()) {
                let _ = fs::remove_dir(skills);
            }
        }
    }
    Ok(state)
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

fn write_marker(skill: &Path, sha256: &[String], made_skills_folder: bool) -> Result<(), String> {
    let marker = Marker {
        made_by: MADE_BY.into(),
        skill: SKILL.into(),
        sha256: sha256.to_vec(),
        made_skills_folder,
    };
    let mut bytes = serde_json::to_vec_pretty(&marker).expect("a marker is JSON");
    bytes.push(b'\n');
    write_file(skill, MARKER, &bytes)
}

/// Writes `name` in `folder` whole or not at all: a new file beside it, then a rename over it.
/// The rename replaces a link of that name rather than writing through it.
fn write_file(folder: &Path, name: &str, bytes: &[u8]) -> Result<(), String> {
    let path = folder.join(name);
    let staged = folder.join(format!("{MARKER}.{name}.{}.tmp", std::process::id()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&staged)
        .and_then(|mut file| file.write_all(bytes).and_then(|()| file.sync_all()));
    if let Err(error) = written.and_then(|()| fs::rename(&staged, &path)) {
        // Only the file this call made, which `create_new` proves.
        if error.kind() != ErrorKind::AlreadyExists {
            let _ = fs::remove_file(&staged);
        }
        return Err(format!("{}: {error}", path.display()));
    }
    Ok(())
}

fn remove_file(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("{}: {error}", path.display())),
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

    fn skill(home: &Path, folder: &str) -> PathBuf {
        home.join(folder).join("skills").join(SKILL)
    }

    #[test]
    fn install_writes_only_into_an_agents_folder_that_is_there() {
        let home = Scratch::new("skill-no-agent");
        assert_eq!(
            states(&install(&home, "one")),
            [State::NoAgent, State::NoAgent]
        );
        assert!(!home.join(".claude").exists() && !home.join(".codex").exists());

        fs::create_dir(home.join(".claude")).unwrap();
        assert_eq!(
            states(&install(&home, "one")),
            [State::Installed, State::NoAgent]
        );
        assert_eq!(
            fs::read_to_string(skill(&home, ".claude").join(SKILL_FILE)).unwrap(),
            "one"
        );
        assert!(!home.join(".codex").exists());
    }

    #[test]
    fn install_is_current_then_updated_and_remove_takes_exactly_what_it_wrote() {
        let home = Scratch::new("skill-cycle");
        fs::create_dir(home.join(".claude")).unwrap();
        fs::create_dir_all(home.join(".codex/skills/theirs")).unwrap();
        fs::write(home.join(".codex/skills/theirs/SKILL.md"), "mine").unwrap();

        assert_eq!(
            states(&install(&home, "one")),
            [State::Installed, State::Installed]
        );
        assert_eq!(
            states(&install(&home, "one")),
            [State::Current, State::Current]
        );
        assert_eq!(
            states(&install(&home, "two")),
            [State::Updated, State::Updated]
        );
        let marker = read_marker(&skill(&home, ".claude")).unwrap().unwrap();
        assert_eq!(marker.sha256, [sha256_hex(b"two")]);
        assert!(marker.made_skills_folder);
        assert!(
            !read_marker(&skill(&home, ".codex"))
                .unwrap()
                .unwrap()
                .made_skills_folder
        );

        assert_eq!(states(&remove(&home)), [State::Removed, State::Removed]);
        // Claude's skills folder was Workroom's and is empty, so it went; Codex's holds the user's.
        assert!(!home.join(".claude/skills").exists());
        assert!(home.join(".claude").is_dir());
        assert!(!skill(&home, ".codex").exists());
        assert_eq!(
            fs::read_to_string(home.join(".codex/skills/theirs/SKILL.md")).unwrap(),
            "mine"
        );
        assert_eq!(states(&remove(&home)), [State::Absent, State::Absent]);
    }

    #[test]
    fn a_skill_folder_workroom_did_not_make_is_never_written_or_removed() {
        let home = Scratch::new("skill-not-ours");
        let theirs = skill(&home, ".claude");
        fs::create_dir_all(&theirs).unwrap();
        fs::write(theirs.join(SKILL_FILE), "the user's own").unwrap();
        // A marker that isn't Workroom's: the wrong maker, or no JSON at all.
        fs::write(
            theirs.join(MARKER),
            r#"{"made_by":"someone","skill":"workroom","sha256":[],"made_skills_folder":false}"#,
        )
        .unwrap();
        fs::create_dir_all(skill(&home, ".codex")).unwrap();
        fs::write(skill(&home, ".codex").join(MARKER), "not json").unwrap();

        assert_eq!(
            states(&install(&home, "one")),
            [State::NotOurs, State::NotOurs]
        );
        assert_eq!(states(&remove(&home)), [State::NotOurs, State::NotOurs]);
        assert_eq!(
            fs::read_to_string(theirs.join(SKILL_FILE)).unwrap(),
            "the user's own"
        );
        assert!(theirs.join(MARKER).exists());
        assert!(skill(&home, ".codex").join(MARKER).exists());
    }

    #[test]
    fn an_edited_skill_is_left_by_install_and_kept_by_remove() {
        let home = Scratch::new("skill-edited");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, "one");
        let file = skill(&home, ".claude").join(SKILL_FILE);
        fs::write(&file, "one, with my notes").unwrap();

        assert_eq!(install(&home, "two")[0].state, State::Edited);
        assert_eq!(fs::read_to_string(&file).unwrap(), "one, with my notes");
        assert_eq!(remove(&home)[0].state, State::Edited);
        assert_eq!(fs::read_to_string(&file).unwrap(), "one, with my notes");
        // The folder is the user's now: no marker, so a later install leaves it alone.
        assert!(!skill(&home, ".claude").join(MARKER).exists());
        assert_eq!(install(&home, "two")[0].state, State::NotOurs);
    }

    #[test]
    fn links_are_judged_without_following_them() {
        let home = Scratch::new("skill-links");
        let elsewhere = Scratch::new("skill-links-elsewhere");
        fs::create_dir(home.join(".claude")).unwrap();
        fs::create_dir(home.join(".claude/skills")).unwrap();
        // A link where the skill's folder goes, to a folder holding a Workroom marker.
        install_one(&elsewhere, &elsewhere.join("skills").join(SKILL), "one").unwrap();
        std::os::unix::fs::symlink(
            elsewhere.join("skills").join(SKILL),
            skill(&home, ".claude"),
        )
        .unwrap();
        assert_eq!(install(&home, "two")[0].state, State::NotOurs);
        assert_eq!(remove(&home)[0].state, State::NotOurs);
        assert_eq!(
            fs::read_to_string(elsewhere.join("skills/workroom").join(SKILL_FILE)).unwrap(),
            "one"
        );

        // A link as SKILL.md in Workroom's own folder is not Workroom's file, even pointing at
        // bytes it wrote.
        fs::create_dir(home.join(".codex")).unwrap();
        install(&home, "one");
        let file = skill(&home, ".codex").join(SKILL_FILE);
        fs::remove_file(&file).unwrap();
        std::os::unix::fs::symlink(elsewhere.join("skills/workroom").join(SKILL_FILE), &file)
            .unwrap();
        assert_eq!(remove(&home)[1].state, State::Edited);
        assert!(
            fs::symlink_metadata(&file)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(elsewhere.join("skills/workroom").join(SKILL_FILE).exists());
    }

    #[test]
    fn a_fifo_in_place_of_the_skill_file_is_never_opened() {
        let home = Scratch::new("skill-fifo");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, "one");
        let file = skill(&home, ".claude").join(SKILL_FILE);
        fs::remove_file(&file).unwrap();
        let path = std::ffi::CString::new(file.to_string_lossy().as_bytes()).unwrap();
        // SAFETY: `mkfifo` reads the NUL-terminated path it is given and keeps no pointer.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        assert_eq!(install(&home, "two")[0].state, State::Edited);
        assert_eq!(remove(&home)[0].state, State::Edited);
        assert!(fs::symlink_metadata(&file).unwrap().file_type().is_fifo());
    }

    #[test]
    fn a_crash_between_the_files_of_an_update_still_proves_either() {
        let home = Scratch::new("skill-crash");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, "one");
        let folder = skill(&home, ".claude");
        // The update wrote its marker with both hashes and stopped before the file.
        write_marker(&folder, &[sha256_hex(b"one"), sha256_hex(b"two")], true).unwrap();
        assert_eq!(remove(&home)[0].state, State::Removed);
        assert!(!folder.exists());
    }

    #[test]
    fn remove_keeps_a_folder_that_holds_the_users_files() {
        let home = Scratch::new("skill-extra");
        fs::create_dir(home.join(".claude")).unwrap();
        install(&home, "one");
        let folder = skill(&home, ".claude");
        fs::write(folder.join("notes.md"), "mine").unwrap();
        assert_eq!(remove(&home)[0].state, State::Removed);
        assert_eq!(fs::read_to_string(folder.join("notes.md")).unwrap(), "mine");
        assert!(!folder.join(SKILL_FILE).exists() && !folder.join(MARKER).exists());
        assert!(home.join(".claude/skills").is_dir());
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
