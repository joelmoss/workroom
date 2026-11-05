use super::*;

#[test]
fn idle_timeout_takes_seconds_or_never_and_rejects_anything_else() {
    assert_eq!(idle_timeout(None), Ok(DEFAULT_IDLE_TIMEOUT));
    assert_eq!(idle_timeout(Some("60")), Ok(Duration::from_secs(60)));
    assert_eq!(idle_timeout(Some("never")), Ok(Duration::MAX));
    for bad in ["", "-1", "1.5", "Never", "forever"] {
        assert!(idle_timeout(Some(bad)).is_err(), "{bad:?}");
    }
}
