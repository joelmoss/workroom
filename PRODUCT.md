# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Workroom is primarily for agentic developers coordinating several coding tasks, branches, terminals, or projects at once. They need to move between parallel streams of work without repeatedly stashing changes, switching branches, reconstructing context, or losing sight of what each task is doing.

The native macOS app is the primary product. A standalone CLI is available as an addon for terminal-first use on macOS, Linux, and Windows.

## Product Purpose

Workroom gives each task an isolated, on-disk copy of its project, backed by a Git worktree or Jujutsu workspace, and brings those parallel contexts into a terminal-centered development environment. Success means a developer can create, run, inspect, review, and move between concurrent work safely while keeping the state and purpose of each workroom legible.

Embedded terminals belong to each workroom and remain alive while Workroom is running, including when the developer navigates elsewhere in the app. Terminal sessions and their processes are not persisted or restored across app restarts.

## Positioning

Workroom's durable distinction is parallel development context: each task gets an isolated worktree or workspace, its own branch or bookmark, embedded terminal access, and visible work state. Multiple workrooms and terminal or content panes can be arranged in split views so concurrent contexts remain visible together. The product combines that isolation with native VCS operations, project navigation, changes, history, diffs, pull-request status, file viewing, activity, and notifications rather than treating parallel branches as an external workflow users must manage themselves.

## Operating Context

- Developers add existing Git or Jujutsu repositories as projects, then create multiple workrooms for concurrent tasks.
- Workrooms are real directories, normally stored under `~/workrooms`, and share repository history while keeping working copies isolated.
- Setup and teardown scripts can prepare and clean up a workroom using product-provided environment variables.
- The macOS app centers embedded terminals and surrounds them with project/workroom navigation, file viewing, VCS operations, working-copy changes, commit history, diffs, pull-request and CI information, activity, and notifications.
- Developers can split the workspace to view multiple workrooms side by side and split an individual workroom into multiple terminal or content panes.
- Developers can open files in an external editor and use keyboard shortcuts for common navigation and terminal actions.

## Capabilities and Constraints

- Primary app: native SwiftUI for macOS 15 Sequoia or later on Apple Silicon.
- Workspace mechanisms: Git worktrees and Jujutsu workspaces.
- A **workroom** is an isolated project working directory associated with its own Git branch or JJ bookmark.
- Split views support multiple workrooms and multiple terminal or content panes within a workroom.
- Built-in VCS functionality covers Git and Jujutsu working-copy state, changes, history, commits, branches or bookmarks, and related workflows.
- A native diff viewer supports reviewing changed files and changesets without leaving Workroom.
- A built-in file viewer supports browsing and reading project files with language-aware syntax highlighting; editing remains in the terminal or an external editor.
- The app bundles a Go CLI engine and uses its JSON contract for workspace management.
- Pull-request and CI integration depends on an installed and authenticated GitHub CLI.
- The standalone CLI is an addon, and is the available interface on Linux and Windows.
- Launch-facing product copy presents Workroom as released software and must not describe it as beta.
- Embedded terminals have session-scoped continuity while Workroom is running. Persistence or restoration across app restarts is not a current capability and must not be promised in product copy or future designs.

## Brand Commitments

- Product name: **Workroom**.
- Parent brand: **Codaset**.
- Confirmed product framing: a terminal-driven development environment for parallel agentic work.
- The square blocked mark is the shared Codaset and Workroom brand symbol; do not introduce a separate Codaset logo on the Workroom site.
- Existing product terminology such as **project**, **workroom**, **worktree**, **workspace**, **branch**, and **bookmark** should remain precise and distinct.

## Evidence on Hand

- Product documentation and factual feature inventory: `/Users/joelmoss/.codex/worktrees/3f49/workroom/README.md`.
- Native app architecture and development documentation: `/Users/joelmoss/.codex/worktrees/3f49/workroom/macapp/README.md`.
- Current product screenshot: `/Users/joelmoss/.codex/worktrees/3f49/workroom/docs/workroom-app.png`.
- Shared Codaset/Workroom square mark: `website/assets/workroom-mark.svg` and its inline SVG equivalent.
- Repository tests and implementation provide evidence for current workflows, terminology, keyboard use, reduced-motion handling, and accessibility labels.
- No approved testimonials, customer logos, usage benchmarks, pricing claims, or market-leadership claims were established during init; future work must not fabricate them.

## Product Principles

1. Keep parallel work genuinely isolated so developers can run concurrent tasks without branch-switching churn.
2. Make every workroom's identity and current state immediately legible.
3. Keep the terminal central while bringing navigation, review, and status into the same working context.
4. Preserve developer control: use real repositories, directories, branches, bookmarks, scripts, and external editors rather than hiding them behind proprietary abstractions.
5. Never imply that a planned or adjacent capability already exists; in particular, distinguish terminals that stay alive during the current app session from terminal persistence across app restarts.

## Accessibility & Inclusion

The native app includes accessibility labels and identifiers, keyboard-first workflows, and reduced-motion handling in relevant animated interfaces. Future work should preserve native macOS interaction conventions, VoiceOver clarity, full keyboard access, sufficient contrast, and reduced-motion behavior.
