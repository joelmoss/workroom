# App copy voice

How the app's words read: titles, messages, buttons, notices, and the CLI warnings the app shows
as they are. Write every new string in this voice, and bring a string you touch into it.

## Who reads it

Developers who use git every day. Name things exactly, in git's own words: origin/main, the
worktree, uncommitted changes, 4 commits ahead, detached HEAD. A precise term they already know
beats a friendly paraphrase they have to translate back.

Workroom's own internals are a different matter: the user never meets wr-agent, a session backend
or an error sentinel, so copy names what they see instead (the terminal, the remote machine).

## Voice

- Talk to the person: "you" and "your". The app is "Workroom" or, better, unnamed.
- Say what is true, then why it matters, then what they can do:
  "You have 4 commits on main that you haven't pushed yet. New workrooms start from what you've
  pushed, so this one won't have it unless you include it."
- Be specific: the branch, the remote, the script, the command that failed and what it said.
  "git fetch origin failed: Could not resolve host: github.com" beats "exit status 128".
- One idea per sentence, short sentences, no exclamation marks.
- A message reassures where something could feel lost: "Your changes stay where they are too;
  the new workroom gets a copy."

## Buttons

- A button names what happens, in title case: "Include My Commits", "Continue Without Script",
  "Cancel Creation". "OK" and "Yes" never say what happens.
- A button that asks before acting ends in an ellipsis: "Continue Without Script…", "Choose Start…".
- Cancel says what it cancels when that is more than closing the sheet: "Cancel Creation".
- The confirmation's own button repeats the action, without the ellipsis.

## Confirmations

The title is the question, naming the thing: "Create the workroom without running
scripts/setup?". The message says what will and won't happen, and what happens next time:
"The workroom is created, but nothing the script would have set up is done. The script stays
unapproved, so you'll be asked again next time."
