//! Small helpers more than one context uses and none owns.

use std::panic::Location;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, LockResult, Mutex, MutexGuard, TryLockError, TryLockResult};

/// A counted signal. `wait_past` a count read by `seen` returns once `raise` has moved it, so a
/// raise between the read and the wait is never missed.
#[derive(Default)]
pub(crate) struct Wake {
    count: Mutex<u64>,
    raised: Condvar,
}

impl Wake {
    pub(crate) fn seen(&self) -> u64 {
        *lock_or_recover(&self.count)
    }

    pub(crate) fn raise(&self) {
        *lock_or_recover(&self.count) += 1;
        self.raised.notify_all();
    }

    pub(crate) fn wait_past(&self, seen: u64) {
        let mut count = lock_or_recover(&self.count);
        while *count == seen {
            count = recover(self.raised.wait(count));
        }
    }
}

/// Locks `mutex`, recovering it if a panic poisoned it (owner decision D5): the daemon holds live
/// shells, and a panic under a lock must not stop a session draining, or fail every later caller of
/// that lock, for as long as the daemon runs. The first poisoned lock this process meets is logged,
/// once. Poison sticks, so without that every later lock of it would log again.
///
/// The one exception is a connection's writer (`SharedWriter`), whose poisoning still means the
/// connection is gone: see the lock order on `SessionStore`.
#[track_caller]
pub(crate) fn lock_or_recover<T: ?Sized>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    recover(mutex.lock())
}

/// The guard in `result`, poisoned or not: `lock_or_recover` for an `RwLock` or a `Condvar` wait.
#[track_caller]
pub(crate) fn recover<G>(result: LockResult<G>) -> G {
    let at = Location::caller();
    recover_noting(result, &POISON_NOTED, || {
        crate::note!(
            "a lock was poisoned by a panic while it was held (first at {at}); recovering it, and any other, without saying so again"
        )
    })
}

/// A `try_lock`'s guard, poisoned or not, or `None` when the lock is held: `lock_or_recover` for a
/// try.
#[track_caller]
pub(crate) fn try_recover<G>(result: TryLockResult<G>) -> Option<G> {
    match result {
        Ok(guard) => Some(guard),
        Err(TryLockError::Poisoned(poisoned)) => Some(recover(Err(poisoned))),
        Err(TryLockError::WouldBlock) => None,
    }
}

/// Whether this process has logged a poisoned lock yet.
static POISON_NOTED: AtomicBool = AtomicBool::new(false);

/// `recover`, logging through `note` only the first time `noted` sees a poisoned lock.
fn recover_noting<G>(result: LockResult<G>, noted: &AtomicBool, note: impl FnOnce()) -> G {
    result.unwrap_or_else(|poisoned| {
        if !noted.swap(true, Ordering::Relaxed) {
            note();
        }
        poisoned.into_inner()
    })
}

/// Standard base64 with padding. Hand-rolled because it is fifteen lines and the crate has no other
/// use for a base64 dependency; `Data(base64Encoded:)` is its decoder on the Swift side. The File
/// service's reads and the Kitty image chunks a reattach re-sends are both encoded with it.
pub(crate) fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod tests;
