# There is no remote project, only remote workrooms of local projects

`add-project` refuses a remote path, either `ssh://` or `host:path`, with `RemoteProjectUnsupported`. A project is always a repository registered on this Mac and identified by its canonical local path, and only its workrooms can live on a host. Project keys are canonicalised local paths and `add-project` needs an existing local git repository, so this is a real product constraint, not an oversight, and the design says to state it in the UI instead of letting users discover it. A repository that exists only on a host cannot be added as a project.

Source: [`docs/designs/remote-workrooms.md`](../designs/remote-workrooms.md) ("Phase 4", the remote project passage), [`cmd/add_project.go`](../../cmd/add_project.go) (`isRemotePath` and `runAddProject`), [`internal/errs/errs.go`](../../internal/errs/errs.go) (`RemoteProjectUnsupported`).
