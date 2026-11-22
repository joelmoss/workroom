//! The daemon's bin folder on a session's PATH (#695, `daemon::bin_dir`): the one rule for every
//! session, a Mac pane's, a host pane's and a run's.
//!
//! - The session gets `WORKROOM_BIN_DIR`, the folder, and a `PATH` that starts with it, once. A
//!   PATH that is missing or empty becomes the folder and the standard directories, since the
//!   folder alone would leave the shell no `ls`.
//! - An interactive zsh, fish, or bash that Ghostty's integration starts, is also pointed at the
//!   folder's hook (`daemon::bin_dir`), which puts the folder first again once the shell's startup
//!   files have run: a login profile can move it (macOS's `path_helper`) or set PATH outright
//!   (Debian's `/etc/profile`). Each hook first runs what it stands in for, so the shell starts as
//!   it did.
//! - elvish and nu, which have no hook, get Ghostty's own `path` feature with the folder as
//!   `GHOSTTY_BIN_DIR`, where Ghostty's integration starts them: it appends the folder once their
//!   startup files have run if they took it off, and leaves a PATH that has it alone. Not where
//!   the session's features use `GHOSTTY_BIN_DIR` for Ghostty's own program (`ssh-*`).
//! - Other shells (sh, dash, ksh, and bash without the integration) and run commands have the
//!   folder first on the PATH they start with, which their profile may change.
//! - Every hook does nothing when `WORKROOM_BIN_DIR` is unset or empty by then, so a startup file
//!   that unsets it keeps the PATH it made.
//!
//! A daemon without a bin folder (`bin_dir::keep` could not make it) gives a session no
//! `WORKROOM_BIN_DIR`, and puts the folder of its own `workroom`, when it has one beside it (a
//! host's bootstrap link), after the session's PATH instead, as #681 did.
//!
//! What the attach client sent under these names is another pane's, or the Mac's, and is dropped.

use std::ffi::{OsStr, OsString};
use std::path::Path;

use crate::daemon::bin_dir::{BASH_FILE, FISH_FILE, Folders, ZSH_DIR};
use crate::terminal::shell::{Invocation, XDG_FALLBACK_DATA_DIRECTORIES, shell_name};

/// The folder, for the session's shell and what it runs.
pub(crate) const BIN_DIR_VARIABLE: &str = "WORKROOM_BIN_DIR";
/// The zsh `ZDOTDIR` the hook stands in for.
const ZSH_ZDOTDIR: &str = "WORKROOM_ZSH_ZDOTDIR";
/// The bash `ENV` (Ghostty's integration) the hook stands in for.
const BASH_ENV: &str = "WORKROOM_BASH_ENV";
/// The `XDG_DATA_DIRS` entry fish finds the hook through, which the hook takes off again.
const FISH_XDG_DIR: &str = "WORKROOM_FISH_XDG_DIR";

/// Puts `folders`' bin folder first on `invocation`'s PATH, as the module says. With no folders
/// (a daemon on stdio, or one that could not make its folder), puts `fallback`, the folder of this
/// program's `workroom` if any, after it.
pub(crate) fn apply(
    invocation: &mut Invocation,
    folders: Option<&Folders>,
    fallback: Option<&Path>,
) {
    apply_with(invocation, folders, fallback, |hook| {
        std::fs::metadata(hook).is_ok_and(|meta| meta.is_file())
    });
}

/// [`apply`], pointing a shell at a hook only when `present` says its file is there: a shell sent
/// to a hook that is gone would read none of its startup files (zsh), or stay in POSIX mode with
/// none read (bash).
fn apply_with(
    invocation: &mut Invocation,
    folders: Option<&Folders>,
    fallback: Option<&Path>,
    present: impl Fn(&Path) -> bool,
) {
    let env = &mut invocation.environment;
    env.retain(|(key, _)| {
        ![BIN_DIR_VARIABLE, ZSH_ZDOTDIR, BASH_ENV, FISH_XDG_DIR]
            .iter()
            .any(|name| key == name)
    });
    let Some(folders) = folders else {
        if let Some(fallback) = fallback {
            let path = crate::host::environment::with_commands(get(env, "PATH"), fallback);
            set(env, "PATH", path);
        }
        return;
    };
    let path = bin_first(get(env, "PATH"), &folders.bin);
    set(env, "PATH", path);
    set(env, BIN_DIR_VARIABLE, folders.bin.clone().into_os_string());
    if !invocation.interactive {
        return;
    }
    let name = shell_name(&invocation.program.to_string_lossy()).to_string();
    if matches!(name.as_str(), "elvish" | "nu") {
        ghosttys_path_feature(env, &folders.bin);
        return;
    }
    let Some(hooks) = folders.hooks.as_deref() else {
        return;
    };
    match name.as_str() {
        "zsh" if present(&hooks.join(ZSH_DIR).join(".zshenv")) => {
            if let Some(zdotdir) = get(env, "ZDOTDIR").map(OsStr::to_os_string) {
                set(env, ZSH_ZDOTDIR, zdotdir);
            }
            set(env, "ZDOTDIR", hooks.join(ZSH_DIR).into_os_string());
        }
        "bash" if present(&hooks.join(BASH_FILE)) => {
            // Only where Ghostty's integration starts bash, in POSIX mode with its `ENV`: no other
            // file runs after bash's startup files.
            let injected = get(env, "GHOSTTY_BASH_INJECT").is_some_and(|value| !value.is_empty());
            if let Some(ghostty) = get(env, "ENV")
                .filter(|_| injected)
                .map(OsStr::to_os_string)
            {
                set(env, BASH_ENV, ghostty);
                set(env, "ENV", hooks.join(BASH_FILE).into_os_string());
            }
        }
        "fish" if present(&hooks.join(FISH_FILE)) => {
            let dirs = get(env, "XDG_DATA_DIRS")
                .filter(|dirs| !dirs.is_empty())
                .map(OsStr::to_os_string)
                .unwrap_or_else(|| OsString::from(XDG_FALLBACK_DATA_DIRECTORIES));
            let mut joined = hooks.as_os_str().to_os_string();
            joined.push(":");
            joined.push(dirs);
            set(env, "XDG_DATA_DIRS", joined);
            set(env, FISH_XDG_DIR, hooks.as_os_str().to_os_string());
        }
        _ => {}
    }
}

/// Ghostty's `path` feature, with `folder` as the folder it appends, where Ghostty's integration
/// starts the shell (`GHOSTTY_SHELL_INTEGRATION_XDG_DIR`, `shell::invocation`) and no feature
/// already uses `GHOSTTY_BIN_DIR` for Ghostty's own program.
fn ghosttys_path_feature(env: &mut Vec<(OsString, OsString)>, folder: &Path) {
    if get(env, "GHOSTTY_SHELL_INTEGRATION_XDG_DIR").is_none() {
        return;
    }
    let features = get(env, "GHOSTTY_SHELL_FEATURES")
        .map(|features| features.to_string_lossy().into_owned())
        .unwrap_or_default();
    let listed: Vec<&str> = features.split(',').filter(|f| !f.is_empty()).collect();
    if listed.iter().any(|feature| feature.starts_with("ssh-")) {
        return;
    }
    if !listed.contains(&"path") {
        let mut features = listed.join(",");
        if !features.is_empty() {
            features.push(',');
        }
        features.push_str("path");
        set(env, "GHOSTTY_SHELL_FEATURES", OsString::from(features));
    }
    set(env, "GHOSTTY_BIN_DIR", folder.as_os_str().to_os_string());
}

/// `path` with `folder` first and nowhere else; the standard directories after it when `path` is
/// missing or holds nothing but the folder.
pub(crate) fn bin_first(path: Option<&OsStr>, folder: &Path) -> OsString {
    let rest: Vec<_> = path
        .map(|path| {
            std::env::split_paths(path)
                .filter(|entry| entry != folder && !entry.as_os_str().is_empty())
                .collect()
        })
        .unwrap_or_default();
    let mut joined = folder.as_os_str().to_os_string();
    joined.push(":");
    if rest.is_empty() {
        joined.push(crate::host::environment::FLOOR_PATH);
    } else {
        // Entries came from a PATH, so none holds a `:`.
        joined.push(std::env::join_paths(rest).unwrap_or_default());
    }
    joined
}

fn get<'a>(env: &'a [(OsString, OsString)], key: &str) -> Option<&'a OsStr> {
    env.iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.as_os_str())
}

/// Sets `key`, in place when it is there, so the order of the rest stays.
fn set(env: &mut Vec<(OsString, OsString)>, key: &str, value: OsString) {
    match env.iter().position(|(name, _)| name == key) {
        Some(at) => {
            env[at].1 = value;
            let mut seen = false;
            env.retain(|(name, _)| {
                if name != key {
                    return true;
                }
                let first = !seen;
                seen = true;
                first
            });
        }
        None => env.push((OsString::from(key), value)),
    }
}

#[cfg(test)]
mod tests;
