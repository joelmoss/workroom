//! How a session's shell is actually invoked.
//!
//! Ported from `macapp/WorkroomSessionProtocol/SessionShellIntegration.swift`, because the agent
//! has to do this on the far side too, where there is no Swift to ask.
//!
//! Two things here are not optional, and skipping them produced two visible bugs the first time
//! this ran in the app:
//!
//! 1. **`argv[0]` is the shell's name prefixed with `-`.** That is the only thing that makes it a
//!    LOGIN shell — there is no flag for it — so without it the login profile never runs.
//! 2. **Ghostty's shell integration is wired in through the environment.** For zsh that means
//!    pointing `ZDOTDIR` at the bundled integration directory, whose config then sources the
//!    user's own. What it adds is the OSC 133 prompt marks: `TerminalSessions` clears a pane's
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
}

/// The basename of a shell path.
pub fn shell_name(shell: &str) -> &str {
    match shell.rfind('/') {
        Some(index) => &shell[index + 1..],
        None => shell,
    }
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

    if !resources_directory.is_empty() {
        env.set("GHOSTTY_RESOURCES_DIR", resources_directory);
        let root = format!("{resources_directory}/shell-integration");
        match name {
            "zsh" => apply_zsh(&root, &mut env),
            "bash" => apply_bash(&root, &mut env),
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
        };
    }

    // The leading dash is what makes this a login shell.
    let mut arguments = vec![OsString::from(format!("-{name}"))];
    // bash needs --posix alongside the ENV-based integration, but only for an interactive shell;
    // a run command took the branch above.
    if name == "bash" && !resources_directory.is_empty() {
        arguments.push(OsString::from("--posix"));
    }

    Invocation {
        program: OsString::from(resolved_shell),
        arguments,
        environment: env.entries(),
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
    if env.get("HISTFILE").is_none() {
        if let Some(home) = env.get("HOME").filter(|home| !home.is_empty()) {
            env.set("HISTFILE", &format!("{home}/.bash_history"));
            env.set("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
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
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
        pairs
            .iter()
            .map(|(k, v)| (OsString::from(*k), OsString::from(*v)))
            .collect()
    }

    fn lookup(invocation: &Invocation, key: &str) -> Option<String> {
        invocation
            .environment
            .iter()
            .find(|(k, _)| k == OsStr::new(key))
            .map(|(_, v)| v.to_string_lossy().into_owned())
    }

    /// The bug this file exists for: without the leading dash the shell is not a login shell, so
    /// the login profile never runs.
    #[test]
    fn the_shell_is_invoked_as_a_login_shell() {
        let result = invocation("", "/bin/zsh", "", &[]);
        assert_eq!(result.program, OsString::from("/bin/zsh"));
        assert_eq!(result.arguments[0], OsString::from("-zsh"));
    }

    /// The other one: without ghostty's ZDOTDIR there are no OSC 133 prompt marks, so the app
    /// never learns a command finished and the shell's own title latches as the pane's forever.
    #[test]
    fn zsh_gets_ghosttys_integration_directory() {
        let result = invocation("", "/bin/zsh", "/res", &[]);
        assert_eq!(
            lookup(&result, "ZDOTDIR").as_deref(),
            Some("/res/shell-integration/zsh")
        );
        assert_eq!(
            lookup(&result, "GHOSTTY_RESOURCES_DIR").as_deref(),
            Some("/res")
        );
    }

    /// The user's own ZDOTDIR is handed to ghostty's config rather than discarded — that is how
    /// their shell configuration still loads.
    #[test]
    fn an_existing_zdotdir_is_preserved_for_ghostty_to_source() {
        let result = invocation(
            "",
            "/bin/zsh",
            "/res",
            &env(&[("ZDOTDIR", "/home/u/.config/zsh")]),
        );
        assert_eq!(
            lookup(&result, "GHOSTTY_ZSH_ZDOTDIR").as_deref(),
            Some("/home/u/.config/zsh")
        );
        assert_eq!(
            lookup(&result, "ZDOTDIR").as_deref(),
            Some("/res/shell-integration/zsh")
        );
    }

    #[test]
    fn bash_gets_env_injection_and_posix_mode() {
        let result = invocation("", "/bin/bash", "/res", &env(&[("HOME", "/home/u")]));
        assert_eq!(result.arguments[0], OsString::from("-bash"));
        assert!(result.arguments.contains(&OsString::from("--posix")));
        assert_eq!(
            lookup(&result, "ENV").as_deref(),
            Some("/res/shell-integration/bash/ghostty.bash")
        );
        assert_eq!(lookup(&result, "GHOSTTY_BASH_INJECT").as_deref(), Some("1"));
        assert_eq!(
            lookup(&result, "HISTFILE").as_deref(),
            Some("/home/u/.bash_history")
        );
    }

    #[test]
    fn an_existing_bash_env_is_preserved() {
        let result = invocation("", "/bin/bash", "/res", &env(&[("ENV", "/home/u/.env")]));
        assert_eq!(
            lookup(&result, "GHOSTTY_BASH_ENV").as_deref(),
            Some("/home/u/.env")
        );
    }

    #[test]
    fn fish_gets_the_xdg_integration() {
        let result = invocation("", "/opt/homebrew/bin/fish", "/res", &[]);
        assert_eq!(result.arguments[0], OsString::from("-fish"));
        assert_eq!(
            lookup(&result, "XDG_DATA_DIRS").as_deref(),
            Some("/res/shell-integration:/usr/local/share:/usr/share")
        );
    }

    #[test]
    fn an_existing_xdg_data_dirs_is_prepended_not_replaced() {
        let result = invocation(
            "",
            "/bin/fish",
            "/res",
            &env(&[("XDG_DATA_DIRS", "/opt/share")]),
        );
        assert_eq!(
            lookup(&result, "XDG_DATA_DIRS").as_deref(),
            Some("/res/shell-integration:/opt/share")
        );
    }

    /// Idempotent: reattaching or re-invoking must not keep prepending the same directory.
    #[test]
    fn the_xdg_directory_is_not_added_twice() {
        let result = invocation(
            "",
            "/bin/fish",
            "/res",
            &env(&[("XDG_DATA_DIRS", "/res/shell-integration:/opt/share")]),
        );
        assert_eq!(
            lookup(&result, "XDG_DATA_DIRS").as_deref(),
            Some("/res/shell-integration:/opt/share")
        );
    }

    /// A run command replaces its shell rather than leaving one waiting around it, so closing the
    /// command closes the pane.
    #[test]
    fn a_run_command_execs_through_the_posix_shell() {
        let result = invocation("npm run dev", "/bin/zsh", "/res", &[]);
        assert_eq!(result.program, OsString::from("/bin/sh"));
        assert_eq!(
            result.arguments,
            vec![
                OsString::from("/bin/sh"),
                OsString::from("-c"),
                OsString::from("exec npm run dev"),
            ]
        );
    }

    /// A run command is not an interactive shell, so bash's interactive-only flag must not appear.
    #[test]
    fn a_run_command_does_not_get_posix_mode() {
        let result = invocation("make test", "/bin/bash", "/res", &[]);
        assert!(!result.arguments.contains(&OsString::from("--posix")));
    }

    #[test]
    fn an_empty_shell_falls_back_to_the_default() {
        let result = invocation("", "", "", &[]);
        assert_eq!(result.program, OsString::from(DEFAULT_SHELL));
        assert_eq!(result.arguments[0], OsString::from("-zsh"));
    }

    /// No resources directory means no integration — the shell still has to start.
    #[test]
    fn without_resources_the_shell_still_runs() {
        let result = invocation("", "/bin/zsh", "", &[]);
        assert!(lookup(&result, "ZDOTDIR").is_none());
        assert!(lookup(&result, "GHOSTTY_RESOURCES_DIR").is_none());
    }

    #[test]
    fn shell_names_come_from_the_basename() {
        assert_eq!(shell_name("/bin/zsh"), "zsh");
        assert_eq!(shell_name("/opt/homebrew/bin/fish"), "fish");
        assert_eq!(shell_name("zsh"), "zsh");
    }
}
