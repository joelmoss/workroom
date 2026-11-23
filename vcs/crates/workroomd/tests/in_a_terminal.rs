//! The commands that ask a person at a terminal, asked by one. `workroom delete` (#678): with no
//! `--confirm` it asks, with no name it offers the project's workrooms to pick, and a teardown
//! script this Mac hasn't approved is shown and asked about. `workroom create` (#677): a setup
//! script this Mac hasn't approved is shown and asked about, and so is work the start would leave
//! out. Each answer is typed into a real pty, the binary's stdin, so the binary sees a terminal as
//! it does in one; what it writes goes to a pipe.
//!
//! The contract suite (`commands_contract.rs`) runs against the Go CLI too, whose prompts are a
//! full-screen form (charmbracelet/huh) no line of input drives, so these run against this crate's
//! binary only; the contract suite has what each command does with no one at a terminal. Each run
//! gets a throwaway HOME and config, as the contract suite's do.
#![cfg(target_os = "macos")]

mod outside;

use std::io::Write;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The digest of `#!/bin/sh\necho stopping\n`, the teardown each project here has.
const STOPPING_SHA256: &str = "46afe9251fa214a976ea23e0094166dceb1f79f39ef879bd4cc3d59b26808059";
/// The digest of `#!/bin/sh\necho installing\n`, a create's setup script here.
const INSTALLING_SHA256: &str = "0ce619c6c940c7c71a56a15360c8f4d662b6358bd35c47bbf3b70d2b3714d3f7";

/// A throwaway HOME, removed when the test ends; one this run made itself, never a leftover.
struct Home {
    dir: PathBuf,
}

impl Home {
    fn new(name: &str) -> Home {
        let parent = std::env::temp_dir();
        for attempt in 0u32.. {
            let dir = parent.join(format!(
                "workroom-tty-{name}-{}-{attempt}",
                std::process::id()
            ));
            match std::fs::create_dir(&dir) {
                Ok(()) => {
                    return Home {
                        dir: dir.canonicalize().expect("resolve HOME"),
                    };
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create HOME {}: {error}", dir.display()),
            }
        }
        unreachable!("u32 attempts ran out")
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.dir.join(relative)
    }

    fn config_path(&self) -> PathBuf {
        self.path(".config/workroom/config.json")
    }

    fn config(&self) -> String {
        std::fs::read_to_string(self.config_path()).unwrap_or_default()
    }

    fn command(&self, program: impl AsRef<std::ffi::OsStr>, cwd: &Path) -> Command {
        let mut command = Command::new(program);
        command
            .env_clear()
            .current_dir(cwd)
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &self.dir)
            .env("WORKROOM_CONFIG", self.config_path())
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t");
        command
    }

    fn git(&self, dir: &Path, args: &[&str]) {
        let output = self.command("git", dir).args(args).output().expect("git");
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn commit(&self, dir: &Path, message: &str) {
        self.git(
            dir,
            &[
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                message,
            ],
        );
    }

    /// What git prints for `args` in `dir`, trimmed.
    fn git_output(&self, dir: &Path, args: &[&str]) -> String {
        let output = self.command("git", dir).args(args).output().expect("git");
        assert!(output.status.success(), "git {args:?}");
        String::from_utf8(output.stdout)
            .expect("UTF-8")
            .trim()
            .to_string()
    }

    /// `src/app`, a git repository on `main` with one commit.
    fn repo(&self) -> PathBuf {
        let project = self.path("src/app");
        std::fs::create_dir_all(project.join("scripts")).expect("project");
        self.git(&project, &["init", "-q", "-b", "main"]);
        self.commit(&project, "first");
        project
    }

    /// Writes the executable `scripts/<name>` in `project`.
    fn script(&self, project: &Path, name: &str, text: &str) {
        let script = project.join("scripts").join(name);
        std::fs::write(&script, text).expect("script");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    }

    /// Registers `project`, with no script approved and no workroom.
    fn register(&self, project: &Path) {
        std::fs::create_dir_all(self.config_path().parent().expect("dir")).expect("config dir");
        std::fs::write(
            self.config_path(),
            format!(
                "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{}}}}}}",
                project.display()
            ),
        )
        .expect("config");
    }

    /// The one workroom a create made under `~/workrooms`, if it made one.
    fn workroom(&self) -> Option<PathBuf> {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(self.path("workrooms"))
            .ok()?
            .map(|entry| entry.expect("entry").path())
            .collect();
        assert!(entries.len() <= 1, "{entries:?}");
        entries.pop()
    }

    /// A registered project with an approved (or, with another `digest`, unapproved) teardown
    /// script, and a real workroom for each of `names` under `~/workrooms`.
    fn project(&self, names: &[&str], digest: &str) -> PathBuf {
        let project = self.repo();
        self.script(&project, "workroom_teardown", "#!/bin/sh\necho stopping\n");
        let mut workrooms = Vec::new();
        for name in names {
            let path = self.path(&format!("workrooms/{name}"));
            self.git(
                &project,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    &format!("workroom/{name}"),
                    &path.to_string_lossy(),
                ],
            );
            workrooms.push(format!("\"{name}\": {{\"path\": \"{}\"}}", path.display()));
        }
        std::fs::create_dir_all(self.config_path().parent().expect("dir")).expect("config dir");
        std::fs::write(
            self.config_path(),
            format!(
                "{{\"{}\": {{\"trusted_scripts\": {{\"workroom_teardown\": \"{digest}\"}}, \"vcs\": \"git\", \"workrooms\": {{{}}}}}}}",
                project.display(),
                workrooms.join(", ")
            ),
        )
        .expect("config");
        project
    }

    /// Runs this crate's `workroom` in `cwd` with `args`, a pty as its stdin with `typed` already
    /// typed into it: (exit code, stdout, stderr). Outside this test's process tree (`outside`),
    /// so a coding agent running the tests is none of its parents, and `delete` asks as it asks a
    /// person (#793).
    fn run_typing(&self, cwd: &Path, args: &[&str], typed: &str) -> (i32, String, String) {
        let (primary, secondary) = pty();
        let mut keyboard = std::fs::File::from(primary);
        keyboard.write_all(typed.as_bytes()).expect("type");
        let mut command = self.command(env!("CARGO_BIN_EXE_workroom"), cwd);
        command.args(args).stdin(Stdio::from(secondary));
        let output = outside::spawn(command, None).wait_with_output();
        drop(keyboard);
        (
            output.status.code().expect("exited"),
            String::from_utf8(output.stdout).expect("UTF-8"),
            String::from_utf8(output.stderr).expect("UTF-8"),
        )
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// (the side the test types into, the side the binary's stdin is).
fn pty() -> (OwnedFd, OwnedFd) {
    let (mut primary, mut secondary) = (-1, -1);
    // SAFETY: both pointers are to live locals; openpty writes the two descriptors, and the null
    // name, termios and size are documented as "none".
    let rc = unsafe {
        libc::openpty(
            &mut primary,
            &mut secondary,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(rc, 0, "openpty: {}", std::io::Error::last_os_error());
    // SAFETY: openpty succeeded, so both are open descriptors this test now owns.
    unsafe {
        (
            OwnedFd::from_raw_fd(primary),
            OwnedFd::from_raw_fd(secondary),
        )
    }
}

const DELETED: &str = "Workroom 'calm-river' deleted successfully.\n\nNote: Git branch \
                       'workroom/calm-river' was not deleted.\n      Delete manually with `git \
                       branch -D workroom/calm-river` if needed.\n";

/// Without `--confirm` the person is asked: a no deletes nothing, a yes deletes it.
#[test]
fn without_confirm_a_person_is_asked_first() {
    let home = Home::new("confirm");
    let project = home.project(&["calm-river"], STOPPING_SHA256);
    let before = home.config();
    let question = "Are you sure you want to delete workroom 'calm-river'? [y/N] ";

    let (code, stdout, stderr) = home.run_typing(&project, &["delete", "calm-river"], "n\n");
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    assert_eq!(
        stdout,
        format!("{question}Aborting. Workroom 'calm-river' was not deleted.\n")
    );
    assert_eq!(home.config(), before);
    assert!(home.path("workrooms/calm-river/.git").exists());

    let (code, stdout, stderr) = home.run_typing(&project, &["d", "calm-river"], "y\n");
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    let panel = format!(
        "╭─ Teardown {}\n│ stopping\n╰{}\n\n",
        "─".repeat(48),
        "─".repeat(59)
    );
    assert_eq!(stdout, format!("{question}{panel}{DELETED}"));
    assert!(!home.path("workrooms/calm-river").exists());
}

/// Without a name the person picks from the project's workrooms, then confirms the picks; only
/// the picked ones go.
#[test]
fn without_a_name_a_person_picks_which_to_delete() {
    let home = Home::new("pick");
    let project = home.project(&["calm-river", "bright-star"], STOPPING_SHA256);
    let before = home.config();
    let list = "Select workrooms to delete:\n  1) bright-star\n  2) calm-river\nNumbers to \
                delete, separated by spaces (none to delete nothing): ";
    let confirm = "Are you sure you want to delete 1 workroom(s): 'calm-river'? [y/N] ";

    for (typed, said) in [
        (
            "\n",
            format!("{list}Aborting. No workrooms were selected.\n"),
        ),
        (
            "2\nn\n",
            format!("{list}{confirm}Aborting. No workrooms were deleted.\n"),
        ),
    ] {
        let (code, stdout, stderr) = home.run_typing(&project, &["delete"], typed);
        assert_eq!((code, stderr.as_str()), (0, ""), "{typed:?}: {stdout}");
        assert_eq!(stdout, said, "{typed:?}");
        assert_eq!(home.config(), before, "{typed:?}");
    }

    let (code, stdout, stderr) = home.run_typing(&project, &["delete"], "2\ny\n");
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    assert!(
        stdout.starts_with(&format!("{list}{confirm}╭─ Teardown")),
        "{stdout:?}"
    );
    assert!(stdout.ends_with(DELETED), "{stdout:?}");
    assert!(!home.path("workrooms/calm-river").exists());
    assert!(home.path("workrooms/bright-star/.git").exists());
    assert!(home.config().contains("\"bright-star\""));
    assert!(!home.config().contains("\"calm-river\""));
}

/// A picked workroom whose folder holds no git checkout is only forgotten, as `delete NAME`
/// forgets one: its folder and files stay, no teardown runs, and the other workroom is untouched.
#[test]
fn a_picked_workroom_that_isnt_a_checkout_is_only_forgotten() {
    let home = Home::new("pick-orphan");
    let project = home.project(&["calm-river"], STOPPING_SHA256);
    let orphan = home.path("elsewhere/orphan");
    std::fs::create_dir_all(&orphan).expect("orphan");
    std::fs::write(orphan.join("notes"), "keep").expect("notes");
    let config = home.config().replacen(
        "\"workrooms\": {",
        &format!(
            "\"workrooms\": {{\"orphan\": {{\"path\": \"{}\"}}, ",
            orphan.display()
        ),
        1,
    );
    std::fs::write(home.config_path(), &config).expect("config");

    let (code, stdout, stderr) = home.run_typing(&project, &["delete"], "2\ny\n");
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    assert_eq!(
        stdout,
        "Select workrooms to delete:\n  1) calm-river\n  2) orphan\nNumbers to delete, separated \
         by spaces (none to delete nothing): Are you sure you want to delete 1 workroom(s): \
         'orphan'? [y/N] Workroom 'orphan' removed from Workroom. It is not a git worktree, so \
         no git or teardown ran.\nNote: its folder was left at ~/elsewhere/orphan. Delete it \
         manually if needed.\n"
    );
    assert_eq!(
        std::fs::read_to_string(orphan.join("notes")).expect("notes"),
        "keep"
    );
    assert!(!home.config().contains("\"orphan\""), "{}", home.config());
    assert!(home.config().contains("\"calm-river\""));
    assert!(home.path("workrooms/calm-river/.git").exists());
}

/// A picked config key that is no name, here `..`, is refused as `delete NAME` refuses it, before
/// it is joined onto the workrooms folder: no teardown runs and nothing is forgotten.
#[test]
fn a_picked_key_that_is_no_name_is_refused() {
    let home = Home::new("pick-no-name");
    let project = home.project(&["calm-river"], STOPPING_SHA256);
    let config = home.config().replacen(
        "\"workrooms\": {",
        &format!(
            "\"workrooms\": {{\"..\": {{\"path\": \"{}\"}}, ",
            home.path("workrooms/calm-river").display()
        ),
        1,
    );
    std::fs::write(home.config_path(), &config).expect("config");

    let (code, stdout, stderr) = home.run_typing(&project, &["delete"], "1\ny\n");
    assert_eq!(code, 3, "{stdout}{stderr}");
    assert_eq!(
        stdout,
        "Select workrooms to delete:\n  1) ..\n  2) calm-river\nNumbers to delete, separated by \
         spaces (none to delete nothing): Are you sure you want to delete 1 workroom(s): '..'? \
         [y/N] "
    );
    assert!(
        stderr.contains(
            "workroom name must be alphanumeric (dashes and underscores allowed), and must not \
             start or end with a dash or underscore: \"..\""
        ),
        "{stderr}"
    );
    assert_eq!(home.config(), config);
    assert!(home.path("workrooms/calm-river/.git").exists());
}

/// A teardown script this Mac hasn't approved is shown and asked about: a no cancels the delete
/// (exit 4) with nothing recorded or run, a yes records its digest and deletes.
#[test]
fn an_unapproved_teardown_is_shown_and_asked_about() {
    let home = Home::new("approve");
    let project = home.project(&["calm-river"], "deadbeef");
    let before = home.config();
    let shown = format!(
        "scripts/workroom_teardown in the project's root has not been approved on this Mac.\n\
         ╭─ scripts/workroom_teardown {}\n│ #!/bin/sh\n│ echo stopping\n╰{}\nApprove \
         scripts/workroom_teardown and run it? [y/N] ",
        "─".repeat(31),
        "─".repeat(59)
    );
    let args = ["delete", "calm-river", "--confirm", "calm-river"];

    let (code, stdout, stderr) = home.run_typing(&project, &args, "n\n");
    assert_eq!(code, 4, "{stdout}{stderr}");
    assert_eq!(stdout, shown);
    assert_eq!(
        stderr,
        "Error: operation cancelled: scripts/workroom_teardown was not approved\n"
    );
    assert_eq!(home.config(), before);
    assert!(home.path("workrooms/calm-river/.git").exists());

    let (code, stdout, stderr) = home.run_typing(&project, &args, "y\n");
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    assert!(stdout.starts_with(&shown), "{stdout:?}");
    assert!(
        stdout.contains("│ stopping\n"),
        "the teardown didn't run: {stdout:?}"
    );
    assert!(stdout.ends_with(DELETED), "{stdout:?}");
    assert!(
        home.config()
            .contains(&format!("\"workroom_teardown\": \"{STOPPING_SHA256}\"")),
        "{}",
        home.config()
    );
    assert!(!home.path("workrooms/calm-river").exists());
}

/// A registered project whose root has `scripts/workroom_setup`, `#!/bin/sh\n<body>`, untracked
/// and approved by nothing.
fn setup_project(home: &Home, body: &str) -> PathBuf {
    let project = home.repo();
    home.script(&project, "workroom_setup", &format!("#!/bin/sh\n{body}"));
    home.register(&project);
    project
}

/// The human create's success line for the workroom at `path`.
fn created(path: &Path) -> String {
    let name = path.file_name().expect("name").to_string_lossy();
    format!("Workroom '{name}' created successfully at ~/workrooms/{name}.\n")
}

/// The panel a create shows its setup script in before it asks, for `scripts/workroom_setup`
/// with `lines`.
fn approval(lines: &[&str]) -> String {
    let shown: String = lines.iter().map(|line| format!("│ {line}\n")).collect();
    format!(
        "scripts/workroom_setup in the project's root has not been approved on this Mac.\n\
         ╭─ scripts/workroom_setup {}\n{shown}╰{}\nApprove scripts/workroom_setup and run it? \
         [y/N] ",
        "─".repeat(34),
        "─".repeat(59)
    )
}

/// A setup script this Mac hasn't approved is shown and asked about before anything exists: a no
/// cancels the create (exit 4) with nothing made or recorded, and a yes records its digest before
/// the workroom is made, then runs it.
#[test]
fn create_asks_about_an_unapproved_setup_script() {
    let home = Home::new("create-approve");
    let project = setup_project(&home, "echo installing\n");
    let before = home.config();
    let shown = approval(&["#!/bin/sh", "echo installing"]);

    let (code, stdout, stderr) = home.run_typing(&project, &["create"], "n\n");
    assert_eq!(code, 4, "{stdout}{stderr}");
    assert_eq!(stdout, shown);
    assert_eq!(
        stderr,
        "Error: operation cancelled: scripts/workroom_setup was not approved\n"
    );
    assert_eq!(home.config(), before);
    assert_eq!(home.workroom(), None);
    assert_eq!(
        home.git_output(&project, &["branch", "--list", "workroom/*"]),
        ""
    );

    let (code, stdout, stderr) = home.run_typing(&project, &["c"], "y\n");
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    let workroom = home.workroom().expect("a workroom");
    let panel = format!(
        "╭─ Setup {}\n│ installing\n╰{}\n\n",
        "─".repeat(51),
        "─".repeat(59)
    );
    assert_eq!(stdout, format!("{shown}{panel}{}", created(&workroom)));
    assert!(
        home.config()
            .contains(&format!("\"workroom_setup\": \"{INSTALLING_SHA256}\"")),
        "{}",
        home.config()
    );
}

/// Input that ends before the answer gives up, as Go's prompt reports Ctrl-C: nothing is made or
/// recorded.
#[test]
fn create_given_no_answer_gives_up() {
    let home = Home::new("create-no-answer");
    let project = setup_project(&home, "echo installing\n");
    let before = home.config();
    let (code, stdout, stderr) = home.run_typing(&project, &["create"], "\x04");
    assert_eq!(code, 1, "{stdout}{stderr}");
    assert_eq!(stdout, approval(&["#!/bin/sh", "echo installing"]));
    assert_eq!(stderr, "Error: user aborted\n");
    assert_eq!(home.config(), before);
    assert_eq!(home.workroom(), None);
}

/// Work the start would leave out (here a commit on `main` origin lacks) is asked about, offering
/// only what applies: a choice that is no choice is asked again, the commits start the workroom
/// from the local branch, and leaving it out starts it from origin's, without a warning.
#[test]
fn create_asks_whether_to_include_work_the_start_leaves_out() {
    let asked = "You have 1 commit on main that you haven't pushed yet.\nNew workrooms start from \
                 what you've pushed. Include this work in the new one?\n  1) Include my \
                 commits\n  2) Leave it out\nChoose 1-2: ";
    for (typed, local) in [("x\n3\n1\n", true), ("2\n", false)] {
        let home = Home::new("create-start");
        home.git(
            &home.dir,
            &["init", "-q", "--bare", "-b", "main", "app.git"],
        );
        let project = home.repo();
        let origin = home.path("app.git");
        home.git(
            &project,
            &["remote", "add", "origin", &origin.to_string_lossy()],
        );
        home.git(&project, &["push", "-q", "-u", "origin", "main"]);
        home.git(&project, &["remote", "set-head", "origin", "main"]);
        home.commit(&project, "unpushed");
        home.register(&project);

        let (code, stdout, stderr) = home.run_typing(&project, &["create"], typed);
        assert_eq!((code, stderr.as_str()), (0, ""), "{typed:?}: {stdout}");
        let workroom = home.workroom().expect("a workroom");
        let again = "Choose 1-2: ".repeat(typed.lines().count() - 1);
        assert_eq!(
            stdout,
            format!("{asked}{again}{}", created(&workroom)),
            "{typed:?}"
        );
        let start = if local { "main" } else { "origin/main" };
        assert_eq!(
            home.git_output(&workroom, &["rev-parse", "HEAD"]),
            home.git_output(&project, &["rev-parse", start]),
            "{typed:?}"
        );
    }
}

/// A setup script's output is still read for a second after it exits (the runner's drain, which
/// a local setup script keeps), for a background job it left holding the output: what the job
/// prints within that second is shown, what it prints later is not, and the create doesn't wait
/// for it.
#[test]
fn create_reads_a_setup_scripts_output_for_a_second_after_it_exits() {
    let home = Home::new("create-drain");
    let body = "echo installing\n(sleep 0.2; echo soon) &\n(sleep 8; echo late) &\n";
    let project = setup_project(&home, body);
    let started = Instant::now();
    let (code, stdout, stderr) = home.run_typing(&project, &["create"], "y\n");
    let took = started.elapsed();
    assert_eq!((code, stderr.as_str()), (0, ""), "{stdout}");
    let shown = approval(&[
        "#!/bin/sh",
        "echo installing",
        "(sleep 0.2; echo soon) &",
        "(sleep 8; echo late) &",
    ]);
    let workroom = home.workroom().expect("a workroom");
    let panel = format!(
        "╭─ Setup {}\n│ installing\n│ soon\n╰{}\n\n",
        "─".repeat(51),
        "─".repeat(59)
    );
    assert_eq!(stdout, format!("{shown}{panel}{}", created(&workroom)));
    assert!(took < Duration::from_secs(6), "took {took:?}");
}
