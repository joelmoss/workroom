use super::*;

#[test]
fn clone_error_lines_keep_gits_account_of_the_failure_without_its_progress() {
    for (stderr, want) in [
        (
            "Cloning into '/x'...\nfatal: repository '/nope' does not exist\n",
            "fatal: repository '/nope' does not exist",
        ),
        (
            "Cloning into 'x'...\r\nPermission denied (publickey).\r\nfatal: Could not read from \
             remote repository.\n",
            "Permission denied (publickey).\nfatal: Could not read from remote repository.",
        ),
        (
            "remote: Enumerating objects: 5, done.\nremote: Counting objects: 5\nremote: Total 5 \
             (delta 0)\nReceiving objects:  40% (2/5)\rReceiving objects: 100% (5/5), done.\n\
             remote: Repository not found.\n",
            "remote: Repository not found.",
        ),
        ("Cloning into 'x'...\n", ""),
    ] {
        assert_eq!(clone_error_lines(stderr), want, "{stderr:?}");
    }
}

#[test]
fn the_tail_buffer_keeps_only_the_last_64_kib_and_drops_the_line_it_cut_into() {
    let mut tail = TailBuffer::default();
    tail.write(b"short\n");
    assert_eq!(tail.text(), "short\n");

    let mut tail = TailBuffer::default();
    tail.write(&vec![b'x'; STDERR_CAP - 3]);
    tail.write(b"ab\nfatal: end\n");
    assert_eq!(tail.kept.len(), STDERR_CAP);
    assert_eq!(tail.text(), "fatal: end\n");

    let mut tail = TailBuffer::default();
    let mut huge = vec![b'y'; STDERR_CAP * 2];
    huge.extend_from_slice(b"\nlast\n");
    tail.write(&huge);
    assert_eq!(tail.kept.len(), STDERR_CAP);
    assert_eq!(tail.text(), "last\n");

    let mut tail = TailBuffer::default();
    tail.write(&vec![b'z'; STDERR_CAP + 1]);
    assert_eq!(tail.text(), "", "a cut line with no end is dropped whole");
}

#[test]
fn base36_is_gos_format_uint() {
    for (value, want) in [(0, "0"), (35, "z"), (36, "10"), (u32::MAX, "1z141z3")] {
        assert_eq!(base36(value), want);
    }
}

#[test]
fn the_clone_environment_drops_repository_variables_ignoring_case_and_never_prompts() {
    let inherited = [
        ("git_index_file", "/elsewhere/index"),
        ("GIT_SHALLOW_FILE", "/x"),
        ("GIT_TERMINAL_PROMPT", "1"),
        ("GIT_SSH_COMMAND", "ssh -v"),
    ]
    .map(|(key, value)| (key.into(), value.into()));
    let command = clone_command("file:///x", Path::new("/y"), None, inherited.into_iter());
    let envs: Vec<(String, Option<String>)> = command
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|value| value.to_string_lossy().into_owned()),
            )
        })
        .collect();
    assert!(
        envs.contains(&("git_index_file".to_string(), None)),
        "{envs:?}"
    );
    assert!(
        envs.contains(&("GIT_SHALLOW_FILE".to_string(), None)),
        "{envs:?}"
    );
    assert!(envs.contains(&("GIT_TERMINAL_PROMPT".to_string(), Some("0".to_string()))));
    assert!(
        !envs.iter().any(|(key, _)| key == "GIT_SSH_COMMAND"),
        "{envs:?}"
    );
    let args: Vec<_> = command.get_args().collect();
    assert_eq!(args, ["clone", "--progress", "--", "file:///x", "/y"]);
    assert_eq!(
        command.get_current_dir(),
        None,
        "runs where the CLI does, as Go's"
    );
}

#[test]
fn a_rename_onto_an_existing_folder_is_refused_as_gos_is() {
    let dir = scratch("rename");
    let from = dir.join("from");
    let to = dir.join("to");
    std::fs::create_dir(&from).unwrap();
    std::fs::create_dir(&to).unwrap();
    let error = go_rename(&from, &to).unwrap_err();
    assert!(error.ends_with(": file exists"), "{error}");
    assert!(from.exists() && to.exists());
    std::fs::remove_dir(&to).unwrap();
    go_rename(&from, &to).unwrap();
    assert!(!from.exists() && to.exists());
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A new directory of this test's own under the system temp dir, removed by the test.
fn scratch(name: &str) -> PathBuf {
    for attempt in 0u32.. {
        let dir = std::env::temp_dir().join(format!(
            "workroom-clone-{name}-{}-{attempt}",
            std::process::id()
        ));
        if std::fs::create_dir(&dir).is_ok() {
            return dir.canonicalize().unwrap();
        }
    }
    unreachable!()
}
