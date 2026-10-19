---
title: workroom trust
description: Approve a project's setup and teardown scripts so Workroom runs them.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Approve a project's setup and teardown scripts so Workroom runs them

### Synopsis

Approve the setup and teardown scripts a create or delete would run next, by their exact contents. In a terminal each one is shown first and you are asked. A changed script needs approving again. A script git ignores in the project's root needs no approval.

```text
workroom trust [flags]
```

### Options

```text
  -h, --help             help for trust
      --project string   Project directory (defaults to the current directory)
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom trust status](workroom-trust-status.md)	 - Say whether a project's setup and teardown scripts are approved
