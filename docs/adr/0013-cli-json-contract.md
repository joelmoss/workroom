# The app drives the Go engine over a stable `--json` contract, and only breaking changes bump `schema_version`

The app calls the bundled CLI as a subprocess instead of embedding it (no cgo, no duplicated lifecycle logic). Stdout carries one JSON envelope, stderr carries NDJSON logs, and machine `kind` strings and exit codes are stable, so callers branch on the code, never on the message. A new field or a new warning kind is additive because the app's decoders ignore unknown keys; only a breaking change bumps `schema_version`. The wire names, `WorkspaceExists` included, are left as they are on purpose.

Source: [`cmd/json.go`](../../cmd/json.go) (`schemaVersion` comment), [`internal/errs/errs.go`](../../internal/errs/errs.go), [`AGENTS.md`](../../AGENTS.md) ("Architecture & Configuration"), the "left alone on purpose" list in the cleanup plan: see the plan link in ADR 0020.
