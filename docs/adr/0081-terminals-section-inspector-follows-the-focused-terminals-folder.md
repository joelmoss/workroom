# A Terminals-section target's inspector follows its focused terminal's folder

Decided 2026-11-23 (owner, design grilling for #803). Status: accepted, being built (#804–#811). Amends ADR 0077: its rule that nothing project-shaped, the inspector included, applies to a standalone terminal or a terminal group.

ADR 0077 left the inspector empty for every target in the Terminals section, on the premise that a terminal with no project has nothing to inspect. But those terminals do most of their work inside git repositories, and the user had to leave the terminal and find a workroom for the repository, if there was one, to see its changes or history.

When a window selects a standalone terminal or a terminal group, its inspector follows the folder of that target's focused terminal: the shell's live working directory (OSC 7), else the folder it started in. A content tab has no folder, so while one is focused the target's most recently focused terminal counts, else its first. Changes, History and Pull Request show the innermost git repository containing that folder, as `git rev-parse --show-toplevel` answers it, so a linked worktree and a submodule are each their own repository. Files shows the folder itself. Details shows where the terminal runs (this Mac) and the folder, and the header names the repository's folder with its branch and `~`-relative path beneath. Outside any repository, the version-control sections say "Not a git repository" with the folder, and the header and Details show the folder.

The repository is resolved again on every folder or focus change. The version-control sections reload only when the resolved repository's root changes, so a `cd` within one repository moves Files and nothing else. A folder resolved before shows at once when the selection returns to its terminal, before the fresh resolve lands.

Each window's inspector follows only that window's selection. The Quick Terminal, whose terminals live in its panel, never changes any window's inspector, and its own row keeps the old behaviour. An `ssh` inside the terminal changes nothing: libghostty drops a foreign host's folder reports, so the last folder on this Mac stands, and standalone terminals and groups stay this Mac's only (ADR 0077). A repository that is also a registered workroom's is shown in place; following it never changes the selection. A Terminals-section row still has no changes badge.

A followed repository takes the Changes actions a workroom has: commit, and the toolbar's fetch, push and pull. The repository router, which refuses a write to a local repository nothing registered, holds a registration for a followed repository while some window follows it and drops it when the last one stops (a registered workroom's or project's own registration is untouched). A write addresses the repository it was started for, by its root: if the shell has moved to another repository since, the write lands where it began or is refused, never in the new one. Its pull request's actions stay read-only.

What does not change from ADR 0077: these targets still have no project, branch, worktree, run commands or host of their own. The repository belongs to the folder the shell is in, not to the target, so it changes as the shell moves.

Rejected: pointing a standalone terminal or group at a repository by hand. The shell's folder already says where the user is working, and a second, manual answer could disagree with it.

Rejected: resolving the repository root from the target's starting folder only. A shell `cd`s, and the inspector would describe a folder the user has left.

Rejected: reloading every section on every `cd`. Moving between subfolders of one repository would reload and flicker Changes, History and Pull Request for no change in what they show.

Source: #803 and its sub-issues, [`CONTEXT.md`](../../CONTEXT.md) (Inspector, Standalone terminal, Terminal group), ADR 0077.
