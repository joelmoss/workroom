const featureContent = {
  workrooms: {
    heading: "Parallel workrooms",
    copy: "Open several isolated tasks at once and keep their project, branch, terminals and status visibly separate.",
    caption: "Active: parallel workrooms, terminals, diffs and review stay visible together.",
  },
  splits: {
    heading: "Terminal + workroom splits",
    copy: "Arrange multiple workrooms side by side, then split each one into the terminal or content panes its task needs.",
    caption: "Active: workroom and terminal splits keep concurrent contexts on screen.",
  },
  diffs: {
    heading: "Syntax-highlighted diffs",
    copy: "Review working-copy changes and changesets in unified or side-by-side views with language-aware highlighting.",
    caption: "Active: syntax-highlighted diffs sit beside terminals and VCS state.",
  },
  files: {
    heading: "Files + VCS state",
    copy: "Browse and read project files while changes, history, pull requests, CI and notifications remain close by.",
    caption: "Active: file viewer, history, pull requests, CI and notifications share one room.",
  },
};

const controls = [...document.querySelectorAll("[data-feature]")];
const mosaics = [...document.querySelectorAll("[data-mosaic]")];
const heading = document.querySelector("#feature-heading");
const copy = document.querySelector("#feature-copy");
const proofCaption = document.querySelector("#proof-caption");

controls.forEach((control) => {
  control.addEventListener("click", () => {
    const feature = control.dataset.feature;
    const content = featureContent[feature];

    controls.forEach((item) => item.setAttribute("aria-pressed", String(item === control)));
    mosaics.forEach((item) => item.classList.toggle("is-active", item.dataset.mosaic === feature));

    heading.textContent = content.heading;
    copy.textContent = content.copy;
    proofCaption.textContent = content.caption;
  });
});
