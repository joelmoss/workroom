//! How a session's shell is actually invoked.
//!
//! Ported from `macapp/WorkroomSessionProtocol/SessionShellIntegration.swift`, because the daemon
//! has to do this on the far side too, where there is no Swift to ask.
//!
//! Two things here are not optional, and skipping them produced two visible bugs the first time
//! this ran in the app:
//!
//! 1. **`argv[0]` is the shell's name prefixed with `-`.** That is the only thing that makes it a
//!    LOGIN shell — there is no flag for it — so without it the login profile never runs.
//! 2. **Ghostty's shell integration is wired in through the environment.** For zsh that means
//!    pointing `ZDOTDIR` at the bundled integration directory, whose config then sources the
//!    user's own. What it adds is the OSC 133 prompt marks: `TerminalPanes` clears a pane's
//!    live title back to `Terminal N` when it sees the command-finished mark, so without the
//!    integration a title the user's own prompt sets — `user@host:~/dir` on this machine — latches
//!    as the pane's title and never clears. The shell sets that title either way; the integration
//!    is what lets the app know the command ended.
//!
//! The integration also reports the working directory (OSC 7), which the pane footer reads and
//! which `isDirectoryTitle` needs in order to ignore a directory-shaped title.

use std::ffi::{OsStr, OsString};

pub const DEFAULT_SHELL: &str = "/bin/zsh";
const POSIX_SHELL: &str = "/bin/sh";
const XDG_FALLBACK_DATA_DIRECTORIES: &str = "/usr/local/share:/usr/share";

/// What to exec for a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    pub program: OsString,
    /// Including `argv[0]`, which is NOT the program path — see the module doc.
    pub arguments: Vec<OsString>,
    pub environment: Vec<(OsString, OsString)>,
    /// An interactive shell, not a run command: a report it sends itself is never a program
    /// waiting on the user (#481).
    pub interactive: bool,
}

/// The basename of a shell path.
pub fn shell_name(shell: &str) -> &str {
    match shell.rfind('/') {
        Some(index) => &shell[index + 1..],
        None => shell,
    }
}

/// The user's shell: `env_shell` (a `SHELL`) when it names one, else the login shell the passwd
/// database gives this process's effective user. A container's processes start from `docker exec`,
/// which sets no `SHELL` (#308), and an image's numeric `USER` may have no passwd entry at all:
/// there it is `/bin/sh`, which every image Workroom accepts has, not zsh, which few do. Elsewhere
/// it is empty, which each caller turns into its own fallback.
pub fn user_shell(env_shell: Option<OsString>) -> String {
    let fallback = if cfg!(target_os = "linux") {
        POSIX_SHELL
    } else {
        ""
    };
    user_shell_with(env_shell, passwd_shell, fallback)
}

fn user_shell_with(
    env_shell: Option<OsString>,
    passwd: impl FnOnce() -> Option<String>,
    fallback: &str,
) -> String {
    match env_shell.filter(|shell| !shell.is_empty()) {
        Some(shell) => shell.to_string_lossy().into_owned(),
        None => passwd()
            .filter(|shell| !shell.is_empty())
            .unwrap_or_else(|| fallback.to_string()),
    }
}

/// The login shell the passwd database names for this process's effective user. Static musl
/// reads /etc/passwd itself, with no NSS, which is what a container has.
fn passwd_shell() -> Option<String> {
    // SAFETY: `passwd` is plain C data (integers and pointers), for which all-zero is valid.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    // SAFETY: every pointer is to a live local sized as passed; the strings `entry` points at live
    // in `buffer`, which outlives their use below.
    let rc = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut entry,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut found,
        )
    };
    if rc != 0 || found.is_null() || entry.pw_shell.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r succeeded, so `pw_shell` is a NUL-terminated string inside `buffer`.
    let shell = unsafe { std::ffi::CStr::from_ptr(entry.pw_shell) };
    Some(shell.to_string_lossy().into_owned()).filter(|shell| !shell.is_empty())
}

/// Builds the invocation for a session.
///
/// `command` non-empty means a run command rather than an interactive shell: it goes through
/// `/bin/sh -c "exec …"` so it inherits a shell's environment handling and replaces that shell
/// rather than leaving one waiting around it.
pub fn invocation(
    command: &str,
    shell: &str,
    resources_directory: &str,
    environment: &[(OsString, OsString)],
) -> Invocation {
    let resolved_shell = if shell.is_empty() {
        DEFAULT_SHELL
    } else {
        shell
    };
    let name = shell_name(resolved_shell);
    let mut env = Environment::new(environment);
    // Apple's bash 3.2 ignores `ENV`, so ghostty.bash never runs to undo `--posix` and the shell
    // stays in POSIX mode. Ghostty skips `/bin/bash` on Darwin for the same reason
    // (`src/termio/shell_integration.zig`); match its exact path, so a symlink to it still misses.
    let bash_integration =
        name == "bash" && !(cfg!(target_os = "macos") && resolved_shell == "/bin/bash");

    if !resources_directory.is_empty() {
        env.set("GHOSTTY_RESOURCES_DIR", resources_directory);
        let root = format!("{resources_directory}/shell-integration");
        match name {
            "zsh" => apply_zsh(&root, &mut env),
            "bash" if bash_integration => apply_bash(&root, &mut env),
            "fish" | "elvish" | "nu" => apply_xdg(&root, &mut env),
            _ => {}
        }
    }

    if !command.is_empty() {
        return Invocation {
            program: OsString::from(POSIX_SHELL),
            arguments: vec![
                OsString::from(POSIX_SHELL),
                OsString::from("-c"),
                OsString::from(format!("exec {command}")),
            ],
            environment: env.entries(),
            interactive: false,
        };
    }

    // The leading dash is what makes this a login shell.
    let mut arguments = vec![OsString::from(format!("-{name}"))];
    // bash needs --posix alongside the ENV-based integration, but only for an interactive shell;
    // a run command took the branch above.
    if bash_integration && !resources_directory.is_empty() {
        arguments.push(OsString::from("--posix"));
    }

    Invocation {
        program: OsString::from(resolved_shell),
        arguments,
        environment: env.entries(),
        interactive: true,
    }
}

/// zsh has no per-shell integration hook, so ghostty substitutes its own `ZDOTDIR` and its config
/// sources the user's from `GHOSTTY_ZSH_ZDOTDIR`. Losing the original is what makes the user's
/// shell configuration silently vanish, so it is preserved before being replaced.
fn apply_zsh(root: &str, env: &mut Environment) {
    if let Some(existing) = env.get("ZDOTDIR") {
        env.set("GHOSTTY_ZSH_ZDOTDIR", &existing);
    }
    env.set("ZDOTDIR", &format!("{root}/zsh"));
}

fn apply_bash(root: &str, env: &mut Environment) {
    if let Some(existing) = env.get("ENV") {
        env.set("GHOSTTY_BASH_ENV", &existing);
    }
    env.set("ENV", &format!("{root}/bash/ghostty.bash"));
    env.set("GHOSTTY_BASH_INJECT", "1");
    if env.get("HISTFILE").is_none()
        && let Some(home) = env.get("HOME").filter(|home| !home.is_empty())
    {
        env.set("HISTFILE", &format!("{home}/.bash_history"));
        env.set("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
    }
}

fn apply_xdg(root: &str, env: &mut Environment) {
    env.set("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", root);
    match env.get("XDG_DATA_DIRS").filter(|dirs| !dirs.is_empty()) {
        None => env.set(
            "XDG_DATA_DIRS",
            &format!("{root}:{XDG_FALLBACK_DATA_DIRECTORIES}"),
        ),
        Some(existing) => {
            if !existing.split(':').any(|dir| dir == root) {
                env.set("XDG_DATA_DIRS", &format!("{root}:{existing}"));
            }
        }
    }
}

/// An environment that preserves insertion order and replaces in place.
///
/// Order matters only for reproducibility — a child cannot observe it — but a stable order makes a
/// diff of two invocations readable, which is what these tests compare.
struct Environment {
    keys: Vec<OsString>,
    values: std::collections::HashMap<OsString, OsString>,
}

impl Environment {
    fn new(entries: &[(OsString, OsString)]) -> Environment {
        let mut env = Environment {
            keys: Vec::new(),
            values: std::collections::HashMap::new(),
        };
        for (key, value) in entries {
            env.set_os(key.clone(), value.clone());
        }
        env
    }

    fn get(&self, key: &str) -> Option<String> {
        self.values
            .get(OsStr::new(key))
            .map(|value| value.to_string_lossy().into_owned())
    }

    fn set(&mut self, key: &str, value: &str) {
        self.set_os(OsString::from(key), OsString::from(value));
    }

    fn set_os(&mut self, key: OsString, value: OsString) {
        if !self.values.contains_key(&key) {
            self.keys.push(key.clone());
        }
        self.values.insert(key, value);
    }

    fn entries(&self) -> Vec<(OsString, OsString)> {
        self.keys
            .iter()
            .filter_map(|key| {
                self.values
                    .get(key)
                    .map(|value| (key.clone(), value.clone()))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests;
