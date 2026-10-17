# Shared directories

Workroom does not share a directory between the root and its workrooms. Orca's
`worktree.sharedDirectories` symlinks a gitignored directory, such as a cache,
from each new worktree back to the primary checkout's copy. Workroom has no
equivalent and won't add one.

## Why this is out of scope

Every workroom kind, local or on a host, gets the same treatment of local files:
the root's included files (`.worktreeinclude`) are copied into the new workroom.
A symlink into the root can only work on this Mac. On a host it would point at
nothing, so shared directories would be the one local-file rule that splits the
kinds.

A workroom is also an isolated copy of its project. A shared directory makes one
workroom's writes, like a cache rebuilt by a different branch, land in the root
and in every other workroom at once. That is exactly the cross-talk workrooms
exist to avoid.

A project that really wants a shared cache can still make the symlink itself
in its setup script, on the local workrooms where it can work:

```bash
ln -s "$WORKROOM_ROOT_PATH/tmp/cache" tmp/cache
```

## Prior requests

- #367: "Copy gitignored files (.env etc.) into new workrooms without a setup
  script", which proposed shared directories as an optional second step
