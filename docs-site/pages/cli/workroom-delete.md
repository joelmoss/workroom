---
title: workroom delete
description: "Delete an existing workroom."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Delete an existing workroom. When run without a name, shows an interactive multi-select menu.

Nightly only. Runs on a Mac only, and fails with `MacOnly` elsewhere.

Nightly only. Only a person may run it. Under a coding agent, such as Claude Code or Codex, it is refused with NeedsTheUser and changes nothing, so the agent asks you to do it in the Workroom app or in your own terminal. That stops a confused coding agent, not a determined one.

```text
workroom delete [NAME]
```

## Options

```text
  -h, --help[=true|false]            help for delete
      --confirm string               Skip confirmation if value matches the workroom name (required in --json mode)
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
