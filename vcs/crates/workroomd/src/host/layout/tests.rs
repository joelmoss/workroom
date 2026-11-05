use super::*;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wr-layouts-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn request(value: Value) -> Vec<u8> {
    serde_json::to_vec(&value).unwrap()
}

/// A key never written is revision 0 with no layout; a put at 0 makes it 1, a put naming 1
/// makes it 2, and a get returns the latest.
#[test]
fn a_put_at_the_current_revision_is_kept_and_raises_it() {
    let dir = scratch("cas");
    let layouts = Layouts::open(&dir).unwrap();
    assert_eq!(layouts.get("wr-1"), (0, None));
    assert_eq!(layouts.put("wr-1", 0, b"{\"tabs\":[]}"), Ok(1));
    assert_eq!(layouts.put("wr-1", 1, b"{\"tabs\":[1]}"), Ok(2));
    assert_eq!(layouts.get("wr-1"), (2, Some(b"{\"tabs\":[1]}".to_vec())));
    let _ = fs::remove_dir_all(&dir);
}

/// A put naming a revision that has moved is refused with the current one, and changes nothing.
#[test]
fn a_stale_put_is_refused_with_the_current_revision() {
    let dir = scratch("stale");
    let layouts = Layouts::open(&dir).unwrap();
    layouts.put("wr-1", 0, b"first").unwrap();
    assert_eq!(
        layouts.put("wr-1", 0, b"second"),
        Err(LayoutError::Stale { revision: 1 })
    );
    assert_eq!(layouts.get("wr-1"), (1, Some(b"first".to_vec())));
    let _ = fs::remove_dir_all(&dir);
}

/// Two writers at one revision: exactly one wins (R3-5).
#[test]
fn two_puts_at_one_revision_have_exactly_one_winner() {
    let dir = scratch("race");
    let layouts = std::sync::Arc::new(Layouts::open(&dir).unwrap());
    const WRITERS: usize = 8;
    for round in 0..20u64 {
        // Released together, so every writer reads the revision before any has renamed.
        let start = std::sync::Arc::new(std::sync::Barrier::new(WRITERS));
        let handles: Vec<_> = (0..WRITERS)
            .map(|n| {
                let layouts = std::sync::Arc::clone(&layouts);
                let start = std::sync::Arc::clone(&start);
                std::thread::spawn(move || {
                    start.wait();
                    layouts.put("wr-1", round, format!("writer {n}").as_bytes())
                })
            })
            .collect();
        let results: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect();
        let won = results.iter().filter(|result| result.is_ok()).count();
        let stale = results
            .iter()
            .filter(|result| matches!(result, Err(LayoutError::Stale { .. })))
            .count();
        // Every loser is told it was stale, never a disk error from a shared temporary file.
        assert_eq!((won, stale), (1, WRITERS - 1), "round {round}: {results:?}");
    }
    let _ = fs::remove_dir_all(&dir);
}

/// A file cut short, or not a layout at all, reads as never written rather than as garbage, and
/// the next put at revision 0 replaces it (R3-5).
#[test]
fn a_truncated_layout_reads_as_never_written() {
    let dir = scratch("torn");
    let layouts = Layouts::open(&dir).unwrap();
    layouts.put("wr-1", 0, b"whole layout").unwrap();
    let path = layouts.path("wr-1");
    let bytes = fs::read(&path).unwrap();
    fs::write(&path, &bytes[..HEADER - 1]).unwrap();
    assert_eq!(layouts.get("wr-1"), (0, None));
    fs::write(&path, b"not a layout at all").unwrap();
    assert_eq!(layouts.get("wr-1"), (0, None));
    assert_eq!(layouts.put("wr-1", 0, b"again"), Ok(1));
    let _ = fs::remove_dir_all(&dir);
}

/// The key names no path: its file is the SHA-256 of the key, whatever the key holds.
#[test]
fn a_key_is_hashed_into_its_file_name() {
    let dir = scratch("names");
    let layouts = Layouts::open(&dir).unwrap();
    layouts.put("../../etc/passwd", 0, b"x").unwrap();
    let names: Vec<String> = fs::read_dir(&dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names.len(), 1);
    assert_eq!(names[0].len(), 64 + 1 + EXTENSION.len());
    assert!(names[0].chars().take(64).all(|c| c.is_ascii_hexdigit()));
    let _ = fs::remove_dir_all(&dir);
}

/// A blob over the cap, and a new key past the key cap, are refused rather than truncated or
/// evicted; an existing key can still be written at the key cap.
#[test]
fn the_blob_and_key_caps_refuse() {
    let dir = scratch("caps");
    let layouts = Layouts::open(&dir).unwrap();
    assert!(matches!(
        layouts.put("big", 0, &vec![b'x'; MAX_BLOB + 1]),
        Err(LayoutError::TooLarge(_))
    ));
    assert_eq!(layouts.put("big", 0, &vec![b'x'; MAX_BLOB]), Ok(1));
    for n in 1..MAX_KEYS {
        layouts.put(&format!("k{n}"), 0, b"x").unwrap();
    }
    assert!(matches!(
        layouts.put("one-too-many", 0, b"x"),
        Err(LayoutError::TooLarge(_))
    ));
    assert_eq!(layouts.put("k1", 1, b"y"), Ok(2));
    let _ = fs::remove_dir_all(&dir);
}

/// The wire: capabilities, get, put and a stale put, as the app sees them.
#[test]
fn requests_and_replies() {
    let dir = scratch("wire");
    let layouts = Layouts::open(&dir).unwrap();
    let caps = handle(Some(&layouts), &request(json!({"method": "capabilities"}))).unwrap();
    assert_eq!(caps["available"], true);
    assert_eq!(caps["maxBlobBytes"], MAX_BLOB);
    assert_eq!(
        handle(
            Some(&layouts),
            &request(json!({"method": "get", "key": "wr"}))
        )
        .unwrap(),
        json!({"revision": 0, "blob": null})
    );
    assert_eq!(
        handle(
            Some(&layouts),
            &request(json!({"method": "put", "key": "wr", "expected": 0, "blob": "{\"tabs\":[]}"}))
        )
        .unwrap(),
        json!({"revision": 1})
    );
    assert_eq!(
        handle(
            Some(&layouts),
            &request(json!({"method": "get", "key": "wr"}))
        )
        .unwrap(),
        json!({"revision": 1, "blob": "{\"tabs\":[]}"})
    );
    assert_eq!(
        reply(handle(
            Some(&layouts),
            &request(json!({"method": "put", "key": "wr", "expected": 0, "blob": "x"}))
        )),
        json!({"version": 1, "error": {"stale": {"revision": 1}}})
    );
    let _ = fs::remove_dir_all(&dir);
}

/// A daemon with no screens directory keeps no layouts: capabilities says so, and get and put
/// are refused as unsupported, which the app treats as a daemon without the service.
#[test]
fn a_daemon_without_a_layouts_directory_says_so() {
    let caps = handle(None, &request(json!({"method": "capabilities"}))).unwrap();
    assert_eq!(caps["available"], false);
    assert!(matches!(
        handle(None, &request(json!({"method": "get", "key": "wr"}))),
        Err(LayoutError::Unsupported(_))
    ));
}

/// Anything can reach the socket, so a malformed request is refused as unsupported, and none
/// of them writes a layout.
#[test]
fn malformed_requests_are_refused_and_write_nothing() {
    let dir = scratch("malformed");
    let layouts = Layouts::open(&dir).unwrap();
    for bad in [
        json!({"method": "get"}),
        json!({"method": "get", "key": ""}),
        json!({"method": "put", "key": "k", "blob": "x"}),
        json!({"method": "put", "key": "k", "expected": 0, "blob": 5}),
        json!({"method": "nope", "key": "k"}),
    ] {
        assert!(
            matches!(
                handle(Some(&layouts), &request(bad.clone())),
                Err(LayoutError::Unsupported(_))
            ),
            "{bad}"
        );
    }
    assert!(matches!(
        handle(Some(&layouts), b"not json"),
        Err(LayoutError::Unsupported(_))
    ));
    assert_eq!(layouts.get("k"), (0, None));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn layouts_sit_beside_the_screens() {
    assert_eq!(
        dir_beside(Path::new("/home/workroom/.local/state/workroom/screens")),
        PathBuf::from("/home/workroom/.local/state/workroom/layouts")
    );
}
