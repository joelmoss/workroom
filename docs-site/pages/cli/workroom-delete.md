---
title: workroom delete
description: Delete an existing workroom.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Delete an existing workroom

### Synopsis

Delete an existing workroom. When run without a name, shows an interactive multi-select menu.

```text
workroom delete [NAME] [flags]
```

### Options

```text
      --confirm string   Skip confirmation if value matches the workroom name (required in --json mode)
  -h, --help             help for delete
      --project string   Project directory the workroom belongs to (defaults to the current directory)
      --skip-teardown    Delete without running the teardown script (after it failed)
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom](workroom.md)	 - Manage development workrooms
