use super::action;

#[test]
fn the_action_is_found_after_the_socket_git_was_given() {
    let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(action(&args(&["credential", "get"])), "get");
    assert_eq!(
        action(&args(&["credential", "--socket", "/run/w.sock", "get"])),
        "get"
    );
    assert_eq!(
        action(&args(&["credential", "relay", "--port", "1"])),
        "relay"
    );
    assert_eq!(action(&args(&["credential"])), "");
}
