## Summary

<!-- What changes, and why. Describe any behavior change. If nothing changes for users, say so. -->

## Linked issues

<!-- `Fixes #123` closes the issue on merge; `Refs #123` only links it. -->

## Validation

<!-- List what you ran and the result. Say which checks you skipped and why. -->

- [ ] `make app-lint` and `make app-test` (Swift)
- [ ] `make app-package-test` (changes under `macapp/Packages`)
- [ ] `make app-test-scripts` (changes under `macapp/Scripts`)
- [ ] `make actions-lint` (changes under `.github/workflows`)
- [ ] `make vcs-lint`, `make vcs-test` and `make contract-test` (Rust changes, the CLI included)

## Screenshots

<!-- Required for visible UI changes. Delete this section otherwise. -->

## Checklist

- [ ] The `--json` contract has no breaking change, or `SCHEMA_VERSION` in `vcs/crates/workroomd/src/commands/envelope.rs` is bumped.
- [ ] Tests cover the changed behavior and any regression it fixes.
- [ ] `docs-site/` is updated for any change users see, or none is needed.
- [ ] The title follows the repo's commit style, such as `fix(macapp): …`, `refactor(macapp): …` or `docs(…): …`.
