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
    assert!(result.interactive);
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
    let result = invocation(
        "",
        "/opt/homebrew/bin/bash",
        "/res",
        &env(&[("HOME", "/home/u")]),
    );
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
    let result = invocation(
        "",
        "/opt/homebrew/bin/bash",
        "/res",
        &env(&[("ENV", "/home/u/.env")]),
    );
    assert_eq!(
        lookup(&result, "GHOSTTY_BASH_ENV").as_deref(),
        Some("/home/u/.env")
    );
}

/// Apple's bash never reads `ENV`, so the integration that would undo `--posix` never runs:
/// the shell stayed in POSIX mode (no `<(…)`, no dashed function names). It gets a plain login
/// shell instead, as Ghostty gives it.
#[cfg(target_os = "macos")]
#[test]
fn apple_bash_gets_a_plain_login_shell() {
    let result = invocation("", "/bin/bash", "/res", &env(&[("HOME", "/home/u")]));
    assert_eq!(result.program, OsString::from("/bin/bash"));
    assert_eq!(result.arguments, vec![OsString::from("-bash")]);
    assert_eq!(
        lookup(&result, "GHOSTTY_RESOURCES_DIR").as_deref(),
        Some("/res")
    );
    for key in [
        "ENV",
        "GHOSTTY_BASH_INJECT",
        "GHOSTTY_BASH_ENV",
        "HISTFILE",
        "GHOSTTY_BASH_UNEXPORT_HISTFILE",
    ] {
        assert!(lookup(&result, key).is_none(), "{key} was injected");
    }
}

/// Runs only off macOS: a remote host's `/bin/bash` is a modern bash that loads the
/// integration, so the Apple-bash skip must not reach it.
#[cfg(not(target_os = "macos"))]
#[test]
fn linux_bin_bash_keeps_the_integration() {
    let result = invocation("", "/bin/bash", "/res", &env(&[("HOME", "/home/u")]));
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
    assert!(
        !result.interactive,
        "its own reports are a program's (#481)"
    );
}

/// A run command is not an interactive shell, so bash's interactive-only flag must not appear.
#[test]
fn a_run_command_does_not_get_posix_mode() {
    let result = invocation("make test", "/bin/bash", "/res", &[]);
    assert!(!result.arguments.contains(&OsString::from("--posix")));
}

/// A container's processes start from `docker exec`, which sets no `SHELL` (#308), so the
/// passwd database is where the user's shell is found; a numeric `USER` with no entry gets the
/// fallback.
#[test]
fn the_user_shell_is_shell_else_the_passwd_entry_else_the_fallback() {
    let passwd = || Some("/bin/bash".to_string());
    assert_eq!(
        user_shell_with(Some(OsString::from("/usr/bin/fish")), passwd, ""),
        "/usr/bin/fish"
    );
    assert_eq!(user_shell_with(None, passwd, ""), "/bin/bash");
    assert_eq!(
        user_shell_with(Some(OsString::new()), passwd, ""),
        "/bin/bash"
    );
    assert_eq!(user_shell_with(None, || None, ""), "");
    assert_eq!(user_shell_with(None, || None, POSIX_SHELL), POSIX_SHELL);
    assert_eq!(
        user_shell_with(None, || Some(String::new()), POSIX_SHELL),
        POSIX_SHELL
    );
}

/// The real lookup, against the account running the tests: whatever it names is a file.
#[test]
fn the_passwd_lookup_names_this_users_shell() {
    let shell = passwd_shell().expect("the test runner's account has a login shell");
    assert!(
        std::path::Path::new(&shell).exists(),
        "{shell} is not a file"
    );
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
