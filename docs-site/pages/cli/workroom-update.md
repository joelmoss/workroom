---
title: workroom update
description: Update workroom to the latest version.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Update workroom to the latest version

### Synopsis

Check for and install the latest version of workroom from GitHub Releases.

Use --channel to choose a release channel for this (main) binary:
  stable   GA releases only (default)
  pre      betas / release candidates, plus stable

Passing --channel switches you to that channel (installing its latest build even if that
means a downgrade) and remembers it. Nightly is not a channel switch — it's a separate
side-by-side install (a `workroom-nightly` binary); see the install script's WORKROOM_CHANNEL.

```text
workroom update [flags]
```

### Options

```text
      --channel string   Release channel: stable or pre (remembered for next time)
  -c, --check            Only check if an update is available
  -h, --help             help for update
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom](workroom.md)	 - Manage development workrooms
