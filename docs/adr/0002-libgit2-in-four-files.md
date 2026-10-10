# Local git reads use libgit2 through SwiftGitX, and raw libgit2 is touched in exactly four files

Local reads run in pure Swift on SwiftGitX (libgit2). Three reads SwiftGitX cannot express (push state over a commit range, rename detection on commit diffs, working-tree diffstat) call the libgit2 C API directly, and only `Core/LibGit2.swift`, `GitGraph.swift`, `GitCommitDiff.swift` and `GitDiffStats.swift` may do so. SwiftGitX has no `git_revwalk_hide`, keeps its repository pointer internal, frees the `git_diff` before returning and builds every hunk line eagerly. An all-Rust core on gix was tried and dropped: it bought no real unification, and libgit2 is the more complete engine. The direct `libgit2` package must keep the same URL and version as SwiftGitX's own dependency so SwiftPM sees one package identity.

Source: [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("VCS core"), [`macapp/project.yml`](../../macapp/project.yml) (the `libgit2` pin).
