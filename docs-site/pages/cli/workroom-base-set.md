---
title: workroom base set
description: "Start new workrooms from BRANCH."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

Runs on a Mac only, and fails with `MacOnly` elsewhere.

```text
workroom base set BRANCH
```

## Options

```text
  -h, --help[=true|false]     help for set
      --global[=true|false]   The default for every project that names no base branch
      --project string        Project directory (defaults to the current directory)
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## See also

* [workroom base](workroom-base.md)	 - Set or clear the branch new workrooms start from
