# The app drives the Go engine over a stable `--json` contract, and only breaking changes bump `schema_version`

The app calls the bundled CLI as a subprocess instead of embedding it (no cgo, no duplicated lifecycle logic). Stdout carries one JSON envelope, stderr carries NDJSON logs, and machine `kind` strings and exit codes are stable, so callers branch on the code, never on the message. A new field or a new warning kind is additive because the app's decoders ignore unknown keys; only a breaking change bumps `schema_version`. The `kind` names, such as `WorkspaceExists`, are part of the documented contract, so renaming one is a breaking change.

Source: [`cmd/json.go`](../../cmd/json.go) (`schemaVersion` comment), [`internal/errs/errs.go`](../../internal/errs/errs.go), [`AGENTS.md`](../../AGENTS.md) ("Architecture & Configuration"), [`README.md`](../../README.md) ("The --json machine contract").
