---
title: workroom api
description: "List, describe and call the terminal API's methods."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Raw access to every terminal API method, on the daemon WORKROOM_DAEMON names. `api list` lists the methods, `api describe METHOD` shows the JSON Schema of its parameters and its result, with examples, and `api call METHOD [PARAMS]` calls it. PARAMS is a JSON object given inline, @FILE to read it from a file, or - to read it from stdin; left out, it is {}. With --json, `api call` prints the method's reply in the envelope: its `result`, the API's `revision`, and `more`. A method that streams several replies gets one envelope per line (one result each without --json) until `more` is false. Every method, event and error is in the reference at https://codaset.dev/workroom/docs/reference/terminal-api.

```text
workroom api [command]
```

## Options

```text
  -h, --help[=true|false]   help for api
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Raw access to every terminal API method on the daemon, for what no command above covers. `api list` lists the methods, `api describe METHOD` shows the JSON Schema of its parameters, its result and its errors, with examples, and `api call METHOD [PARAMS]` calls it, PARAMS a JSON object inline, `@FILE` or `-` for stdin. A method that streams prints one reply per line until `more` is false. The API only ever adds fields and methods; `revision` counts the additions. Every method, event and error, with an example of each method, is in the reference at https://codaset.dev/workroom/docs/reference/terminal-api.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom api call](workroom-api-call.md)	 - Call METHOD with JSON parameters: inline, @FILE, or - for stdin
* [workroom api describe](workroom-api-describe.md)	 - Show METHOD's parameter and result schemas, with examples
* [workroom api list](workroom-api-list.md)	 - List every method the daemon has
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
* [Terminal API reference](../reference/terminal-api.md)	 - Every method, event and error of the terminal API
