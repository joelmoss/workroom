# A create asks before it leaves local work out

Decided 2026-10-21 (owner). Builds on the origin-default start (PR #387): a create still starts from `origin`'s copy of the base branch, freshly fetched, not from whatever the main checkout has out.

That start silently left out commits on the local base branch that `origin` lacks, and uncommitted changes in the main checkout. Now, once the start is a remote's copy and its fetch worked, the create compares it with the local branch of the same name (`vcs.LocalWork`): the commits the local branch has that the start lacks, and whether the main checkout has that branch out with changes (modified, staged or untracked files). Changes on another branch aren't the base branch's and don't count. It also counts the commits the start has that the local branch lacks: when the local branch is behind, including the work starts from that older copy, and the choice says so ("Your master is also 3 commits behind origin, so including your work starts from your older copy."). A start that already warns (a failed fetch, a fallback) is compared all the same but marked stale: nobody is asked against a stale remote copy, though a start chosen beforehand (`--start local`, or the app's choice kept through a retry) still holds.

When there is local work, the create asks where it starts, on every create; nothing is remembered:

- `origin`: the remote's copy, as before.
- `local`: the local branch, with its unpushed commits. Offered only when there are some.
- `local-with-changes`: the local branch, and the main checkout's uncommitted changes copied into the new workroom (`git stash create` and `stash apply`, plus untracked files git doesn't ignore, regular files only; an untracked folder that is a repository of its own isn't copied, and the step warns naming it). The main checkout keeps them: copied, never moved. Offered only when the main checkout has the base branch out with changes. The copy needs the workroom to start from the main checkout's own commit; if that has moved, the step warns rather than leave conflicts.

The setup script is judged at the start chosen, since a local branch can carry another one.

Who asks: a person at a terminal is asked (`ChooseStartFn`); the app passes `--start ask`, which refuses before anything exists (`LocalWorkLeftOut`, exit 3, `local_work` in the envelope) and asks in a window-modal choice, then creates again with the answer. A create with nobody to ask (a script, `--json` without `--start`) keeps starting from `origin`, now with a warning naming what it left out, so no existing caller starts failing.

A remote workroom clones from GitHub, so local work can't reach it. It is only said, in the start notice after it lands, from the `local_work` that `trust status` reports at the same start.

Rejected: a remembered per-project answer (it would quietly do the wrong thing later); moving the changes out of the main checkout (a surprise there); refusing by default in `--json` (it would break scripts that create today); copying changes onto `origin`'s copy (they conflict wherever the two differ).

Source: [`internal/vcs/git.go`](../../internal/vcs/git.go) (`LocalWork`), [`internal/vcs/changes.go`](../../internal/vcs/changes.go), [`internal/workroom/start.go`](../../internal/workroom/start.go), [`cmd/create.go`](../../cmd/create.go) (`--start`), [`macapp/WorkroomApp/Core/AppStore+WorkroomCreation.swift`](../../macapp/WorkroomApp/Core/AppStore+WorkroomCreation.swift) (`refuseCreation(_:leaving:)`).
