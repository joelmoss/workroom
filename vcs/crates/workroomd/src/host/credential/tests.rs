use super::*;

#[test]
fn the_helper_command_survives_spaces_and_quotes_in_the_path() {
    assert_eq!(
        helper_command(Path::new("/home/me/.workroom/workroomd"), None),
        "!'/home/me/.workroom/workroomd' credential"
    );
    assert_eq!(
        helper_command(Path::new("/a b/it's/workroomd"), None),
        r"!'/a b/it'\''s/workroomd' credential"
    );
    assert_eq!(
        helper_command(
            Path::new("/.workroom/bin/workroomd"),
            Some(Path::new("/run/it's/workroomd.sock"))
        ),
        r"!'/.workroom/bin/workroomd' credential --socket '/run/it'\''s/workroomd.sock'"
    );
}

/// A container's relay file goes beside its socket, not its binary (#308): the binary's
/// folder is root's, and on Apple's runtime a read-only mount.
#[test]
fn the_relay_file_goes_beside_the_socket_it_is_given() {
    assert_eq!(
        directory(Some(Path::new("/run/workroom/workroomd.sock"))).unwrap(),
        PathBuf::from("/run/workroom")
    );
    assert_eq!(
        directory(None).unwrap(),
        std::env::current_exe().unwrap().parent().unwrap()
    );
}
