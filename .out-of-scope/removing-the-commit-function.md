# Removing the commit function

Workroom keeps its in-app commit and amend (the commit sheet, `CommitFlow`). The request was to remove it, leave Git writes to the coding agent, and keep the app for reading, with only push and pull as buttons.

## Why this is out of scope

The owner decided to keep commit and amend (2026-11-08). TODOS records them as shipped and as the product's direction. Many changes are small enough to commit by hand without an agent: a typo, a reverted experiment, a message to reword. Taking commit away would force those through a terminal or an agent for no gain. The commit sheet is also how the app's changes view connects reading a diff with acting on it.

## If this comes back

Reopen it on evidence that the commit sheet gets in the way: users confused by two ways to commit, or the sheet drifting out of step with what agents do in the same repository.

## Prior requests

- #209: "Remove VCS commit function"
