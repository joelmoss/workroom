//! `workroom resume-hook report|install|remove` (#828, hidden): Claude Code's resume report, which
//! Claude doesn't send itself yet (anthropics/claude-code#112408), so a pane brings back Claude's
//! conversation after a restart (ADR 0082).
//!
//! **The report** (`resume-hook report`), which a `SessionStart` hook runs: at every start of a
//! conversation (a new one, a resumed one, after `/clear` or a compact). It reads the hook's input
//! (`session_id`), finds Claude, the nearest of its parents whose arguments are Claude Code's (the
//! hook's own parent is the shell Claude runs it with, whose parent is Claude), and builds
//! `claude --resume <id>` with the flags Claude was started with that shape the session
//! (`claude::resume_command`). It writes that as an OSC 7577 report, with Claude's pid as its
//! owner and signed with the session's `OSC7577_TOKEN`, to Claude's own terminal device, found from
//! Claude's pid: never to stdout, which Claude hands the model, and not to `/dev/tty`, since Claude
//! runs its hooks with no controlling terminal (`docs/designs/osc-7577-hook-spike.md`). With no
//! token (not a Workroom pane, or resume turned off for it) it does nothing; with no Claude above
//! it, a flag it doesn't know or one that means there is nothing to resume (`-p`), it sends
//! nothing. Either way it prints nothing and succeeds, within `REPORT_BOUND`.
//!
//! **The hook** (`resume-hook install|remove`), which the app runs on the Mac while Settings ▸
//! Terminal's "Resume programs after a restart" is on, or off, and each host's bootstrap on that
//! host. It goes into `hooks.SessionStart` in each Claude profile's `settings.json`: the profile
//! `CLAUDE_CONFIG_DIR` names and the default `~/.claude`, where each is set up (its folder is
//! there), and every profile it was installed in before (`RECORD`), so a removal finds one a
//! variable no longer names. A cswap profile links its `settings.json` to `~/.claude`'s, which is
//! followed, so the one file gets it. The hook's command (`COMMAND`) is the same from every build:
//! it runs the `workroom` in the pane's own daemon's bin folder (`WORKROOM_BIN_DIR`), so a stable,
//! a Nightly and a Dev app never rewrite each other's entry, and it does nothing outside a
//! Workroom pane or when that `workroom` is gone.
//!
//! **What is Workroom's.** A hook handler whose command holds `MARKER` is Workroom's to update or
//! remove; nothing else in the file is touched. Install adds its group when there is none, and
//! replaces any of its own that differ; remove takes its handlers out, and a group they leave empty.
//! A file that doesn't parse, or whose `hooks` or `SessionStart` isn't what Claude reads, is left
//! as it is and the profile reported `failed`, never overwritten. A file that already says what it
//! should is not written; one that changes is written whole to a file of this run's own beside it
//! and renamed over it, keeping its permissions, with every key it had (in key order: the JSON is
//! read into a map, so a rewrite sorts the keys). A link where `settings.json` should be is
//! followed, and the file it names written, so a dotfiles or cswap link stays a link.

mod claude;

use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::kind::CliError;
use super::skill::{Places, given_home};
use super::{Args, Context, Flag, Outcome};
use crate::terminal::process;

/// The marker that makes a hook handler Workroom's.
pub(super) const MARKER: &str = "# workroom-resume-hook";

/// The hook's command, in every profile and from every build alike. Claude runs it with `sh -c`.
/// The pane's daemon's own `workroom`, else the one on PATH, for a daemon that could make no bin
/// folder (`terminal::bin_path`); nothing it says reaches Claude, and it always succeeds.
pub(super) const COMMAND: &str = "[ -n \"$OSC7577_TOKEN\" ] && { w=\"$WORKROOM_BIN_DIR/workroom\"; \
     [ -x \"$w\" ] || w=workroom; \"$w\" resume-hook report; } >/dev/null 2>&1; \
     true # workroom-resume-hook";

/// How long the hook may take, in seconds, as Claude reads a handler's `timeout`: longer than the
/// report's own bound.
const HOOK_TIMEOUT: u64 = 10;

/// The longest the report runs: past it, a read of the hook's input or a write to the terminal
/// that hasn't finished is given up, and it exits.
const REPORT_BOUND: u32 = 5;

/// The most of the hook's input read. Claude's is a few hundred bytes.
const INPUT_LIMIT: usize = 1 << 20;

/// The most of a `settings.json` read; Claude's own limit for a settings file is 2 MiB.
const SETTINGS_LIMIT: u64 = 2 << 20;

/// How many parents up from the report Claude may be: the shell Claude runs the hook with, then
/// Claude.
const MAX_HOPS: usize = 4;

/// Where under the home the profiles the hook went into are recorded.
pub(super) const RECORD: &str = ".local/state/workroom/resume-hook.json";

/// `install` and `remove` take it: read `CLAUDE_CONFIG_DIR` from the login environment, as a
/// host's bootstrap asks, rather than this process's.
pub(super) const FLAGS: &[Flag] = &[Flag {
    name: "login-environment",
    usage: "Read CLAUDE_CONFIG_DIR from the login shell's environment",
    hidden: true,
    ..Flag::BOOL
}];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let (name, install) = match args.positional.as_slice() {
        // Whatever happens, nothing is printed: Claude shows a hook's output to the model.
        [action] if action == "report" => {
            report();
            return Outcome::Printed(String::new());
        }
        [action] if action == "install" => ("resume-hook install", true),
        [action] if action == "remove" => ("resume-hook remove", false),
        _ => {
            return Outcome::Usage(CliError::internal(
                "`workroom resume-hook` takes report, install or remove",
            ));
        }
    };
    let Some(home) = given_home(context) else {
        return Outcome::FailedIn(
            name,
            CliError::internal("HOME is not set to a folder, so no Claude profile can be found"),
        );
    };
    let places = Places::read(context, &home, args.is_set("login-environment"));
    let profiles = if install {
        self::install(&home, &places)
    } else {
        remove(&home, &places)
    };
    if context.json {
        return Outcome::Success(super::envelope::success(name, &Payload { profiles }));
    }
    Outcome::Printed(
        profiles
            .iter()
            .map(|profile| {
                let said = match profile.state {
                    State::Installed => "installed",
                    State::Updated => "updated",
                    State::Current => "already current",
                    State::Removed => "removed",
                    State::Absent => "not installed",
                    State::NoAgent => "not set up on this machine, so nothing was written",
                    State::Failed => "failed",
                };
                let why = profile
                    .message
                    .as_deref()
                    .map_or(String::new(), |message| format!(": {message}"));
                format!("claude {}: {said}{why}\n", profile.path)
            })
            .collect(),
    )
}

// MARK: - The report

/// `resume-hook report`, bounded by `REPORT_BOUND`.
fn report() {
    let Some(token) = std::env::var(crate::terminal::resume::TOKEN_VARIABLE)
        .ok()
        .filter(|token| !token.is_empty())
    else {
        return;
    };
    bound(REPORT_BOUND);
    let Some(id) = conversation(&read_input()) else {
        return;
    };
    let Some((pid, argv)) = find_claude(std::os::unix::process::parent_id()) else {
        return;
    };
    let profile = std::env::var("CLAUDE_CONFIG_DIR").ok();
    let Some(command) = claude::claude_arguments(&argv)
        .and_then(|args| claude::resume_command(args, &id, profile.as_deref()))
    else {
        return;
    };
    let Some(now) = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|since| since.as_secs())
    else {
        return;
    };
    let Some(frame) = crate::terminal::resume::launch::record_report(&token, pid, now, &command)
    else {
        return;
    };
    if let Some((path, device)) = process::terminal_device(pid as i32) {
        let _ = write_to_terminal(&path, device, &frame);
    }
}

extern "C" fn woken(_: libc::c_int) {}

/// Has `SIGALRM` interrupt a read or write that is still waiting `seconds` from now, without
/// ending the process, so the report gives up and exits 0.
fn bound(seconds: u32) {
    // SAFETY: a handler that does nothing, installed with no `SA_RESTART`, so a blocked call
    // returns `EINTR`; `sigaction` reads the struct it is given and keeps no pointer.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = woken as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        action.sa_flags = 0;
        libc::sigaction(libc::SIGALRM, &action, std::ptr::null_mut());
        libc::alarm(seconds);
    }
}

/// The hook's input, from stdin, up to `INPUT_LIMIT`, with `read(2)` alone so an interrupted read
/// ends it rather than being tried again.
fn read_input() -> Vec<u8> {
    let mut input = Vec::new();
    let mut buffer = [0u8; 8192];
    while input.len() < INPUT_LIMIT {
        // SAFETY: `buffer` is valid for its length.
        let read = unsafe { libc::read(0, buffer.as_mut_ptr().cast(), buffer.len()) };
        if read <= 0 {
            break;
        }
        input.extend_from_slice(&buffer[..read.unsigned_abs()]);
    }
    input
}

/// The conversation's id in the hook's input (`session_id`).
fn conversation(input: &[u8]) -> Option<String> {
    #[derive(Deserialize)]
    struct Input {
        session_id: String,
    }
    serde_json::from_slice::<Input>(input)
        .ok()
        .map(|input| input.session_id)
}

/// The nearest process, from `pid` up, whose arguments are Claude Code's, within `MAX_HOPS`: its
/// pid and arguments.
fn find_claude(pid: u32) -> Option<(u32, Vec<String>)> {
    let mut next = pid;
    for _ in 0..MAX_HOPS {
        if next <= 1 {
            return None;
        }
        let argv = process::arguments(next as i32)?;
        if claude::claude_arguments(&argv).is_some() {
            return Some((next, argv));
        }
        next = process::identity(next)?.parent;
    }
    None
}

/// Writes `frame` to the terminal device at `path`, which must still be `device`: opened as no
/// controlling terminal, and sent in one `write(2)` where the terminal takes it whole, so Claude's
/// own output doesn't land inside it.
fn write_to_terminal(path: &Path, device: u64, frame: &[u8]) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    let file = fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.file_type().is_char_device() || meta.rdev() != device {
        return Err(ErrorKind::InvalidInput.into());
    }
    let mut rest = frame;
    while !rest.is_empty() {
        // SAFETY: `rest` is valid for its length.
        let written = unsafe { libc::write(file.as_raw_fd(), rest.as_ptr().cast(), rest.len()) };
        if written <= 0 {
            return Err(std::io::Error::last_os_error());
        }
        rest = &rest[written.unsigned_abs()..];
    }
    Ok(())
}

// MARK: - The hook

/// What `install` and `remove` reply, one entry per Claude profile.
#[derive(Serialize, Debug)]
struct Payload {
    profiles: Vec<Report>,
}

/// One profile's `settings.json`, in the shape `workroom skill` reports a folder in.
#[derive(Serialize, Debug, PartialEq, Eq)]
pub(super) struct Report {
    agent: &'static str,
    /// The profile's `settings.json`.
    path: String,
    state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub(super) enum State {
    /// Install: added where there was none of Workroom's.
    Installed,
    /// Install: Workroom's, replaced with this build's.
    Updated,
    /// Install: already this build's.
    Current,
    /// Remove: Workroom's is gone.
    Removed,
    /// Remove: none of Workroom's there.
    Absent,
    /// The profile's folder isn't there, so nothing was written.
    NoAgent,
    /// The file couldn't be read, parsed or written; `message` says why, and it is as it was.
    Failed,
}

/// Workroom's hook group, as it goes into `hooks.SessionStart`: no matcher, so every start.
fn entry() -> Value {
    json!({
        "hooks": [{"type": "command", "command": COMMAND, "timeout": HOOK_TIMEOUT}]
    })
}

/// Whether a hook handler is Workroom's.
fn is_ours(handler: &Value) -> bool {
    handler
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| command.contains(MARKER))
}

/// The settings' `hooks.SessionStart`, made when `make` and it isn't there; an error when
/// `hooks` or it is something Claude wouldn't read as hooks.
fn session_start(
    settings: &mut Map<String, Value>,
    make: bool,
) -> Result<Option<&mut Vec<Value>>, String> {
    if !make && !settings.contains_key("hooks") {
        return Ok(None);
    }
    let hooks = settings
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()));
    let Value::Object(hooks) = hooks else {
        return Err("its \"hooks\" isn't an object".into());
    };
    if !make && !hooks.contains_key("SessionStart") {
        return Ok(None);
    }
    let start = hooks
        .entry("SessionStart")
        .or_insert_with(|| Value::Array(Vec::new()));
    match start {
        Value::Array(groups) => Ok(Some(groups)),
        _ => Err("its \"hooks.SessionStart\" isn't a list".into()),
    }
}

/// Takes Workroom's handlers out of `groups`, and any group they leave empty; whether there were
/// any.
fn take_ours(groups: &mut Vec<Value>) -> bool {
    let mut found = false;
    groups.retain_mut(|group| {
        let Some(Value::Array(handlers)) = group.get_mut("hooks") else {
            return true;
        };
        let before = handlers.len();
        handlers.retain(|handler| !is_ours(handler));
        if handlers.len() == before {
            return true;
        }
        found = true;
        !handlers.is_empty()
    });
    found
}

/// `settings` with Workroom's hook in it, and what that was.
pub(super) fn with_hook(settings: &mut Map<String, Value>) -> Result<State, String> {
    let groups = session_start(settings, true)?.expect("made");
    let ours = entry();
    let current = groups.iter().filter(|group| **group == ours).count() == 1
        && groups
            .iter()
            .filter(|group| **group != ours)
            .all(|group| match group.get("hooks") {
                Some(Value::Array(handlers)) => !handlers.iter().any(is_ours),
                _ => true,
            });
    if current {
        return Ok(State::Current);
    }
    let had = take_ours(groups);
    groups.push(ours);
    Ok(if had {
        State::Updated
    } else {
        State::Installed
    })
}

/// `settings` without Workroom's hook, and what that was. A `SessionStart`, then a `hooks`, left
/// empty by it goes too.
pub(super) fn without_hook(settings: &mut Map<String, Value>) -> Result<State, String> {
    let Some(groups) = session_start(settings, false)? else {
        return Ok(State::Absent);
    };
    if !take_ours(groups) {
        return Ok(State::Absent);
    }
    let start_empty = groups.is_empty();
    if start_empty && let Some(Value::Object(hooks)) = settings.get_mut("hooks") {
        hooks.remove("SessionStart");
        if hooks.is_empty() {
            settings.remove("hooks");
        }
    }
    Ok(State::Removed)
}

/// The Claude profiles to look at: `CLAUDE_CONFIG_DIR`'s and the default, then each recorded.
fn profiles(home: &Path, places: &Places) -> Vec<PathBuf> {
    let mut profiles: Vec<PathBuf> = places
        .claude_config_dir()
        .map(Path::to_path_buf)
        .into_iter()
        .chain([home.join(".claude")])
        .collect();
    for recorded in read_record(home) {
        if !profiles.contains(&recorded) {
            profiles.push(recorded);
        }
    }
    profiles
}

/// Installs the hook in each Claude profile that is set up, and records where.
pub(super) fn install(home: &Path, places: &Places) -> Vec<Report> {
    let reports = each_profile(&profiles(home, places), with_hook);
    let mut record = read_record(home);
    for (profile, report) in &reports {
        if matches!(
            report.state,
            State::Installed | State::Updated | State::Current
        ) && !record.contains(profile)
        {
            record.push(profile.clone());
        }
    }
    write_record(home, &record);
    reports.into_iter().map(|(_, report)| report).collect()
}

/// Removes the hook from each Claude profile, where it would go now and wherever it went before.
pub(super) fn remove(home: &Path, places: &Places) -> Vec<Report> {
    let reports = each_profile(&profiles(home, places), without_hook);
    // Only a removal that failed is left to try again.
    let left: Vec<PathBuf> = reports
        .iter()
        .filter(|(_, report)| report.state == State::Failed)
        .map(|(profile, _)| profile.clone())
        .collect();
    write_record(home, &left);
    reports.into_iter().map(|(_, report)| report).collect()
}

/// `change` applied to each profile's `settings.json` that is set up, each file once however many
/// profiles link to it.
fn each_profile(
    profiles: &[PathBuf],
    change: fn(&mut Map<String, Value>) -> Result<State, String>,
) -> Vec<(PathBuf, Report)> {
    let mut written: Vec<PathBuf> = Vec::new();
    let mut reports = Vec::new();
    for profile in profiles {
        let path = profile.join("settings.json");
        let report = |state, message| Report {
            agent: "claude",
            path: path.to_string_lossy().into_owned(),
            state,
            message,
        };
        if !fs::metadata(profile).is_ok_and(|meta| meta.is_dir()) {
            reports.push((profile.clone(), report(State::NoAgent, None)));
            continue;
        }
        let target = match settings_file(&path) {
            Ok(target) => target,
            Err(error) => {
                reports.push((profile.clone(), report(State::Failed, Some(error))));
                continue;
            }
        };
        if written.contains(&target) {
            continue;
        }
        written.push(target.clone());
        let state = update_file(&target, change);
        reports.push((
            profile.clone(),
            match state {
                Ok(state) => report(state, None),
                Err(error) => report(State::Failed, Some(error)),
            },
        ));
    }
    reports
}

/// The file a profile's `settings.json` at `path` is: itself, or what a link there names, which
/// must be a plain file. It needn't be there yet.
fn settings_file(path: &Path) -> Result<PathBuf, String> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(path.to_path_buf()),
        Err(error) => Err(format!("{}: {error}", path.display())),
        Ok(meta) if meta.file_type().is_symlink() => {
            let target = fs::canonicalize(path).map_err(|error| {
                format!(
                    "{} is a link to nothing Workroom can read: {error}",
                    path.display()
                )
            })?;
            if !fs::symlink_metadata(&target).is_ok_and(|meta| meta.is_file()) {
                return Err(format!(
                    "{} links to something that isn't a file",
                    path.display()
                ));
            }
            Ok(target)
        }
        Ok(meta) if meta.is_file() => Ok(path.to_path_buf()),
        Ok(_) => Err(format!("{} isn't a file", path.display())),
    }
}

/// Reads the settings at `path` (none there is `{}`), applies `change`, and writes them back when
/// they changed. An error, and the file as it was, when it can't be read or parsed.
fn update_file(
    path: &Path,
    change: fn(&mut Map<String, Value>) -> Result<State, String>,
) -> Result<State, String> {
    let shown = path.display();
    let existing = match fs::symlink_metadata(path) {
        Err(error) if error.kind() == ErrorKind::NotFound => None,
        Err(error) => return Err(format!("{shown}: {error}")),
        Ok(meta) if !meta.is_file() => return Err(format!("{shown} isn't a file")),
        Ok(meta) if meta.len() > SETTINGS_LIMIT => {
            return Err(format!("{shown} is larger than Claude Code reads"));
        }
        Ok(meta) => Some(meta),
    };
    let mut settings = match existing {
        None => Map::new(),
        Some(_) => {
            let mut bytes = Vec::new();
            fs::File::open(path)
                .and_then(|file| file.take(SETTINGS_LIMIT + 1).read_to_end(&mut bytes))
                .map_err(|error| format!("{shown}: {error}"))?;
            if bytes.iter().all(u8::is_ascii_whitespace) {
                Map::new()
            } else {
                match serde_json::from_slice::<Value>(&bytes) {
                    Ok(Value::Object(settings)) => settings,
                    Ok(_) => {
                        return Err(format!(
                            "{shown} isn't a JSON object, so Workroom left it as it is"
                        ));
                    }
                    Err(error) => {
                        return Err(format!(
                            "{shown} isn't valid JSON ({error}), so Workroom left it as it is"
                        ));
                    }
                }
            }
        }
    };
    let before = settings.clone();
    let state = change(&mut settings)
        .map_err(|why| format!("{shown}: {why}, so Workroom left it as it is"))?;
    if settings == before {
        return Ok(state);
    }
    if existing.is_none() && settings.is_empty() {
        return Ok(state);
    }
    let mode = existing.map_or(0o600, |meta| meta.permissions().mode() & 0o7777);
    write_atomically(path, &Value::Object(settings), mode)?;
    Ok(state)
}

/// Writes `value` to `path` whole or not at all: to a file of this run's own beside it, synced,
/// then renamed over it.
fn write_atomically(path: &Path, value: &Value, mode: u32) -> Result<(), String> {
    let shown = path.display();
    let folder = path
        .parent()
        .ok_or_else(|| format!("{shown} has no folder"))?;
    let name = path
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let staged = folder.join(format!(
        ".{name}.workroom.{}.{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_nanos())
    ));
    let mut bytes = serde_json::to_vec_pretty(value).expect("settings are JSON");
    bytes.push(b'\n');
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&staged)
        .and_then(|mut file| {
            file.write_all(&bytes)?;
            // `mode` is masked by the umask at create; set exactly, as the file had it.
            file.set_permissions(fs::Permissions::from_mode(mode))?;
            file.sync_all()
        })
        .and_then(|()| fs::rename(&staged, path));
    if let Err(error) = written {
        // Only the file this call made, which `create_new` proves.
        let _ = fs::remove_file(&staged);
        return Err(format!("{shown}: {error}"));
    }
    Ok(())
}

#[derive(Serialize, Deserialize, Default)]
struct RecordFile {
    profiles: Vec<PathBuf>,
}

/// The profiles recorded under `home`; none when there is no readable record.
fn read_record(home: &Path) -> Vec<PathBuf> {
    let path = home.join(RECORD);
    if !fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file() && meta.len() <= 1 << 20) {
        return Vec::new();
    }
    fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<RecordFile>(&bytes).ok())
        .map(|record| record.profiles)
        .unwrap_or_default()
}

/// Records `profiles` under `home`, whole or not at all. A record that can't be written leaves the
/// last one; only a removal after the variable moved a profile would miss it.
fn write_record(home: &Path, profiles: &[PathBuf]) {
    let path = home.join(RECORD);
    if read_record(home) == profiles && path.exists() {
        return;
    }
    if profiles.is_empty() && !path.exists() {
        return;
    }
    if path
        .parent()
        .is_none_or(|folder| fs::create_dir_all(folder).is_err())
    {
        return;
    }
    let _ = write_atomically(
        &path,
        &serde_json::to_value(RecordFile {
            profiles: profiles.to_vec(),
        })
        .expect("a record is JSON"),
        0o600,
    );
}

#[cfg(test)]
mod tests;
