use super::*;

/// A new private folder for one test, removed with everything in it when dropped.
struct Dir(PathBuf);

impl Dir {
    fn new(name: &str) -> Dir {
        let dir = std::env::temp_dir().join(format!(
            "wr-resume-launch-{name}-{}-{}",
            std::process::id(),
            launch_name(SESSION, "x").unwrap()
        ));
        private_dir(&dir).unwrap();
        Dir(dir)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const SESSION: SessionId = SessionId([0x5a; 16]);

fn launch() -> Launch {
    Launch {
        argv: vec!["claude".into(), "--resume".into(), "a b".into()],
        cwd: "/".into(),
        reported_at_ms: 1_795_543_200_000,
    }
}

/// Value: protects=a launch file being run once at most, by the session it names, and then gone;
/// fails_when=a second claim reads it, a claim leaves it behind, or another session's id passes;
/// why_new=new; seam=none
#[test]
fn a_launch_file_is_claimed_once_by_its_own_session_and_then_gone() {
    let dir = Dir::new("once");
    let path = write_launch(&dir.0, SESSION, &launch()).unwrap();
    let mode = std::fs::metadata(&path).unwrap().mode() & 0o777;
    assert_eq!(mode, 0o600);
    assert!(
        claim_launch(&path, Some(SessionId([1; 16]))).is_err(),
        "another session's"
    );
    assert_eq!(claim_launch(&path, Some(SESSION)).unwrap(), launch());
    assert!(claim_launch(&path, Some(SESSION)).is_err(), "claimed twice");
    assert_eq!(
        std::fs::read_dir(&dir.0).unwrap().count(),
        0,
        "nothing left"
    );
}

/// Value: protects=the helper reading only a file this code wrote for this user; fails_when=a
/// readable-by-others file, a second link, a symlink, a stray name or a shared folder is read;
/// why_new=new; seam=none
#[test]
fn a_claim_refuses_a_file_it_cannot_prove_is_its_own() {
    let dir = Dir::new("refuse");
    let open = write_launch(&dir.0, SESSION, &launch()).unwrap();
    std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(claim_launch(&open, None).is_err(), "readable by others");

    let linked = write_launch(&dir.0, SESSION, &launch()).unwrap();
    std::fs::hard_link(&linked, dir.0.join("elsewhere")).unwrap();
    assert!(claim_launch(&linked, None).is_err(), "another link");

    let target = write_launch(&dir.0, SESSION, &launch()).unwrap();
    let link = dir.0.join(launch_name(SESSION, "json").unwrap());
    std::os::unix::fs::symlink(&target, &link).unwrap();
    assert!(claim_launch(&link, None).is_err(), "a symlink");
    assert!(target.exists(), "a symlink's target is never touched");

    let stray = dir.0.join("resume-notes.json");
    std::fs::write(&stray, serde_json::to_vec(&launch()).unwrap()).unwrap();
    assert!(
        claim_launch(&stray, None).is_err(),
        "not a launch file's name"
    );
    assert!(stray.exists());

    std::fs::set_permissions(&dir.0, std::fs::Permissions::from_mode(0o755)).unwrap();
    let shared = write_new(&dir.0, SESSION, "json", b"{}").unwrap();
    assert!(claim(&shared, None).is_err(), "a folder others can enter");
    assert!(shared.exists());
}

/// Value: protects=the clean-up removing only launch files, and never one a helper may still
/// claim: a new one, or any of a session that still runs, whose shell file waits for its program
/// to end; fails_when=it removes another name, a link, a new file when told an age, or a running
/// session's file however old; why_new=new; seam=the `live` callback
#[test]
fn a_sweep_removes_only_launch_files_and_never_a_running_sessions() {
    let dir = Dir::new("sweep-live");
    let shell = write_new(&dir.0, SESSION, "shell", b"{}").unwrap();
    sweep(&dir.0, Some(Duration::ZERO), |session| session == SESSION);
    assert!(shell.exists(), "its session still runs its program");
    sweep(&dir.0, Some(Duration::ZERO), |_| false);
    assert!(!shell.exists(), "its session is gone");
}

#[test]
fn a_sweep_removes_only_launch_files_and_not_new_ones_when_told_an_age() {
    let dir = Dir::new("sweep");
    let fresh = write_launch(&dir.0, SESSION, &launch()).unwrap();
    let claimed = dir
        .0
        .join(format!("{}.claim", launch_name(SESSION, "shell").unwrap()));
    std::fs::write(&claimed, b"").unwrap();
    let other = dir.0.join("notes.txt");
    std::fs::write(&other, b"").unwrap();
    let link = dir.0.join(launch_name(SESSION, "json").unwrap());
    std::os::unix::fs::symlink(&other, &link).unwrap();

    sweep(&dir.0, Some(ABANDONED), |_| false);
    assert!(
        fresh.exists() && claimed.exists(),
        "too new to be abandoned"
    );
    sweep(&dir.0, None, |_| false);
    assert!(!fresh.exists() && !claimed.exists());
    assert!(other.exists(), "not a launch file");
    assert!(std::fs::symlink_metadata(&link).is_ok(), "a link is left");
}

#[test]
fn a_launch_files_name_is_its_session_and_32_hex() {
    let name = launch_name(SESSION, "json").unwrap();
    assert!(is_launch_name(&name, Some(SESSION)));
    assert!(is_launch_name(&name, None));
    assert!(!is_launch_name(&name, Some(SessionId([1; 16]))));
    assert!(is_launch_name(
        &launch_name(SESSION, "shell").unwrap(),
        None
    ));
    assert!(!is_launch_name(&launch_name(SESSION, "txt").unwrap(), None));
    let upper = name.replace(
        &SESSION.to_hyphenated(),
        &SESSION.to_hyphenated().to_uppercase(),
    );
    assert!(!is_launch_name(&upper, None), "one written form of the id");
    assert!(!is_launch_name(&format!("{name}.claim"), None));
    assert!(!is_launch_name("resume-x-y.json", None));
}

/// Value: protects=only a record a report could have made being run; fails_when=an option, a
/// relative path or a control character as the command, or a relative folder, passes;
/// why_new=new; seam=none
#[test]
fn only_a_record_a_report_could_make_is_run() {
    let with = |argv: &[&str], cwd: &str| Launch {
        argv: argv.iter().map(|word| word.to_string()).collect(),
        cwd: cwd.into(),
        reported_at_ms: 0,
    };
    assert!(with(&["claude", "--resume", "x"], "/w").is_well_formed());
    assert!(with(&["/usr/bin/env", "A=1", "claude"], "/w").is_well_formed());
    assert!(!with(&[], "/w").is_well_formed());
    assert!(!with(&["-c"], "/w").is_well_formed());
    assert!(!with(&["./a"], "/w").is_well_formed());
    assert!(!with(&["vim", "a\u{1b}b"], "/w").is_well_formed());
    assert!(!with(&["vim"], "w").is_well_formed());
    assert!(!with(&["vim"; 65], "/w").is_well_formed());
}

fn invocation(program: &str, arguments: &[&str]) -> Invocation {
    Invocation {
        program: program.into(),
        arguments: arguments.iter().map(OsString::from).collect(),
        environment: vec![("ZDOTDIR".into(), "/ghostty/zsh".into())],
        interactive: true,
    }
}

fn words(invocation: &Invocation) -> Vec<String> {
    invocation
        .arguments
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

/// Value: protects=the wrapper being the session's own login shell (argv0 and flags kept, so its
/// startup files give the program its PATH) with every path a positional parameter, never script;
/// fails_when=the login argv0 or bash's `--posix` goes, a path is put in the script, or a shell
/// that can't run it is given it; why_new=new; seam=none
#[test]
fn the_wrapper_is_the_sessions_own_login_shell_with_paths_as_parameters() {
    let (helper, launch, shell) = (
        Path::new("/bin dir/workroom"),
        Path::new("/r/l.json"),
        Path::new("/r/s.shell"),
    );
    let zsh = wrapper(&invocation("/bin/zsh", &["-zsh"]), helper, launch, shell);
    assert_eq!(zsh.program, "/bin/zsh");
    assert_eq!(
        words(&zsh),
        [
            "-zsh",
            "-ic",
            SH_SCRIPT,
            "/bin/zsh",
            "/bin dir/workroom",
            "/r/l.json",
            "/r/s.shell"
        ]
    );
    assert_eq!(zsh.environment, invocation("", &[]).environment);
    let bash = wrapper(
        &invocation("/opt/bash", &["-bash", "--posix"]),
        helper,
        launch,
        shell,
    );
    assert_eq!(words(&bash)[..3], ["-bash", "--posix", "-ic"]);
    let fish = wrapper(&invocation("/opt/fish", &["-fish"]), helper, launch, shell);
    assert_eq!(
        words(&fish),
        [
            "-fish",
            "-i",
            "-c",
            FISH_SCRIPT,
            "/bin dir/workroom",
            "/r/l.json",
            "/r/s.shell",
            "/opt/fish"
        ]
    );
    let nu = wrapper(&invocation("/opt/nu", &["-nu"]), helper, launch, shell);
    assert_eq!(nu.program, "/bin/sh");
    assert_eq!(words(&nu)[..4], ["-sh", "-ic", SH_SCRIPT, "/opt/nu"]);
    for script in [SH_SCRIPT, FISH_SCRIPT] {
        assert!(!script.contains('/'), "no path in the script: {script}");
    }
}

/// Value: protects=a missing reported folder meaning no resume, and nothing left behind;
/// fails_when=a launch is prepared for a folder that is gone; why_new=new; seam=none
#[test]
fn a_record_whose_folder_is_gone_is_not_prepared() {
    let dir = Dir::new("gone");
    let gone = Launch {
        cwd: "/definitely/not/a/folder".into(),
        ..launch()
    };
    let shell = invocation("/bin/zsh", &["-zsh"]);
    let error = prepare(&shell, &gone, &dir.0, SESSION, Path::new("/w"), |_| false).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::NotFound);
    assert_eq!(std::fs::read_dir(&dir.0).unwrap().count(), 0);
    let prepared = prepare(&shell, &launch(), &dir.0, SESSION, Path::new("/w"), |_| {
        false
    })
    .unwrap();
    assert_eq!(prepared.program, "/bin/zsh");
    assert_eq!(
        std::fs::read_dir(&dir.0).unwrap().count(),
        2,
        "a launch and a shell file"
    );
}

#[test]
fn ctrl_c_and_success_are_no_failure_to_resume() {
    assert!(!failed(0));
    assert!(!failed(130));
    assert!(failed(1));
    assert!(failed(127));
}
