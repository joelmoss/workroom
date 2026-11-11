---
title: workroom delete
description: Delete an existing workroom.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Delete an existing workroom. When run without a name, shows an interactive multi-select menu.

```text
workroom delete [NAME] [flags]
```

## Options

```text
      --confirm string               Skip confirmation if value matches the workroom name (required in --json mode)
  -h, --help[=true|false]            help for delete
      --project string               Project directory the workroom belongs to (defaults to the current directory)
      --skip-teardown[=true|false]   Delete without running the teardown script (after it failed)
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## See also

* [workroom](workroom.md)	 - Manage development workrooms
