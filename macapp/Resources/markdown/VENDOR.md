# Vendored Markdown-preview libraries

Bundled into this directory and loaded offline by `template.html` (see `MarkdownWebView.swift`).
**Do not edit these files by hand.** Refresh with `macapp/Scripts/vendor-markdown.sh`.
DOMPurify sanitizes untrusted Markdown before it hits the DOM, so keep it current.

`pele.global.js`, the diagram engine, is the exception: it is NOT in `template.html`. At 0.7 MB
it is most of the bundled script and almost no file has a diagram, so `render.js` injects it
on demand, the first time a document actually contains a \`\`\`mermaid fence.

| File | Package | Version | SHA-256 | Source |
|------|---------|---------|---------|--------|
| `dompurify.min.js` | dompurify | 3.5.0 | `f69a46022ab1f53e969c8ebbca98172c8995785a9b3be72ea4a12d25b1a1bf67` | https://cdn.jsdelivr.net/npm/dompurify@3.5.0/dist/purify.min.js |
| `marked.min.js` | marked | 18.3.0 | `4d31a4e7ba7f4e169860f1e85b991639cb04d457b0b0204dbb0723b3871e0c90` | https://cdn.jsdelivr.net/npm/marked@18.3.0/lib/marked.umd.min.js |
| `pele.global.js` | pele | 1.13.0 | `0b0a46c57a5a6971670c09f5ec4066705bd78505f90fd11adf6260325efa0910` | https://cdn.jsdelivr.net/npm/pele@1.13.0/dist/pele.global.js |
