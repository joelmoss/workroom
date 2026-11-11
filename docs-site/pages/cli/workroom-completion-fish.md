---
title: workroom completion fish
description: Generate the autocompletion script for fish.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Generate the autocompletion script for the fish shell.

To load completions in your current shell session:

	workroom completion fish | source

To load completions for every new session, execute once:

	workroom completion fish > ~/.config/fish/completions/workroom.fish

You will need to start a new shell for this setup to take effect.


```text
workroom completion fish [flags]
```

## Options

```text
  -h, --help[=true|false]              help for fish
      --no-descriptions[=true|false]   disable completion descriptions
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## See also

* [workroom completion](workroom-completion.md)	 - Generate the autocompletion script for the specified shell
