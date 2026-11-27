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
/// claim: a new one, or any of a session that still runs, whose shell may still be starting;
/// fails_when=it removes another name, a link, a new file when told an age, or a running
/// session's file however old; why_new=new; seam=the `live` callback
#[test]
fn a_sweep_removes_only_launch_files_and_never_a_running_sessions() {
    let dir = Dir::new("sweep-live");
    let file = write_launch(&dir.0, SESSION, &launch()).unwrap();
    sweep(&dir.0, Some(Duration::ZERO), |session| session == SESSION);
    assert!(file.exists(), "its session's shell may still be starting");
    sweep(&dir.0, Some(Duration::ZERO), |_| false);
    assert!(!file.exists(), "its session is gone");
}

#[test]
fn a_sweep_removes_only_launch_files_and_not_new_ones_when_told_an_age() {
    let dir = Dir::new("sweep");
    let fresh = write_launch(&dir.0, SESSION, &launch()).unwrap();
    let claimed = dir
        .0
        .join(format!("{}.claim", launch_name(SESSION, "json").unwrap()));
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
    assert!(!is_launch_name(
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
        environment: vec![
            ("ZDOTDIR".into(), "/hooks/zsh".into()),
            (FILE_VARIABLE.into(), "/another/pane's".into()),
        ],
        interactive: true,
    }
}

fn get<'a>(invocation: &'a Invocation, key: &str) -> Vec<&'a OsStr> {
    invocation
        .environment
        .iter()
        .filter(|(name, _)| name == key)
        .map(|(_, value)| value.as_os_str())
        .collect()
}

/// Value: protects=a resuming session being its own shell as it would have started, told of its
/// launch file and helper by path alone, and only a shell with Workroom's hook resuming;
/// fails_when=the shell's program, arguments or environment change, the command reaches the
/// environment, a variable is given twice, or a shell with no hook gets a file; why_new=the
/// wrapper script went (#825 review); seam=none
#[test]
fn a_resuming_session_is_its_own_shell_told_of_its_file_by_path() {
    let dir = Dir::new("prepare");
    let shell = invocation("/bin/zsh", &["-zsh"]);
    let helper = Path::new("/bin dir/workroom");
    let prepared = prepare(&shell, true, &launch(), &dir.0, SESSION, helper, |_| false).unwrap();
    assert_eq!(prepared.invocation.program, shell.program);
    assert_eq!(prepared.invocation.arguments, shell.arguments);
    assert!(prepared.invocation.interactive);
    assert_eq!(get(&prepared.invocation, "ZDOTDIR"), ["/hooks/zsh"]);
    assert_eq!(
        get(&prepared.invocation, FILE_VARIABLE),
        [prepared.file.as_os_str()]
    );
    assert_eq!(
        get(&prepared.invocation, HELPER_VARIABLE),
        [helper.as_os_str()]
    );
    assert!(
        prepared
            .invocation
            .environment
            .iter()
            .all(|(_, value)| !value.to_string_lossy().contains("--resume")),
        "the command is in the file alone"
    );
    assert_eq!(
        claim_launch(&prepared.file, Some(SESSION)).unwrap(),
        launch()
    );

    let sh = invocation("/bin/sh", &["-sh"]);
    let error = prepare(&sh, false, &launch(), &dir.0, SESSION, helper, |_| false)
        .err()
        .expect("no hook, no resume");
    assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    assert_eq!(std::fs::read_dir(&dir.0).unwrap().count(), 0);
}

/// Value: protects=a session that could not be made removing the launch file it wrote and no
/// other: not the file of the attach that made the same id first, nor a link, nor a stray name;
/// fails_when=its file is left, or another session's file, a link or another name is removed;
/// why_new=#825 review (files left when `create_then` failed); seam=none
#[test]
fn a_session_that_was_not_made_removes_its_own_launch_file_alone() {
    let dir = Dir::new("discard");
    let mine = write_launch(&dir.0, SESSION, &launch()).unwrap();
    let winners = write_launch(&dir.0, SESSION, &launch()).unwrap();
    discard(&mine, SessionId([1; 16]));
    assert!(mine.exists(), "not a launch file for that session");
    discard(&mine, SESSION);
    assert!(!mine.exists());
    assert!(winners.exists(), "the other attach's file, of the same id");

    let other = dir.0.join("notes.txt");
    std::fs::write(&other, b"").unwrap();
    let link = dir.0.join(launch_name(SESSION, "json").unwrap());
    std::os::unix::fs::symlink(&other, &link).unwrap();
    discard(&link, SESSION);
    assert!(std::fs::symlink_metadata(&link).is_ok(), "a link is left");
    discard(&other, SESSION);
    assert!(other.exists(), "not a launch file's name");
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
    let helper = Path::new("/w");
    let error = prepare(&shell, true, &gone, &dir.0, SESSION, helper, |_| false)
        .err()
        .expect("a gone folder, no resume");
    assert_eq!(error.kind(), io::ErrorKind::NotFound);
    assert_eq!(std::fs::read_dir(&dir.0).unwrap().count(), 0);
    prepare(&shell, true, &launch(), &dir.0, SESSION, helper, |_| false).unwrap();
    assert_eq!(
        std::fs::read_dir(&dir.0).unwrap().count(),
        1,
        "one launch file, and nothing else"
    );
}

#[test]
fn ctrl_c_and_success_are_no_failure_to_resume() {
    assert!(!failed(0));
    assert!(!failed(130));
    assert!(failed(1));
    assert!(failed(127));
}
