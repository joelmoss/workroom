use super::*;
use std::path::PathBuf;

/// `apply`, with every hook there.
fn apply(invocation: &mut Invocation, folders: Option<&Folders>) {
    apply_with(invocation, folders, None, |_| true);
}

/// A hook that is gone is never pointed at: the shell starts as it would without one, with the
/// folder still first on the PATH it starts with.
#[test]
fn a_shell_whose_hook_is_gone_starts_without_it() {
    for (program, env) in [
        ("/bin/zsh", vec![("ZDOTDIR", "/res/shell-integration/zsh")]),
        (
            "/usr/bin/bash",
            vec![
                ("ENV", "/res/shell-integration/bash/ghostty.bash"),
                ("GHOSTTY_BASH_INJECT", "1"),
            ],
        ),
        ("/usr/bin/fish", vec![("XDG_DATA_DIRS", "/usr/share")]),
    ] {
        let mut invocation = shell(program, &env);
        let before = invocation.environment.clone();
        apply_with(&mut invocation, Some(&folders()), None, |_| false);
        let mut changed: Vec<_> = invocation
            .environment
            .iter()
            .filter(|entry| !before.contains(entry))
            .map(|(key, _)| key.to_string_lossy().into_owned())
            .collect();
        changed.sort();
        assert_eq!(changed, ["PATH", "WORKROOM_BIN_DIR"], "{program}");
    }
}

fn folders() -> Folders {
    Folders {
        bin: PathBuf::from("/run/w.bin/path"),
        hooks: Some(PathBuf::from("/run/w.bin/shell")),
    }
}

fn shell(program: &str, environment: &[(&str, &str)]) -> Invocation {
    Invocation {
        program: OsString::from(program),
        arguments: vec![OsString::from(format!("-{}", shell_name(program)))],
        environment: environment
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect(),
        interactive: true,
    }
}

fn value(invocation: &Invocation, key: &str) -> Option<String> {
    get(&invocation.environment, key).map(|v| v.to_string_lossy().into_owned())
}

#[test]
fn the_folder_goes_first_and_only_once() {
    let folder = Path::new("/run/w.bin/path");
    for (path, want) in [
        ("/usr/bin:/bin", "/run/w.bin/path:/usr/bin:/bin"),
        (
            "/usr/bin:/run/w.bin/path:/bin:/run/w.bin/path",
            "/run/w.bin/path:/usr/bin:/bin",
        ),
        ("/run/w.bin/path:/usr/bin", "/run/w.bin/path:/usr/bin"),
    ] {
        assert_eq!(
            bin_first(Some(OsStr::new(path)), folder),
            OsString::from(want)
        );
    }
}

/// A PATH of nothing, or of the folder alone, would leave the shell no `ls`.
#[test]
fn a_missing_or_empty_path_gets_the_standard_directories_after_the_folder() {
    let folder = Path::new("/run/w.bin/path");
    let want = format!("/run/w.bin/path:{}", crate::host::environment::FLOOR_PATH);
    for path in [None, Some(""), Some("/run/w.bin/path")] {
        assert_eq!(
            bin_first(path.map(OsStr::new), folder),
            OsString::from(&want),
            "{path:?}"
        );
    }
}

/// Every session gets the folder, any shell or a run's command; what the client sent under the
/// names is dropped.
#[test]
fn every_session_gets_the_folder_and_its_variable() {
    for program in ["/bin/sh", "/bin/dash", "/bin/ksh"] {
        let mut invocation = shell(
            program,
            &[
                ("PATH", "/usr/bin:/bin"),
                ("WORKROOM_BIN_DIR", "/another/panes"),
                ("WORKROOM_ZSH_ZDOTDIR", "/another"),
            ],
        );
        apply(&mut invocation, Some(&folders()));
        assert_eq!(
            value(&invocation, "PATH").as_deref(),
            Some("/run/w.bin/path:/usr/bin:/bin")
        );
        assert_eq!(
            value(&invocation, "WORKROOM_BIN_DIR").as_deref(),
            Some("/run/w.bin/path")
        );
        assert_eq!(value(&invocation, "WORKROOM_ZSH_ZDOTDIR"), None);
        assert_eq!(value(&invocation, "ZDOTDIR"), None, "{program}");
    }
    let mut run = shell("/run/w.bin/workroom-aaaa", &[("PATH", "/usr/bin")]);
    run.interactive = false;
    apply(&mut run, Some(&folders()));
    assert_eq!(
        value(&run, "PATH").as_deref(),
        Some("/run/w.bin/path:/usr/bin")
    );
}

/// zsh is pointed at the hook, which restores the ZDOTDIR it replaced: Ghostty's, or none.
#[test]
fn zsh_starts_from_the_hook_which_knows_the_zdotdir_it_replaced() {
    let mut integrated = shell(
        "/bin/zsh",
        &[("ZDOTDIR", "/res/shell-integration/zsh"), ("PATH", "/bin")],
    );
    apply(&mut integrated, Some(&folders()));
    assert_eq!(
        value(&integrated, "ZDOTDIR").as_deref(),
        Some("/run/w.bin/shell/zsh")
    );
    assert_eq!(
        value(&integrated, "WORKROOM_ZSH_ZDOTDIR").as_deref(),
        Some("/res/shell-integration/zsh")
    );

    let mut plain = shell("/bin/zsh", &[("PATH", "/bin")]);
    apply(&mut plain, Some(&folders()));
    assert_eq!(
        value(&plain, "ZDOTDIR").as_deref(),
        Some("/run/w.bin/shell/zsh")
    );
    assert_eq!(value(&plain, "WORKROOM_ZSH_ZDOTDIR"), None);
}

/// bash is pointed at the hook only where Ghostty's integration starts it through `ENV`.
#[test]
fn bash_starts_from_the_hook_only_under_ghosttys_integration() {
    let mut integrated = shell(
        "/usr/bin/bash",
        &[
            ("ENV", "/res/shell-integration/bash/ghostty.bash"),
            ("GHOSTTY_BASH_INJECT", "1"),
        ],
    );
    apply(&mut integrated, Some(&folders()));
    assert_eq!(
        value(&integrated, "ENV").as_deref(),
        Some("/run/w.bin/shell/bash/workroom.bash")
    );
    assert_eq!(
        value(&integrated, "WORKROOM_BASH_ENV").as_deref(),
        Some("/res/shell-integration/bash/ghostty.bash")
    );

    let mut plain = shell("/bin/bash", &[("ENV", "/home/u/.shrc")]);
    apply(&mut plain, Some(&folders()));
    assert_eq!(value(&plain, "ENV").as_deref(), Some("/home/u/.shrc"));
    assert_eq!(value(&plain, "WORKROOM_BASH_ENV"), None);
}

/// fish finds the hook through `XDG_DATA_DIRS`, ahead of what was there or the defaults.
#[test]
fn fish_finds_the_hook_through_its_data_dirs() {
    let mut integrated = shell(
        "/usr/bin/fish",
        &[("XDG_DATA_DIRS", "/res/shell-integration:/usr/share")],
    );
    apply(&mut integrated, Some(&folders()));
    assert_eq!(
        value(&integrated, "XDG_DATA_DIRS").as_deref(),
        Some("/run/w.bin/shell:/res/shell-integration:/usr/share")
    );
    assert_eq!(
        value(&integrated, "WORKROOM_FISH_XDG_DIR").as_deref(),
        Some("/run/w.bin/shell")
    );
    let mut plain = shell("/usr/bin/fish", &[]);
    apply(&mut plain, Some(&folders()));
    assert_eq!(
        value(&plain, "XDG_DATA_DIRS").as_deref(),
        Some("/run/w.bin/shell:/usr/local/share:/usr/share")
    );
}

/// A daemon with no folder changes no PATH, and still drops another pane's variable.
#[test]
fn a_daemon_without_a_folder_changes_no_path() {
    let mut invocation = shell(
        "/bin/zsh",
        &[("PATH", "/usr/bin"), ("WORKROOM_BIN_DIR", "/another")],
    );
    apply(&mut invocation, None);
    assert_eq!(value(&invocation, "PATH").as_deref(), Some("/usr/bin"));
    assert_eq!(value(&invocation, "WORKROOM_BIN_DIR"), None);
    assert_eq!(value(&invocation, "ZDOTDIR"), None);
}

/// A daemon whose bin folder could not be made still gives a host pane `workroom`: the folder of
/// its own, the bootstrap's link beside `workroomd`, after the PATH, as #681 did.
#[test]
fn a_daemon_without_a_folder_appends_the_folder_of_its_own_workroom() {
    let mut invocation = shell("/bin/sh", &[("PATH", "/usr/bin:/bin")]);
    apply_with(
        &mut invocation,
        None,
        Some(Path::new("/run/workroom")),
        |_| true,
    );
    assert_eq!(
        value(&invocation, "PATH").as_deref(),
        Some("/usr/bin:/bin:/run/workroom")
    );
    assert_eq!(value(&invocation, "WORKROOM_BIN_DIR"), None);
}

/// elvish and nu have no hook: Ghostty's `path` feature appends the folder after their startup
/// files took it off, where Ghostty's integration starts them and no `ssh-*` feature needs
/// `GHOSTTY_BIN_DIR` for Ghostty's own program.
#[test]
fn elvish_and_nu_get_ghosttys_path_feature_for_the_folder() {
    for program in ["/usr/bin/elvish", "/usr/bin/nu"] {
        let mut integrated = shell(
            program,
            &[
                (
                    "GHOSTTY_SHELL_INTEGRATION_XDG_DIR",
                    "/res/shell-integration",
                ),
                ("GHOSTTY_SHELL_FEATURES", "cursor,sudo,title"),
            ],
        );
        apply(&mut integrated, Some(&folders()));
        assert_eq!(
            value(&integrated, "GHOSTTY_SHELL_FEATURES").as_deref(),
            Some("cursor,sudo,title,path"),
            "{program}"
        );
        assert_eq!(
            value(&integrated, "GHOSTTY_BIN_DIR").as_deref(),
            Some("/run/w.bin/path")
        );
    }
    let mut ssh = shell(
        "/usr/bin/elvish",
        &[
            (
                "GHOSTTY_SHELL_INTEGRATION_XDG_DIR",
                "/res/shell-integration",
            ),
            ("GHOSTTY_SHELL_FEATURES", "cursor,ssh-terminfo"),
            (
                "GHOSTTY_BIN_DIR",
                "/Applications/Workroom.app/Contents/MacOS",
            ),
        ],
    );
    apply(&mut ssh, Some(&folders()));
    assert_eq!(
        value(&ssh, "GHOSTTY_BIN_DIR").as_deref(),
        Some("/Applications/Workroom.app/Contents/MacOS")
    );
    let mut plain = shell("/usr/bin/elvish", &[]);
    apply(&mut plain, Some(&folders()));
    assert_eq!(value(&plain, "GHOSTTY_SHELL_FEATURES"), None);
    // zsh has its hook instead.
    let mut zsh = shell(
        "/bin/zsh",
        &[
            ("GHOSTTY_SHELL_FEATURES", "cursor"),
            ("ZDOTDIR", "/res/zsh"),
        ],
    );
    apply(&mut zsh, Some(&folders()));
    assert_eq!(
        value(&zsh, "GHOSTTY_SHELL_FEATURES").as_deref(),
        Some("cursor")
    );
}
