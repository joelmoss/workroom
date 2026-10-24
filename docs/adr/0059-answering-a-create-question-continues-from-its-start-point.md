# Answering a create question continues from the start point it was asked about

Decided 2026-10-24 (owner), for #531. Builds on ADR 0054 (scripts run only once their exact bytes are approved) and ADR 0055 (a create asks before it leaves local work out).

A local create resolves its start point first, fetching the remote, and only then asks its create questions: where it starts when the root has local work, then whether to approve its setup script. The app answers them by running `workroom create` again with the answer: `--start` for the start choice, after `workroom trust --stdin` for Approve, `--skip-setup` for Continue Without Script. Each of those is a fresh create, so each fetched again. A create that asked both questions fetched three times.

The extra fetch also changed what the answer applied to. The app auto-fetches each project in the background, at most every five minutes, so a fetch can land while the user reads the script sheet. The next create then started from wherever the remote's branch had moved. If the script's bytes had changed, the gate refused and asked again. If they hadn't, the workroom started from a commit the user never saw.

So answering a create question continues the same create from the start point it was asked about:

- The refusal names the commit it resolved. `--json` reports `start_commit` beside `script` or `local_work`. The field is additive, so `schema_version` stays.
- The answer passes it back as `--start-commit <sha>`, a hidden flag only the app uses. A person at a terminal answers in the same process (`ApproveScriptFn`, `ChooseStartFn`), which never fetched twice.
- With the pin, the create resolves the start point as before, but without fetching. It keeps the ref's name for the local branch it compares with and for its wording, and uses the pinned commit for the worktree, the script gate and the local-work comparison. The pin fixes the remote's copy only: a start the user switches to the local branch is that branch, which no fetch moves.
- A pinned create emits no fetch step and never says it could not fetch. The app keeps the first run's fetch row and its warning, and shows them on the continued create. The workroom's notice adds only what the first run couldn't know, such as a start switched to the local branch.
- A pin that can't be used (the commit is missing, or the project's base branch changed in between) is an error of its own kind, never applied silently. The app turns it into a Try Again.
- Try Again is not an answer to a create question. It starts over, reads the base branch afresh and fetches, as before.

Rejected:

- **Skipping the fetch** (`--no-fetch`, the first proposal on #531). It starts from whatever the local ref holds when the answer comes, and the background auto-fetch can move that ref.
- **Keeping the first create's process alive** to take the answer in-process, as a terminal does. That needs a stdin protocol between the app and the CLI, and a process held open behind a sheet the user may leave open indefinitely.
- **A public, documented flag.** Nobody types it, and a terminal create never needs it.

Remote creates are out of scope. They fetch for `trust status` and again in the host's clone, a separate path with separate costs.

Source: [`internal/vcs/git.go`](../../internal/vcs/git.go) (`Git.Create`, `QuestionError`, `fetchStep`), [`internal/workroom/workroom.go`](../../internal/workroom/workroom.go) (`CreateNamed`, `StartCommit`), [`cmd/create.go`](../../cmd/create.go) (`--start-commit`), [`cmd/json.go`](../../cmd/json.go) (`start_commit`), [`macapp/WorkroomApp/Core/CreationRun.swift`](../../macapp/WorkroomApp/Core/CreationRun.swift) (`startCommit`, `askedAt`, `carriedFetch`), [`macapp/WorkroomApp/Core/AppStore+WorkroomCreation.swift`](../../macapp/WorkroomApp/Core/AppStore+WorkroomCreation.swift) (`retryCreation`, `approveSetupScript`, `skipSetupScript`, `chooseStart`).
