---
title: workroom create
description: Create a new workroom.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Create a new workroom at the same level as your main project directory, using a git worktree. A random friendly name is auto-generated.

```text
workroom create [flags]
```

## Options

```text
  -h, --help[=true|false]         help for create
      --no-editor[=true|false]    Do not offer to open the new workroom in $EDITOR
      --project string            Project directory to create the workroom in (defaults to the current directory)
      --skip-setup[=true|false]   Create without running the setup script, and without asking to approve it
      --start string              What to include when you have commits you haven't pushed, or changes you haven't committed: local-with-changes (both), local (your commits), origin (neither), or ask (stop with exit 3 and say what there is). A terminal asks when unset
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## See also

* [workroom](workroom.md)	 - Manage development workrooms
