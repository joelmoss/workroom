use super::*;

/// A folder of this test's own, removed with what is in it when the test ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("wr-bin-dir-{name}-{}", std::process::id()));
        fs::create_dir(&dir).expect("a scratch folder of this run's own");
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// The folder holds one entry, the link, which a second pointing replaces in place.
#[test]
fn the_link_is_the_folders_one_entry_and_is_re_pointed_in_place() {
    let scratch = Scratch::new("relink");
    let folder = scratch.0.join("path");
    own_subfolder(&folder).expect("the folder");
    let first = scratch.0.join("workroom-aaaa");
    let second = scratch.0.join("workroom-bbbb");
    fs::write(&first, "a").unwrap();
    fs::write(&second, "b").unwrap();

    relink(&folder, &first).expect("pointed");
    assert_eq!(fs::read_link(folder.join(LINK)).unwrap(), first);
    relink(&folder, &second).expect("re-pointed");
    assert_eq!(fs::read_link(folder.join(LINK)).unwrap(), second);
    assert_eq!(names(&folder), vec![LINK.to_string()]);
    // Pointing it where it points already changes nothing.
    relink(&folder, &second).expect("unchanged");
    assert_eq!(names(&folder), vec![LINK.to_string()]);
}

/// A `workroom` that is not a symlink was not made by this code, and is left as it is.
#[test]
fn a_workroom_that_is_not_a_link_is_never_replaced() {
    let scratch = Scratch::new("foreign");
    let folder = scratch.0.join("path");
    own_subfolder(&folder).expect("the folder");
    fs::write(folder.join(LINK), "the user's").unwrap();
    assert!(relink(&folder, &scratch.0.join("target")).is_err());
    assert_eq!(fs::read_to_string(folder.join(LINK)).unwrap(), "the user's");
    assert_eq!(names(&folder), vec![LINK.to_string()]);
}

/// A folder in the bin folder's place that is a symlink is not one this code made.
#[test]
fn a_symlink_in_the_folders_place_is_not_the_folder() {
    let scratch = Scratch::new("linked");
    let elsewhere = scratch.0.join("elsewhere");
    fs::create_dir(&elsewhere).unwrap();
    std::os::unix::fs::symlink(&elsewhere, scratch.0.join("path")).unwrap();
    assert!(own_subfolder(&scratch.0.join("path")).is_err());
}

/// Only a staged link whose process is gone is removed; a live process's, and a file of the same
/// shape, stay.
#[test]
fn a_sweep_removes_only_a_dead_processs_staged_link() {
    let scratch = Scratch::new("sweep");
    let folder = scratch.0.join("path");
    own_subfolder(&folder).expect("the folder");
    let dead = folder.join(format!(".{LINK}.999999999"));
    std::os::unix::fs::symlink("/nowhere", &dead).unwrap();
    let live = folder.join(format!(".{LINK}.{}", std::os::unix::process::parent_id()));
    std::os::unix::fs::symlink("/nowhere", &live).unwrap();
    let file = folder.join(format!(".{LINK}.999999998"));
    fs::write(&file, "not a link").unwrap();

    sweep_staged(&folder);
    assert!(
        fs::symlink_metadata(&dead).is_err(),
        "a dead process's link stayed"
    );
    assert!(fs::symlink_metadata(&live).is_ok());
    assert!(file.exists());
}

/// The hooks are written, and written again only when their text changed.
#[test]
fn the_hooks_are_written_where_the_sessions_look_for_them() {
    let scratch = Scratch::new("hooks");
    let hooks = scratch.0.join("shell");
    write_hooks(&hooks).expect("written");
    assert_eq!(
        fs::read_to_string(hooks.join(ZSH_DIR).join(".zshenv")).unwrap(),
        ZSH_HOOK
    );
    assert_eq!(
        fs::read_to_string(hooks.join(BASH_FILE)).unwrap(),
        BASH_HOOK
    );
    assert_eq!(
        fs::read_to_string(hooks.join(FISH_FILE)).unwrap(),
        FISH_HOOK
    );
    fs::write(hooks.join(BASH_FILE), "an older start's").unwrap();
    write_hooks(&hooks).expect("written again");
    assert_eq!(
        fs::read_to_string(hooks.join(BASH_FILE)).unwrap(),
        BASH_HOOK
    );
    assert_eq!(
        names(&hooks.join("bash")),
        vec!["workroom.bash".to_string()]
    );
}
