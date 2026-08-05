const markPath = "M2 2h9v9H2zM14 2h8v9h-8zM25 2h9v9h-9zM2 14h9v8H2zM25 14h9v8h-9zM2 25h9v9H2zM14 25h8v9h-8zM25 25h9v9h-9z";

const presets = {
  workroom: {
    word: "Workroom",
    subtitle: "",
    subtitleVisible: false,
    canvasWidth: 1120,
    canvasHeight: 280,
    markX: 62,
    markY: 83.75,
    markScale: 3.625,
    wordX: 220,
    wordY: 206,
    wordSize: 164,
    wordTracking: 1,
    subtitleX: 220,
    subtitleY: 274,
    subtitleSize: 56,
    subtitleTracking: 2,
    primaryColor: "#ffea00",
    subtitleColor: "#9f9300",
    backgroundColor: "#000000",
    transparentBackground: false,
  },
  codaset: {
    word: "Codaset",
    subtitle: "",
    subtitleVisible: false,
    canvasWidth: 920,
    canvasHeight: 280,
    markX: 62,
    markY: 83.75,
    markScale: 3.625,
    wordX: 220,
    wordY: 206,
    wordSize: 164,
    wordTracking: 1,
    subtitleX: 220,
    subtitleY: 274,
    subtitleSize: 56,
    subtitleTracking: 2,
    primaryColor: "#ffea00",
    subtitleColor: "#9f9300",
    backgroundColor: "#000000",
    transparentBackground: false,
  },
  endorsed: {
    word: "Workroom",
    subtitle: "by Codaset",
    subtitleVisible: true,
    canvasWidth: 1120,
    canvasHeight: 320,
    markX: 62,
    markY: 83.75,
    markScale: 3.625,
    wordX: 220,
    wordY: 206,
    wordSize: 164,
    wordTracking: 1,
    subtitleX: 220,
    subtitleY: 274,
    subtitleSize: 56,
    subtitleTracking: 2,
    primaryColor: "#ffea00",
    subtitleColor: "#9f9300",
    backgroundColor: "#000000",
    transparentBackground: false,
  },
};

let activePreset = "endorsed";
let state = loadState() || structuredClone(presets.endorsed);
let fontDataUrlPromise;

const preview = document.querySelector("#logoPreview");
const previewBackground = document.querySelector("#previewBackground");
const previewMark = document.querySelector("#previewMark");
const previewWord = document.querySelector("#previewWord");
const previewSubtitle = document.querySelector("#previewSubtitle");
const status = document.querySelector("#exportStatus");

const keyInputs = [...document.querySelectorAll("[data-key]")];
const presetButtons = [...document.querySelectorAll("[data-preset]")];

function loadState() {
  try {
    return JSON.parse(localStorage.getItem("codaset-logo-lab"));
  } catch {
    return null;
  }
}

function saveState() {
  localStorage.setItem("codaset-logo-lab", JSON.stringify(state));
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function setKnob(input) {
  const min = Number(input.min);
  const max = Number(input.max);
  const ratio = (Number(input.value) - min) / (max - min);
  const turn = -120 + ratio * 240;
  input.closest(".knob").style.setProperty("--turn", `${turn}deg`);
}

function setOutput(input) {
  const output = input.closest("label")?.querySelector("output");
  if (!output) return;
  const suffix = input.id === "markScale" ? "×" : input.closest(".knob-control") ? "px" : "";
  output.value = `${Number(input.value).toLocaleString(undefined, { maximumFractionDigits: 3 })}${suffix}`;
}

function syncControls() {
  document.querySelector("#wordInput").value = state.word;
  document.querySelector("#subtitleInput").value = state.subtitle;
  document.querySelector("#subtitleVisible").checked = state.subtitleVisible;
  document.querySelector("#primaryColor").value = state.primaryColor;
  document.querySelector("#subtitleColor").value = state.subtitleColor;
  document.querySelector("#backgroundColor").value = state.backgroundColor;
  document.querySelector("#transparentBackground").checked = state.transparentBackground;
  document.querySelector("#canvasWidth").value = state.canvasWidth;
  document.querySelector("#canvasHeight").value = state.canvasHeight;

  keyInputs.forEach((input) => {
    if (state[input.dataset.key] !== undefined) input.value = state[input.dataset.key];
    setOutput(input);
    if (input.closest(".knob")) setKnob(input);
  });

  presetButtons.forEach((button) => button.classList.toggle("is-active", button.dataset.preset === activePreset));
}

function render() {
  const width = clamp(Number(state.canvasWidth) || 1120, 320, 2400);
  const height = clamp(Number(state.canvasHeight) || 320, 160, 1200);
  state.canvasWidth = width;
  state.canvasHeight = height;

  preview.setAttribute("viewBox", `0 0 ${width} ${height}`);
  previewBackground.setAttribute("width", width);
  previewBackground.setAttribute("height", height);
  previewBackground.setAttribute("fill", state.backgroundColor);
  previewBackground.style.display = state.transparentBackground ? "none" : "block";

  previewMark.setAttribute("fill", state.primaryColor);
  previewMark.setAttribute("transform", `translate(${state.markX} ${state.markY}) scale(${state.markScale})`);

  previewWord.textContent = state.word || " ";
  previewWord.setAttribute("x", state.wordX);
  previewWord.setAttribute("y", state.wordY);
  previewWord.setAttribute("fill", state.primaryColor);
  previewWord.style.fontSize = `${state.wordSize}px`;
  previewWord.style.letterSpacing = `${state.wordTracking}px`;

  previewSubtitle.textContent = state.subtitle || " ";
  previewSubtitle.setAttribute("x", state.subtitleX);
  previewSubtitle.setAttribute("y", state.subtitleY);
  previewSubtitle.setAttribute("fill", state.subtitleColor);
  previewSubtitle.style.fontSize = `${state.subtitleSize}px`;
  previewSubtitle.style.letterSpacing = `${state.subtitleTracking}px`;
  previewSubtitle.style.display = state.subtitleVisible ? "block" : "none";

  document.querySelector("#canvasReadout").textContent = `${width} × ${height}`;
  document.querySelector("#primaryHex").textContent = state.primaryColor.toUpperCase();
  document.querySelector("#subtitleHex").textContent = state.subtitleColor.toUpperCase();
  document.querySelector("#backgroundHex").textContent = state.backgroundColor.toUpperCase();
  document.querySelector(".subtitle-axes").hidden = !state.subtitleVisible;
  document.querySelector("#subtitleKnob").closest(".knob-control").style.opacity = state.subtitleVisible ? "1" : "0.35";

  saveState();
}

function applyPreset(name) {
  activePreset = name;
  state = structuredClone(presets[name]);
  syncControls();
  render();
  status.textContent = `${name[0].toUpperCase()}${name.slice(1)} preset loaded.`;
}

keyInputs.forEach((input) => {
  input.addEventListener("input", () => {
    state[input.dataset.key] = Number(input.value);
    setOutput(input);
    if (input.closest(".knob")) setKnob(input);
    render();
  });
});

presetButtons.forEach((button) => button.addEventListener("click", () => applyPreset(button.dataset.preset)));

document.querySelector("#wordInput").addEventListener("input", (event) => {
  state.word = event.target.value;
  render();
});

document.querySelector("#subtitleInput").addEventListener("input", (event) => {
  state.subtitle = event.target.value;
  render();
});

document.querySelector("#subtitleVisible").addEventListener("change", (event) => {
  state.subtitleVisible = event.target.checked;
  render();
});

for (const [id, key] of [["primaryColor", "primaryColor"], ["subtitleColor", "subtitleColor"], ["backgroundColor", "backgroundColor"]]) {
  document.querySelector(`#${id}`).addEventListener("input", (event) => {
    state[key] = event.target.value;
    render();
  });
}

document.querySelector("#transparentBackground").addEventListener("change", (event) => {
  state.transparentBackground = event.target.checked;
  render();
});

document.querySelector("#canvasWidth").addEventListener("input", (event) => {
  state.canvasWidth = Number(event.target.value);
  render();
});

document.querySelector("#canvasHeight").addEventListener("input", (event) => {
  state.canvasHeight = Number(event.target.value);
  render();
});

document.querySelector("#resetButton").addEventListener("click", () => applyPreset(activePreset));

async function getFontDataUrl() {
  if (!fontDataUrlPromise) {
    fontDataUrlPromise = fetch("assets/fonts/barlow-condensed-700.ttf")
      .then((response) => response.arrayBuffer())
      .then((buffer) => {
        const bytes = new Uint8Array(buffer);
        let binary = "";
        const chunk = 0x8000;
        for (let index = 0; index < bytes.length; index += chunk) {
          binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
        }
        return `data:font/ttf;base64,${btoa(binary)}`;
      });
  }
  return fontDataUrlPromise;
}

function escapeXml(value) {
  return value.replace(/[<>&"']/g, (character) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" })[character]);
}

async function buildSvg() {
  const fontData = await getFontDataUrl();
  const width = state.canvasWidth;
  const height = state.canvasHeight;
  const background = state.transparentBackground ? "" : `<rect width="${width}" height="${height}" fill="${state.backgroundColor}"/>`;
  const subtitle = state.subtitleVisible
    ? `<text x="${state.subtitleX}" y="${state.subtitleY}" fill="${state.subtitleColor}" font-family="Logo Barlow" font-size="${state.subtitleSize}" font-weight="700" letter-spacing="${state.subtitleTracking}">${escapeXml(state.subtitle)}</text>`
    : "";

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${escapeXml(state.word)} logo">
  <style>@font-face{font-family:"Logo Barlow";src:url("${fontData}") format("truetype");font-weight:700}</style>
  ${background}
  <g fill="${state.primaryColor}" transform="translate(${state.markX} ${state.markY}) scale(${state.markScale})"><path d="${markPath}"/></g>
  <text x="${state.wordX}" y="${state.wordY}" fill="${state.primaryColor}" font-family="Logo Barlow" font-size="${state.wordSize}" font-weight="700" letter-spacing="${state.wordTracking}">${escapeXml(state.word)}</text>
  ${subtitle}
</svg>`;
}

function filename(extension) {
  const base = (state.word || "logo").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  return `${base}${state.subtitleVisible ? "-by-codaset" : ""}.${extension}`;
}

function download(blob, name) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

document.querySelector("#downloadSvg").addEventListener("click", async () => {
  status.textContent = "Building self-contained SVG…";
  try {
    const svg = await buildSvg();
    download(new Blob([svg], { type: "image/svg+xml" }), filename("svg"));
    status.textContent = "SVG downloaded.";
  } catch {
    status.textContent = "Export failed. Reload the page and try again.";
  }
});

document.querySelector("#downloadPng").addEventListener("click", async () => {
  status.textContent = "Rendering PNG…";
  try {
    const svg = await buildSvg();
    const blob = new Blob([svg], { type: "image/svg+xml" });
    const url = URL.createObjectURL(blob);
    const image = new Image();
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = reject;
      image.src = url;
    });
    const canvas = document.createElement("canvas");
    canvas.width = state.canvasWidth;
    canvas.height = state.canvasHeight;
    canvas.getContext("2d").drawImage(image, 0, 0);
    URL.revokeObjectURL(url);
    canvas.toBlob((png) => {
      download(png, filename("png"));
      status.textContent = "PNG downloaded.";
    }, "image/png");
  } catch {
    status.textContent = "Export failed. Reload the page and try again.";
  }
});

syncControls();
render();
