---
title: workroom completion bash
description: Generate the autocompletion script for bash.
---

<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->

Generate the autocompletion script for bash

### Synopsis

Generate the autocompletion script for the bash shell.

This script depends on the 'bash-completion' package.
If it is not installed already, you can install it via your OS's package manager.

To load completions in your current shell session:

	source &lt;(workroom completion bash)

To load completions for every new session, execute once:

#### Linux:

	workroom completion bash > /etc/bash_completion.d/workroom

#### macOS:

	workroom completion bash > $(brew --prefix)/etc/bash_completion.d/workroom

You will need to start a new shell for this setup to take effect.


```text
workroom completion bash
```

### Options

```text
  -h, --help              help for bash
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
