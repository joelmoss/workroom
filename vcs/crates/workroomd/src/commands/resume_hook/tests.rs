use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::super::Scratch;
use super::claude::{Found, claude_arguments, kept_flags, resume_command};
use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_string).collect()
}

const ID: &str = "be5a1e0f-0d6c-4c9f-9c3e-2b7f1d0a8e17";

/// A native install's executable, which `~/.local/bin/claude` links to.
const NATIVE: &str = "/Users/me/.local/share/claude/versions/2.1.332";

/// Any word is a file, as an interpreter's script is.
fn any_file(_: &str) -> bool {
    true
}

/// Claude's own arguments in `argv`, run by the native executable.
fn native_arguments(argv: &[String]) -> Option<&[String]> {
    match claude_arguments(argv, Some(NATIVE), &any_file) {
        Found::Claude(args) => Some(args),
        _ => None,
    }
}

/// The command Claude started as `line` resumes as, with the default profile.
fn resumed(line: &str) -> Option<String> {
    let argv = words(line);
    let args = native_arguments(&argv)?;
    resume_command(args, ID, None).map(|command| command.join(" "))
}

#[test]
fn the_flags_that_shape_a_session_are_kept_with_their_values() {
    assert_eq!(
        resumed("claude").as_deref(),
        Some(format!("claude --resume {ID}").as_str())
    );
    assert_eq!(
        resumed("claude --model sonnet --permission-mode plan").unwrap(),
        format!("claude --resume {ID} --model sonnet --permission-mode plan")
    );
    assert_eq!(
        resumed("claude --dangerously-skip-permissions --add-dir ../apps ../lib --effort high")
            .unwrap(),
        format!(
            "claude --resume {ID} --dangerously-skip-permissions --add-dir ../apps ../lib --effort high"
        )
    );
    // A required value is taken whatever it looks like, as commander takes it.
    assert_eq!(
        resumed("claude --append-system-prompt -terse").unwrap(),
        format!("claude --resume {ID} --append-system-prompt -terse")
    );
    // `=` forms keep their one word; a list's `=` value is its only one, the next word a prompt.
    assert_eq!(
        resumed("claude --model=opus --add-dir=../a fix").unwrap(),
        format!("claude --resume {ID} --model=opus --add-dir=../a")
    );
    assert_eq!(
        resumed("claude --allowedTools Read Edit --disallowed-tools Bash --mcp-config a.json")
            .unwrap(),
        format!(
            "claude --resume {ID} --allowedTools Read Edit --disallowed-tools Bash --mcp-config a.json"
        )
    );
}

#[test]
fn prompts_resume_flags_diagnostics_and_words_after_a_double_dash_are_dropped() {
    assert_eq!(
        resumed("claude fix the tests --model sonnet").unwrap(),
        format!("claude --resume {ID} --model sonnet")
    );
    assert_eq!(
        resumed("claude --continue --fork-session --model sonnet").unwrap(),
        format!("claude --resume {ID} --model sonnet")
    );
    // `--resume`'s value is optional: taken unless it is an option.
    assert_eq!(
        resumed("claude --resume old-id --verbose").unwrap(),
        format!("claude --resume {ID} --verbose")
    );
    assert_eq!(
        resumed("claude -r --verbose").unwrap(),
        format!("claude --resume {ID} --verbose")
    );
    assert_eq!(
        resumed("claude -rold-id -c").unwrap(),
        format!("claude --resume {ID}")
    );
    assert_eq!(
        resumed("claude --session-id 550e8400-e29b-41d4-a716-446655440000 -n work --name=w")
            .unwrap(),
        format!("claude --resume {ID}")
    );
    assert_eq!(
        resumed("claude --debug --debug=mcp --debug-file /tmp/d.log --ide").unwrap(),
        format!("claude --resume {ID} --ide")
    );
    assert_eq!(
        resumed("claude --model sonnet -- --dangerously-skip-permissions hi").unwrap(),
        format!("claude --resume {ID} --model sonnet")
    );
}

#[test]
fn print_mode_another_place_and_an_unknown_flag_give_no_command() {
    for line in [
        "claude -p hi",
        "claude --print hi",
        "claude --model sonnet -p",
        "claude --bg investigate",
        "claude --cloud task",
        "claude -w feature",
        "claude --worktree",
        "claude --teleport",
        "claude --version",
        // Not in the reference, or its words unclear.
        "claude --bogus",
        "claude --tools Bash,Edit",
        "claude --remote-control",
        // Several short flags in one word, and a value where none is taken.
        "claude -cp",
        "claude --verbose=yes",
        // A required value missing.
        "claude --model",
        "claude --add-dir --verbose",
    ] {
        assert_eq!(resumed(line), None, "{line}");
    }
}

/// A resumed Claude runs its hook again: what it reports then is what it was resumed with.
#[test]
fn a_resumed_command_reports_itself_again() {
    for line in [
        "claude --model sonnet --permission-mode plan",
        "claude --add-dir a b --dangerously-skip-permissions",
        "claude --resume x --model=opus",
    ] {
        let first = resumed(line).unwrap();
        assert_eq!(resumed(&first).unwrap(), first, "{line}");
    }
    let profiled = resume_command(&words("--model sonnet"), ID, Some("/p/sessions/2-me")).unwrap();
    assert_eq!(
        profiled.join(" "),
        format!("env CLAUDE_CONFIG_DIR=/p/sessions/2-me claude --resume {ID} --model sonnet")
    );
    // `env` exec's `claude`, whose own arguments are those after it.
    let again = resume_command(
        native_arguments(&profiled[2..]).unwrap(),
        ID,
        Some("/p/sessions/2-me"),
    );
    assert_eq!(again.unwrap(), profiled);
    // Unset or empty is the default profile.
    assert_eq!(resume_command(&[], ID, Some("")).unwrap()[0], "claude");
}

const NODE: &str = "/opt/homebrew/Cellar/node/26.1.0/bin/node";
const CLI: &str = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js";

#[test]
fn claude_is_found_by_its_program_alone_or_under_an_interpreter() {
    let args = |line: &str, executable: &str| match claude_arguments(
        &words(line),
        Some(executable),
        &any_file,
    ) {
        Found::Claude(args) => Some(args.to_vec()),
        _ => None,
    };
    assert_eq!(args("claude --model x", NATIVE), Some(words("--model x")));
    assert_eq!(
        args("/Users/me/.local/bin/claude -c", NATIVE),
        Some(words("-c"))
    );
    assert_eq!(
        args(&format!("{NATIVE} --verbose"), NATIVE),
        Some(words("--verbose"))
    );
    assert_eq!(
        args("node /usr/local/bin/claude --model x", NODE),
        Some(words("--model x"))
    );
    assert_eq!(
        args(&format!("node --no-warnings {CLI} -c"), NODE),
        Some(words("-c"))
    );
    assert_eq!(
        args("/bin/sh /tmp/bin/claude --ide", "/bin/bash"),
        Some(words("--ide"))
    );
    for (other, executable) in [
        ("codex --model x", "/opt/bin/codex"),
        ("node server.js", NODE),
        ("/bin/zsh -c claude", "/bin/zsh"),
        ("2.1.332", "/usr/bin/true"),
        ("sh", "/bin/sh"),
    ] {
        let argv = words(other);
        assert_eq!(
            claude_arguments(&argv, Some(executable), &any_file),
            Found::Other,
            "{other}"
        );
    }
}

/// Value: protects=a resumed Claude keeping its model, permissions, directories and MCP servers
/// (#828); fails_when=an npm install's argv that node blanked with its title, or that names no
/// script under node, is reported as a plain `claude --resume`; why_new=new (#828 review);
/// seam=the argv and executable a process read gives
#[test]
fn an_npm_claudes_argv_counts_only_when_it_is_provably_whole() {
    let found = |argv: &[&str], executable: Option<&str>| {
        let argv: Vec<String> = argv.iter().map(|word| word.to_string()).collect();
        match claude_arguments(&argv, executable, &|path| path == CLI) {
            Found::Claude(args) => Ok(args.to_vec()),
            Found::Unproven => Err("unproven"),
            Found::Other => Err("other"),
        }
    };
    let flags = [
        "--model",
        "opus",
        "--add-dir",
        "../lib",
        "--dangerously-skip-permissions",
    ];
    let whole: Vec<&str> = ["node", CLI].iter().chain(&flags).copied().collect();
    assert_eq!(
        found(&whole, Some(NODE)),
        Ok(flags.iter().map(|w| w.to_string()).collect())
    );
    // node's `process.title = "claude"`: macOS reads the title, then each word after it empty.
    let blanked = ["claude", "", "", "", "", "", ""];
    assert_eq!(found(&blanked, Some(NODE)), Err("unproven"));
    // Linux's `cmdline` reads the title alone, empty words dropped; node still runs it.
    assert_eq!(found(&["claude"], Some(NODE)), Err("unproven"));
    // Blanked only past the script: an empty prompt, or a flag's value gone.
    assert_eq!(
        found(&["node", CLI, "--model", ""], Some(NODE)),
        Err("unproven")
    );
    // Under node, with no script of Claude's named; and an executable that can't be read.
    assert_eq!(
        found(&["node", "--model", "opus"], Some(NODE)),
        Err("other")
    );
    assert_eq!(found(&whole, None), Err("unproven"));
    // argv saying an interpreter that the executable isn't, or the reverse.
    assert_eq!(
        found(&["claude", "--model", "opus"], Some("/usr/bin/nodejs")),
        Err("unproven")
    );
    assert_eq!(found(&whole, Some(NATIVE)), Err("unproven"));
    // A native Claude whose title replaced argv[0] is still Claude, and gets nothing.
    assert_eq!(found(&["2.1.332", "", ""], Some(NATIVE)), Err("unproven"));
}

#[test]
fn a_conversation_id_is_only_letters_digits_and_dashes() {
    for bad in ["", "a b", "a:b", "a/b", "\u{1b}]7577", &"a".repeat(129)] {
        assert_eq!(resume_command(&[], bad, None), None, "{bad:?}");
    }
    assert!(conversation(br#"{"session_id":"abc","source":"clear"}"#).as_deref() == Some("abc"));
    assert_eq!(conversation(b"not json"), None);
    assert_eq!(conversation(br#"{"source":"startup"}"#), None);
}

#[test]
fn kept_flags_leave_the_words_as_they_were_given() {
    assert_eq!(
        kept_flags(&words(
            "--settings ./s.json --agents {} --plugin-dir a --plugin-dir b"
        )),
        Some(words(
            "--settings ./s.json --agents {} --plugin-dir a --plugin-dir b"
        ))
    );
}

/// The report is the one the daemon accepts, and none at all where it would reject one, which
/// would remove the record Claude has.
#[test]
fn the_report_is_signed_for_claude_and_none_is_sent_that_the_daemon_would_reject() {
    let argv = words("claude --resume abc --model sonnet");
    let frame =
        crate::terminal::resume::launch::record_report("tok", 42, 1_800_000_000, &argv).unwrap();
    let text = String::from_utf8(frame).unwrap();
    let body = text
        .strip_prefix("\x1b]7577;")
        .and_then(|rest| rest.strip_suffix('\x07'))
        .unwrap();
    let (signed, mac) = body.rsplit_once(":mac=").unwrap();
    assert!(
        signed.starts_with("pid=42:time=1800000000:argv="),
        "{signed}"
    );
    assert!(!signed.contains("cwd="), "the owner's own folder: {signed}");
    assert_eq!(
        mac,
        crate::util::sha256_hex(format!("{signed}:tok").as_bytes())
    );

    let report = |argv: Vec<String>| {
        crate::terminal::resume::launch::record_report("tok", 42, 1_800_000_000, &argv)
    };
    // A multi-line system prompt, too many words, too many bytes.
    assert_eq!(
        report(vec![
            "claude".into(),
            "--append-system-prompt".into(),
            "a\nb".into()
        ]),
        None
    );
    assert_eq!(report(vec!["claude".to_string(); 65]), None);
    assert_eq!(
        report(vec![
            "claude".into(),
            "--system-prompt".into(),
            "x".repeat(7000)
        ]),
        None
    );
}

// MARK: - The hook in settings.json

fn settings(profile: &Path) -> Value {
    serde_json::from_slice(&fs::read(profile.join("settings.json")).unwrap()).unwrap()
}

fn states(reports: &[Report]) -> Vec<State> {
    reports.iter().map(|report| report.state).collect()
}

/// No variables: the test's home alone, never the developer's own Claude config.
fn none() -> Places {
    Places::default()
}

fn ours(groups: &Value) -> usize {
    groups
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|group| group["hooks"].as_array().cloned().unwrap_or_default())
        .filter(is_ours)
        .count()
}

#[test]
fn install_adds_the_hook_beside_the_users_own_and_remove_takes_only_it() {
    let home = Scratch::new("resume-hook-cycle");
    let profile = home.join(".claude");
    fs::create_dir(&profile).unwrap();
    let theirs = json!({
        "model": "opus",
        "statusLine": {"type": "command", "command": "mine.sh"},
        "hooks": {
            "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "echo hi"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
        }
    });
    fs::write(
        profile.join("settings.json"),
        serde_json::to_vec(&theirs).unwrap(),
    )
    .unwrap();
    let path = profile.join("settings.json");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();

    assert_eq!(states(&install(&home, &none())), [State::Installed]);
    let installed = settings(&profile);
    assert_eq!(installed["model"], "opus");
    assert_eq!(installed["statusLine"], theirs["statusLine"]);
    assert_eq!(installed["hooks"]["Stop"], theirs["hooks"]["Stop"]);
    let start = &installed["hooks"]["SessionStart"];
    assert_eq!(start[0], theirs["hooks"]["SessionStart"][0]);
    assert_eq!(start[1], entry());
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o640
    );
    assert!(home.join(RECORD).is_file());

    // Current: not written again.
    let written = fs::metadata(&path).unwrap().modified().unwrap();
    assert_eq!(states(&install(&home, &none())), [State::Current]);
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), written);

    assert_eq!(states(&remove(&home, &none())), [State::Removed]);
    assert_eq!(settings(&profile), theirs);
    assert_eq!(states(&remove(&home, &none())), [State::Absent]);
    assert_eq!(read_record(&home), Vec::<PathBuf>::new());
}

/// Value: protects=a user's settings.json keeping their key order, spacing and newline through
/// the hook's install and removal (#828); fails_when=the file is written from a sorted map, or
/// in another indent, or a removal leaves a stray comma or blank line; why_new=new (#828
/// review); seam=none
#[test]
fn a_settings_file_without_hooks_gets_its_own_bytes_back_after_install_then_remove() {
    let home = Scratch::new("resume-hook-bytes");
    let profile = home.join(".claude");
    fs::create_dir(&profile).unwrap();
    let path = profile.join("settings.json");
    for original in [
        // Four spaces, keys out of order, a space before a colon, a trailing newline.
        "{\n    \"theme\" : \"dark\",\n    \"model\": \"opus\",\n    \"env\": {\"B\": \"1\", \"A\": \"2\"}\n}\n",
        // Tabs, and no trailing newline.
        "{\n\t\"permissions\": {\"allow\": [\"Bash(ls)\"]},\n\t\"alwaysThinkingEnabled\": true\n}",
        // One line, and one member.
        "{\"zeta\":1,\"alpha\":[1, 2]}",
        "{\"model\": \"opus\"}\n",
        "{}\n",
    ] {
        fs::write(&path, original).unwrap();
        assert_eq!(
            states(&install(&home, &none())),
            [State::Installed],
            "{original}"
        );
        let installed = fs::read_to_string(&path).unwrap();
        assert_eq!(ours(&settings(&profile)["hooks"]["SessionStart"]), 1);
        // The user's members are where they were, in their order, as they wrote them, and the
        // hook comes after them, before the file's own end.
        let members = original.trim_end().strip_suffix('}').unwrap().trim_end();
        let end = &original[members.len()..];
        assert!(installed.ends_with(end), "{installed}");
        if members != "{" {
            assert!(installed.starts_with(&format!("{members},")), "{installed}");
            let one_line = !original.trim_end().contains('\n');
            assert_eq!(
                !installed.trim_end().contains('\n'),
                one_line,
                "a one-line file stays one: {installed}"
            );
        }
        assert_eq!(states(&remove(&home, &none())), [State::Removed]);
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
    }
}

/// Value: protects=every byte of a user's settings.json outside its `hooks` value (#828);
/// fails_when=a change to `hooks` rewrites or reorders anything around it; why_new=new (#828
/// review); seam=none
#[test]
fn only_the_hooks_value_changes_in_a_settings_file_that_has_one() {
    let home = Scratch::new("resume-hook-hooks-only");
    let profile = home.join(".claude");
    fs::create_dir(&profile).unwrap();
    let path = profile.join("settings.json");
    let before = "{\n   \"zeta\": true,\n   \"hooks\": {\n      \"Stop\": []\n   },\n   \"alpha\" :  [ 1,2 ]\n}";
    let (head, tail) = (
        "{\n   \"zeta\": true,\n   \"hooks\": ",
        ",\n   \"alpha\" :  [ 1,2 ]\n}",
    );
    fs::write(&path, before).unwrap();
    assert_eq!(states(&install(&home, &none())), [State::Installed]);
    let installed = fs::read_to_string(&path).unwrap();
    assert!(installed.starts_with(head), "{installed}");
    assert!(installed.ends_with(tail), "{installed}");
    // The hooks value in the file's own three-space indent, at its depth.
    let value = &installed[head.len()..installed.len() - tail.len()];
    assert!(
        value.starts_with("{\n      \"SessionStart\": [\n         {"),
        "{value}"
    );
    assert!(value.ends_with("\n      \"Stop\": []\n   }"), "{value}");
    assert_eq!(ours(&settings(&profile)["hooks"]["SessionStart"]), 1);

    assert_eq!(states(&remove(&home, &none())), [State::Removed]);
    let removed = fs::read_to_string(&path).unwrap();
    assert!(
        removed.starts_with(head) && removed.ends_with(tail),
        "{removed}"
    );
    assert_eq!(settings(&profile)["hooks"], json!({"Stop": []}));
    // Its `hooks` was as Workroom writes one in that indent, so it is all as it was.
    assert_eq!(removed, before);
}

#[test]
fn an_older_hook_of_workrooms_is_replaced_and_an_empty_settings_file_gets_one() {
    let home = Scratch::new("resume-hook-update");
    let profile = home.join(".claude");
    fs::create_dir(&profile).unwrap();
    fs::write(
        profile.join("settings.json"),
        serde_json::to_vec(&json!({"hooks": {"SessionStart": [
            {"hooks": [
                {"type": "command", "command": "echo mine"},
                {"type": "command", "command": format!("/old/workroom resume-hook report {MARKER}")}
            ]},
            {"hooks": [{"type": "command", "command": format!("another {MARKER}")}]}
        ]}}))
        .unwrap(),
    )
    .unwrap();
    assert_eq!(states(&install(&home, &none())), [State::Updated]);
    let start = settings(&profile)["hooks"]["SessionStart"].clone();
    assert_eq!(ours(&start), 1);
    assert_eq!(
        start,
        json!([{"hooks": [{"type": "command", "command": "echo mine"}]}, entry()])
    );

    // Removing leaves the user's group, and an install into an empty file writes the hook alone.
    assert_eq!(states(&remove(&home, &none())), [State::Removed]);
    fs::write(profile.join("settings.json"), "  \n").unwrap();
    assert_eq!(states(&install(&home, &none())), [State::Installed]);
    assert_eq!(
        settings(&profile),
        json!({"hooks": {"SessionStart": [entry()]}})
    );
    assert_eq!(states(&remove(&home, &none())), [State::Removed]);
    assert_eq!(settings(&profile), json!({}));
}

#[test]
fn a_settings_file_claude_would_not_read_is_never_overwritten() {
    let home = Scratch::new("resume-hook-refuse");
    let profile = home.join(".claude");
    fs::create_dir(&profile).unwrap();
    for bad in [
        "{\"model\": \"opus\",}",
        "[]",
        r#"{"hooks": []}"#,
        r#"{"hooks": {"SessionStart": {"hooks": []}}}"#,
    ] {
        fs::write(profile.join("settings.json"), bad).unwrap();
        for reports in [install(&home, &none()), remove(&home, &none())] {
            assert_eq!(states(&reports), [State::Failed], "{bad}");
            assert!(
                reports[0]
                    .message
                    .as_deref()
                    .unwrap()
                    .contains("left it as it is"),
                "{bad}: {reports:?}"
            );
        }
        assert_eq!(
            fs::read_to_string(profile.join("settings.json")).unwrap(),
            bad
        );
    }
    // Nothing of this run's left beside it.
    let left: Vec<_> = fs::read_dir(&profile)
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name())
        .collect();
    assert_eq!(left, ["settings.json"]);
}

#[test]
fn a_profile_that_isnt_set_up_gets_nothing_and_claude_config_dir_is_one_too() {
    let home = Scratch::new("resume-hook-places");
    let config = Scratch::new("resume-hook-places-config");
    assert_eq!(states(&install(&home, &none())), [State::NoAgent]);
    assert!(!home.join(".claude").exists());

    let places = Places::from_env(|name| {
        (name == "CLAUDE_CONFIG_DIR").then(|| config.to_string_lossy().into_owned())
    });
    fs::create_dir(home.join(".claude")).unwrap();
    assert_eq!(
        states(&install(&home, &places)),
        [State::Installed, State::Installed]
    );
    assert_eq!(ours(&settings(&config)["hooks"]["SessionStart"]), 1);
    assert_eq!(
        ours(&settings(&home.join(".claude"))["hooks"]["SessionStart"]),
        1
    );
    // The variable gone, the record still finds where it went.
    let reports = remove(&home, &none());
    assert_eq!(
        states(&reports),
        [State::Removed, State::Removed],
        "{reports:?}"
    );
    assert_eq!(settings(&config), json!({}));
}

/// cswap links a profile's `settings.json` to `~/.claude`'s, and a user's dotfiles may too: the
/// file it names is written, once, and the link stays.
#[test]
fn a_linked_settings_file_is_written_through_its_link_once() {
    let home = Scratch::new("resume-hook-linked");
    let dotfiles = Scratch::new("resume-hook-linked-dotfiles");
    let profile = home.join(".claude");
    let session = home.join("cswap-session");
    fs::create_dir(&profile).unwrap();
    fs::create_dir(&session).unwrap();
    fs::write(dotfiles.join("settings.json"), r#"{"theme": "dark"}"#).unwrap();
    std::os::unix::fs::symlink(
        dotfiles.join("settings.json"),
        profile.join("settings.json"),
    )
    .unwrap();
    std::os::unix::fs::symlink(profile.join("settings.json"), session.join("settings.json"))
        .unwrap();
    let places = Places::from_env(|name| {
        (name == "CLAUDE_CONFIG_DIR").then(|| session.to_string_lossy().into_owned())
    });
    let reports = install(&home, &places);
    assert_eq!(states(&reports), [State::Installed], "{reports:?}");
    for link in [profile.join("settings.json"), session.join("settings.json")] {
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
    let written = settings(&dotfiles);
    assert_eq!(written["theme"], "dark");
    assert_eq!(ours(&written["hooks"]["SessionStart"]), 1);
    assert_eq!(states(&remove(&home, &places)), [State::Removed]);
    assert_eq!(settings(&dotfiles), json!({"theme": "dark"}));
}

#[test]
fn a_fifo_or_folder_in_place_of_the_settings_file_is_never_opened() {
    let home = Scratch::new("resume-hook-fifo");
    let profile = home.join(".claude");
    fs::create_dir(&profile).unwrap();
    let path =
        std::ffi::CString::new(profile.join("settings.json").to_string_lossy().as_bytes()).unwrap();
    // SAFETY: `mkfifo` reads the NUL-terminated path it is given and keeps no pointer.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert_eq!(states(&install(&home, &none())), [State::Failed]);
    assert_eq!(states(&remove(&home, &none())), [State::Failed]);
}

/// The hook's command does nothing, and succeeds, outside a Workroom pane.
#[test]
fn the_hooks_command_does_nothing_outside_a_workroom_pane() {
    // No token, then a token but no `workroom` anywhere (no bin folder, none on PATH).
    for token in [None, Some("a-token")] {
        let mut command = std::process::Command::new("/bin/sh");
        command
            .args(["-c", COMMAND])
            .env_clear()
            .env("PATH", "/usr/bin:/bin");
        if let Some(token) = token {
            command.env("OSC7577_TOKEN", token);
        }
        let output = command.output().unwrap();
        assert!(output.status.success(), "{token:?}");
        assert!(
            output.stdout.is_empty() && output.stderr.is_empty(),
            "{token:?}: {output:?}"
        );
    }
    assert!(COMMAND.ends_with(MARKER));
}
