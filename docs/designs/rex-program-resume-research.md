# Rex "program resume" compared with Workroom

Status: research, 2026-11-26. Rex pages were read through a summarising fetch tool, not verbatim, so quoted
values are the summariser's reading of each page; re-read a page before relying on a detail. Rex has no public
source repository that I could find, so nothing here comes from Rex code.

**Answer: Rex's program resume is a way to restart a program inside a restored pane, not a way to keep it alive.
A program in a Rex terminal reports its own resume command (for example `claude --resume <uuid>`) in an
authenticated terminal escape sequence, the Program Resume Protocol (OSC 7577). The Rex Server keeps that record
with its saved session. After a server restart, if a user-config "trust rule" allows the command, Rex runs it
again in the pane's directory; otherwise the pane gets a plain shell there. Today only Claude Code reports, and
only through a hook that `rex skill setup` installs. Workroom does something different and earlier in the
chain: its daemon keeps the real process alive across app quit and reattaches to it. It has no resume step for
when the process is gone (reboot, daemon death), where it shows a frozen screen or a new empty shell. It does
not capture agent session ids or run `--resume`. Workroom already speaks Rex's sibling protocol, OSC 7501
(program status), but not OSC 7577.**

Terms: record = a stored resume report; rule = Rex's `resume.trust.*` config; session = Rex's saved set of tabs
and panes (Workroom's "session" is one daemon-held pty).

## 1. What Rex's resume is

| Fact | Finding | Source |
|---|---|---|
| Meaning | A program reports a command that brings it back. After a restart the terminal may run it in the user's shell environment. "Program resumption is a hint, not a guarantee; terminals may ignore or reject reports for any reason." It is not reattach to a live process, not scrollback restore, and carries no process state. | [S1] |
| Who restores | The Rex Server, which holds session state (not the clients). Client restart: sessions return with full history. Server restart: sessions, tabs and panes return with labels; whether scrollback survives a server restart is not stated. | [S2], [S3] |
| Where stored | `servers/<id>/snapshot` under the server state dir (`~/.local/state/rex` on Linux/FreeBSD, `~/Library/Application Support/rex` on macOS, `%LocalAppData%\rex` on Windows, `/var/lib/rex` for the shared server). Files `0600`, directories `0700`. | [S2] |
| Secrets | Saved commands are plain text and can hold secrets (a system prompt passed to Claude Code). Encryption is "planned where a key store is available". | [S2] |
| Fallback | Anything not resumed comes back as a plain shell in the working directory the pane had when the server last exited. | [S2] |
| Scope of restore | Only the reported command and its working directory. Shell state is not restored; hand-exported environment variables are lost (fresh terminal environment). | [S1], [S2] |
| Triggers | Server restart / restore at server start. Crash, reboot and host reconnect are not named as separate triggers. | [S2] (not documented for the others) |
| Retry | A failed resume is never retried. A missing `cwd` means the record is not resumed. | [S1], [S2] |
| Exited programs | A program that exits clears its record about 2 seconds after exit. A deliberate tab close discards the record (terminals SHOULD). | [S1], [S2] |
| Never saved | Programs under a non-shell wrapper (a sandbox), runs with no session (`claude -p`), programs no rule trusted when the server stopped. | [S2], [S3] |
| Off switches | `rex.set("resume.defaults", false)` (drop built-in rules); `resume.trust.<program> = false` (drop one); `rex server run --restore=false` (no restore, no save); `rex server stop --discard` (delete saved sessions). Resume is off on Windows and when running as root. A way to disable reporting itself: "can't currently be disabled through configuration". | [S2], [S3] |

## 2. The wire protocol (OSC 7577, spec v0.5, 2026-11-25)

| Item | Finding | Source |
|---|---|---|
| Frame | `OSC 7577 ; body ST`, ST = `ESC \` or BEL. | [S1] |
| Keys | Required: `pid`, `time` (Unix seconds), `mac` (last). Optional: `argv`, `cwd`, `clear=1`, `need`. Exactly one of `argv` or `clear`. | [S1] |
| `argv` | Comma-separated base64 of UTF-8 elements, one per argument (not one string). First element is a bare name (not starting with `-`, looked up on PATH where the command starts) or an absolute path. Control characters rejected. At least 2048 bytes and 64 elements must be supported. | [S1] |
| `cwd` | Base64 absolute path. If it no longer exists at resume time, do not resume. | [S1] |
| Environment | "Environment variables cannot be sent." | [S1] |
| `need` | Keys the terminal must support; an unsupported one means reject. | [S1] |
| Auth | `mac` = SHA-256(body bytes before `:mac=`, `:`, token), 64 hex; a plain hash, not an HMAC. Token is the `OSC7577_TOKEN` environment variable, 22 to 64 chars of `[A-Za-z0-9_-]`, generated per terminal at startup. Support is detected by that variable existing; there is no query or reply. | [S1] |
| Freshness | `time` must be inside a window (60 s suggested) and not older than the last accepted report for that pid. | [S1] |
| Ignored vs rejected | Bad or missing `mac`, bad `time`, incomplete report: ignored. Relative paths, both `argv` and `clear`, unsupported `need`, strict-parse failure, over-limit command: rejected, and all records of that owner are removed. | [S1] |
| Lifecycle | Terminal SHOULD clear a record when the owning pid exits (grace of a second or two at shutdown). Programs MUST NOT send `clear` on SIGHUP, SIGTERM or terminal loss, so a record survives a restart. | [S1] |
| Restore rules | Run in the user's shell environment after startup files; arguments passed literally, never evaluated; only as the same user. Directory comes from `cwd`, the owner's directory, OSC 7 (opt-in) or the default shell directory. | [S1] |
| Security | Programs MUST NOT send the token and SHOULD strip it from children; do not forward it over SSH; remote output cannot create records. Root or elevated terminals SHOULD NOT accept reports without opt-in. | [S1] |
| Compared to OSC 88 | OSC 88 is unauthenticated (terminal must inspect processes) and takes one argument string with no split rule. tmux-resurrect and kitty sessions re-run the process's OS command line, which is often not a valid resume command. | [S1], [S4] |
| Implementers | The page names no program that implements it; Neovim, lazygit and a `resume-wrap` sh script are examples only. It says the protocol "is used for rich functionality within Rex". | [S1] |

## 3. Rex's trust rules (what actually decides a resume)

A report alone does nothing: the server checks it against rules in `init.lua`. Rex treats the rules as authoritative.

| Item | Finding | Source |
|---|---|---|
| Rule shape | `command` (leading elements, e.g. `claude --resume <uuid>`), `flags` (each allowed flag, with `keep`/`drop` or a value shape `1`/`"optional"`/`"many"`), `dir` (allowed directories, subdirectories count; none = anywhere). Matchers: `rex.match.uuid`, `rex.match.id` (1 to 128 word chars), `rex.match.under(dir)`. | [S5] |
| Built-in rules | `claude --resume <uuid>` (44 flags kept, 12 dropped; the page's debug example says 43), `codex resume <uuid>` (no flags), `opencode --session <id>` (no flags). | [S5] |
| Claude flags | Keeps session-shaping flags (`--model`, `--permission-mode`, `--dangerously-skip-permissions`); drops flags that pick a session or start a task such as `--continue`. `--print` or any unlisted flag: not resumed. | [S5] |
| Prompts | Prompts and anything after a bare `--` never come back. | [S5] |
| Process check | The running process must be the program the command starts (`claude`, an absolute path, or `node /opt/homebrew/bin/claude` all count). Under a non-shell wrapper: not trusted. Paths are compared as text (`..` fails) and re-checked after symlinks just before resuming. | [S5] |
| Config errors | A rule with an error is skipped with a warning; an error in an edit to a built-in drops that whole built-in. `rex config reload` applies at once; a failed reload keeps the last good rules. If no load has ever succeeded, nothing resumes. | [S5] |
| Debug | `rex config check`; `rex block call -b "$REX_BLOCK" program_resume_records` with an `untrusted_reason` (`no_rule`, `program_differs`, `wrapped`, `flag_not_listed`, `flag_value`, `flags_differ`, `dir_not_allowed`, `launch_unreadable`, `config_incomplete`). The server log names the program, never the command. | [S5], [S2] |
| Neovim | No built-in rule. `init.lua` must report `nvim -S <file>` on `SessionWritePost`; the user adds a rule limited to `~/.local/state/nvim/sessions`. A wrapper that reports for another program cannot be trusted (Rex sees the wrapper's child). | [S5] |

## 4. Which programs resume today

| Program | State in Rex | Source |
|---|---|---|
| Claude Code | The only one the docs say resumes today: same conversation, original flags. Needs the hook from `rex skill setup` (written into `~/.claude/settings.json`), a trust rule, and a supported shell (bash, zsh, fish, nushell and several POSIX shells). | [S2], [S6] |
| Codex | Rule exists; "nothing reports yet", so it does not resume. `rex skill setup` writes a Codex hook (`~/.codex/hooks.json`), described as telling the agent about its session and terminal. | [S2], [S6] |
| OpenCode | Rule exists; nothing reports yet. No hook support. | [S2], [S6] |
| Pi | No rule. | [S2] |
| Dev servers, shells | Not covered by built-in rules. A shell comes back as a new shell in its directory. A user can add a rule (the docs' example is lazygit), but the program has to emit OSC 7577 itself or via a wrapper, and a wrapper is untrusted. | [S5], [S1] |

How the Claude hook turns a session start into an OSC 7577 report is not documented. The skill page says only that the hook "tells the agent it's running in Rex and which session and terminal it's in" and gives no fields for session id or resume [S6]. Whether the session id is read from the hook's own input, from Claude's transcript, or elsewhere: not documented.

## 5. The agents' own flags (checked against their docs)

| Agent | Rex's command | Official documentation | Source |
|---|---|---|---|
| Claude Code | `claude --resume <uuid>` | `--resume` / `-r`: "Resume a specific session by ID or name, or show an interactive picker"; also accepts a transcript path. `--continue` / `-c` loads the most recent conversation in the current directory. `--session-id` sets a UUID for a new conversation. `--print` is non-interactive. Confirmed. | [S7] |
| Codex | `codex resume <uuid>` | `codex resume`: "Continue an interactive session by ID or resume the most recent chat". `SESSION_ID` is a uuid or session name; `--last` resumes the most recent from the current directory; `--all` widens it; `--include-non-interactive` adds non-interactive sessions. Confirmed. | [S8] |
| OpenCode | `opencode --session <id>` | Not checked (out of scope of the question). | none |

## 6. What Workroom does today

| Area | What Workroom does | Source |
|---|---|---|
| Keep the process alive | A terminal's shell is held by a background helper (the daemon), not its tab, so terminals keep running when the app quits and reattach on reopen. Closing a terminal ends it. | `docs-site/pages/app/terminals-and-tabs.md` L144; `macapp/WorkroomApp/Core/Terminal/Session/PersistentSessionService.swift` |
| Reattach on launch | Visible panes reconnect at once; hidden tabs reconnect gradually. Screens, including Kitty images, come back from the daemon's shadow terminal. | `docs-site/pages/app/terminals-and-tabs.md` L160-162 and the Images section; ADR 0010, ADR 0062 |
| Layout restore | One writer rebuilds the whole saved-session document from every live window (debounce 1 s, ceiling 5 s); writes are gated during restore and frozen if a restore never finishes, so the file survives. | `macapp/WorkroomApp/Core/Terminal/SavedLayoutCoordinator.swift` L12-30, L95-113, L184-209 |
| Daemon gone (reboot, daemon death), local pane | The pane gets a new daemon session under the same id, with a toast saying so. It is a fresh shell; no program is restarted. | ADR 0046 (as amended, #459); `PersistentSessionService.swift` L529-545 (`willReplaceRestoredSession`) |
| Host gone, remote pane | With `serve --screens` on durable disk, the last screen is shown frozen with no pty and no new shell; otherwise "This terminal has ended". The user opens a new tab. | ADR 0031; ADR 0046; `docs-site/pages/remote/reconnecting.md` L54 |
| Link drops | A remote pane retries 1, 2, 4 ... up to every 30 s for as long as it takes. | `docs-site/pages/remote/reconnecting.md` L26 |
| Run (dev server) tabs | Survive quit like any terminal; a run that is still going reattaches; one whose session is gone comes back as a stopped tab saying it ended; "Nothing restarts a run by itself". ⌘R starts it again. | ADR 0058 |
| Agent state | Workroom reads OSC 7501 program status (Claude Code 2.1.295+, Codex 0.163+): working / waiting / done / error marks and alerts. | `docs/program-status.md` L1-8 |
| Agent session ids and resume | Not present. A search of `macapp/`, `vcs/`, `docs/`, `docs-site/` for `OSC 7577`, `osc-88`, `--resume`, `codex resume` found only test fixtures that recognise a title containing `claude --resume` (`macapp/WorkroomAppTests/CodingAgentUsageTests.swift` L12, `ToolLogoRegistryTests.swift` L20). Per the OSC 7501 spec as Rex documents it, the status protocol carries no session ids [S9]. | grep, 2026-11-26; [S9] |
| Working directory | Workroom tracks live title/cwd/progress per tab for saving. Whether a new shell after daemon loss starts in the saved cwd: not checked here. | `SavedLayoutCoordinator.swift` L19-24 |

## 7. Gaps against Rex

| Gap | Rex has | Workroom has | Source |
|---|---|---|---|
| G1. Restart a program after its process is gone | Re-run a trusted, self-reported command in the pane | New empty shell (local) or frozen screen / "ended" (remote) | [S2]; ADR 0046, 0031 |
| G2. Agent conversation id capture | A hook plus the protocol puts a `--resume <uuid>` command on record | None | [S2], [S6]; grep |
| G3. Trust model for what may be re-run | Per-program rules with dir and flag allow-lists, wrapper and symlink checks, debug command | None needed today, since nothing is re-run | [S5] |
| G4. Opt-out and visibility | `resume.defaults`, per-program, per-dir, per-flag; `program_resume_records` | None needed today | [S2], [S5] |
| G5. Secrets at rest | Commands stored in plain text, documented as a risk | Not applicable | [S2] |

Where Workroom is ahead of Rex's restore: live process survival across app quit (Rex's restart story is restart
and resume; a Rex server restart ends processes, which is why resume exists) [S1]; images restored from the
daemon [Workroom docs]; run-tab state. Rex's server is a separate daemon too, but its docs do not say its
processes survive a server restart, so this comparison rests on the docs' framing, not a test.

## Not documented / open questions

- Rex source code: no public repository found; no code was read.
- How the Claude Code hook produces the report, and how the session id is obtained: [S6] is silent.
- Whether Rex's processes survive a Rex Server restart (the resume docs imply they do not; nothing says so directly).
- Scrollback after a server restart [S2].
- Crash, reboot and host-reconnect behaviour as distinct triggers [S2].
- Whether Codex or OpenCode ever report today (docs say not yet) and what will change that.
- The built-in Claude rule's flag count (44 on the rules table, 43 in the debug example) [S5].
- OSC 7577 is a young draft (v0.1 on 2026-11-18, v0.5 on 2026-11-25) and the page names no implementer outside Rex, so it may change.
- OpenCode's `--session` flag was not checked against OpenCode's docs.
- Codex's top-level `codex resume` page section was read in two chunks of a long page, so `--last` and `--all` wording is from that reading.

## Implications for Workroom

Facts and options only; no recommendation.

| Gap | What adopting it would take | Cost or constraint |
|---|---|---|
| Accept OSC 7577 reports (G1, G2) | The daemon already parses OSC 7501 per session. It would also need the per-terminal `OSC7577_TOKEN` in each pty's environment, the SHA-256 check, the time window, per-pid records, clear-on-exit with the grace rule, and a place to persist records beside the screens and layout. The token must be kept out of agents' children and out of SSH. | New protocol surface, reserved in the terminal API contract (ADR 0079); remote hosts need the daemon on the host to do the same, and "remote output cannot create records" has to hold. |
| Capture agent ids without a hook | Rex's route is a hook the user installs into `~/.claude/settings.json` and `~/.codex/hooks.json`. Workroom already writes a Claude status-line wrapper (docs-site `coding-agents.md` L73), so there is precedent for editing agent config. Alternative sources (reading transcripts, parsing the title) are not what Rex does. | Installing a hook edits user config; Codex asks for hook approval and Claude Code needs folder trust [S6]. |
| Re-run trusted commands | Rules for `claude --resume <uuid>` and `codex resume <uuid>` are verified against the agents' docs [S7], [S8]. A rule engine needs dir and flag allow-lists, a process check that the pane's program matches, and rejection of wrapped programs. | Re-running a command is new behaviour. Today ADR 0046 deliberately starts a plain shell, and ADR 0058 says nothing restarts a run by itself. |
| Where it would trigger | Only where the process is gone: a local pane after reboot or daemon death (ADR 0046 path) and a remote pane after host restart (ADR 0031 path). Today those end in an empty shell or a frozen screen. Live processes need no resume. | Remote panes today never get a new shell on purpose, so remote behaviour would be a separate decision. |
| Opt-out and visibility | Rex ships config keys, a reload command and a records debug command. Workroom would need its own settings and a way to see why a pane did not resume. | Docs-site and the CLI docs must change in the same PR (AGENTS.md). |
| Secrets at rest | Stored commands can hold secrets (Rex's documented warning). Workroom's saved layout and screens files would hold them too. | Needs a storage and file-permission decision. |
| Do nothing | Keep reattach-only. Process survival already covers app quit and update relaunch; resume would only change the reboot and daemon-death cases. | Users lose agent conversations context in those cases only, as today. |

## Sources

Fetched 2026-11-26 with a summarising WebFetch (not raw markdown), except where noted.

- [S1] Program Resume Protocol (OSC 7577), v0.5: <https://www.superlogical.com/rex/docs/build/program-resume>
- [S2] Session Restore: <https://www.superlogical.com/rex/docs/features/session-restore.md>
- [S3] Rex docs index (what Rex is, navigation): <https://www.superlogical.com/rex>
- [S4] OSC 88 Terminal Resume Protocol (proposal): <https://github.com/otty-sh/osc-88>
- [S5] Resume Rules: <https://www.superlogical.com/rex/docs/customize/resume-rules.md>
- [S6] Agents (`rex skill setup`): <https://www.superlogical.com/rex/docs/automate/agent-skill.md>
- [S7] Claude Code CLI reference: <https://code.claude.com/docs/en/cli-reference>
- [S8] Codex CLI commands: <https://developers.openai.com/codex/cli/reference> (redirects to <https://learn.chatgpt.com/docs/developer-commands?surface=cli>)
- [S9] Program Status Protocol (OSC 7501): <https://www.superlogical.com/rex/docs/build/program-status.md>
- Workroom side: `docs/program-status.md`, `macapp/WorkroomApp/Core/Terminal/Session/PersistentSessionService.swift`, `macapp/WorkroomApp/Core/Terminal/SavedLayoutCoordinator.swift`, `macapp/Packages/TerminalModel/` (`TabRecords.swift`, `TerminalLaunch.swift`), ADRs [0010](../adr/0010-shadow-terminal-attach-only.md), [0031](../adr/0031-screens-persist-as-vt-bytes.md), [0046](../adr/0046-restore-never-prunes-an-ended-pane-stays.md), [0058](../adr/0058-run-tabs-survive-quit-and-run-on-the-host.md), [0062](../adr/0062-reattach-restores-images-from-the-reader.md), [0079](../adr/0079-the-terminal-api-is-a-public-versioned-contract.md), `docs-site/pages/app/terminals-and-tabs.md`, `docs-site/pages/remote/reconnecting.md`, `docs-site/pages/app/coding-agents.md`. `docs/designs/oq8-cross-machine-reattach.md` was not read in full; it is cited only through ADR 0046.
