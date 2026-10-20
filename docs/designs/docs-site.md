# Workroom documentation site

Status: built (2026-10-20) in workroom PR #512 and Codaset PR #58, not yet merged or deployed.
Every decision below was made by the owner in a grilling session (Q1–Q32); "As built" notes record
where the build differs.

Workroom has no user documentation beyond `README.md`. This plan builds a full docs site, served by
the Codaset app at `codaset.dev/workroom/docs`, with the content kept in this repo.

## Facts the plan rests on

- **Codaset** (`~/dev/codaset`, `joelmoss/codaset`) is Rails 8.1 on Ruby 4.0.3. Views are Phlex
  classes and assets go through Proscenium. Its JS is plain per-page files plus Action Cable and
  idiomorph, with no Stimulus, Turbo or React. It has no Markdown pipeline and no search today.
- **The `/workroom` page** is `get 'workroom' => 'pages#workroom'` (`config/routes.rb:25`). Its view
  is `app/views/pages/workroom.rb` with `workroom.css` and `workroom.js`, and it uses the layout
  `app/views/layouts/base.rb`. It is public. Every other route except the landing page needs `WIP`
  (`config/routes.rb:27`).
- **Codaset's CSP** (`config/initializers/content_security_policy.rb`) uses nonces and allows no
  inline styles or scripts. Rendered Markdown must not emit `style=` attributes.
- **Codaset has two styles**, and its `DESIGN.md` forbids a third. The Workroom style (Barlow
  Condensed and Share Tech Mono, black with a grid) is dark only. The Codaset style (Inter,
  `light-dark()` tokens in `lib/themes/tokens.css`, a 65ch measure) has light and dark modes.
- **Codaset is deployed with Hatchbox.** A deploy runs a script on the server (bundle, yarn,
  `assets:precompile`, migrate), with build hooks it runs from the repo (`.hatchbox/pre-build` and
  others, Hatchbox help article 18) or from per-app settings, and `$RELEASE_DIR` set. A deploy can be triggered with
  `POST https://app.hatchbox.io/webhooks/deployments/<TOKEN>?sha=<SHA>`.
  Sources: Hatchbox help articles 28, 55 and 73.
- **Codaset's CI** (`.github/workflows/ci.yml`) runs on PRs and pushes to master. It has no deploy
  job.
- **This repo is public.** The CLI is built on cobra v1.10.2 (`go.mod`). The canonical shortcut list
  is `macapp/WorkroomApp/Views/KeyboardShortcutsView.swift`. The app has no Help menu entries of
  its own.

## Decisions

### Content and audience

- **D1. The content lives in this repo**, under `docs-site/`. Codaset only renders it, so a feature
  PR can carry its own docs change.
- **D2. The docs are for people who use Workroom.** The main reader is a developer new to the Mac
  app, and power users (the CLI, remote hosts, scripts) come second. Contributor docs stay in the
  repo (`CONTRIBUTING.md`, `AGENTS.md`).
- **D3. There is one living version, built from master.** A feature not yet in a stable release
  carries a Nightly badge. There is no version picker.
- **D4. The docs can be read by AI.** Every page is also served as raw Markdown at `<url>.md`.
  `/workroom/docs/llms.txt` lists every page. Each page has a "Copy page" button.
- **D5. Claude drafts and the owner reviews.** Every page is drafted from the code and the existing
  docs, then checked against the real app before it ships. No feature is described from memory.

### Rendering, search and look

- **D6. Codaset renders Markdown itself.** It uses `commonmarker` for Markdown and `rouge` for code
  highlighting on the server. One `DocsController` and one Phlex layout serve every page. In
  production each page is cached by content hash. No highlighting JS ships.
  - **As built:** `WorkroomDocsController`, `Layouts::Docs` and the `WorkroomDocs` model. Outside
    development each page is rendered once and kept for the life of the process, because the docs
    can't change without a deploy, so there is no content-hash cache. Rouge highlights each code
    block in a Nokogiri pass into classes coloured from Codaset's tokens. Commonmarker's own
    highlighter is off, because it writes inline styles that the CSP refuses.
- **D7. Search uses MiniSearch in the browser.** The JSON index is built from the same Markdown and
  covers titles, headings and body text, with typo tolerance. ⌘K and `/` open the search box. A
  result jumps straight to the heading it matched.
- **D8. Pages use the Codaset reading style with Workroom branding.** That means Inter, the Codaset
  tokens and the 65ch measure, plus Workroom's logo, mark and yellow accent. Light, dark and auto
  modes are all supported. No third style is invented.

### Table of contents

- **D9. The sidebar groups are as follows.**

  ```
  Get started
    Introduction            what Workroom is; project, workroom, host, base
    Install                 app, CLI in PATH, Nightly
    Your first workroom     guided walkthrough, start to merged PR
  Guides
    Prepare a project       setup/teardown scripts, script trust, .worktreeinclude, run command
    Run agents in parallel  one workroom per task, alerts, usage
    Review and ship         diffs, commit, push, PR and CI
    Work on a remote host   from zero to a remote workroom
    Coming from tmux or git worktree
  The app
    Projects
    Workrooms
    Terminals and tabs      incl. detached sessions (DetachedSessionsButton)
    Splits and windows      incl. popping a pane out into its own window (⌃⌘O, #172)
    Inspector (History, Changes, Files, PR)
    Details and ports
    Notifications
    Coding agents           incl. voice mode (the mic entitlement, macapp/project.yml:249)
    Settings
    Updates and channels
  Remote workrooms
    Overview and host kinds · boxd · exe.dev · Containers (Docker, Apple)
    Port forwarding · Reconnecting after sleep or restart
  Reference
    CLI (one page per command, incl. `workroom trust`)
    JSON output and exit codes
    config.json · Environment variables · Keyboard shortcuts
  Help
    Troubleshooting (incl. a mic prompt that never appears)
    Release notes (links to GitHub Releases)
  ```

  Script trust (PR #510) is on master but not yet in a stable release, so its sections carry the
  Nightly badge. There is no generic ssh host driver; `HostDrivers` has boxd, exe.dev and container
  only. It gets a page when it ships.

  - **As built:** the command pages are a "CLI" group of their own, after Reference. `nav.yml` has
    only flat groups, and 17 unlabelled commands under Reference were hard to find (owner,
    2026-10-20).

### Content pipeline

- **D10 and D27.** D10 was a Docker-build clone, and D27 established that Codaset is deployed with
  Hatchbox, which builds no Dockerfile. D29 and D32 replace D10.
- **D11. The site is built from master**, and the Nightly badges from D3 mark unreleased features.
- **D12. The CLI reference is generated with `cobra/doc`**, and CI fails if the generated pages are
  stale. The keyboard shortcuts page is written by hand, and a Swift test fails when it drifts from
  `KeyboardShortcutsView.swift`. Everything else is written by hand.
- **D13. Every page has the same chrome:**
  - a sidebar on the left and an "On this page" list on the right
  - breadcrumbs, and Previous/Next links at the bottom
  - "Edit on GitHub", and a "Last updated" date taken from git
  - "Copy page" and "View as Markdown"
  - anchor links on every heading, and copy buttons on code blocks

  There is no "Ask AI" panel and no feedback widget.
- **D14. The README shrinks** to an intro, an install line and a link to the docs. The docs site is
  the one source of truth.
  - **As built (2026-10-20):** done once the docs were live. The README keeps the intro, the demo
    video, the app and CLI install lines, and links to the docs, CONTRIBUTING.md and the licence.
    Links into its old sections (CONTRIBUTING.md, ADR 0013, PRODUCT.md) point at the docs pages.
- **D15. Screenshots appear only on the Get started and Guides pages,** in dark mode. Claude asks
  before every capture session, which drives the real app, or the owner takes them.
- **D16. URLs follow the file path:** `/workroom/docs/<group>/<page>`. Adding `.md` returns the raw
  Markdown, and `/workroom/docs/llms.txt` lists every page.

### Local development

- **D17. Codaset reads docs from `WORKROOM_DOCS_PATH`.**
  - In development it defaults to `../workroom/docs-site`, and every request reads from disk with no
    cache.
  - In production it defaults to the folder the deploy pulled (D29), and each page is cached by
    content hash.
  - The same code runs in both, and only the path changes.
- **D18. Live reload works in development only.** Codaset watches the docs folder, pushes a reload
  over Action Cable, and morphs the page with idiomorph so the scroll position stays put.
  - **As built:** no live reload. The owner dropped it as not needed (2026-10-20). Development reads
    the folder fresh on every request, so refreshing the page shows a saved edit.
- **D19. `make docs-preview` previews any worktree.** It runs Codaset's `bin/dev` with
  `WORKROOM_DOCS_PATH` set to the current worktree's `docs-site/`. It finds Codaset at
  `$CODASET_PATH`, which defaults to `~/dev/codaset`, and fails with a clear message if Codaset is
  missing. There is no standalone previewer in this repo, because a second renderer would drift.
  - **As built:** it serves at `https://workroom-docs.localhost/workroom/docs`, with its own Caddy
    name (`RAILS_CADDY_DEV_DOMAIN=workroom-docs`) and pidfile. With the defaults, `bin/dev` repoints
    `codaset.localhost` to its new port, then exits because Codaset's own server holds the pidfile,
    which leaves that server unreachable.
- **D20. Testing has three layers.**
  - **(a) This repo's CI** runs a Go test over `docs-site/`. It checks that every link and `#anchor`
    resolves, that every page is in the nav and every nav entry has a page, that front matter is
    valid, and that the generated CLI pages are current. It needs no Codaset.
  - **(b) Codaset** has Rails tests for the renderer, search index, `.md` and `llms.txt`, run
    against a fixture docs folder.
  - **(c) A broken deploy can't go live.** A Codaset build fails on unreadable content, and the
    deploy gate in D32 covers the rest.
- **D21. `docs-site/nav.yml` alone sets the groups, the page order and the sidebar titles.**

### Authoring

- **D22. Markdown is GitHub-flavoured**, plus three additions:
  - Alerts written as `> [!NOTE]`, `> [!TIP]` or `> [!WARNING]`, which commonmarker supports natively.
  - `<kbd>` for keys.
  - Images with a dark variant: `![x](shot.png)` uses `shot.dark.png` in dark mode when that file
    exists.

  There are no tabs, steps or card components; numbered lists serve as steps.
- **D23. Nightly badges.**
  - `nightly: true` in a page's front matter badges the whole page.
  - `{nightly}` at the end of a heading badges that section.
  - The `curate-release` skill gains a step: when a stable release is cut, remove the badges for
    features that release includes.
- **D24. Docs ship with the feature.** AGENTS.md gains a rule that any PR changing user-facing
  behaviour updates `docs-site/` in the same PR. The PR template gets a "Docs updated / not needed"
  checkbox.
- **D25. The docs home page** shows a two-line intro and a large search box. Below them are three
  cards (Install, Your first workroom, Guides), then a compact list of every section. It has the
  sidebar but no "On this page" column.
- **D26. There are four ways into the docs:**
  - a "Docs" link in the `/workroom` page header
  - a new Help menu in the app, with "Workroom Documentation" and "Keyboard Shortcuts"
  - links from error messages to the matching Troubleshooting section
  - the README
- **D30. The writing style is plain.** Pages are in plain English, address the reader as "you", and
  keep sentences short. Each task page opens with what you'll get. Terms follow `CONTEXT.md` ("host",
  not "machine"; "coding agents" for Claude and Codex). Steps are numbered lists. Nothing is
  described that hasn't been checked in the app.

### Deploy

- **D29. Hatchbox pulls the docs at build time.** Codaset's Hatchbox `pre_build_script` runs a
  sparse clone of this repo's master `docs-site/` into `$RELEASE_DIR/vendor/workroom-docs`, using
  `--filter=blob:none --sparse` rather than `--depth 1`. A shallow clone would lose the history that
  D13's "Last updated" date comes from.
  `WORKROOM_DOCS_PATH` defaults to that folder in production, so the build needs no environment
  variable.
  - **As built:** the hook is Codaset's `.hatchbox/pre-build`, which Hatchbox runs from the repo on
    every deploy, not a `pre_build_script` set in Hatchbox. It runs `bin/fetch-workroom-docs` after
    the `bun install` that hook already did, so it needs no Hatchbox setting (Codaset 7046b33,
    2026-10-20).
- **D32. Every Codaset deploy goes through Codaset's CI.**
  1. Codaset's `ci.yml` gains a `deploy` job. It needs every other job to pass, runs only for
     master, and allows one deploy at a time. It calls the Hatchbox webhook with
     `?sha=$GITHUB_SHA`, so only the exact commit that passed ships. The Hatchbox token is stored
     only in Codaset's secrets.
  2. Codaset's `ci.yml` also starts on a `repository_dispatch` event of type `workroom-docs`. That
     run pulls this repo's master `docs-site/` and runs the full suite, including a test that renders
     every real docs page and builds the search index. It deploys only if all of that passes.
  3. This repo sends that dispatch only after master CI succeeds. As built, it sends it on every
     green master push, not only when `docs-site/` changed (owner, 2026-10-20): a docs change whose
     own run went red would otherwise wait for the next docs change to publish. It sends it
     using `CODASET_DISPATCH_TOKEN`, a fine-grained token limited to the Codaset repo, with
     Contents set to "Read and write" (read-only gets a 403). As built, it
     is a `docs-deploy` job at the end of `ci.yml` rather than a `workflow_run` workflow. CI is one
     workflow, and a job that `needs` every other job is the same gate without `workflow_run`'s
     pitfalls: it runs the default branch's copy of the file, has no path filter, and needs its own
     success check. The dispatch carries the commit as `client_payload.sha`. Until the token is set,
     the job warns and skips.
  4. The owner turns off Hatchbox's automatic deploy on push for Codaset, so CI is the only way to
     deploy.

  This gates every Codaset deploy, not only the docs ones, so a red master never ships.

### Delivery

- **D28. The work ships as two PRs, one per repo, with one commit per step.**
  - **This repo:** this design doc first, then `docs-site/` with all content, `nav.yml`, the Go checks,
    the cobra doc generator, `make docs-preview`, the Help menu, the AGENTS.md rule and PR template,
    the dispatch workflow and the trimmed README.
  - **Codaset:** the renderer, search, `.md` and `llms.txt`, the fixture and real-docs
    tests, the pre-build hook, and the CI `deploy` and `repository_dispatch` jobs.

  This repo's PR merges first, since it does nothing without a renderer. The Codaset PR merges and
  goes live once the owner has reviewed every page. Screenshots come third, after an approved
  capture session.
- **D31. This file is the record.** It is the first commit of this repo's PR, and both PRs are built
  from it.

## Not done yet

- **D26, links from error messages to Troubleshooting**, is a follow-up.
- **D15, screenshots**, need a capture session the owner approves.
- **D5, checking every page in the app**: [docs-site-launch-checks.md](docs-site-launch-checks.md)
  lists what to check, page by page, and the contradictions with the older docs found while
  drafting.

## Not doing

- Redirects for moved pages, until a page actually moves.
- A version picker, an "Ask AI" panel, a feedback widget, or tabs, steps and card components.
- Deployed previews of docs PRs. `make docs-preview` covers local preview.
- Contributor docs on the site.

## Owner actions

All done on 2026-10-20:

- Hatchbox's automatic deploy on push for Codaset is off, so CI's `deploy` job is the only way to
  deploy.
- The Hatchbox deploy token is Codaset's `HATCHBOX_DEPLOY_TOKEN` secret. It is the token at the end
  of the deploy URL on the app's Repository tab in Hatchbox.
- `CODASET_DISPATCH_TOKEN` is this repo's secret: a fine-grained token on `joelmoss/codaset` with
  Contents "Read and write". With Contents read-only, the dispatch failed with a 403.

The pre-build step needs no owner action: it lives in Codaset's `.hatchbox/pre-build` (D29).

## Not verified

- Whether a failing `.hatchbox/pre-build` stops the deploy. Hatchbox's docs don't say. If it
  doesn't, a failed docs fetch ships a release whose `/workroom/docs` answers 503.
- Whether Hatchbox builds a new release when asked to deploy the commit it already runs. A
  `workroom-docs` dispatch deploys Codaset's unchanged master, so if Hatchbox skips a deploy of the
  same commit, docs-only changes never publish. Check it on the first docs-only change.
- Codaset's CI tests the docs at `client_payload.sha`, but Hatchbox pulls master's `docs-site/` when it
  builds. If a second docs change merges in between, the deploy ships docs that only this repo's CI
  has checked. The window is a few minutes and the cost is one page not checked by Codaset's own
  tests. Pulling `client_payload.sha` in the build would need the SHA passed through Hatchbox, so it
  is left for now.

Checked since (2026-10-20):

- Hatchbox's automatic deploy on push was on for Codaset: #58's merge went live with no CI deploy.
  The owner has since turned it off.
- `.hatchbox/pre-build` runs before `assets:precompile` with `$RELEASE_DIR` set, which Codaset's
  existing `bun install` hook already relied on, so D29 runs at the right point.
- The docs went live with the first CI deploy (Codaset 7046b33, Hatchbox deployment 4636414):
  `/workroom/docs` went from 503 to 200, with pages, `.md` twins, search and `llms.txt` serving.
- The publish path works end to end. This repo's `docs-deploy` (master run 39431555161, commit
  f85a3f786) sent the dispatch. Codaset's dispatch run (39435325713) tested the docs at
  f85a3f786, rendering every real page, and passed every job. Its `deploy` job found Codaset's
  master unchanged and asked Hatchbox to deploy it (deployment 4636623). Whether Hatchbox rebuilt
  that same commit, rather than skipping it, shows only in that deployment's log in Hatchbox; it
  stays listed under Not verified until a docs-only change is seen to go live.
