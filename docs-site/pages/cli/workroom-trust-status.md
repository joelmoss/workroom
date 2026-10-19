---
title: workroom trust status
description: Say whether a project's setup and teardown scripts are approved.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Say whether a project's setup and teardown scripts are approved

### Synopsis

Say whether the setup and teardown scripts a create or delete would run next are approved. Exits 0 when every script there is approved or ignored by git, 1 when one is not, and 2 when it cannot tell.

```text
workroom trust status [flags]
```

### Options

```text
  -h, --help             help for status
      --project string   Project directory (defaults to the current directory)
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom trust](workroom-trust.md)	 - Approve a project's setup and teardown scripts so Workroom runs them
