# Vendored Markdown-preview libraries

Bundled into this directory and loaded offline by `template.html` (see `MarkdownWebView.swift`).
**Do not edit these files by hand.** Refresh with `macapp/Scripts/vendor-markdown.sh`.
DOMPurify sanitizes untrusted Markdown before it hits the DOM, so keep it current.

`pele.global.js`, the diagram engine, is the exception: it is NOT in `template.html`. At 0.7 MB
it is most of the bundled script and almost no file has a diagram, so `render.js` injects it
on demand, the first time a document actually contains a \`\`\`mermaid fence.

| File | Package | Version | SHA-256 | Source |
|------|---------|---------|---------|--------|
| `dompurify.min.js` | dompurify | 3.4.11 | `dbabb5b205a333ec49c8c09e7fca30ef66df0523bb8bc0fa9ea843841f111dbd` | https://cdn.jsdelivr.net/npm/dompurify@3.4.11/dist/purify.min.js |
| `marked.min.js` | marked | 18.0.5 | `8855491f5f19e2584a87785cb1982ae831547c38d324989f9ea77cb3f7fd4217` | https://cdn.jsdelivr.net/npm/marked@18.0.5/lib/marked.umd.min.js |
| `pele.global.js` | pele | 1.8.0 | `9bf34b3a9a19351dc69d0d238e365560331a8ae392c41656df7f5090653253d0` | https://cdn.jsdelivr.net/npm/pele@1.8.0/dist/pele.global.js |
