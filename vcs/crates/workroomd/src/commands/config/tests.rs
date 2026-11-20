use std::os::unix::fs::PermissionsExt;

use super::*;
use crate::commands::{Platform, Scratch};

/// A config file, not yet made, in a directory not yet made, inside `scratch`.
fn config_in(scratch: &Scratch) -> Config {
    Config {
        path: scratch.0.join("nested/config.json"),
    }
}

fn context(env: fn(&str) -> Option<String>) -> Context {
    Context {
        json: true,
        pretend: false,
        verbose: false,
        platform: Platform::Mac,
        env,
        color: false,
    }
}

#[test]
fn the_path_is_workroom_config_else_under_home() {
    let config = Config::new(&context(|name| {
        (name == "WORKROOM_CONFIG").then(|| "/x/c.json".to_string())
    }))
    .unwrap();
    assert_eq!(config.path(), Path::new("/x/c.json"));
    let config = Config::new(&context(|name| match name {
        "WORKROOM_CONFIG" => Some(String::new()),
        "HOME" => Some("/Users/dev".to_string()),
        _ => None,
    }))
    .unwrap();
    assert_eq!(
        config.path(),
        Path::new("/Users/dev/.config/workroom/config.json")
    );
    let error = Config::new(&context(|_| None)).map(|_| ()).unwrap_err();
    assert_eq!(error.kind, Kind::InternalError);
}

#[test]
fn a_missing_file_reads_as_an_empty_object_and_a_bad_one_fails() {
    let scratch = Scratch::new("read");
    let config = config_in(&scratch);
    assert_eq!(config.read().unwrap(), Json::Object(Object::new()));
    std::fs::create_dir_all(config.path().parent().unwrap()).unwrap();
    std::fs::write(config.path(), "{} x").unwrap();
    let error = config.read().unwrap_err();
    assert_eq!(error.kind, Kind::ConfigReadFailed);
    assert_eq!(
        error.message,
        format!(
            "failed to read config {}: unexpected data after the config object",
            config.path().display()
        )
    );
}

#[test]
fn a_write_makes_the_directory_and_leaves_a_0644_file_and_no_temporary_one() {
    let scratch = Scratch::new("write");
    let config = config_in(&scratch);
    config.set_global_base_branch("main").unwrap();
    let dir = config.path().parent().unwrap();
    assert_eq!(
        std::fs::read_to_string(config.path()).unwrap(),
        "{\n  \"base_branch\": \"main\"\n}"
    );
    let mode = std::fs::metadata(config.path())
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o644);
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    // The lock file stays: another process may be waiting on it.
    assert_eq!(names, ["config.json", "config.json.lock"]);
}

#[test]
fn clearing_the_global_base_of_a_null_config_writes_null_as_go_does() {
    let scratch = Scratch::new("null");
    let config = config_in(&scratch);
    std::fs::create_dir_all(config.path().parent().unwrap()).unwrap();
    std::fs::write(config.path(), "null").unwrap();
    config.set_global_base_branch("").unwrap();
    assert_eq!(std::fs::read_to_string(config.path()).unwrap(), "null");
    // Setting one makes it an object, where Go would panic on its nil map.
    config.set_global_base_branch("main").unwrap();
    assert_eq!(
        std::fs::read_to_string(config.path()).unwrap(),
        "{\n  \"base_branch\": \"main\"\n}"
    );
}

#[test]
fn a_projects_vcs_is_set_only_when_it_is_registered() {
    let scratch = Scratch::new("vcs");
    let config = config_in(&scratch);
    std::fs::create_dir_all(config.path().parent().unwrap()).unwrap();
    std::fs::write(config.path(), r#"{"/p": {"vcs": "jj", "x": 1}}"#).unwrap();
    config.set_project_vcs("/p", "git").unwrap();
    assert_eq!(
        std::fs::read_to_string(config.path()).unwrap(),
        "{\n  \"/p\": {\n    \"vcs\": \"git\",\n    \"x\": 1\n  }\n}"
    );
    let before = std::fs::metadata(config.path())
        .unwrap()
        .modified()
        .unwrap();
    config.set_project_vcs("/elsewhere", "git").unwrap();
    assert_eq!(
        std::fs::metadata(config.path())
            .unwrap()
            .modified()
            .unwrap(),
        before,
        "an unregistered project is never written"
    );
}

#[test]
fn projects_decode_leniently() {
    let data = json::parse_config(
        br#"{"channel":"pre","/a":{"vcs":5,"host":null,"workrooms":{"w":{"path":"/w","host":{}},"bad":3}},"/b":{}}"#,
    )
    .unwrap();
    let projects = all_projects(&data);
    assert_eq!(projects.keys().collect::<Vec<_>>(), ["/a", "/b"]);
    let a = &projects["/a"];
    assert_eq!(a.vcs, "", "a vcs of the wrong type reads as none");
    assert!(a.host.is_none(), "a null host is no host");
    assert_eq!(a.entries, 2);
    assert_eq!(a.workrooms.len(), 1);
    assert!(a.workrooms["w"].is_remote(), "any host but null is remote");
    assert!(!a.workrooms["w"].host_destroyed());
    assert_eq!(projects["/b"].entries, 0);
}

#[test]
fn the_current_project_is_the_one_at_or_holding_the_directory() {
    let data =
        json::parse_config(br#"{"/a":{"workrooms":{"w":{"path":"/wr/w"}}},"/b":{"workrooms":{}}}"#)
            .unwrap();
    assert_eq!(find_current_project(&data, "/b").unwrap().0, "/b");
    assert_eq!(find_current_project(&data, "/wr/w").unwrap().0, "/a");
    assert!(find_current_project(&data, "/nowhere").is_none());
}

#[test]
fn paths_clean_as_gos_filepath_does() {
    for (path, cleaned) in [
        ("", "."),
        ("/", "/"),
        ("//a//b/", "/a/b"),
        ("/a/./b/../c", "/a/c"),
        ("/../a", "/a"),
        ("a/../..", ".."),
        ("../../a", "../../a"),
        ("a/..", "."),
    ] {
        assert_eq!(clean(path), cleaned, "{path:?}");
    }
    assert_eq!(join("/Users/dev/", "/workrooms"), "/Users/dev/workrooms");
    assert_eq!(join("/Users/dev", ""), "/Users/dev");
}

#[test]
fn the_workrooms_dir_expands_a_tilde() {
    let home = context(|name| (name == "HOME").then(|| "/Users/dev".to_string()));
    let data = json::parse_config(br#"{"workrooms_dir":"~/rooms"}"#).unwrap();
    assert_eq!(workrooms_dir(&data, &home).unwrap(), "/Users/dev/rooms");
    let data = json::parse_config(br#"{"workrooms_dir":""}"#).unwrap();
    assert_eq!(workrooms_dir(&data, &home).unwrap(), "/Users/dev/workrooms");
    let data = json::parse_config(br#"{"workrooms_dir":"/abs/~"}"#).unwrap();
    assert_eq!(workrooms_dir(&data, &home).unwrap(), "/abs/~");
}

#[test]
fn a_canonical_path_resolves_what_exists_and_cleans_what_doesnt() {
    let scratch = Scratch::new("canonical");
    let real = scratch.0.join("real");
    std::fs::create_dir(&real).unwrap();
    std::os::unix::fs::symlink(&real, scratch.0.join("link")).unwrap();
    let none = context(|_| None);
    let link = format!("{}/link/", scratch.0.display());
    assert_eq!(
        canonical_path(&link, &none).unwrap(),
        real.to_string_lossy()
    );
    let missing = format!("{}/link/../gone/./x", scratch.0.display());
    assert_eq!(
        canonical_path(&missing, &none).unwrap(),
        format!("{}/gone/x", scratch.0.display())
    );
    let home = context(|name| (name == "HOME").then(|| "/nonexistent-home".to_string()));
    assert_eq!(
        canonical_path("~/src", &home).unwrap(),
        "/nonexistent-home/src"
    );
}

#[test]
fn symlinks_resolve_as_gos_eval_symlinks_resolves_them() {
    let scratch = Scratch::new("eval-symlinks");
    let root = scratch.0.to_string_lossy().into_owned();
    std::fs::create_dir_all(scratch.0.join("real/sub")).unwrap();
    std::fs::write(scratch.0.join("file"), "").unwrap();
    // A relative link resolves against its own directory; an absolute one from the root.
    std::os::unix::fs::symlink("real/sub", scratch.0.join("rel")).unwrap();
    std::os::unix::fs::symlink(scratch.0.join("real"), scratch.0.join("abs")).unwrap();
    std::os::unix::fs::symlink("loop", scratch.0.join("loop")).unwrap();
    for (path, resolved) in [
        (format!("{root}/rel"), format!("{root}/real/sub")),
        (format!("{root}/rel/.."), format!("{root}/real")),
        (format!("{root}/abs/./sub/"), format!("{root}/real/sub")),
        (format!("{root}/real/../abs"), format!("{root}/real")),
    ] {
        assert_eq!(eval_symlinks(&path).unwrap(), resolved, "{path}");
    }
    for path in [
        format!("{root}/gone"),
        format!("{root}/file/x"),
        format!("{root}/loop"),
    ] {
        assert!(eval_symlinks(&path).is_err(), "{path}");
    }
    assert_eq!(
        eval_symlinks(&format!("{root}/file/x"))
            .unwrap_err()
            .raw_os_error(),
        Some(libc::ENOTDIR)
    );
}

/// macOS's disk is case-insensitive: Go names a directory as it was given, where realpath would
/// name it as it is on disk, and config keys are compared byte for byte.
#[cfg(target_os = "macos")]
#[test]
fn a_canonical_path_keeps_the_case_it_was_given() {
    let scratch = Scratch::new("canonical-case");
    std::fs::create_dir(scratch.0.join("CaseProj")).unwrap();
    std::os::unix::fs::symlink("CaseProj", scratch.0.join("Link")).unwrap();
    let none = context(|_| None);
    let root = scratch.0.display();
    assert_eq!(
        canonical_path(&format!("{root}/caseproj"), &none).unwrap(),
        format!("{root}/caseproj")
    );
    assert_eq!(
        canonical_path(&format!("{root}/LINK/"), &none).unwrap(),
        format!("{root}/CaseProj"),
        "a link's target is named as the link names it"
    );
}

#[test]
fn config_errors_are_worded_as_go_wraps_them() {
    let scratch = Scratch::new("errors");
    let dir = Config {
        path: scratch.0.clone(),
    };
    let error = dir.read().unwrap_err();
    let path = scratch.0.display();
    assert_eq!(error.kind, Kind::ConfigReadFailed);
    assert_eq!(
        error.message,
        format!("failed to read config {path}: read {path}: is a directory")
    );
    // A file where the config's directory should be.
    std::fs::write(scratch.0.join("file"), "").unwrap();
    let blocked = Config {
        path: scratch.0.join("file/sub/config.json"),
    };
    let error = blocked.write(&Json::Null).unwrap_err();
    assert_eq!(error.kind, Kind::ConfigWriteFailed);
    assert_eq!(
        error.message,
        format!(
            "failed to write config: create config directory {path}/file/sub: mkdir {path}/file: \
             not a directory"
        )
    );
    // A directory in the config's place, so the rename over it fails after the temp file's write.
    std::fs::create_dir_all(scratch.0.join("taken/config.json/x")).unwrap();
    let taken = Config {
        path: scratch.0.join("taken/config.json"),
    };
    let error = taken.write(&Json::Null).unwrap_err();
    let message = error.message;
    let config = format!("{path}/taken/config.json");
    let tmp = message
        .strip_prefix(&format!("failed to write config {config}: rename "))
        .and_then(|rest| rest.strip_suffix(&format!(" {config}: is a directory")))
        .unwrap_or_else(|| panic!("{message}"));
    assert!(
        tmp.starts_with(&format!("{path}/taken/.config-")) && tmp.ends_with(".json.tmp"),
        "{tmp}"
    );
    assert!(!Path::new(tmp).exists(), "the temp file is removed");
}

#[test]
fn os_errors_are_worded_as_go_words_them() {
    let error = io::Error::from_raw_os_error(libc::EACCES);
    assert_eq!(os_error(&error), "permission denied");
    let missing = io::Error::from_raw_os_error(libc::ENOENT);
    assert_eq!(os_error(&missing), "no such file or directory");
}
