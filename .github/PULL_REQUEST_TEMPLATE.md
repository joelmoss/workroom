## Summary

<!-- What changes, and why. Describe any behavior change. If nothing changes for users, say so. -->

## Linked issues

<!-- `Fixes #123` closes the issue on merge; `Refs #123` only links it. -->

## Validation

<!-- List what you ran and the result. Say which checks you skipped and why. -->

- [ ] `make cli-lint` and `make cli-test` (Go)
- [ ] `make app-lint` and `make app-test` (Swift)
- [ ] `make app-package-test` (changes under `macapp/Packages`)
- [ ] `make app-test-scripts` (changes under `macapp/Scripts`)
- [ ] `make actions-lint` (changes under `.github/workflows`)
- [ ] In `vcs/`: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test` (Rust changes)

## Screenshots

<!-- Required for visible UI changes. Delete this section otherwise. -->

## Checklist

- [ ] The `--json` contract has no breaking change, or `schema_version` in `cmd/json.go` is bumped.
- [ ] Tests cover the changed behavior and any regression it fixes.
- [ ] The title follows the repo's commit style, such as `fix(macapp): …`, `refactor(macapp): …` or `docs(…): …`.
