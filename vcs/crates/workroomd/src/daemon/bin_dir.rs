//! The daemon's bin folder (#695): `<socket>.bin/path`, holding one entry, `workroom`, a symlink
//! to the binary this daemon runs. Every session's shell, on the Mac and on a host, gets the folder
//! first on its `PATH` and as `WORKROOM_BIN_DIR` (`terminal::bin_path`), so `workroom` typed in a
//! pane is the build of the daemon it talks to, whatever else is installed.
//!
//! **What the link points at.** The daemon's own copy of its binary (`own_copy`) once it has one,
//! and until then the file this program runs. Not that file for good: an update or a downgrade
//! replaces or removes it (the swap took `Contents/MacOS/workroomd` away, and moving or deleting the
//! app takes `Contents/Resources/workroom` with it), and a link to it would then run something that
//! is not this daemon, or nothing. The copy is this daemon's alone and goes only once no daemon
//! runs from it. An update whose CLI commands alone changed (#680) is installed over that file
//! without a hand-off; the next session to start notices (`ensure`) and the copy is made again
//! from it, so panes, open ones too, run the new commands while the daemon runs its own.
//!
//! **Re-pointed after every hand-off.** A program a hand-off starts runs `keep` as any daemon does:
//! the link points at that program's own file at once, then at its copy once that is made, and both
//! times through a link made under a name of this process's own (`.workroom.<pid>`) that is renamed
//! over `workroom`, so a pane never finds the name missing. The folder's path is the socket's, which
//! a hand-off keeps, so a pane opened before it reaches the new binary through the PATH it has.
//!
//! **Whose files these are.** The folder is made, exclusively, inside the folder `own_copy` marks
//! as its own. `workroom` is replaced only while it is a symlink, which only this code makes there,
//! and a staged link only when its pid is this process's or a process that is gone. Nothing else
//! in the folder is touched.
//!
//! **The shells' hooks** (`shell/`, beside it). A login profile can reorder `PATH` (macOS's
//! `path_helper`) or set it outright (Debian's `/etc/profile`), so first at spawn is not first at
//! the prompt. For zsh, fish and bash with Ghostty's integration, the session points the shell at a
//! hook of this folder's that runs its own startup as before and then moves the folder back to the
//! front: at the first prompt in zsh and fish, once Ghostty's integration has read the startup files
//! in bash. They are written at every start, so a hand-off brings its own.

use std::fs;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use crate::util::lock_or_recover;

/// The one entry the folder is for.
pub(crate) const LINK: &str = "workroom";

/// zsh's hook, as `<hooks>/zsh/.zshenv`.
const ZSH_HOOK: &str = include_str!("bin_dir/zshenv");
/// bash's, as `<hooks>/bash/workroom.bash`: the `ENV` Ghostty's integration starts bash with.
const BASH_HOOK: &str = include_str!("bin_dir/workroom.bash");
/// fish's, as `<hooks>/fish/vendor_conf.d/workroom.fish`, found through `XDG_DATA_DIRS`.
const FISH_HOOK: &str = include_str!("bin_dir/workroom.fish");

/// Where the hooks are, under the hooks folder.
pub(crate) const ZSH_DIR: &str = "zsh";
pub(crate) const BASH_FILE: &str = "bash/workroom.bash";
pub(crate) const FISH_FILE: &str = "fish/vendor_conf.d/workroom.fish";

/// This daemon's folders, once `keep` has made them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Folders {
    /// The bin folder, `WORKROOM_BIN_DIR`.
    pub bin: PathBuf,
    /// The shells' hooks, or None when they could not be written.
    pub hooks: Option<PathBuf>,
}

static FOLDERS: OnceLock<Folders> = OnceLock::new();

/// The bin folder of a socket's daemon.
pub fn dir_beside(socket: &Path) -> PathBuf {
    crate::daemon::own_copy::dir_beside(socket).join("path")
}

/// The hooks folder of a socket's daemon.
fn hooks_beside(socket: &Path) -> PathBuf {
    crate::daemon::own_copy::dir_beside(socket).join("shell")
}

/// Makes the bin folder of `socket`'s daemon and its hooks, and points the link at this program's
/// own file. At start, before `own_copy::keep`, whose thread re-points it at the copy: cheap, and
/// done before the first session, which gets the folder on its PATH.
pub fn keep(socket: &Path) {
    let bin = dir_beside(socket);
    let made = crate::daemon::own_copy::own_folder(&crate::daemon::own_copy::dir_beside(socket))
        .and_then(|()| own_subfolder(&bin));
    if let Err(e) = made {
        crate::note!(
            "no bin folder at {}: {e}; sessions get no WORKROOM_BIN_DIR, and the folder of this \
             program's `workroom` after their PATH instead (`terminal::bin_path`)",
            bin.display()
        );
        return;
    }
    sweep_staged(&bin);
    let own = own_file();
    if let Some(own) = &own {
        let _ = SOURCE.set(own.clone());
    }
    *lock_or_recover(&SEEN) = source_now().and_then(|source| identity(&source));
    match own {
        Some(own) => {
            if let Err(e) = relink(&bin, &own) {
                crate::note!(
                    "could not point {}/{LINK} at {}: {e}",
                    bin.display(),
                    own.display()
                );
            }
        }
        None => crate::note!(
            "this program's own file is gone; {}/{LINK} stays",
            bin.display()
        ),
    }
    let hooks = hooks_beside(socket);
    let hooks = match write_hooks(&hooks) {
        Ok(()) => Some(hooks),
        Err(e) => {
            crate::note!("no shell hooks in {}: {e}", hooks.display());
            None
        }
    };
    let _ = FOLDERS.set(Folders { bin, hooks });
}

/// This daemon's folders, for a session's environment. None for a daemon on stdio, or one whose
/// folder could not be made.
pub fn folders() -> Option<&'static Folders> {
    FOLDERS.get()
}

/// Points the link at `target`, this daemon's copy once it has one.
pub fn point(target: &Path) {
    let Some(folders) = FOLDERS.get() else {
        return;
    };
    match relink(&folders.bin, target) {
        Ok(()) => crate::note!("{}/{LINK} runs {}", folders.bin.display(), target.display()),
        Err(e) => crate::note!(
            "could not point {}/{LINK} at {}: {e}",
            folders.bin.display(),
            target.display()
        ),
    }
}

/// As a new session starts: makes the folders, hooks and link again when something took them (a
/// cleaner takes a `/tmp` fallback's files, #528, and a copy can go from under the daemon), and
/// makes the copy again from the file this daemon started from once an update whose CLI commands
/// alone changed replaced it (`own_copy::refresh`), so every pane's `workroom`, open ones too,
/// runs the new commands. That last is judged by the file's identity, size and time, one `stat`
/// per session, and done on a thread of its own: a copy is tens of MB.
pub fn ensure() {
    let Some(folders) = FOLDERS.get() else {
        return;
    };
    if let Some(parent) = folders.bin.parent()
        && fs::symlink_metadata(parent).is_err()
        && let Err(e) = crate::daemon::own_copy::own_folder(parent)
    {
        crate::note!("could not make {} again: {e}", parent.display());
        return;
    }
    if let Err(e) = own_subfolder(&folders.bin) {
        crate::note!("could not make {} again: {e}", folders.bin.display());
        return;
    }
    // A shell is pointed at a hook only while it is there (`terminal::bin_path`), so one that
    // cannot be written again costs the shell its PATH fix, never its startup files.
    if let Some(hooks) = &folders.hooks
        && let Err(e) = write_hooks(hooks)
    {
        crate::note!(
            "could not write the shell hooks in {} again: {e}",
            hooks.display()
        );
    }
    refresh_when_replaced();
    if fs::metadata(folders.bin.join(LINK)).is_ok() {
        return;
    }
    if let Some(target) = crate::daemon::own_copy::kept().or_else(own_file) {
        point(&target);
    }
}

/// What a file is, to tell when an install replaced it: device, inode, size, modification time.
type Identity = (u64, u64, u64, i64, i64);

fn identity(path: &Path) -> Option<Identity> {
    use std::os::unix::fs::MetadataExt;
    let meta = fs::metadata(path).ok()?;
    Some((
        meta.dev(),
        meta.ino(),
        meta.size(),
        meta.mtime(),
        meta.mtime_nsec(),
    ))
}

/// The path this daemon's program was started from, as it is now. On Linux the kernel's: the file
/// wherever an install renamed it, or, once an install replaced it, the path it had (the
/// replacement's). Elsewhere, its path at start.
fn source_now() -> Option<PathBuf> {
    if cfg!(target_os = "linux") {
        let path = fs::read_link("/proc/self/exe").ok()?;
        let text = path.to_string_lossy();
        Some(match text.strip_suffix(" (deleted)") {
            Some(gone) => PathBuf::from(gone),
            None => path,
        })
    } else {
        SOURCE.get().cloned()
    }
}

/// The file this program was started from, resolved, at start (not on Linux: `source_now`).
static SOURCE: OnceLock<PathBuf> = OnceLock::new();
/// The identity of that file when it was last looked at.
static SEEN: Mutex<Option<Identity>> = Mutex::new(None);
/// Whether a refresh is under way, so a burst of sessions starts one.
static REFRESHING: AtomicBool = AtomicBool::new(false);

fn refresh_when_replaced() {
    let Some(source) = source_now() else {
        return;
    };
    let now = identity(&source);
    {
        let mut seen = lock_or_recover(&SEEN);
        if now.is_none() || *seen == now {
            return;
        }
        *seen = now;
    }
    if REFRESHING.swap(true, Ordering::AcqRel) {
        // The one under way may have read the file before this change: the next session looks
        // again.
        *lock_or_recover(&SEEN) = None;
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("own-copy-refresh".into())
        .spawn(move || {
            if let Some(copy) = crate::daemon::own_copy::refresh(&source) {
                point(&copy);
            }
            REFRESHING.store(false, Ordering::Release);
        });
    if spawned.is_err() {
        REFRESHING.store(false, Ordering::Release);
    }
}

/// The real path of the file this program runs. On Linux through `/proc/self/exe`, whose target
/// is the file wherever an install renamed it to, and None once it is gone; elsewhere its path as
/// started, resolved, which at start is still there. Never `/proc/self/exe` itself: a link to it
/// would run whatever process followed it.
fn own_file() -> Option<PathBuf> {
    let path = if cfg!(target_os = "linux") {
        fs::read_link("/proc/self/exe").ok()?
    } else {
        fs::canonicalize(std::env::current_exe().ok()?).ok()?
    };
    fs::metadata(&path)
        .is_ok_and(|meta| meta.is_file())
        .then_some(path)
}

/// Makes `dir`, inside a folder of `own_copy`'s, or checks that it is a real folder there.
fn own_subfolder(dir: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
            if fs::symlink_metadata(dir).is_ok_and(|meta| meta.is_dir()) {
                Ok(())
            } else {
                Err(io::Error::other(format!(
                    "{} is not a folder",
                    dir.display()
                )))
            }
        }
        Err(e) => Err(e),
    }
}

/// Points `folder/workroom` at `target` through a link of this process's own renamed over it.
/// Refuses a `workroom` that is anything but a symlink: only this code makes one there.
fn relink(folder: &Path, target: &Path) -> io::Result<()> {
    let link = folder.join(LINK);
    match fs::symlink_metadata(&link) {
        Ok(meta) if !meta.file_type().is_symlink() => {
            return Err(io::Error::other(format!(
                "{} is not a link this daemon made",
                link.display()
            )));
        }
        Ok(_) if fs::read_link(&link).is_ok_and(|now| now == target) => return Ok(()),
        _ => {}
    }
    let staged = folder.join(crate::daemon::own_copy::staged_name(LINK));
    // One there under this name is this process's own, left by a hand-off's exec (the pid outlives
    // it, and the count starts again), or a dead process's whose pid this one reuses.
    if fs::symlink_metadata(&staged).is_ok_and(|meta| meta.file_type().is_symlink()) {
        let _ = fs::remove_file(&staged);
    }
    std::os::unix::fs::symlink(target, &staged)?;
    fs::rename(&staged, &link).inspect_err(|_| {
        // This process made it, a moment ago.
        let _ = fs::remove_file(&staged);
    })
}

/// Removes every staged link (`.workroom.<pid>-<n>`, a symlink) whose process is gone, or is this
/// one's from the program before a hand-off: called once, at start, before this program stages
/// any.
fn sweep_staged(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name
            .to_str()
            .and_then(|name| name.strip_prefix(&format!(".{LINK}.")))
            .and_then(crate::daemon::own_copy::staged_pid)
        else {
            continue;
        };
        let path = entry.path();
        if (pid == std::process::id() as i32 || crate::daemon::own_copy::gone(pid))
            && fs::symlink_metadata(&path).is_ok_and(|meta| meta.file_type().is_symlink())
        {
            let _ = fs::remove_file(&path);
        }
    }
}

/// Writes the hooks under `dir`, each through a file of this process's own renamed into place, so
/// a shell starting meanwhile reads the last start's or this one's, never half of one.
fn write_hooks(dir: &Path) -> io::Result<()> {
    own_subfolder(dir)?;
    for (file, text) in [
        (format!("{ZSH_DIR}/.zshenv"), ZSH_HOOK),
        (BASH_FILE.to_string(), BASH_HOOK),
        (FISH_FILE.to_string(), FISH_HOOK),
    ] {
        let path = dir.join(&file);
        let mut at = dir.to_path_buf();
        for part in Path::new(&file)
            .parent()
            .into_iter()
            .flat_map(Path::components)
        {
            at.push(part);
            own_subfolder(&at)?;
        }
        if fs::read(&path).is_ok_and(|now| now == text.as_bytes()) {
            continue;
        }
        if fs::symlink_metadata(&path).is_ok_and(|meta| !meta.is_file()) {
            return Err(io::Error::other(format!(
                "{} is not a file this daemon wrote",
                path.display()
            )));
        }
        let staged = path.with_file_name(crate::daemon::own_copy::staged_name(
            &path.file_name().unwrap_or_default().to_string_lossy(),
        ));
        let _ = fs::remove_file(&staged);
        let written = fs::write(&staged, text).and_then(|()| fs::rename(&staged, &path));
        if written.is_err() {
            let _ = fs::remove_file(&staged);
        }
        written?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
