---
name: "Workroom Broadcast Index"
description: "A high-contrast developer broadcast for isolated parallel work."
colors:
  broadcast-black: "#000000"
  panel-ink: "#050505"
  signal-white: "#ffffff"
  muted-signal: "#bfc3c5"
  workroom-yellow: "#ffea00"
  split-cyan: "#00e6ef"
  review-green: "#00e24b"
  alert-red: "#f3261f"
  channel-blue: "#162acb"
  auxiliary-magenta: "#ef2bc4"
typography:
  display:
    fontFamily: "Barlow Condensed, Arial Narrow, sans-serif"
    fontSize: "clamp(3.9rem, 6.5vw, 6rem)"
    fontWeight: 700
    lineHeight: 0.88
    letterSpacing: "-0.025em"
  headline:
    fontFamily: "Barlow Condensed, Arial Narrow, sans-serif"
    fontSize: "clamp(2.5rem, 5vw, 5.5rem)"
    fontWeight: 700
    lineHeight: 0.9
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Barlow Condensed, Arial Narrow, sans-serif"
    fontSize: "clamp(1.5rem, 2.4vw, 2.5rem)"
    fontWeight: 700
    lineHeight: 1
  body:
    fontFamily: "Share Tech Mono, ui-monospace, monospace"
    fontSize: "18px"
    fontWeight: 400
    lineHeight: 1.42
  label:
    fontFamily: "Share Tech Mono, ui-monospace, monospace"
    fontSize: "0.8rem"
    fontWeight: 400
    lineHeight: 1.42
    letterSpacing: "normal"
  control:
    fontFamily: "Barlow Condensed, Arial Narrow, sans-serif"
    fontSize: "1.2rem"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "0.04em"
rounded:
  cell: "0"
spacing:
  cell: "clamp(6px, 0.64vw, 10px)"
  gutter: "clamp(16px, 2vw, 32px)"
  compact: "8px"
  control: "14px"
  section: "clamp(42px, 6vw, 96px)"
components:
  button-primary:
    backgroundColor: "{colors.workroom-yellow}"
    textColor: "{colors.broadcast-black}"
    typography: "{typography.control}"
    rounded: "{rounded.cell}"
    padding: "14px 22px"
    height: "58px"
  button-primary-hover:
    backgroundColor: "{colors.channel-blue}"
    textColor: "{colors.signal-white}"
    rounded: "{rounded.cell}"
---

# Design System: Workroom Broadcast Index

## Overview

**Creative North Star: "The Live Developer Broadcast"**

Workroom presents parallel development as a focused live service: terse, exact, high-contrast, and always visibly in progress. Its visual language borrows the strongest universal qualities of broadcast teletext—hard color bands, condensed display type, block geometry, and dense information framing—without depending on page numbers or specialist teletext vocabulary.

The system refuses soft, centered SaaS polish. It is intentionally flat, rectilinear, and cell-aligned. Visual personality comes from role-specific signal colors and the rhythm of hard divisions, not gradients, glass, rounded cards, stock illustrations, or decorative shadows.

**Key Characteristics:**

- Broadcast-black fields divided by exact, high-contrast rules.
- Fixed yellow, cyan, green, red, and blue roles; color communicates channel and state.
- Smooth condensed display type paired with readable monospaced copy.
- Clear labels, block mosaics, and square marks.
- Dense on wide screens, structurally stacked on narrow screens without losing the lattice.
- Motion is sparse, discrete, and non-essential.

## Colors

The palette behaves like a broadcast signal kit: pure dark fields, bright fixed-function channels, and restrained neutral copy.

### Primary

- **Workroom Yellow:** The brand signal, primary action fill, key display copy, and principal frame color.

### Secondary

- **Split Cyan:** Download-link interaction, split-view framing, selected controls, and captions.
- **Review Green:** Review/file channel markers, positive diff signal, and compact status labels.

### Tertiary

- **Alert Red:** Fact ticker, destructive diff signal, and important disclosure.
- **Channel Blue:** Full-width section bars, mosaic stages, and primary-action hover inversion.
- **Auxiliary Magenta:** Reserved broadcast channel color; use only when a genuinely distinct fifth channel is needed.

### Neutral

- **Broadcast Black:** Canonical page canvas and control field.
- **Panel Ink:** Slightly lifted code/demo surface without introducing shadow.
- **Signal White:** Primary text, structural dividers, and universal focus outline.
- **Muted Signal:** Supporting copy, metadata, and inactive file-tree content.

### Named Rules

**The Fixed Channel Rule.** Yellow means brand/action, cyan means interaction/splits, green means review/files, red means alert, and blue means structural broadcast band; do not casually swap their jobs.

**The Black Field Rule.** Bright signal colors live on black or in flat full-color bands. Do not dilute them into pastel tints or soft neutral cards.

## Typography

**Display Font:** Barlow Condensed (self-hosted 700, with Arial Narrow and sans-serif fallbacks)
**Body Font:** Share Tech Mono (self-hosted 400, with ui-monospace and monospace fallbacks)
**Label/Mono Font:** Share Tech Mono

**Character:** Barlow Condensed supplies a strong broadcast voice without bitmap edges. Share Tech Mono carries longer copy and technical labels with terminal precision; the pairing stays mechanical while remaining clean and readable.

### Hierarchy

- **Display:** Hero-scale statements only; tightly led, slightly tracked inward, and balanced over short lines.
- **Headline:** Major section propositions and feature-state headings, normally capped near 10–12 characters per line.
- **Title:** Channel headings, section bars, brand wordmark, and prominent controls.
- **Body:** Technical explanation and product proof, normally constrained to roughly 46–54 characters per line.
- **Label:** Status, captions, metadata, and uppercase control language.
- **Control:** Primary and secondary action labels in the condensed display face.

### Named Rules

**The Two-Face Rule.** Use Barlow Condensed for display, sectional, and action moments; use Share Tech Mono for readable information. Never introduce a third expressive face.

**The Broadcast-Height Rule.** Display lines are compact and forceful, but retain enough leading for Barlow Condensed's smooth letterforms. Never use the display face for paragraphs.

## Layout

The spatial model is a fluid broadcast lattice. A shared cell unit scales from 6px to 10px; the global inline gutter scales from 16px to 32px. The content canvas is capped at 1720px, centered, and crossed by full-width rule bands. Most composition is CSS Grid with unequal fractions, deliberate minimum widths, and no floating card layer.

Above 1320px, the opening composition keeps the offer and product proof side by side. From 761px through 1320px, the hero copy becomes a compact two-column introduction—headline on the left, explanation and actions on the right—then the real product screenshot spans up to 1120px beneath it. This fills the horizontal space without shrinking the proof into a secondary thumbnail. At 1120px and below, demonstration splits become single-column, three channels become two plus one full-width channel, and the download close becomes a compact two-column arrangement. At 760px and below, the hero returns to a single-column text-first flow, the compact brand/download header remains on one row, all channels stack, the branch diagram rotates into a vertical flow, controls become a two-column matrix, buttons become full width, body type reduces to 16px, the gutter locks to 16px, and the structural rule reduces from 2px to 1px.

Spacing follows cell multiples and a compact broadcast density. Preserve strong outer section padding, then use smaller fixed gaps inside controls, labels, and diagrams. Avoid arbitrary offsets that break visible alignment between neighboring borders.

**The Broadcast Grid Rule.** Every major region should feel clearly structured by row, column, or color channel—even after responsive stacking.

## Elevation & Depth

The system is flat by doctrine and uses no box shadows. Depth comes from contrast, solid color fields, hard borders, slight tonal separation between black and panel ink, and the occasional inset grid texture. Product imagery uses a single strong signal rail and restrained perimeter rather than decorative backing. Focus is expressed with a 3px white outline offset by 4px, never a glow.

**The No-Shadow Rule.** Surfaces separate through rules, fills, and cell patterns. Do not add ambient shadows, soft elevation, glass blur, or neumorphic relief.

## Shapes

All geometry is square and cell-aligned. Components use zero corner radius; frames use 1px, 2px, or 3px hard borders according to hierarchy. Signature silhouettes are assembled from countable rectangles: the compact square pixel mark is a three-by-three perimeter with an open center, carets are clipped polygons, and diagrams use crisp orthogonal paths.

**The Zero-Radius Rule.** Buttons, panels, chips, disclosures, tabs, and frames remain rectangular. A rounded control belongs to another visual world.

**The Countable Geometry Rule.** Decorative forms should resolve into an obvious small grid or orthogonal path rather than organic blobs.

## Components

### Buttons

- **Shape:** Rectangular, zero radius, minimum 58px high, with a 3px current-color border.
- **Primary:** Workroom Yellow fill with Broadcast Black text; on hover or keyboard focus it changes to Channel Blue with Signal White text and a white border.
- **Behavior:** Uppercase Barlow Condensed labels with light tracking, optional block icon, no lift or shadow. On narrow screens buttons span the available width.

### Cards / Containers

- **Corner Style:** Zero radius.
- **Background:** Broadcast Black for standard frames; Panel Ink for code and file demonstrations.
- **Shadow Strategy:** None; see Elevation & Depth.
- **Border:** Hard signal-colored rules that inherit the component's channel.
- **Internal Padding:** Fluid outer padding with compact fixed padding for headers and metadata rows.

### Product Proof Frame

The product screenshot is the dominant surface. Use a 5px Workroom Yellow top rail, a 1px translucent white perimeter, a compact muted metadata row, and a plain Panel Ink caption row. Do not add checker patterns, offset backing layers, signal dots, or heavy internal padding around the image.

### Broadcast Header

A sticky black masthead contains only the shared square Codaset/Workroom mark, the Workroom wordmark, and a yellow download link. The download link inverts to cyan on hover or focus. Do not add section navigation, launch-status labels, or a separate parent-brand logo.

### Section Bars

Section bars are full-width color fields with one condensed title. Blue bars use yellow headings; cyan bars invert content to black.

### Capability Switcher

The capability switcher is a border-divided matrix of plain-language controls. The active or hovered option fills cyan with black text; inactive options remain black with white text. State is communicated with `aria-pressed`, and associated content remains readable without animation.

### Restart Disclosure

The disclosure is a square red frame with a solid red, plainly worded summary row and a literal plus/minus indicator. It is reserved for clarifying constraints or secondary mechanism detail and uses the browser's native open/closed semantics.

### Compact Pixel Mark

The Workroom signature is a square three-by-three perimeter mosaic with an open center, rendered as crisp inline SVG or CSS cells. Default to Workroom Yellow on Broadcast Black, keep it square, and pair it with a text wordmark when brand recognition matters.

## Do's and Don'ts

### Do:

- **Do** preserve fixed semantic color roles across actions, channels, diagrams, and component states.
- **Do** use hard borders and grid alignment to make every region feel clearly structured.
- **Do** keep Barlow Condensed to short, high-impact copy and Share Tech Mono to readable content.
- **Do** preserve minimum 48px interactive targets on narrow screens and the 3px white focus outline.
- **Do** disable smooth scrolling when reduced motion is requested.
- **Do** render the compact square mark from crisp, countable geometry.

### Don't:

- **Don't** add rounded cards, pill chips, gradients, glass, glows, or drop shadows.
- **Don't** soften the palette into pastels, invent nearby shades for decoration, or reassign channel colors arbitrarily.
- **Don't** center every section into a generic hero stack; use unequal grids, restrained product proof, and clear labels.
- **Don't** animate essential content or make state depend on motion.
- **Don't** replace the self-hosted type pairing with generic geometric sans typography.
- **Don't** require knowledge of teletext conventions; broadcast cues must remain understandable in plain language.
