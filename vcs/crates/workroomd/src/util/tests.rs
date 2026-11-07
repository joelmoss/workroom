use super::*;
use std::cell::Cell;

/// A lock a panic poisoned is recovered with what it held, every time, and logged the first time
/// only: poison sticks, so a recovered lock reads as poisoned to every later caller too.
#[test]
fn a_poisoned_lock_is_recovered_and_logged_once() {
    let mutex = Mutex::new(7);
    let _ = std::thread::scope(|scope| {
        scope
            .spawn(|| {
                let mut held = mutex.lock().unwrap();
                *held = 8;
                panic!("poisoning the lock on purpose");
            })
            .join()
    });
    assert!(mutex.is_poisoned(), "the fixture did not poison the lock");

    let noted = AtomicBool::new(false);
    let notes = Cell::new(0);
    for _ in 0..3 {
        let held = recover_noting(mutex.lock(), &noted, || notes.set(notes.get() + 1));
        assert_eq!(*held, 8, "recovered with what the panicking thread left");
    }
    assert!(mutex.is_poisoned(), "poison sticks after a recovery");
    assert_eq!(notes.get(), 1, "logged once, not per lock");

    // The helpers themselves recover it too, through the process-wide flag.
    *lock_or_recover(&mutex) += 1;
    assert_eq!(*lock_or_recover(&mutex), 9);
    let rw = std::sync::RwLock::new(());
    let _ = std::thread::scope(|scope| {
        scope
            .spawn(|| {
                let _held = rw.write().unwrap();
                panic!("poisoning the lock on purpose");
            })
            .join()
    });
    drop(recover(rw.read()));
    assert!(try_recover(rw.try_write()).is_some());
}

#[test]
fn base64_matches_the_rfc_4648_vectors() {
    for (plain, encoded) in [
        ("", ""),
        ("f", "Zg=="),
        ("fo", "Zm8="),
        ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy"),
    ] {
        assert_eq!(base64(plain.as_bytes()), encoded);
    }
    assert_eq!(base64(&[0xff, 0xfe, 0x00]), "//4A");
}
