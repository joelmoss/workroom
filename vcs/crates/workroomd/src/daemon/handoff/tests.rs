use super::*;

/// A program blocked on the user, as a hand-off finds it: probed, so its record may alert.
fn blocked_status() -> crate::terminal::program_status::Store {
    use crate::terminal::program_status::{Event, Kind, Report, State, Store};
    let mut status = Store::default();
    status.apply(Event::Probed, 4242);
    status.report(
        Report {
            id: String::new(),
            state: State::Blocked,
            kind: Kind::Permission,
            progress: -1,
            app: "claude-code".into(),
            title: String::new(),
            message: "Apply?".into(),
        },
        4242,
    );
    status.commit();
    status
}

#[test]
fn a_table_survives_encoding() {
    let table = Table {
        listener: 3,
        lock: 4,
        boot: Some(SessionId([9; 16])),
        sessions: vec![
            FrozenSession {
                id: SessionId([7; 16]),
                pid: 4242,
                master: 9,
                columns: 120,
                rows: 40,
                screen: b"\x1b[2Jhello".to_vec(),
                metadata: vec![
                    ("workroom".into(), "wr|/p|cyan".into()),
                    ("created".into(), "1791130740000".into()),
                ],
                program_status: blocked_status(),
                // What its shell was built from (#693), a text that is no UTF-8 among it.
                recipe: Some(crate::terminal::session::Recipe {
                    environment: vec![
                        ("PATH".into(), "/opt/bin:/usr/bin".into()),
                        (
                            "RAW".into(),
                            std::os::unix::ffi::OsStringExt::from_vec(vec![0xff, b'x']),
                        ),
                    ],
                    shell: "/bin/zsh".into(),
                    resources: "/Applications/W.app/Contents/Resources/ghostty".into(),
                    run_shell: Some("/bin/zsh".into()),
                    commands: None,
                    // Its app turned resume off (#827), so a `session.new` from it gets no token.
                    resume_off: true,
                }),
                // Its resume state (ADR 0082), token and stream offset included (version 6).
                resume: Some(crate::terminal::resume::Carried::for_test(
                    "token-of-7",
                    4096,
                )),
            },
            FrozenSession {
                id: SessionId([8; 16]),
                pid: 4343,
                master: 10,
                columns: 80,
                rows: 24,
                screen: Vec::new(),
                metadata: Vec::new(),
                program_status: Default::default(),
                recipe: None,
                resume: None,
            },
        ],
        events: Some(br#"{"boot":"x","revision":3}"#.to_vec()),
    };
    assert_eq!(
        Table::decode(&table.encode()).map_err(|e| e.to_string()),
        Ok(table)
    );
}

/// A recipe an older program wrote says nothing of resume (#827): it reads back as on, as that
/// session's resume was.
#[test]
fn an_older_recipe_reads_as_resume_on() {
    let recipe = crate::terminal::session::Recipe {
        shell: "/bin/zsh".into(),
        ..Default::default()
    };
    let mut json = recipe.to_json();
    json.as_object_mut().unwrap().remove("resume_off");
    let read = crate::terminal::session::Recipe::from_json(&json).expect("a recipe");
    assert!(!read.resume_off);
    assert_eq!(read, recipe);
}

/// The terminal API's events cross a version 4 table after the sessions (#687), and one that
/// carries none reads back as none.
#[test]
fn the_events_cross_the_table_after_the_sessions() {
    let table = Table {
        listener: 3,
        lock: 4,
        boot: Some(SessionId([9; 16])),
        sessions: Vec::new(),
        events: None,
    };
    let bytes = table.encode();
    assert_eq!(
        bytes[4..6],
        6u16.to_be_bytes(),
        "version 6, the resume states' (ADR 0082)"
    );
    assert_eq!(bytes[bytes.len() - 4..], [0, 0, 0, 0], "no events");
    assert_eq!(Table::decode(&bytes).map_err(|e| e.to_string()), Ok(table));
}

/// A shell's OSC 133 marks cross the table in its program status, so the next program takes a
/// `command_finished` wait (#690) before the shell's next prompt. A version 3 table has none,
/// and reads as no marks.
#[test]
fn a_shells_marks_cross_the_table() {
    let mut status = crate::terminal::program_status::Store::default();
    status.apply(crate::terminal::program_status::Event::Prompt, 4242);
    assert!(status.shell_marks(), "fixture: a prompt is a mark");
    let table = Table {
        listener: 3,
        lock: 4,
        boot: None,
        sessions: vec![FrozenSession {
            id: SessionId([7; 16]),
            pid: 4242,
            master: 9,
            columns: 80,
            rows: 24,
            screen: Vec::new(),
            metadata: Vec::new(),
            program_status: status,
            recipe: None,
            resume: None,
        }],
        events: None,
    };
    let back = Table::decode(&table.encode()).expect("the table reads back");
    assert!(back.sessions[0].program_status.shell_marks());
    assert!(!blocked_status().shell_marks());
}

/// A build without the shadow terminal refuses a table with screens, which it could only drop.
#[test]
fn screens_are_refused_by_a_build_that_cannot_paint_them() {
    let scratch = crate::commands::Scratch::in_temp("workroomd-table");
    let path = scratch.join("table");
    let table = Table {
        listener: 3,
        lock: 4,
        boot: None,
        sessions: vec![FrozenSession {
            id: SessionId([7; 16]),
            pid: 1,
            master: 5,
            columns: 80,
            rows: 24,
            screen: b"on screen".to_vec(),
            metadata: Vec::new(),
            program_status: Default::default(),
            recipe: None,
            resume: None,
        }],
        events: None,
    };
    std::fs::write(&path, table.encode()).expect("table");
    let checked = check_table(&path);
    assert_eq!(
        checked.is_ok(),
        cfg!(feature = "terminal-state"),
        "{checked:?}"
    );
}

/// A binary's daemon build is found wherever its marker falls, across the reads the scan makes in
/// particular; a near miss is not a marker, and a file with none has none.
#[test]
fn a_daemon_build_is_read_out_of_a_binarys_bytes() {
    let dir = crate::commands::Scratch::in_temp("workroomd-marker");
    let marker = |build: &str| format!("WORKROOMD-DAEMON-BUILD:{build};").into_bytes();
    let build = "0123456789abcdef".repeat(4);
    let file = |name: &str, bytes: &[u8]| {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        daemon_build_in(&path).unwrap()
    };
    // Straddling the first read's end at each offset, at the start, and at the very end.
    for offset in [1, 10, 23, 40, 80, 88] {
        let mut bytes = vec![b'x'; (1 << 16) - offset];
        bytes.extend(marker(&build));
        bytes.extend(vec![b'y'; 1000]);
        assert_eq!(file("straddling", &bytes), Some(build.clone()), "{offset}");
    }
    assert_eq!(file("first", &marker(&build)), Some(build.clone()));
    let mut late = vec![b'x'; 3 << 16];
    late.extend(marker(&build));
    assert_eq!(file("last", &late), Some(build.clone()));
    // An unterminated prefix, then a real one; a value that is no hash; none at all.
    let mut near = b"WORKROOMD-DAEMON-BUILD:abc WORKROOMD-DAEMON-BUILD:;".to_vec();
    near.extend(marker(&build));
    assert_eq!(file("near", &near), Some(build.clone()));
    assert_eq!(file("not-hex", &marker("not a hash")), None);
    assert_eq!(file("none", b"#!/bin/sh\nexit 0\n"), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_protocol_report_states_its_build_number() {
    assert_eq!(
        build_number_in("protocol 7\nbuild workroomd 0.1.0\nbuild-number 1791130740\n"),
        1791130740
    );
    // A daemon from before #255 states none, and orders below every build that does.
    assert_eq!(build_number_in("protocol 6\nbuild workroomd 0.1.0\n"), 0);
}

/// Starts `binary`'s build probe, retrying while Linux says the file is busy. A script this test
/// has just written can still be open for writing in a child that another test thread forked and
/// has not yet exec'd, and running it in that window fails with ETXTBSY (#601).
fn start_probe(binary: &Path) -> Result<BuildProbe, HandOffError> {
    for _ in 0..100 {
        match BuildProbe::start(binary) {
            Err(HandOffError::Start { ref source, .. })
                if source.kind() == std::io::ErrorKind::ExecutableFileBusy =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            other => return other,
        }
    }
    BuildProbe::start(binary)
}

/// The race `start_probe` waits out, made certain: Linux refuses to run a file that is open for
/// writing, and a probe started meanwhile succeeds once the writer lets go.
#[cfg(target_os = "linux")]
#[test]
fn a_script_still_open_for_writing_is_waited_for_not_refused() {
    use std::io::Write;
    let dir = crate::commands::Scratch::in_temp("workroomd-busy");
    let path = dir.join("busy");
    let mut writer = std::fs::File::create(&path).unwrap();
    writer
        .write_all(b"#!/bin/sh\necho protocol 7; echo build-number 300; exit 0\n")
        .unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    match BuildProbe::start(&path) {
        Err(HandOffError::Start { ref source, .. })
            if source.kind() == std::io::ErrorKind::ExecutableFileBusy => {}
        other => panic!(
            "expected ETXTBSY while the script is open for writing, got {:?}",
            other.map(|_| ())
        ),
    }
    let release = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        drop(writer);
    });
    let probe = start_probe(&path);
    release.join().unwrap();
    assert_eq!(
        probe
            .and_then(|p| p.no_downgrade(&path, 200, Instant::now() + CHECK_TIMEOUT))
            .map_err(|e| e.to_string()),
        Ok(())
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Fails unless `result` is a refusal whose message contains `wanted`, naming what came instead.
#[track_caller]
fn assert_refused(result: Result<(), HandOffError>, wanted: &str) {
    match result {
        Err(error) if error.to_string().contains(wanted) => {}
        other => panic!(
            "expected a refusal containing {wanted:?}, got {:?}",
            other.map_err(|e| e.to_string())
        ),
    }
}

/// A program with a lower build number is refused, after the table check and before the exec;
/// one at least as high, or any when this build has no number, is let through (D13). One that
/// does not say in time is refused too: every session's output is stopped meanwhile.
#[test]
fn a_hand_off_to_an_older_build_is_refused() {
    let dir = crate::commands::Scratch::in_temp("workroomd-downgrade");
    let program = |name: &str, number: Option<u64>| {
        let path = dir.join(name);
        let line = number.map_or(String::new(), |n| format!("echo build-number {n}; "));
        std::fs::write(&path, format!("#!/bin/sh\necho protocol 7; {line}exit 0\n")).unwrap();
        std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        path
    };
    let older = program("older", Some(100));
    let same = program("same", Some(200));
    let newer = program("newer", Some(300));
    let unnumbered = program("unnumbered", None);
    let soon = || Instant::now() + CHECK_TIMEOUT;
    let no_downgrade = |binary: &Path, ours: u64, deadline: Instant| {
        start_probe(binary)?.no_downgrade(binary, ours, deadline)
    };
    assert_refused(
        no_downgrade(&older, 200, soon()),
        "older than this daemon's build 200",
    );
    let unnumbered_result = no_downgrade(&unnumbered, 200, soon());
    assert!(
        unnumbered_result.is_err(),
        "an unnumbered program must be refused, got {unnumbered_result:?}"
    );
    assert_eq!(
        no_downgrade(&same, 200, soon()).map_err(|e| e.to_string()),
        Ok(())
    );
    assert_eq!(
        no_downgrade(&newer, 200, soon()).map_err(|e| e.to_string()),
        Ok(())
    );
    assert_eq!(
        no_downgrade(&older, 0, soon()).map_err(|e| e.to_string()),
        Ok(())
    );
    let slow = dir.join("slow");
    std::fs::write(&slow, "#!/bin/sh\nsleep 30\necho build-number 300\n").unwrap();
    std::fs::set_permissions(&slow, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let started = Instant::now();
    assert_refused(
        no_downgrade(&slow, 200, Instant::now() + Duration::from_millis(300)),
        "did not say its build",
    );
    assert!(started.elapsed() < Duration::from_secs(5));
    // One that exits but leaves a process holding its output open is refused at the deadline,
    // not waited on.
    let lingering = dir.join("lingering");
    std::fs::write(
        &lingering,
        "#!/bin/sh\n(sleep 30 &)\necho build-number 300\nexit 0\n",
    )
    .unwrap();
    std::fs::set_permissions(
        &lingering,
        std::os::unix::fs::PermissionsExt::from_mode(0o755),
    )
    .unwrap();
    let started = Instant::now();
    assert_refused(
        no_downgrade(&lingering, 200, Instant::now() + Duration::from_millis(300)),
        "did not say its build",
    );
    assert!(started.elapsed() < Duration::from_secs(5));
    // Asked for while the table is checked: a check that takes all the time leaves a report
    // already given to be read, not refused.
    let mut probe = start_probe(&newer).unwrap();
    while probe.child.try_wait().unwrap().is_none() {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        probe
            .no_downgrade(&newer, 200, Instant::now())
            .map_err(|e| e.to_string()),
        Ok(())
    );
    // One whose report comes through just after it exited, with the time already used, is
    // read within `REPORT_GRACE` rather than refused: here a short-lived process it started
    // holds the pipe for 100 ms.
    let late_report = dir.join("late-report");
    std::fs::write(
        &late_report,
        "#!/bin/sh\necho build-number 300\n(sleep 0.1 &)\nexit 0\n",
    )
    .unwrap();
    std::fs::set_permissions(
        &late_report,
        std::os::unix::fs::PermissionsExt::from_mode(0o755),
    )
    .unwrap();
    let mut probe = start_probe(&late_report).unwrap();
    while probe.child.try_wait().unwrap().is_none() {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        probe
            .no_downgrade(&late_report, 200, Instant::now())
            .map_err(|e| e.to_string()),
        Ok(())
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A table that is cut short or carries more than it declares is refused, not half-restored.
#[test]
fn a_damaged_table_is_refused() {
    let table = Table {
        listener: 3,
        lock: 4,
        boot: None,
        sessions: vec![FrozenSession {
            id: SessionId([7; 16]),
            pid: 1,
            master: 5,
            columns: 80,
            rows: 24,
            screen: b"screen".to_vec(),
            metadata: Vec::new(),
            program_status: Default::default(),
            recipe: None,
            resume: None,
        }],
        events: None,
    };
    let bytes = table.encode();
    assert!(Table::decode(&bytes[..bytes.len() - 1]).is_err());
    let mut longer = bytes.clone();
    longer.push(0);
    assert!(Table::decode(&longer).is_err());
    let mut newer = bytes;
    newer[5] = 7;
    assert!(Table::decode(&newer).is_err());
}

/// A table written by a daemon from before #255 (version 1, no metadata) is still adopted, so
/// upgrading a host keeps every shell; its sessions come over with no metadata (D6), no
/// program status and no boot, so the new program keeps its own (#358).
///
/// The bytes are written out by hand, not by `encode`, which now writes version 4: a fixture an
/// encoder produces would move with the encoder and stop proving anything about old tables.
#[test]
fn a_version_1_table_from_an_older_daemon_is_adopted_without_metadata() {
    #[rustfmt::skip]
        let version_1: &[u8] = &[
            b'W', b'R', b'H', b'O', 0, 1,      // magic, version 1
            0, 0, 0, 3, 0, 0, 0, 4,            // listener 3, lock 4
            0, 0, 0, 1,                        // one session
            7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // id
            0, 0, 0x10, 0x92,                  // pid 4242
            0, 0, 0, 9,                        // master 9
            0, 120, 0, 40,                     // 120 x 40
            0, 0, 0, 5, b'h', b'e', b'l', b'l', b'o', // screen
        ];
    let table = Table::decode(version_1).expect("a version 1 table is read");
    assert_eq!(
        table,
        Table {
            listener: 3,
            lock: 4,
            boot: None,
            sessions: vec![FrozenSession {
                id: SessionId([7; 16]),
                pid: 4242,
                master: 9,
                columns: 120,
                rows: 40,
                screen: b"hello".to_vec(),
                metadata: Vec::new(),
                program_status: Default::default(),
                recipe: None,
                resume: None,
            }],
            events: None,
        }
    );
}

/// This is the table the shipped daemon writes (version 3), its program status exactly as that
/// build's `serde_json` encodes a blocked record. The new program's check decodes the old
/// one's table, so a field added to `Store` or `Record` must decode it: give the new field a
/// serde default, or bump `TABLE_VERSION` and keep accepting 3. Otherwise every upgrade from
/// that release fails its check and the old daemon keeps running.
///
/// Written out by hand for the reason the version 1 fixture above is.
#[test]
fn a_version_3_table_from_the_shipped_daemon_is_adopted_with_its_program_status() {
    let status = concat!(
        r#"{"records":[{"id":"","state":"blocked","kind":"permission","progress":-1,"#,
        r#""app":"claude-code","title":"","message":"Apply?","owner":4242,"updated":1,"#,
        r#""episode":1,"notify":true}],"revision":1,"episode":1,"reporting":4242,"#,
        r#""probed":4242}"#,
    )
    .as_bytes();
    assert_eq!(status.len(), 232);
    #[rustfmt::skip]
        let mut version_3: Vec<u8> = vec![
            b'W', b'R', b'H', b'O', 0, 3,      // magic, version 3
            0, 0, 0, 3, 0, 0, 0, 4,            // listener 3, lock 4
            9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // boot
            0, 0, 0, 1,                        // one session
            7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // id
            0, 0, 0x10, 0x92,                  // pid 4242
            0, 0, 0, 9,                        // master 9
            0, 80, 0, 24,                      // 80 x 24
            0, 0, 0, 0,                        // no screen
            0, 0, 0, 0,                        // no metadata
            0, 0, 0, 232,                      // program status length
        ];
    version_3.extend_from_slice(status);
    let table = Table::decode(&version_3).expect("a version 3 table is read");
    assert_eq!(table.boot, Some(SessionId([9; 16])));
    assert_eq!(table.events, None, "a version 3 table carries no events");
    let store = &table.sessions[0].program_status;
    assert_eq!(store, &blocked_status());
    let event: serde_json::Value =
        serde_json::from_slice(&store.event(SessionId([9; 16]), SessionId([7; 16]))).unwrap();
    assert_eq!(event["revision"], 1);
    assert_eq!(event["records"][0]["state"], "blocked");
    assert_eq!(event["records"][0]["kind"], "permission");
    assert_eq!(event["records"][0]["app"], "claude-code");
    assert_eq!(event["records"][0]["message"], "Apply?");
    assert_eq!(event["records"][0]["episode"], 1);
    assert_eq!(event["records"][0]["notify"], true);
}

/// Each refusal reads as it did when these were strings: the requester is shown this text, and
/// `handoff-check` prints it.
#[test]
fn every_refusal_reads_as_before() {
    use std::os::unix::process::ExitStatusExt;
    let path = || PathBuf::from("/opt/workroomd");
    let io = || std::io::Error::from_raw_os_error(libc::ENOENT);
    let enoent = io().to_string();
    let cases = [
        (HandOffError::NotATable, "not a hand-off table".to_string()),
        (
            HandOffError::TableVersion(9),
            "hand-off table version 9 is not supported".into(),
        ),
        (
            HandOffError::MetadataNotUtf8,
            "hand-off table metadata is not UTF-8".into(),
        ),
        (
            HandOffError::ProgramStatus,
            "hand-off table program status cannot be read".into(),
        ),
        (
            HandOffError::TrailingBytes,
            "hand-off table has trailing bytes".into(),
        ),
        (
            HandOffError::Truncated,
            "hand-off table is truncated".into(),
        ),
        (
            HandOffError::NothingToHandOff,
            "this daemon serves one connection and has nothing to hand off".into(),
        ),
        (
            HandOffError::NotAbsolute(path()),
            "/opt/workroomd is not an absolute path".into(),
        ),
        (
            HandOffError::NotAFile(path()),
            "cannot read /opt/workroomd: not a regular file".into(),
        ),
        (
            HandOffError::Read {
                path: path(),
                source: io(),
            },
            format!("cannot read /opt/workroomd: {enoent}"),
        ),
        (
            HandOffError::InProgress,
            "another hand-off is in progress".into(),
        ),
        (
            HandOffError::RepositoryBusy,
            "a repository command, or a send typing into a session, is still running; try again \
             when it finishes"
                .into(),
        ),
        (
            HandOffError::FilesystemStuck,
            "a filesystem operation is still stuck on a mount; try again when it returns".into(),
        ),
        (
            HandOffError::SessionEnding,
            "a session is being ended; try again when it finishes".into(),
        ),
        (
            HandOffError::SessionsBusy,
            "a session is being ended or repainted; try again when it finishes".into(),
        ),
        (
            HandOffError::Duplicate {
                fd: 7,
                source: io(),
            },
            format!("could not duplicate descriptor 7: {enoent}"),
        ),
        (
            HandOffError::WriteTable {
                path: path(),
                source: io(),
            },
            format!("could not write /opt/workroomd: {enoent}"),
        ),
        (
            HandOffError::Start {
                binary: path(),
                source: io(),
            },
            format!("/opt/workroomd could not start: {enoent}"),
        ),
        (
            HandOffError::BuildLate(path()),
            "/opt/workroomd did not say its build within 3s".into(),
        ),
        (
            HandOffError::Older {
                binary: path(),
                theirs: 100,
                ours: 200,
            },
            "/opt/workroomd is build 100, older than this daemon's build 200".into(),
        ),
        (
            HandOffError::CheckLate(path()),
            "/opt/workroomd did not check the sessions within 3s".into(),
        ),
        (
            HandOffError::CannotRestore {
                binary: path(),
                status: ExitStatus::from_raw(1 << 8),
                stderr: "no".into(),
            },
            "/opt/workroomd cannot restore these sessions (exit status: 1): no".into(),
        ),
        (
            HandOffError::BinaryNul,
            "the binary's path contains a NUL".into(),
        ),
        (
            HandOffError::ArgumentNul,
            "an argument contains a NUL".into(),
        ),
        (
            HandOffError::TablePathNul,
            "the table path has a NUL".into(),
        ),
        (
            HandOffError::RequesterGone,
            "the requester stopped waiting, so nothing was replaced".into(),
        ),
        (
            HandOffError::Exec {
                binary: path(),
                source: io(),
            },
            format!("/opt/workroomd could not be executed: {enoent}"),
        ),
        (
            HandOffError::NoTerminalState,
            "this build cannot restore screens (built without terminal-state)".into(),
        ),
    ];
    for (error, text) in cases {
        assert_eq!(error.to_string(), text);
    }
}
