# docs-site

The source of the Workroom documentation site, served by Codaset at `/workroom/docs`. The plan and
every decision behind it are in [`docs/designs/docs-site.md`](../docs/designs/docs-site.md).

This file is the format contract. Codaset's renderer and this repo's check
(`internal/docsite/docsite_test.go`) both implement what it says. If you change a rule here, change both.

## Preview and check

- `make docs-preview` runs Codaset's dev server against this checkout's `docs-site/`, at
  `https://workroom-docs.localhost/workroom/docs`. Refresh the page to see a saved edit. It needs a
  Codaset checkout at `$CODASET_PATH`, which defaults to `~/dev/codaset`, and runs beside Codaset's own
  dev server.
- `make docs-check` runs the checks below. CI runs them too.
- `make docs-cli` regenerates the CLI reference after you change a command or flag.

## Layout

```
docs-site/
  nav.yml          the sidebar: groups, page order, sidebar titles
  pages/           one Markdown file per page
    index.md       the docs home, at /workroom/docs
  images/          images the pages use
```

`index.md` holds only the home page's introduction. Codaset's home layout adds the search box, the
cards (Install, Your first workroom, Guides) and the list of every section, taken from `nav.yml`.

A page's URL is its path under `pages/` without `.md`. For example,
`pages/guides/review-and-ship.md` is served at `/workroom/docs/guides/review-and-ship`, and `pages/index.md`
is served at `/workroom/docs`. Adding `.md` to any URL returns the page's raw Markdown.

Files and folders whose names start with `.` are ignored. Other file and folder names use lowercase
letters, digits and hyphens only. Every page apart from `index.md` sits
exactly one folder deep.

## nav.yml

`nav.yml` is a list of groups. Each group has a `title` and a list of `pages`. Each page entry has a
`title`, which is the text shown in the sidebar, and a `page`, which is the page's path under `pages/`
without `.md`.

```yaml
- title: Get started
  pages:
    - title: Introduction
      page: get-started/introduction
```

The sidebar, the page order, and Previous/Next all follow `nav.yml`. Every page except `index.md` appears in
it exactly once.

## Front matter

Every page starts with YAML front matter, and it can have only these keys:

| Key           | Required | Meaning                                                                  |
| ------------- | -------- | ------------------------------------------------------------------------ |
| `title`       | yes      | The page's `<h1>` and `<title>`. Don't repeat it as a `#` heading.       |
| `description` | yes      | One sentence, used for the meta description, `llms.txt` and search.      |
| `nightly`     | no       | `true` marks the whole page as Nightly only, and shows a Nightly badge.  |

## Markdown

Pages use GitHub-flavoured Markdown (tables, task lists, strikethrough, autolinks), with these rules.

- Headings use `##` to `####`, written ATX-style (`## Heading`). Setext (underlined) headings are not used.
- A heading that ends in ` {nightly}` marks that section as Nightly only. The renderer removes the marker
  and shows a badge in its place.
- Alerts are written as `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]` or `> [!CAUTION]`.
- `<kbd>` is the only raw HTML allowed, used for keys. A combination is one `<kbd>`: `<kbd>⌘D</kbd>`, `<kbd>⌃Tab</kbd>`. HTML comments are allowed
  and never shown.
- Code blocks are fenced with three backticks and name their language, for example `sh`, `json` or `text`.
- Links to other pages are relative paths to their `.md` files, with an optional anchor:
  `[Review and ship](../guides/review-and-ship.md#open-a-pull-request)`. The renderer rewrites them to page
  URLs. They work when you browse the folder on GitHub as well.
- Images are relative paths into `images/`: `![The sidebar](../../images/sidebar.png)`. When
  `sidebar.dark.png` exists next to `sidebar.png`, the renderer uses it in dark mode. Every image needs alt
  text. Images are `.png`, `.jpg`, `.jpeg`, `.gif` or `.webp` files, never symlinks.
- Reference-style links (`[text][ref]`) are not used.

## Heading anchors

Every `##` to `####` heading gets an `id`, which is its anchor. The id is derived like this:

1. Take the heading's text without its Markdown. Code spans keep their text, links keep their link text, and
   emphasis and `<kbd>` tags are dropped. Remove a trailing ` {nightly}` marker.
2. Lowercase it.
3. Remove every character that is not a letter, mark, number, connector punctuation (such as `_`), space or
   hyphen.
4. Replace each space with `-`.
5. If an earlier heading on the page already has this id, append `-1`, then `-2`, and so on.

This is the algorithm commonmarker's `header_ids` option uses, so Codaset can rely on it.

## Keyboard shortcuts

`pages/reference/keyboard-shortcuts.md` has a `##` heading per group the app's Keyboard Shortcuts sheet
shows, and one table row per shortcut, written exactly `| <label> | <kbd><keys></kbd> |`, with no
padding. `macapp/WorkroomAppTests/KeyboardShortcutsDocsTests.swift` fails when a shortcut in
`KeyboardShortcutsView.swift` has no matching row.

## CLI reference

The pages under `pages/cli/` are generated from the CLI's cobra commands. Don't edit them by hand; run
`make docs-cli` instead. There is one page per public command, named after its command path, so
`workroom create` is `cli/workroom-create.md`. `nav.yml` lists each one in the CLI group, and the test in
`cmd/docs_test.go` fails when they are stale.

## Search, `.md` and `llms.txt`

Codaset builds these from the pages, so nothing in this folder needs to change for them.

- The search index holds every page's title, description, headings and body text.
- `/workroom/docs/llms.txt` lists every page in `nav.yml` order, as a Markdown link followed by its
  `description`.
