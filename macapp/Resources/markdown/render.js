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

// Markdown may embed raw HTML, and marked passes it through untouched. Some tags change how the HTML
// parser treats everything that FOLLOWS them, so an unclosed one eats the rest of the document. A
// bare prose mention is enough — `a label ("Terminal <title>, pane N of M")` in TODOS.md made the
// preview render ~12% of the file while the source view showed all of it. Two distinct mechanisms:
//
//   1. DELETED. <title>/<textarea> hold *escapable raw text*, <script>/<style>/<xmp>/<plaintext>
//      hold *raw text* — the remainder of the document becomes that element's text content, and
//      DOMPurify then drops it wholesale, since all of them are in its FORBID_CONTENTS set (tag
//      *and* children removed). An unbalanced `<!--` behaves the same way.
//   2. REPARENTED, then not rendered. <select>/<dialog>/<object>/<applet> keep the text in the DOM
//      but adopt the remainder as their children, and none of them renders arbitrary children — a
//      <select> shows a dropdown, a <dialog> without `open` is display:none, <object>/<applet>
//      children are unrendered fallback content. Same "file is cut off" symptom, so same treatment.
//
// A raw-HTML chunk carrying one of those tags is escaped to visible text instead of passed through as
// markup. Everything else (GitHub-style <details>, <br>, <img>, <sub>, raw <table>…) still flows to
// DOMPurify unchanged — it remains the security gate; this only stops the *parser* from eating the
// document. Escaping is strictly safer than passing through, so it never widens the attack surface.
//
// Deliberately NOT here: an unclosed <div>/<a>/<ul>/<li>/<code>/<details> also adopts what follows,
// but still *renders* it (wrapped or styled oddly, not hidden). That is what raw HTML in Markdown
// means, and GitHub renders it the same way, so escaping those would break real documents.
const SWALLOWING_TAGS =
  /<\/?(?:script|style|textarea|title|xmp|plaintext|noembed|noframes|noscript|iframe|template|select|dialog|object|applet)[\s/>]/i;

function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Whether a raw-HTML chunk can be handed to the parser as markup without it eating the rest of the
// document. The trailing `[\s/>]` in SWALLOWING_TAGS keeps `<titlebar>` from matching `<title`.
function isInertMarkup(raw) {
  const opened = (raw.match(/<!--/g) || []).length;
  const closed = (raw.match(/-->/g) || []).length;
  if (opened !== closed) return false;
  return !SWALLOWING_TAGS.test(raw.replace(/<!--[\s\S]*?-->/g, ""));
}

// Applies to inline *and* block raw-HTML tokens — marked routes both through renderer.html. The
// token/string dance covers both marked signatures: current versions pass a token object, older ones
// passed the raw HTML string. Without it, re-vendoring an older marked would make `token.text`
// undefined and throw, degrading every file with raw HTML to unformatted plain text.
marked.use({
  renderer: {
    html(token) {
      const raw = typeof token === "string" ? token : token.text;
      if (typeof raw !== "string") return "";
      return isInertMarkup(raw) ? raw : escapeHtml(raw);
    },
  },
});

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
