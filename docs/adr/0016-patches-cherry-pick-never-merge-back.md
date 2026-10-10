# Patch releases are cherry-picked from master onto `release/X.Y` and never merged back

`master` is always the next minor. A patch ships from a lazily created `release/X.Y` branch by `git cherry-pick -x`, and the branch is never merged into master: that would make `vX.Y.Z` reachable from master, and the nightly's `git describe` would compute its base from a patch tag. Nightly's base version is therefore the next minor of the latest stable tag. One known caveat is accepted: patching an old minor makes GitHub's `/releases/latest` (ordered by creation date) offer 2.1 users a downgrade, so only the newest released line is patched.

Source: [`CONTRIBUTING.md`](../../CONTRIBUTING.md) ("Patch releases"), [`.github/workflows/nightly.yml`](../../.github/workflows/nightly.yml) (the base-version step).
