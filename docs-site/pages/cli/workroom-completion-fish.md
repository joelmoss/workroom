---
title: workroom completion fish
description: Generate the autocompletion script for fish.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Generate the autocompletion script for fish

### Synopsis

Generate the autocompletion script for the fish shell.

To load completions in your current shell session:

	workroom completion fish | source

To load completions for every new session, execute once:

	workroom completion fish > ~/.config/fish/completions/workroom.fish

You will need to start a new shell for this setup to take effect.


```text
workroom completion fish [flags]
```

### Options

```text
  -h, --help              help for fish
      --no-descriptions   disable completion descriptions
```

### Options inherited from parent commands

```text
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
```

### SEE ALSO

* [workroom completion](workroom-completion.md)	 - Generate the autocompletion script for the specified shell
