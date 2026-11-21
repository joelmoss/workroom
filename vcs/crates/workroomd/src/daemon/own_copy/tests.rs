use super::*;

/// A folder of this test's own, removed with what is in it when the test ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("wr-own-copy-{name}-{}", std::process::id()));
        fs::create_dir(&dir).expect("a scratch folder of this run's own");
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const BUILD: &str = "aaaa";
const OTHER: &str = "bbbb";

/// A file standing in for a daemon binary of `build`: what `daemon_build_in` finds in it.
fn binary(at: &Path, build: &str) -> PathBuf {
    let marker = handoff::DAEMON_BUILD_MARKER;
    let prefix = &marker[..=marker.find(':').expect("a marker")];
    fs::write(at, format!("ELF bytes {prefix}{build}; more bytes")).expect("write a binary");
    at.to_path_buf()
}

#[test]
fn a_copy_is_made_in_a_folder_of_its_own_and_found_again_by_the_next_start() {
    let scratch = Scratch::new("made");
    let source = binary(&scratch.0.join("workroom"), BUILD);
    let dir = scratch.0.join("d.bin");
    let kept = establish(&dir, &source, BUILD).expect("a copy");
    assert_eq!(kept.path, dir.join("workroom-aaaa"));
    assert_eq!(fs::read(&kept.path).unwrap(), fs::read(&source).unwrap());
    assert_eq!(fs::read_to_string(dir.join(OWNER)).unwrap(), OWNER_TEXT);
    let inode = fs::metadata(&kept.path).unwrap().ino();
    drop(kept);

    // The source gone, as an update takes it away: the copy is found, not made again.
    fs::remove_file(&source).unwrap();
    let again = establish(&dir, &source, BUILD).expect("the copy again");
    assert_eq!(fs::metadata(&again.path).unwrap().ino(), inode);
}

#[test]
fn a_source_that_is_not_this_daemon_build_is_never_copied() {
    let scratch = Scratch::new("wrong");
    // A downgrade's Go CLI at the daemon's path: no daemon build in it at all.
    let source = scratch.0.join("workroom");
    fs::write(&source, "a Go CLI").unwrap();
    let dir = scratch.0.join("d.bin");
    assert!(establish(&dir, &source, BUILD).is_err());
    assert!(!dir.join("workroom-aaaa").exists());
    let left: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert_eq!(
        left,
        vec![std::ffi::OsString::from(OWNER)],
        "a staged file was left"
    );
}

#[test]
fn a_folder_this_code_did_not_make_is_neither_used_nor_swept() {
    let scratch = Scratch::new("foreign");
    let source = binary(&scratch.0.join("workroom"), BUILD);
    let dir = scratch.0.join("d.bin");
    fs::create_dir(&dir).unwrap();
    let theirs = binary(&dir.join("workroom-bbbb"), OTHER);
    assert!(establish(&dir, &source, BUILD).is_err());
    sweep(&dir, "workroom-aaaa");
    assert!(
        theirs.exists(),
        "a file in someone else's folder was removed"
    );
}

#[test]
fn a_sweep_removes_only_another_builds_copy_that_no_daemon_holds() {
    let scratch = Scratch::new("sweep");
    let source = binary(&scratch.0.join("workroom"), BUILD);
    let dir = scratch.0.join("d.bin");
    let _ours = establish(&dir, &source, BUILD).expect("a copy");
    let unheld = binary(&dir.join("workroom-bbbb"), OTHER);
    let held = binary(&dir.join("workroom-cccc"), "cccc");
    let holder = File::open(&held).unwrap();
    assert!(lock(&holder, libc::LOCK_SH));
    // Named like a copy, and not one: its marker names another build, or none.
    let misnamed = binary(&dir.join("workroom-dddd"), OTHER);
    let plain = dir.join("workroom-eeee");
    fs::write(&plain, "notes").unwrap();
    let elsewhere = dir.join("README");
    fs::write(&elsewhere, "the user's").unwrap();
    // Staged by a process that is gone, and by one that is not (this one, standing in).
    let orphan = dir.join(".workroom-bbbb.999999999");
    fs::write(&orphan, "half").unwrap();
    let live = dir.join(format!(
        ".workroom-bbbb.{}",
        std::os::unix::process::parent_id()
    ));
    fs::write(&live, "half").unwrap();

    sweep(&dir, "workroom-aaaa");
    assert!(!unheld.exists(), "an unheld copy of another build stayed");
    assert!(held.exists(), "a copy a daemon holds was removed");
    assert!(misnamed.exists() && plain.exists() && elsewhere.exists());
    assert!(
        dir.join("workroom-aaaa").exists(),
        "the daemon's own copy was removed"
    );
    assert!(!orphan.exists(), "a dead process's staged copy stayed");
    assert!(live.exists(), "a live process's staged copy was removed");
}

#[test]
fn a_symlink_is_never_a_copy() {
    let scratch = Scratch::new("link");
    let target = binary(&scratch.0.join("target"), OTHER);
    let source = binary(&scratch.0.join("workroom"), BUILD);
    let dir = scratch.0.join("d.bin");
    let _ours = establish(&dir, &source, BUILD).expect("a copy");
    std::os::unix::fs::symlink(&target, dir.join("workroom-bbbb")).unwrap();
    sweep(&dir, "workroom-aaaa");
    assert!(fs::symlink_metadata(dir.join("workroom-bbbb")).is_ok());
    assert!(target.exists());
}
