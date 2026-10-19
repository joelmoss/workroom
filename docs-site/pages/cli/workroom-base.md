---
title: workroom base
description: Set or clear the branch new workrooms start from.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Set or clear the branch new workrooms start from

### Synopsis

Set or clear the branch new workrooms start from. BRANCH is a branch on origin, such as develop, or &lt;remote>/&lt;branch> for another remote, such as upstream/main. Workroom fetches that remote and uses its copy of the branch, else the local branch. A project's own base wins over the --global one. Unset, new workrooms start from origin's default branch.

### Options

```text
  -h, --help   help for base
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom base clear](workroom-base-clear.md)	 - Start new workrooms from the global base, else origin's default branch
* [workroom base set](workroom-base-set.md)	 - Start new workrooms from BRANCH
