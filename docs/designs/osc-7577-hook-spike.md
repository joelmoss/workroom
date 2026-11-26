# Spike: can a SessionStart hook report OSC 7577 for Claude Code and Codex?

Status: spike, 2026-11-26, for [ADR 0082](../adr/0082-a-gone-session-resumes-what-reported-over-osc-7577.md). Run on
macOS with Claude Code 2.1.332 and codex-cli 0.171.0. Each agent ran in a fresh pty (Python `pty.fork`, 40×120, with
the harness answering the agents' terminal queries) under a throwaway `HOME`, a minimal environment and a fake
`OSC7577_TOKEN`. The Codex home held a fake API key stored as a file (`cli_auth_credentials_store = "file"`). Nothing
was written to the real config or keychain; the real `~/.codex/hooks.json` and `config.toml` were read, never
written, to learn their format. No prompt was sent to Claude. Codex was sent one, `reply ok`, which failed with 401
on the fake key.

**Answer: for Claude Code the hook route works, with one correction: the hook has no controlling terminal, so it
writes the report to the agent's own tty device (`/dev/ttysNNN`, read from the agent's pid), not to `/dev/tty`.
That was observed end to end, with the report arriving on the pane's output. For Codex it works only where Codex
runs its session in the pane's own process (`codex exec`). An interactive Codex runs its session in a shared
background server (`codex app-server --managed-daemon`, parent launchd, no tty), and its `SessionStart` hook ran
there. The hook could find no tty and no pane, and its write failed. Codex also runs no user hook until the user
trusts it.**

## Results

| Check | Claude Code 2.1.332 (interactive) | Codex 0.171.0 `exec` | Codex 0.171.0 interactive (shared server) |
|---|---|---|---|
| When the hook runs | At startup, before any prompt | At startup | Only once the first prompt starts a session; none at startup |
| `OSC7577_TOKEN` in the hook's environment | Yes | Yes | Yes, but only because the server inherited the environment of the pane that started it, here the same pane |
| Hook can open `/dev/tty` | **No** ("not a tty"; the hook's tty is `??`) | No | No |
| Nearest ancestor with a tty | The hook's direct parent, `claude` | `codex` (the pane's process) | **None**: the chain ends at launchd (pid 1) |
| Agent's argv from the hook | Full: `claude --model sonnet --permission-mode plan` | Full: `codex exec … -m gpt-5.5 reply ok` | Not reachable |
| Writing to the agent's tty by path | Works; `ESC ] 7577 ; spike=claude ESC \` arrived on the pty master | Works; arrived | **Fails** (no tty to write to) |
| Hook input | `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `source: startup`, `model` | The same, plus `permission_mode` | The same, plus `permission_mode` |
| Needs approval | No (user settings; the folder was pre-trusted in `.claude.json`) | Untrusted hooks are skipped silently; ran with `--dangerously-bypass-hook-trust` | The TUI showed "1 hook is new or changed … Trust all and continue"; after that it ran |

## Codex's shared background server

- An interactive `codex` started `<CODEX_HOME>/packages/app-server-daemon/releases/0.172.0-aarch64-apple-darwin/bin/codex
  app-server --listen unix:// --managed-daemon` (parent launchd, no tty, recorded in
  `<CODEX_HOME>/app-server-daemon/daemon.pid`), plus an updater. The server is 0.172.0 while the CLI is 0.171.0: it
  updates itself. It outlived the pane's process and the next run attached to it, and the spike stopped it twice.
- The first-run sign-in screen that blocked earlier runs came from a server started before the fake key existed. With
  that server gone, the TUI reached the hook review and its prompt.
- The TUI uses the server unless something rules it out. Its exclusion reasons include `--no-daemon` and
  `--dangerously-bypass-hook-trust` (`codex-rs/tui/src/daemon_startup.rs`, the `config_exclusion` chain around
  L70-125). So a Codex started with either runs embedded, presumably with hooks in the pane's tree as `exec` does.
  That is inferred from the source; the TUI was not run that way.
- In server mode, a hook's environment and process tree belong to the server, not the pane. With more than one pane,
  the token would be the one from whichever terminal started the server, and a write to that terminal would land in
  the wrong pane.

## Codex hook trust

Codex hashes each unmanaged hook (`hook_hash` in `codex-rs/hooks/src/engine/discovery.rs` L1053: sha256 of the sorted
JSON of the event name, matcher and normalized handler, `version_for_toml` in `codex-rs/config/src/fingerprint.rs`).
It runs a hook only when `[hooks.state."<file>:<event>:<i>:<j>"] trusted_hash` in `config.toml` matches
(`hook_trust_status`, L1072-1090). The user trusts hooks in the TUI's review ("Trust all and continue"), which wrote
`trusted_hash = "sha256:ca56…"` for the spike's hook. Workroom writing `trusted_hash` itself would approve its own hook
on the user's behalf.

## What this changes in ADR 0082

- Claude: the helper finds the agent (the hook's parent), reads its argv, and writes the report to that process's tty
  device. Confirmed.
- Codex: the hook route fails for interactive Codex in its default shared-server mode, because nothing in the hook
  names the pane. How a Codex pane gets a record is an open decision in the ADR.

## Sources

- Spike harness and logs (scratchpad, not kept): `runner/ptyrun.py`, `bin/hook2.sh`, `out/claude-2.log`,
  `out/codex-2.log`, `out/*.pty`.
- Codex source, `openai/codex` default branch, read 2026-11-26: `codex-rs/tui/src/daemon_startup.rs`,
  `codex-rs/hooks/src/engine/discovery.rs`, `codex-rs/config/src/fingerprint.rs`,
  `codex-rs/utils/cli/src/shared_options.rs` L61-64 (`--dangerously-bypass-hook-trust`).
