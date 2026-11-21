//! `workroom delete` asked by a person at a terminal (#678): with no `--confirm` it asks, with no
//! name it offers the project's workrooms to pick, and a teardown script this Mac hasn't approved
//! is shown and asked about. Each answer is typed into a real pty, the binary's stdin, so the
//! binary sees a terminal as it does in one; what it writes goes to a pipe.
//!
//! The contract suite (`commands_contract.rs`) runs against the Go CLI too, whose prompts are a
//! full-screen form (charmbracelet/huh) no line of input drives, so these run against this crate's
//! binary only. Each run gets a throwaway HOME and config, as the contract suite's do.
#![cfg(target_os = "macos")]

use std::io::Write;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The digest of `#!/bin/sh\necho stopping\n`, the teardown each project here has.
const STOPPING_SHA256: &str = "46afe9251fa214a976ea23e0094166dceb1f79f39ef879bd4cc3d59b26808059";

/// A throwaway HOME, removed when the test ends; one this run made itself, never a leftover.
struct Home {
    dir: PathBuf,
}

impl Home {
    fn new(name: &str) -> Home {
        let parent = std::env::temp_dir();
        for attempt in 0u32.. {
            let dir = parent.join(format!(
                "workroom-delete-tty-{name}-{}-{attempt}",
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

    /// A registered project with an approved (or, with another `digest`, unapproved) teardown
    /// script, and a real workroom for each of `names` under `~/workrooms`.
    fn project(&self, names: &[&str], digest: &str) -> PathBuf {
        let project = self.path("src/app");
        std::fs::create_dir_all(project.join("scripts")).expect("project");
        self.git(&project, &["init", "-q", "-b", "main"]);
        self.git(
            &project,
            &[
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "first",
            ],
        );
        let script = project.join("scripts/workroom_teardown");
        std::fs::write(&script, "#!/bin/sh\necho stopping\n").expect("teardown");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");
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
    /// typed into it: (exit code, stdout, stderr).
    fn run_typing(&self, cwd: &Path, args: &[&str], typed: &str) -> (i32, String, String) {
        let (primary, secondary) = pty();
        let mut keyboard = std::fs::File::from(primary);
        keyboard.write_all(typed.as_bytes()).expect("type");
        let output = self
            .command(env!("CARGO_BIN_EXE_workroom"), cwd)
            .args(args)
            .stdin(Stdio::from(secondary))
            .output()
            .expect("run workroom");
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
