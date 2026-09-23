use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use wr_vcs_git::{self as vcs, diff};
use wr_vcs_model::{ChangeKind, LineStats, PushState};

struct Repo(PathBuf);
impl Repo {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "wr-agent-git-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        let repo = Self(path);
        repo.git(&["init", "-b", "main"]);
        repo.git(&["config", "user.name", "Test"]);
        repo.git(&["config", "user.email", "test@example.com"]);
        repo
    }
    fn git(&self, args: &[&str]) -> String {
        // Per-child-process overrides, not `std::env::set_var` — isolates this test's git config
        // from the developer's real one (an ambient `init.defaultBranch`, alias, or hook would
        // otherwise make these tests machine-dependent) without racing other tests' concurrently
        // spawned git children over the process-wide environment.
        String::from_utf8(
            diff::run_with_env(
                &self.0,
                "git",
                args,
                &[
                    ("GIT_CONFIG_GLOBAL", "/dev/null"),
                    ("GIT_CONFIG_SYSTEM", "/dev/null"),
                ],
            )
            .unwrap(),
        )
        .unwrap()
    }
    fn write(&self, path: &str, text: &str) {
        std::fs::write(self.0.join(path), text).unwrap();
    }
    fn commit(&self) -> String {
        self.git(&["add", "."]);
        self.git(&[
            "commit",
            "-m",
            "subject\n\nbody\nCo-authored-by: Ada <ada@example.com>",
        ]);
        self.git(&["rev-parse", "HEAD"]).trim().into()
    }
}
impl Drop for Repo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn unborn_history_and_root_commit_reads() {
    let repo = Repo::new();
    assert!(vcs::log_page(&repo.0, 10).unwrap().commits.is_empty());
    assert_eq!(
        vcs::current_ref(&repo.0).unwrap().name.as_deref(),
        Some("main")
    );
    repo.write("hello", "hello\n");
    let id = repo.commit();
    let page = vcs::log_page(&repo.0, 1).unwrap();
    assert!(page.reached_end);
    assert_eq!(page.commits[0].authors.len(), 2);
    assert_eq!(page.commits[0].push_state, PushState::Unknown);
    assert!(!vcs::log_page(&repo.0, 0).unwrap().reached_end);
    let change = vcs::changeset(&repo.0, &id).unwrap();
    assert_eq!(
        change.files[0].line_stats,
        Some(LineStats {
            insertions: 1,
            deletions: 0
        })
    );
    assert!(diff::committed_patch(&repo.0, &change.commit, "hello")
        .unwrap()
        .contains("+hello"));
    assert_eq!(
        vcs::file_content(&repo.0, &id, "hello", false)
            .unwrap()
            .as_deref(),
        Some("hello\n")
    );
    assert_eq!(
        vcs::file_content(&repo.0, &id, "hello", true).unwrap(),
        None
    );
}

#[test]
fn copied_file_patch_excludes_modified_source_and_counts_match_git() {
    let repo = Repo::new();
    repo.git(&["config", "diff.renames", "copies"]);
    let source: String = (0..30).map(|i| format!("line {i}\n")).collect();
    repo.write("source", &source);
    repo.commit();
    repo.write("destination", &source);
    repo.write("source", &format!("{source}changed\n"));
    let id = repo.commit();
    let change = vcs::changeset(&repo.0, &id).unwrap();
    let copied = change
        .files
        .iter()
        .find(|f| f.path == "destination")
        .unwrap();
    assert_eq!(copied.kind, ChangeKind::Copied);
    assert_eq!(
        copied.line_stats,
        Some(LineStats {
            insertions: 0,
            deletions: 0
        })
    );
    let patch = diff::committed_patch(&repo.0, &change.commit, "destination").unwrap();
    assert!(patch.contains("copy from source"));
    assert!(!patch.contains("+changed"));
    assert_eq!(patch.matches("diff --git ").count(), 1);
}

/// One file's patch must not depend on the rest of the comparison: a sibling with non-UTF-8 text
/// (which git still diffs as text) or a sibling whose patch alone passes `MAX_OUTPUT` used to fail
/// every file in the commit, because the whole comparison was read and decoded.
#[test]
fn a_file_patch_survives_a_non_utf8_or_oversized_sibling() {
    let repo = Repo::new();
    repo.write("small", "one\n");
    repo.commit();
    repo.write("small", "two\n");
    std::fs::write(repo.0.join("latin1"), b"caf\xe9\n").unwrap();
    let big: String = (0..300_000).map(|i| format!("line {i:030}\n")).collect();
    assert!(big.len() > 8 * 1024 * 1024);
    repo.write("big", &big);
    let id = repo.commit();
    let change = vcs::changeset(&repo.0, &id).unwrap();
    let patch = diff::committed_patch(&repo.0, &change.commit, "small").unwrap();
    assert!(patch.contains("-one") && patch.contains("+two"));
    assert_eq!(patch.matches("diff --git ").count(), 1);
}

/// `.git/config` is not versioned and so not trusted: a filter driver defined there runs its
/// `clean` command during `status` and a working-tree `diff` for any stat-dirty file it selects.
/// The edit keeps the size unchanged, so git has to hash the file, which is when it filters.
#[test]
fn a_repository_filter_driver_never_runs_during_reads() {
    let repo = Repo::new();
    let marker = repo.0.join("ran");
    repo.write(".gitattributes", "file filter=evil\n");
    repo.write("file", "base\n");
    repo.commit();
    // Configured after the commit, so the fixture's own `git add` never runs it.
    let clean = format!("touch '{}'; cat", marker.display());
    repo.git(&["config", "filter.evil.clean", &clean]);
    std::thread::sleep(std::time::Duration::from_millis(1100));
    repo.write("file", "bass\n");
    let status = diff::working_status(&repo.0).unwrap();
    assert!(status.files.iter().any(|f| f.path == "file"));
    assert!(diff::working_patch(&repo.0, "file")
        .unwrap()
        .contains("+bass"));
    assert!(
        !marker.exists(),
        "a filter from .git/config ran during a read"
    );
}

/// `[filter ""]` is a valid driver (`filter=` selects it), and an empty name is exactly what a
/// `.+` in the key pattern would have skipped.
#[test]
fn an_empty_named_repository_filter_driver_never_runs_during_reads() {
    let repo = Repo::new();
    let marker = repo.0.join("ran");
    repo.write(".gitattributes", "file filter=\n");
    repo.write("file", "base\n");
    repo.commit();
    let config = repo.0.join(".git/config");
    let mut text = std::fs::read_to_string(&config).unwrap();
    text.push_str(&format!(
        "[filter \"\"]\n\tclean = \"touch '{}'; cat\"\n",
        marker.display()
    ));
    std::fs::write(&config, text).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    repo.write("file", "bass\n");
    diff::working_status(&repo.0).unwrap();
    assert!(diff::working_patch(&repo.0, "file")
        .unwrap()
        .contains("+bass"));
    assert!(!marker.exists(), "an empty-named driver ran during a read");
}

/// A submodule's config lives under the superproject's untrusted `.git/modules/`, and a
/// working-tree `status`/`diff` runs a `status` inside every submodule, which applies its filters.
#[test]
fn a_submodule_filter_driver_never_runs_during_reads() {
    let sub = Repo::new();
    sub.write(".gitattributes", "file filter=evil\n");
    sub.write("file", "base\n");
    sub.commit();
    let repo = Repo::new();
    repo.write("top", "top\n");
    repo.commit();
    repo.git(&[
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        sub.0.to_str().unwrap(),
        "sub",
    ]);
    repo.commit();
    let marker = repo.0.join("ran");
    let clean = format!("touch '{}'; cat", marker.display());
    diff::run_with_env(
        &repo.0.join("sub"),
        "git",
        &["config", "filter.evil.clean", &clean],
        &[
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ("GIT_CONFIG_SYSTEM", "/dev/null"),
        ],
    )
    .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    std::fs::write(repo.0.join("sub/file"), "bass\n").unwrap();
    diff::working_status(&repo.0).unwrap();
    assert!(!marker.exists(), "a submodule's filter ran during a read");
}

#[test]
fn rename_newline_path_and_missing_final_newline() {
    let repo = Repo::new();
    repo.write("old", "one\ntwo\n");
    repo.commit();
    repo.git(&["mv", "old", "new\twith\nnewline"]);
    repo.write("new\twith\nnewline", "one\ntwo");
    let id = repo.commit();
    let change = vcs::changeset(&repo.0, &id).unwrap();
    assert_eq!(change.files.len(), 1);
    assert_eq!(change.files[0].path, "new\twith\nnewline");
    assert_eq!(
        change.files[0].line_stats,
        Some(LineStats {
            insertions: 1,
            deletions: 1
        })
    );
    assert!(
        diff::committed_patch(&repo.0, &change.commit, &change.files[0].path)
            .unwrap()
            .contains("No newline")
    );
}

#[test]
fn working_status_combines_staged_and_unstaged_and_keeps_untracked() {
    let repo = Repo::new();
    repo.write("file", "base\n");
    repo.commit();
    repo.write("file", "staged\n");
    repo.git(&["add", "file"]);
    repo.write("file", "final\n");
    repo.write("untracked", "new\n");
    let status = diff::working_status(&repo.0).unwrap();
    assert_eq!(status.files.len(), 2);
    assert_eq!(status.untracked, vec!["untracked"]);
    let patch = diff::working_patch(&repo.0, "file").unwrap();
    assert!(patch.contains("-base") && patch.contains("+final") && !patch.contains("staged"));
    assert!(diff::working_patch(&repo.0, "untracked")
        .unwrap()
        .contains("+new"));
}

#[test]
fn origin_scope_excludes_other_remotes() {
    let repo = Repo::new();
    repo.write("file", "base\n");
    let first = repo.commit();
    repo.git(&["remote", "add", "origin", "."]);
    repo.git(&["update-ref", "refs/remotes/origin/main", &first]);
    repo.write("file", "next\n");
    let second = repo.commit();
    repo.git(&["update-ref", "refs/remotes/backup/main", &second]);
    let page = vcs::log_page(&repo.0, 10).unwrap();
    assert_eq!(page.commits[0].push_state, PushState::Unpushed);
    assert_eq!(page.commits[1].push_state, PushState::Pushed);
    assert_eq!(page.push_scope.unwrap().count, 1);
}

#[test]
fn annotated_tags_and_local_branches_are_the_only_decorations() {
    let repo = Repo::new();
    repo.write("file", "base\n");
    let id = repo.commit();
    repo.git(&["tag", "-a", "v1", "-m", "release"]);
    repo.git(&["branch", "aaa"]);
    repo.git(&["update-ref", "refs/remotes/origin/main", &id]);
    assert_eq!(
        vcs::log_page(&repo.0, 1).unwrap().commits[0].refs,
        vec!["aaa", "main", "v1"]
    );
}

#[test]
fn configured_no_renames_and_type_changes_keep_unique_files() {
    let repo = Repo::new();
    repo.write("old", "base\n");
    repo.write("link", "regular\n");
    repo.commit();
    repo.git(&["config", "diff.renames", "false"]);
    repo.git(&["mv", "old", "new"]);
    std::fs::remove_file(repo.0.join("link")).unwrap();
    std::os::unix::fs::symlink("new", repo.0.join("link")).unwrap();
    let id = repo.commit();
    let change = vcs::changeset(&repo.0, &id).unwrap();
    assert_eq!(change.files.len(), 3);
    assert_eq!(change.files.iter().filter(|f| f.path == "link").count(), 1);
    assert_eq!(
        change.files.iter().find(|f| f.path == "new").unwrap().kind,
        ChangeKind::Added
    );
    // Git emits two patch sections for a typechange; the UI expects both under one file row.
    let patch = diff::committed_patch(&repo.0, &change.commit, "link").unwrap();
    assert!(patch.contains("deleted file mode") && patch.contains("new file mode"));
}

#[test]
fn conflict_working_patch_uses_head_and_materialized_markers() {
    let repo = Repo::new();
    repo.write("file", "base\n");
    repo.commit();
    repo.git(&["checkout", "-b", "side"]);
    repo.write("file", "side\n");
    repo.commit();
    repo.git(&["checkout", "main"]);
    repo.write("file", "main\n");
    repo.commit();
    assert!(diff::run(&repo.0, "git", &["merge", "side"]).is_err());
    let status = diff::working_status(&repo.0).unwrap();
    assert!(status.conflicted);
    assert_eq!(status.files.len(), 1);
    let patch = diff::working_patch(&repo.0, "file").unwrap();
    assert!(patch.contains("+<<<<<<<"));
}
