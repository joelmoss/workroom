// Glue between the native MarkdownWebView and the bundled libraries. The Swift side loads
// template.html, then drives this file through two globals it calls via `evaluateJavaScript`:
//
//   window.__render(markdownSource)  — parse + sanitize + inject, then render any mermaid diagrams
//   window.__applyTheme(vars)        — push theme colours into CSS variables and recolour diagrams
//
// The last-rendered source is retained so a theme change can re-render (mermaid bakes colours into
// the SVG at render time, so recolouring means re-running it).

"use strict";

let lastSource = "";
let mermaidTheme = "default";

marked.setOptions({ gfm: true, breaks: false });

// mermaid draws into whatever we hand it; `securityLevel: 'strict'` makes it sanitize diagram text,
// a second layer behind DOMPurify. startOnLoad is off — we drive it explicitly after each render.
mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: mermaidTheme });

function renderMarkdown(source) {
  lastSource = source;
  const dirty = marked.parse(source);
  // Untrusted Markdown can embed raw HTML; strip anything executable before it touches the DOM.
  const clean = DOMPurify.sanitize(dirty, {
    ADD_TAGS: ["input"], // GitHub-style task-list checkboxes
    ADD_ATTR: ["target"],
  });
  const root = document.getElementById("content");
  root.innerHTML = clean;
  promoteMermaidBlocks(root);
  runMermaid(root);
}

// marked emits a ```mermaid fence as <pre><code class="language-mermaid">…</code></pre>; mermaid wants
// a bare <pre class="mermaid"> holding the diagram source. Rewrite each such block in place. The
// original text is read from textContent, so DOMPurify has already neutralised anything hostile.
function promoteMermaidBlocks(root) {
  const codes = root.querySelectorAll("code.language-mermaid");
  codes.forEach((code) => {
    const pre = code.closest("pre") || code;
    const holder = document.createElement("pre");
    holder.className = "mermaid";
    holder.textContent = code.textContent;
    pre.replaceWith(holder);
  });
}

function runMermaid(root) {
  const nodes = root.querySelectorAll("pre.mermaid");
  if (nodes.length === 0) return;
  // suppressErrors keeps one bad diagram from blanking the whole document; the offending block is
  // left showing its source text instead.
  mermaid.run({ nodes: Array.from(nodes), suppressErrors: true }).catch(() => {});
}

window.__render = function (source) {
  try {
    renderMarkdown(source);
  } catch (e) {
    document.getElementById("content").textContent = String(source);
  }
};

window.__applyTheme = function (vars) {
  const style = document.documentElement.style;
  Object.keys(vars).forEach((key) => {
    if (key === "mermaidTheme") return;
    style.setProperty("--" + key, vars[key]);
  });
  if (vars.mermaidTheme && vars.mermaidTheme !== mermaidTheme) {
    mermaidTheme = vars.mermaidTheme;
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: mermaidTheme });
    if (lastSource) renderMarkdown(lastSource); // re-render so diagrams pick up the new theme
  }
};
