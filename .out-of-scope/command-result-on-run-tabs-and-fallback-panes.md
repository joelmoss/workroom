# Command result on Run tabs and fallback panes

A command result (see `CONTEXT.md`) shows only on daemon-backed panes, where workroomd's shadow terminal builds it (#473). Run tabs and fallback panes don't get the pane mark.

## Why this is out of scope

Run tabs already report how their command ended, by a different route. A Run tab `exec`s over the shell, so it emits no OSC 133 marks and GhosttyKit's command-finished action never fires for it. Instead the run supervisor reports the exit status (`macapp/WorkroomApp/Core/AppStore+RunCommand.swift`), and the app acts on it with the same rules a command result uses:

- exit 0 shows a passed run toast, any other code a failed toast with that code;
- 130 (^C) and 143 count as stopped by the user and show nothing;
- a failure posts a "Run failed" banner when the Run tab is in the background, and hands the output to the inline agent.

The toast stands in for the pane mark. Adding the mark as well would say the same thing twice, and a Run tab's command is usually one that runs until you stop it (a dev server), which the ^C rule leaves unmarked anyway.

A fallback pane is the plain shell the app opens when no persistent session can attach. It is a degraded state, not a place people work by choice. Giving it a command result means a second implementation in Swift beside workroomd's, with its own seen rules, for a pane that exists only while something else is wrong. The fix for a fallback pane is to get the session back, not to make the fallback richer.

## If this comes back

Fallback panes would be the cheaper half: they have shell integration, and GhosttyKit's `ghostty_action_command_finished_s` already carries the exit code and the run time (`duration`, in nanoseconds), so the app would not need its own timing. What it would still need is the seen rules from #473.

## Prior requests

- #476: "Show a command result on Run tabs and fallback panes"
