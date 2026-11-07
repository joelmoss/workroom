use super::*;

#[test]
fn a_leading_tilde_is_the_users_home() {
    let home = Path::new("/home/vscode");
    assert_eq!(
        expand_home(Path::new("~/.local/state/screens"), home),
        PathBuf::from("/home/vscode/.local/state/screens")
    );
    assert_eq!(
        expand_home(Path::new("~"), home),
        PathBuf::from("/home/vscode")
    );
    assert_eq!(expand_home(Path::new("/abs"), home), PathBuf::from("/abs"));
    assert_eq!(
        expand_home(Path::new("~other/x"), home),
        PathBuf::from("~other/x")
    );
}

// Value: protects=a daemon already running as its user (a hand-off's new program, after the drop) only makes the folders and keeps its environment;
// fails_when=become_user chowns, drops credentials or rewrites HOME for an account that is already this process, or leaves a folder unmade;
// why_new=only the live container suites reach become_user, as root; seam=none; no_claim=the root drop itself (needs root)
#[test]
fn an_account_that_is_already_this_process_only_makes_its_folders() {
    // SAFETY: getuid takes nothing and cannot fail.
    let account = lookup(&unsafe { libc::getuid() }.to_string()).unwrap();
    let root = std::env::temp_dir().join(format!("workroomd-become-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let home = std::env::var_os("HOME");

    become_user(
        &account,
        &[(root.join("a/b"), true), (root.join("c"), false)],
    )
    .unwrap();

    assert!(root.join("a/b").is_dir() && root.join("c").is_dir());
    assert_eq!(std::env::var_os("HOME"), home);
    let _ = std::fs::remove_dir_all(&root);
}

/// The account running the tests, found by its name and by its uid, the same either way; a uid
/// with a group overrides the group; a uid nobody has is still an account, rooted at `/`.
#[test]
fn an_account_is_found_by_name_or_uid() {
    // SAFETY: getuid takes nothing and cannot fail.
    let uid = unsafe { libc::getuid() };
    let by_uid = lookup(&uid.to_string()).unwrap();
    let by_name = lookup(&by_uid.name).unwrap();
    assert_eq!(by_uid, by_name);
    assert!(by_uid.home.is_absolute());
    assert_eq!(lookup(&format!("{uid}:4242")).unwrap().gid, 4242);
    // A named group, as `USER app:app` names one: gid 0's, which every system has.
    // SAFETY: getgrgid's static result is read before anything else calls it.
    let root_group = unsafe { CStr::from_ptr((*libc::getgrgid(0)).gr_name) }
        .to_string_lossy()
        .into_owned();
    assert_eq!(lookup(&format!("{uid}:{root_group}")).unwrap().gid, 0);
    assert!(lookup(&format!("{uid}:no-such-group-workroom")).is_err());
    let nobody = lookup("4000000").unwrap();
    assert_eq!((nobody.uid, nobody.home), (4_000_000, PathBuf::from("/")));
    assert!(lookup("no-such-user-workroom").is_err());
}
