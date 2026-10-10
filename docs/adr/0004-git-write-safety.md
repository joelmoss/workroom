# The write path never force-pushes, never deletes a lock file, and serializes writes per project

The engine never force-pushes; a rejected push offers Pull. Workroom never deletes a leftover `index.lock` or `packed-refs.lock`: whether a lock is abandoned or held by a git running right now cannot be known from outside git, and removing a live one corrupts the index, so it reports the lock and leaves removal to the user. The commit timeout is a generous 600 seconds because a SIGKILLed hook leaves a lock behind. Every commit, fetch, push and pull goes through `RepositoryWriteGate`, one serializer per project, because the worktrees of a project share one `.git`; callers wrap the gate in `withTimeout`, never the reverse.

Source: [`macapp/WorkroomApp/Core/VCSWriting.swift`](../../macapp/WorkroomApp/Core/VCSWriting.swift) (lock and timeout comments), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("Writes are serialized per project").
