---
title: workroom completion powershell
description: Generate the autocompletion script for powershell.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Generate the autocompletion script for powershell.

To load completions in your current shell session:

	workroom completion powershell | Out-String | Invoke-Expression

To load completions for every new session, add the output of the above command
to your powershell profile.


```text
workroom completion powershell [flags]
```

## Options

```text
  -h, --help              help for powershell
      --no-descriptions   disable completion descriptions
```

## Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

## See also

* [workroom completion](workroom-completion.md)	 - Generate the autocompletion script for the specified shell
