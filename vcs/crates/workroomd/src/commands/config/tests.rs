use std::os::unix::fs::PermissionsExt;

use super::*;
use crate::commands::Platform;

/// A directory for one test, removed when it ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir =
            std::env::temp_dir().join(format!("workroom-config-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir.canonicalize().unwrap())
    }

    fn config(&self) -> Config {
        Config {
            path: self.0.join("nested/config.json"),
        }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn context(env: fn(&str) -> Option<String>) -> Context {
    Context {
        json: true,
        pretend: false,
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
    let config = scratch.config();
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
    let config = scratch.config();
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
    let config = scratch.config();
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
    let config = scratch.config();
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
fn os_errors_are_worded_as_go_words_them() {
    let error = io::Error::from_raw_os_error(libc::EACCES);
    assert_eq!(os_error(&error), "permission denied");
}
