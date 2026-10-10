# Every remote workroom is a fresh host, and Workroom keeps no wakefulness obligation

Each remote workroom gets a new host from its driver's `create()`, with its own clone, and no driver derives a host from another. Per-project base machines were removed (#395; bases older builds recorded stay until a follow-up retires them): a derive measured slower than a fresh machine on boxd and saved about 2.5 seconds on exe.dev. Wakefulness is the user's concern: the awake ceiling, the heartbeat, the busy/idle classifier and the badge are gone (#380, #382), nothing lets go of an idle connection, and a box an open app holds awake is freed by deleting its workroom. The `workroom-identity` unit stays because fresh boxd machines share the image's machine-id and ssh host key.

Source: [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("boxd driver"), the dated notes at the top of [`docs/designs/remote-workrooms.md`](../designs/remote-workrooms.md) and its "As built (#380)" and "As built (#382)" entries.
