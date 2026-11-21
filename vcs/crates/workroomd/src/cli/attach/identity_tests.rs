use super::*;

fn own() -> Option<String> {
    Some("this-machine".into())
}

/// A pane's attach says it is one, and the machine it runs on; one the app runs on a host says
/// the Mac the app named, or nothing, never the host's own name, which would pass for the Mac's.
#[test]
fn a_pane_names_the_mac_it_is_on_and_never_the_host() {
    assert_eq!(
        declared(true, false, None, own),
        (Some(ClientKind::Pane), Some("this-machine".into()))
    );
    assert_eq!(
        declared(true, true, Some("mac-a".into()), own),
        (Some(ClientKind::Pane), Some("mac-a".into()))
    );
    assert_eq!(
        declared(true, true, None, own),
        (Some(ClientKind::Pane), None)
    );
    assert_eq!(
        declared(true, true, Some("".into()), own),
        (Some(ClientKind::Pane), None)
    );
}

/// A `workroom attach` someone ran is `cli`, on the machine it runs on; a name it can't show is
/// none.
#[test]
fn an_attach_someone_ran_is_cli_on_its_own_machine() {
    assert_eq!(
        declared(false, false, None, own),
        (Some(ClientKind::Cli), Some("this-machine".into()))
    );
    assert_eq!(
        declared(false, false, None, || Some("bad\nname".into())),
        (Some(ClientKind::Cli), None)
    );
    assert_eq!(
        declared(false, false, None, || None),
        (Some(ClientKind::Cli), None)
    );
}
