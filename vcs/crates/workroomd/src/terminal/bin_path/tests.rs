use super::*;
use std::path::PathBuf;

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
    for program in ["/bin/sh", "/bin/dash", "/bin/ksh", "/usr/bin/elvish"] {
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
