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

// mermaid's generated SVG never passes through the DOMPurify call in renderMarkdown (that pass only
// ever saw the fenced block as inert text). Two gates cover mermaid output instead: `securityLevel:
// 'strict'` sanitizes diagram text inside mermaid, and renderMermaid() runs the returned SVG through
// DOMPurify before it reaches the DOM. `htmlLabels: false` makes mermaid draw labels as native SVG
// <text> rather than HTML inside <foreignObject> — foreignObject is an mXSS vector DOMPurify strips as
// a tag, which would otherwise blank every label. startOnLoad is off — we drive rendering explicitly.
function initMermaid(theme) {
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme,
    htmlLabels: false,
    flowchart: { htmlLabels: false },
  });
}
initMermaid(mermaidTheme);

function renderMarkdown(source) {
  lastSource = source;
  const dirty = marked.parse(source);
  // Untrusted Markdown can embed raw HTML; strip anything executable before it touches the DOM.
  const clean = DOMPurify.sanitize(dirty, {
    USE_PROFILES: { html: true }, // HTML only — drop user-authored SVG/MathML (mermaid emits its own)
    ADD_TAGS: ["input"], // GitHub-style task-list checkboxes
    ADD_ATTR: ["target"],
  });
  const root = document.getElementById("content");
  root.innerHTML = clean;
  promoteMermaidBlocks(root);
  renderMermaid(root);
}

// marked emits a ```mermaid fence as <pre><code class="language-mermaid">…</code></pre>; mermaid wants
// a bare <pre class="mermaid"> holding the diagram source. Rewrite each such block in place. The
// original text is read from textContent (inert text, not markup) — mermaid parses it under
// securityLevel 'strict' and renderMermaid sanitizes the resulting SVG.
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

// Render each promoted mermaid block. We use mermaid.render() rather than mermaid.run() (which writes
// SVG straight into the DOM) so the generated SVG can be run through DOMPurify before it is inserted —
// diagram labels are attacker-influenced and would otherwise never meet a sanitizer. Each block is
// caught independently, so one bad diagram is left showing its source text and can't blank the doc.
let mermaidSeq = 0;
function renderMermaid(root) {
  const holders = root.querySelectorAll("pre.mermaid");
  holders.forEach((holder) => {
    const source = holder.textContent;
    mermaid
      .render("mmd-" + mermaidSeq++, source)
      .then(({ svg }) => {
        // mermaid emits native SVG <text> labels (htmlLabels:false above), so an svg-only sanitize
        // keeps them while dropping foreignObject/HTML. DOMPurify still strips scripts / on* handlers
        // / javascript: URLs, so mermaid output is gated without widening the allowed-tag surface.
        holder.innerHTML = DOMPurify.sanitize(svg, {
          USE_PROFILES: { svg: true, svgFilters: true },
        });
      })
      .catch(() => {
        /* leave the source text in place */
      });
  });
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
    initMermaid(mermaidTheme);
    if (lastSource) renderMarkdown(lastSource); // re-render so diagrams pick up the new theme
  }
};
