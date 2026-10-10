# Git writes shell out to the `git` CLI, and Workroom stores no git credentials for local workrooms

Commit, amend, fetch, push and pull run the real `git` binary through `CLIVCSWriter`; libgit2 and SwiftGitX are read-only. SwiftGitX passes `NULL` for the options that would carry a credential callback and has no `pull`, and libgit2 implements no `credential.helper` protocol, runs no hooks and cannot sign, so a native commit would skip `pre-commit` hooks and write unsigned commits under `commit.gpgsign`. Shelling out means the user's own credential helpers, ssh agent and config just work, so Workroom has no OAuth client, keychain writes or git account concept for local workrooms. Remote workrooms are the exception: they push through the credential broker.

Source: [`macapp/WorkroomApp/Core/VCSWriting.swift`](../../macapp/WorkroomApp/Core/VCSWriting.swift) (the `CLIVCSWriter` doc comment), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("Credential broker client").
