---
title: workroom create
description: Create a new workroom.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Create a new workroom

### Synopsis

Create a new workroom at the same level as your main project directory, using a git worktree. A random friendly name is auto-generated.

```text
workroom create [flags]
```

### Options

```text
  -h, --help             help for create
      --no-editor        Do not offer to open the new workroom in $EDITOR
      --project string   Project directory to create the workroom in (defaults to the current directory)
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom](workroom.md)	 - Manage development workrooms
