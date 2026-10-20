---
title: Coding agents
description: Run Claude Code and Codex in workrooms, see their usage, get help with failed commands, and use voice input.
---

Claude Code and Codex are the coding agents Workroom knows about. You run them in a workroom's terminal like any other program, and Workroom adds a few things around them: diagnosis of failed commands, usage meters, alerts when an agent needs you, and microphone access for voice mode.

## Run agents in workrooms

Start `claude` or `codex` in a workroom's terminal. Give each agent its own workroom, and they work on separate branches without getting in each other's way. Switch away and the agent keeps running. See [Run agents in parallel](../guides/run-agents-in-parallel.md).

Workroom shows when an agent needs you. See [Notifications](notifications.md#when-a-terminal-needs-you).

## Diagnose a failed command

When a command fails in a terminal, the pane footer shows **Command failed (exit N)** in red. Click it to open the diagnosis.

The diagnosis has these buttons:

- **Diagnose** asks a coding agent for the cause and a suggested fix.
- **Insert fix** types the suggested command into the terminal without running it. Press <kbd>Return</kbd> yourself to run it. If the command looks destructive, Workroom asks you to confirm before it inserts it.
- **Investigate** opens an interactive Claude Code or Codex session in the same folder, seeded with the failure, to dig deeper. **Settings ▸ AI Agents ▸ Investigate with** picks which. It appears once a diagnosis has arrived.
- The **x** button dismisses it.

The diagnosis always uses the Claude Code command-line tool installed on your Mac, with its tools turned off, so nothing in the failed command's output can make it run anything. Codex has no such mode, so it never runs the diagnosis. If Claude Code is not found, the footer says so, and when Codex is your pick for **Investigate with** it still offers **Investigate**. If Claude Code is not signed in, the footer tells you to run `claude login`. In a remote workroom it warns that a local diagnosis may be inaccurate.

Failed-command detection needs shell integration. See [Terminals and tabs](terminals-and-tabs.md#shell-integration).

### Settings for diagnosis

These are in **Settings ▸ AI Agents**. In Workroom 2.1.0 the pane is called **Agent**.

- **Investigate with** picks the agent **Investigate** opens: **Auto (Claude, else Codex)**, **Claude** or **Codex**. **Auto** opens Claude Code, or Codex when Claude Code is not installed. In Workroom 2.1.0 this setting is called **Diagnose with**, and **Investigate** always opens Claude Code.
- **Diagnose automatically** runs the diagnosis as soon as a command fails, instead of waiting for you to click **Diagnose**.
- **Redact obvious secrets before sending** masks obvious secrets in the output before it reaches the agent. The pane says that redaction is best-effort, not a guarantee.

A failed command's text and output go to the local CLI to get a suggested fix.

## Usage {nightly}

Workroom reads how much of each coding agent's usage allowance you have used and shows it as small bars.

### The window footer

The footer along the bottom of the window shows each coding agent's usage on the left, once Workroom has a reading, whether or not an agent is running. Each agent has its logo and one bar per usage window. Hover a bar for the numbers, or click it to open the details: **Session** and **Weekly** percentages used, when each resets, and a note on your pace. The refresh button at the bottom reads the usage again.

Hide the footer usage with **Settings ▸ AI Agents ▸ Usage ▸ Show in the window footer**.

### The pane footer

**Show in the pane footer** adds the usage of the agent running in a pane to that pane's footer. It shows only while an agent is running in that pane, and it is off by default. It is not shown for remote workrooms, whose agents may use a different login.

### Several Claude accounts

If you use [cswap](https://github.com/realiti4/claude-swap) to manage more than one Claude account, the footer shows every account it manages, each labelled with its alias, shortened to 8 characters, or with `#` and its slot number when it has no alias. The details show the alias and slot together. When there is no room for all of them, a **+N** button lists the rest. Click an account's bars to see its organisation and email.

### Claude usage without cswap

Without cswap, Workroom reads Claude's usage from Claude's status line. You enable it once:

1. Once you have run Claude Code in a pane, click **Enable usage…** in the footer.
2. Read the prompt. It says Workroom will update `~/.claude/settings.json` to run its status-line wrapper. The wrapper stores only Claude's `rate_limits` data and passes the original status-line input, unchanged, to your current status-line command.
3. Click **Enable**.

Click **Don’t Ask Again** to stop the footer offering it. You can still turn it on later from **Settings ▸ AI Agents ▸ Usage ▸ Claude usage ▸ Enable…**.

To undo it, open the Claude usage details and click **Remove**, which restores your own status line. If Workroom's wrapper is installed but its saved details are gone, the button reads **Repair** instead.

### Codex usage

Codex usage comes from the Codex app server, or from its local session files.

### When there is no reading

If cswap has no reading for one of your Claude accounts, that account shows a grey bar with an exclamation-mark icon, and the tooltip says its usage is unavailable. Click it to see why. An agent with no reading at all is not shown.

## Codex alerts {nightly}

Codex does not ask Workroom whether it supports program status, so Workroom treats it differently from Claude Code. It alerts you when Codex has been waiting, in the foreground, for about a second, and the alert reaches you 1 to 3 seconds in. See [Notifications](notifications.md#the-alert) for how Workroom folds Codex's own notification into the alert.

## Voice mode {nightly}

Workroom carries the microphone entitlement macOS needs, so a program in a terminal can use your microphone. Claude Code's voice mode is the main example. The first time a program asks, macOS shows a prompt: **Programs Workroom runs, including terminal commands, repository setup scripts and coding agents, can use your microphone.**

If you do not see the prompt after updating Workroom, close every terminal, quit Workroom, wait about 30 seconds and open it again. Terminals keep running under a helper the previous version started, and new terminals do too while it lives, so opening a new terminal is not enough. If voice still fails, look for Workroom in **System Settings ▸ Privacy & Security ▸ Microphone**. See [Troubleshooting](../help/troubleshooting.md#a-coding-agents-voice-mode-never-asks-for-the-microphone).

> [!NOTE]
> Without the entitlement, macOS refuses microphone access before it ever asks, and voice fails with no prompt and no error.
