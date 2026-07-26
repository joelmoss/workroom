//! The one place this suite decides what happens when the external tools it drives are missing.
//!
//! Every integration test here builds a REAL throwaway jj repo with the `jj` CLI (and two of them
//! also shell out to `git`), so on a machine without those tools the tests genuinely cannot run.
//! They each handled that with an `eprintln!("skipping …")` + `return` — and that is the problem this
//! module exists to fix, because `cargo test` captures the output of PASSING tests. A developer
//! without `jj` saw ~25 green results for tests that executed nothing at all: a skip and a success
//! were indistinguishable, which is the one thing a test result must never be.
//!
//! **Why not `#[ignore]`**, the mechanism Rust actually ships for this: it's a *static* attribute,
//! and "is `jj` on PATH" is a *runtime* fact. Marking these ignored would hide them from everyone
//! including the machines that can run them, and `--include-ignored` would then run them on the
//! machines that can't. The condition can't be expressed there.
//!
//! **What we do instead.** The skip stays a `return` — nothing else is honest when the fixture can't
//! be built — and the ABSENCE is what becomes loud, via [`jj_is_on_path`] below. That test is
//! written once, here, and every file that says `mod common;` compiles its own copy into its own
//! binary. So `cargo test` fails, and so does a single-target run like
//! `cargo test --test line_stats`: there is no way to get a green board out of a machine with no
//! `jj`. On CI, which installs jj before the Rust job (`.github/workflows/ci.yml`), it is a handful
//! of extra passing assertions costing one `jj --version` each and printing nothing — the "don't
//! make CI noisier" half of the requirement.
//!
//! **Deliberately not an opt-in `WR_REQUIRE_JJ=1`.** An env var nobody remembers to set is the same
//! silence with more machinery: the developer who most needs the signal is exactly the one who
//! hasn't heard of the variable. Loud by default, and the developer who knowingly has no `jj` opts
//! out explicitly with `cargo test -- --skip jj_is_on_path`.
//!
//! `git` goes through the same [`skip_without`] helper for a uniform message, but deliberately has
//! NO guard test: only two files shell out to it, so failing all five binaries over it would be a
//! false claim in the other three. A machine with `jj` but no `git` therefore still silently skips
//! those two tests — an accepted residual, and a far narrower one than the ~25 this closes.

use std::process::Command;

/// Is `tool --version` runnable? Kept private so the only way to act on a missing tool is
/// [`skip_without`], which cannot forget to say so.
fn have(tool: &str) -> bool {
    Command::new(tool)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// `true` when `what` cannot run because one or more of `tools` is missing — the caller's cue to
/// `return` immediately.
///
/// The notice it prints is only visible under `--nocapture` (or once something else in the binary
/// fails), which is precisely why the notice is not the signal — [`jj_is_on_path`] is. It's still
/// printed so that a `--nocapture` run names which tests sat out, and why.
pub fn skip_without(tools: &[&str], what: &str) -> bool {
    let missing: Vec<&str> = tools.iter().copied().filter(|tool| !have(tool)).collect();
    if missing.is_empty() {
        return false;
    }
    eprintln!("skipping {what}: `{}` not on PATH", missing.join("` + `"));
    true
}

/// The loud one: the whole point of this module.
///
/// Without `jj` almost every test in this suite returns early, and a returning test passes. This
/// turns that silence into a single unmissable red line naming the cause and the fix, so nobody can
/// read a green run as coverage they don't have.
#[test]
fn jj_is_on_path() {
    assert!(
        have("jj"),
        "`jj` is not on PATH, so nearly every test in this suite skipped itself and passed \
         vacuously — a green board here would mean nothing. Install jj 0.43.0 (`brew install jj`, \
         or the release tarball CI uses in .github/workflows/ci.yml) and re-run. To run only the \
         few tests that need no jj: `cargo test -- --skip jj_is_on_path`."
    );
}
