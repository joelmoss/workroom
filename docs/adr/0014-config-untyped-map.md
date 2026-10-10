# `config.json` is read and written as an untyped map, with typed views for reading only

`Project` and `Workroom` are read-side views. Mutators work on the raw `map[string]any`, and numbers decode with `UseNumber`, so a CLI write never drops a key it does not know. That matters because the app owns the `host` descriptor's schema and the CLI treats it as opaque: a dropped `host` would silently turn a remote workroom local, and a float64 round trip would corrupt integers above 2^53. Every config writer must preserve `host`.

Source: [`internal/config/config.go`](../../internal/config/config.go) (the `Project` comment and `Read`), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("Remote workrooms in config").
