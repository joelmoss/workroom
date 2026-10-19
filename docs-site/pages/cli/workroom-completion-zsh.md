---
title: workroom completion zsh
description: Generate the autocompletion script for zsh.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Generate the autocompletion script for zsh

### Synopsis

Generate the autocompletion script for the zsh shell.

If shell completion is not already enabled in your environment you will need
to enable it.  You can execute the following once:

	echo "autoload -U compinit; compinit" >> ~/.zshrc

To load completions in your current shell session:

	source &lt;(workroom completion zsh)

To load completions for every new session, execute once:

#### Linux:

	workroom completion zsh > "${fpath[1]}/_workroom"

#### macOS:

	workroom completion zsh > $(brew --prefix)/share/zsh/site-functions/_workroom

You will need to start a new shell for this setup to take effect.


```text
workroom completion zsh [flags]
```

### Options

```text
  -h, --help              help for zsh
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
