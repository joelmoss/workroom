# Vendored Markdown-preview libraries

Bundled into this directory and loaded offline by `template.html` (see `MarkdownWebView.swift`).
**Do not edit these files by hand.** Refresh with `macapp/Scripts/vendor-markdown.sh`.
DOMPurify sanitizes untrusted Markdown before it hits the DOM, so keep it current.

`mermaid.min.js` is the exception: it is NOT in `template.html`. At 3.4 MB it was ~104 ms of
the ~117 ms script parse on every Markdown open (8-10 ms without it), so `render.js` injects it
on demand, the first time a document actually contains a \`\`\`mermaid fence.

| File | Package | Version | SHA-256 | Source |
|------|---------|---------|---------|--------|
| `dompurify.min.js` | dompurify | 3.4.11 | `dbabb5b205a333ec49c8c09e7fca30ef66df0523bb8bc0fa9ea843841f111dbd` | https://cdn.jsdelivr.net/npm/dompurify@3.4.11/dist/purify.min.js |
| `marked.min.js` | marked | 18.0.5 | `8855491f5f19e2584a87785cb1982ae831547c38d324989f9ea77cb3f7fd4217` | https://cdn.jsdelivr.net/npm/marked@18.0.5/lib/marked.umd.min.js |
| `mermaid.min.js` | mermaid | 11.16.0 | `74d7c46dabca328c2294733910a8aa1ed0c37451776e8d5295da38a2b758fb9b` | https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js |
