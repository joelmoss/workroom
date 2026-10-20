// Glue between the native MarkdownWebView and the bundled libraries. The Swift side loads
// template.html, then drives this file through two globals it calls via `evaluateJavaScript`:
//
//   window.__render(markdownSource)  — parse + sanitize + inject, then draw any mermaid diagrams
//   window.__applyTheme(vars)        — push theme colours into CSS variables
//
// Diagrams are drawn by Pele, which reads its colours from CSS variables (styles.css maps them to
// the theme's), so a theme change recolours them without drawing them again.

"use strict";

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

// Pele (the diagram engine) is loaded ON DEMAND, the first time a document actually contains a
// ```mermaid fence, rather than by a <script> tag in template.html: most files have no diagram, and
// none of them should pay to parse it. The injected <script> is a sibling file: URL, so the page's
// `script-src 'self'` CSP covers it.
//
// The promise is cached, so N diagrams in one document (and later re-renders) load it once. A failure
// resolves to `false` rather than throwing: a diagram whose engine never arrived must leave its source
// text on screen, exactly like a diagram that fails to parse — it must never blank the document.
let peleLoad = null;
function loadPele() {
  if (peleLoad) return peleLoad;
  peleLoad = new Promise((resolve) => {
    const script = document.createElement("script");
    script.src = "pele.global.js";
    script.onload = () => resolve(true);
    script.onerror = () => resolve(false);
    document.head.appendChild(script);
  });
  return peleLoad;
}

function renderMarkdown(source) {
  const dirty = marked.parse(source);
  // Untrusted Markdown can embed raw HTML; strip anything executable before it touches the DOM.
  const clean = DOMPurify.sanitize(dirty, {
    USE_PROFILES: { html: true }, // HTML only — drop user-authored SVG/MathML (Pele emits its own)
    ADD_TAGS: ["input"], // GitHub-style task-list checkboxes
    ADD_ATTR: ["target"],
  });
  const root = document.getElementById("content");
  root.innerHTML = clean;
  promoteMermaidBlocks(root);
  renderMermaid(root);
}

// marked emits a ```mermaid fence as <pre><code class="language-mermaid">…</code></pre>; rewrite each
// as a bare <pre class="mermaid"> holding the diagram source. The original text is read from
// textContent (inert text, not markup), and renderMermaid sanitizes the SVG drawn from it.
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

// Draw each promoted block with pele.render(), which returns an SVG string, rather than pele.mount(),
// which writes it straight into the DOM, so the SVG goes through DOMPurify first — diagram labels are
// attacker-influenced and would otherwise never meet a sanitizer. Pele draws labels as SVG <text>,
// never <foreignObject>, so the svg-only profile keeps them. Labels use the document's font, sized to
// match it, and the width available lets a wide flowchart turn to run down. Each block is caught
// independently, so one bad diagram is left showing its source text and can't blank the document.
const DIAGRAM_FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';
let diagramSeq = 0;
async function renderMermaid(root) {
  const holders = root.querySelectorAll("pre.mermaid");
  if (holders.length === 0) return;  // the common case: no diagrams, so Pele is never fetched
  if (!(await loadPele())) return;  // engine unavailable — leave every block's source text
  holders.forEach((holder) => {
    try {
      const { svg } = pele.render(holder.textContent, {
        idPrefix: "d" + diagramSeq++ + "-",
        fontFamily: DIAGRAM_FONT,
        fontSize: 14,
        maxWidth: holder.clientWidth || undefined,
      });
      holder.innerHTML = DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true } });
    } catch {
      /* leave the source text in place */
    }
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
  Object.keys(vars).forEach((key) => style.setProperty("--" + key, vars[key]));
};
