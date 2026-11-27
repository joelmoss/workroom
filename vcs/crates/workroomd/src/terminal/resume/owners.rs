//! A session's record owners (ADR 0082): which process may own a record (`check_owner`), when a
//! record whose owner has gone clears (`watch_owners`), and which process stands for a resumed
//! program's helper in the foreground (`foreground_process`).
//!
//! The owner check and the exit grace (`check_owner`, `Resume::check_exit`, `watch_owners`) are
//! ported from herdr-core (herdrdev/herdr-core#429, `crates/herdr-core/src/resume.rs` at
//! `0cb50d57832f3ebb69157ce7f023fbbc520181a8`), Licensed under the Apache License, Version 2.0
//! (`LICENSE` beside this file). Changed from the original for Workroom as the parent module's
//! header says; moved here from it, and the owner check returns its `Reason`.

use std::time::Instant;

use super::{EXIT_GRACE, Owner, Reason, Resume, SharedResume, program_name};
use crate::terminal::process::Identity;

/// The most parents the owner check walks from an owner to the session's first process.
const MAX_ANCESTORS: usize = 128;

/// An owner that passed its check.
pub(crate) struct Checked {
    pub(super) owner: Owner,
    pub(super) ancestors: Vec<Owner>,
    pub(super) cwd: Option<String>,
}

/// Checks that `pid` may own a record in a session whose first process is `root`: alive, run by
/// `uid`, and with `root` among its parents, each parent started no later than its child (so a
/// reused pid in the chain breaks it).
pub(super) fn check_owner(
    root: Option<Owner>,
    uid: u32,
    pid: u32,
    lookup: impl Fn(u32) -> Option<Identity>,
) -> Result<Checked, Reason> {
    let root = root.ok_or(Reason::NotDescendant)?;
    let owner = lookup(pid).ok_or(Reason::OwnerGone)?;
    if owner.uid != uid {
        return Err(Reason::OtherUser);
    }
    let mut ancestors = Vec::new();
    let mut process = owner;
    while Owner::from(process) != root {
        if process.pid == root.pid || process.parent == 0 || ancestors.len() == MAX_ANCESTORS {
            return Err(Reason::NotDescendant);
        }
        let parent = lookup(process.parent).ok_or(Reason::NotDescendant)?;
        if parent.start > process.start || parent.pid == process.pid {
            return Err(Reason::NotDescendant);
        }
        ancestors.push(Owner::from(parent));
        process = parent;
    }
    Ok(Checked {
        owner: owner.into(),
        ancestors,
        cwd: crate::terminal::process::working_directory(pid as i32),
    })
}

/// What one look at a record's owner did (`Resume::check_exit`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Exit {
    /// Nothing: the owner runs, its grace has not passed, or the record is another owner's now.
    Unchanged,
    /// The owner was found gone, which starts its grace.
    Gone,
    /// The owner was found running again before its grace passed.
    Back,
    /// The owner stayed gone for the grace, so its record, which started `program`, cleared.
    Cleared { program: String },
}

impl Resume {
    /// Whether a record's owner was found gone and is still inside its grace.
    fn in_grace(&self) -> bool {
        self.records().any(|record| record.gone_since.is_some())
    }

    /// Every record's owner.
    pub(super) fn owners(&self) -> Vec<Owner> {
        self.records().map(|record| record.owner).collect()
    }

    /// What one look at the records' owners looks at (`watch_owners`): `None` when no record has
    /// an owner to look at, so no look is owed.
    pub(crate) fn watch(&self) -> Option<Watch> {
        let owners = self.owners();
        (!owners.is_empty()).then_some(Watch {
            root: self.carried.root,
            owners,
        })
    }

    /// One look at `owner`, found `gone` (or its pid now another process's) at `now`: starts its
    /// record's grace, ends it if the owner is back, and clears the record once it has been gone
    /// for `EXIT_GRACE`. A record that is no longer `owner`'s (a newer report replaced it, or its
    /// pid was reused) is left alone. The `OwnerSlot` stays, so a replay is still refused.
    pub(super) fn check_exit(&mut self, owner: Owner, gone: bool, now: Instant) -> Exit {
        let Some(slot) = self.carried.slots.get_mut(&owner.pid) else {
            return Exit::Unchanged;
        };
        let Some(record) = slot.record.as_mut().filter(|record| record.owner == owner) else {
            return Exit::Unchanged;
        };
        match record.gone_since {
            Some(since) if gone && now.saturating_duration_since(since) >= EXIT_GRACE => {
                let program = program_name(&record.argv);
                slot.record = None;
                Exit::Cleared { program }
            }
            Some(_) if !gone => {
                record.gone_since = None;
                Exit::Back
            }
            None if gone => {
                record.gone_since = Some(now);
                Exit::Gone
            }
            _ => Exit::Unchanged,
        }
    }
}

/// What one look at a session's record owners looks at (`watch_owners`), copied under its lock:
/// the session's first process, and every record's owner.
pub(crate) struct Watch {
    root: Option<Owner>,
    owners: Vec<Owner>,
}

/// What one look at a session's record owners found (`watch_owners`).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Watched {
    /// The programs whose records cleared, their owners gone for `EXIT_GRACE`.
    pub cleared: Vec<String>,
    /// Whether an owner is inside its grace, so another look is owed whether or not more output
    /// comes. A running owner owes none: its exit prints its shell's prompt, which wakes the next
    /// look, so an idle daemon still sleeps while its programs hold records.
    pub watching: bool,
}

/// One look, at `now`, at whether each record's owner in `shared` still runs, with `lookup`
/// (`process::identity`): an owner gone, or whose pid now names another process, starts its
/// grace, and its record clears once it has stayed gone for `EXIT_GRACE` (`Resume::check_exit`).
/// While the session's own shell is gone nothing clears: the session is ending, and its records
/// must outlast it (#824).
///
/// The lookups run with the state's lock released, so a read waits on it only while the owners are
/// copied (`Resume::watch`, `watch`) and while what was found is applied. A report accepted
/// meanwhile is safe: it replaces its pid's record with one `check_exit` sees is not the owner it
/// looked up, or is the same owner again, which is then running.
pub(crate) fn watch_owners(
    shared: &SharedResume,
    watch: Watch,
    now: Instant,
    lookup: impl Fn(u32) -> Option<Identity>,
) -> Watched {
    let Watch { root, owners } = watch;
    let running = |owner: Owner| lookup(owner.pid).map(Owner::from) == Some(owner);
    // A record is only accepted once the first process is known, so `root` is set here.
    if !root.is_some_and(running) {
        // The session is ending, and its end wakes the thread itself.
        return Watched::default();
    }
    let found: Vec<(Owner, bool)> = owners
        .into_iter()
        .map(|owner| (owner, !running(owner)))
        .collect();
    let mut state = crate::util::lock_or_recover(shared);
    let Some(state) = state.as_mut() else {
        return Watched::default();
    };
    let cleared = found
        .into_iter()
        .filter_map(|(owner, gone)| match state.check_exit(owner, gone, now) {
            Exit::Cleared { program } => Some(program),
            _ => None,
        })
        .collect();
    Watched {
        cleared,
        watching: state.in_grace(),
    }
}

/// The process whose name, folder and Claude profile stand for a session's foreground process
/// group `group` (#825): the group's leader, except where it is the helper that runs a resumed
/// program (`launch`), which the shell made its job's leader, so the program would read as
/// `workroom`. There it is the program. Proof, looked up with `lookup` (`process::identity`): the
/// session resumed a program whose report the daemon accepted, from a process under the session's
/// shell with the leader as its parent (`Launched`), and both are still those processes (pid and
/// start time), the program still the leader's child. The group itself is left as it is: program
/// status and `terminal.prompt` compare groups.
pub(crate) fn foreground_process(
    shared: &SharedResume,
    group: i32,
    lookup: impl Fn(u32) -> Option<Identity>,
) -> i32 {
    let Some(launched) = crate::util::lock_or_recover(shared)
        .as_ref()
        .and_then(|state| state.carried.launched)
    else {
        return group;
    };
    if u32::try_from(group).ok() != Some(launched.helper.pid) {
        return group;
    }
    let helper = lookup(launched.helper.pid).map(Owner::from) == Some(launched.helper);
    let program = lookup(launched.program.pid).is_some_and(|program| {
        Owner::from(program) == launched.program && program.parent == launched.helper.pid
    });
    match i32::try_from(launched.program.pid) {
        Ok(pid) if helper && program => pid,
        _ => group,
    }
}
