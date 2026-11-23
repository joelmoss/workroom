---
title: workroom trust
description: "Approve a project's setup and teardown scripts so Workroom runs them."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Approve the setup and teardown scripts a create or delete would run next, by their exact contents. In a terminal each one is shown first and you are asked. A changed script needs approving again. A script git ignores in the project's root needs no approval.

Nightly only. Runs on a Mac only, and fails with `MacOnly` elsewhere.

```text
workroom trust
```

## Options

```text
  -h, --help[=true|false]   help for trust
      --project string      Project directory (defaults to the current directory)
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom trust status](workroom-trust-status.md)	 - Say whether a project's setup and teardown scripts are approved
