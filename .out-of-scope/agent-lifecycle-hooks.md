# Agent lifecycle hooks, a report CLI and screen detection

Workroom learns what an agent in a terminal is doing only from the agent itself, over OSC 7501 program status (see `CONTEXT.md` and `docs/program-status.md`). It ships no per-agent adapters: no Claude Code plugin mapping hooks to states, no Codex `notify` script, no `workroom agent report <state>` command, and no inferring an agent's state from what is on its screen.

## Why this is out of scope

These were proposed (#361) when OSC 7501 was still a draft and no agent spoke it, so a terminal could only guess from OSC 9;4 progress. That is no longer the case. Claude Code 2.1.295 and later report working, blocked (with a kind and a message), done and clear. Codex reports the same states from openai/codex#52725 and #54114 (October 2026), with `app=codex`. workroomd keeps every session's records and the app shows and alerts on them (#358, ADR 0050), so both agents already get marks, reattach and remote hosts with no adapter.

ADR 0050 already rejected hooks as the source: they cover one agent each, they mean editing the user's own agent settings (`settings.json` for Claude Code), they carry no lifetime rules (what clears a request when the program dies mid-question), and they leave reattach and remote correctness to something other than the agent that owns the session. A report CLI is the same thing with a shell command in the middle.

Screen detection is a guess about another program's UI, which breaks whenever that UI changes, to stand in for a report the program now makes itself. The protocol's answer for an agent that doesn't report is for the agent to report.

## If this comes back

An agent that people use in Workroom and that won't adopt OSC 7501 would be the reason. Even then, prefer asking the agent upstream to report over an adapter here. If an adapter is ever built, it should feed the same daemon-side record store as OSC 7501, never a second path into the app, so lifetime rules, reattach and remote hosts keep working.

## Prior requests

- #361: "Agent lifecycle via first-party hooks (Claude Code plugin, Codex notify) instead of inferring from OSC 9;4"
