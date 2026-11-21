# shellcheck shell=sh
#
# Process-table reading shared by stop-dev-app.sh and sweep-dev-orphans.sh. Sourced, not run.
#
# For tests: STOP_DEV_APP_PS names a FILE holding a process table (`<pid> <command>` per line) to
# read instead of running `ps`. A file, not a command: it used to be expanded unquoted into a command
# substitution, so whatever the variable held was EXECUTED — and `make app-run` runs these scripts
# with the developer's own inherited environment. A value left exported from a debugging session
# then both ran as a command and decided, from its own output, which processes get SIGTERM.

# Prints the process table, one `<pid> <command>` per line. `-ww`: never truncate the command,
# which is where the path is. The COMMAND column is argv, so callers match argv[0] as the
# executable inside a bundle, never a path that merely appears in the arguments.
process_table() {
  if [ -n "${STOP_DEV_APP_PS:-}" ]; then
    cat -- "$STOP_DEV_APP_PS"
  else
    ps -ww -A -o pid= -o command=
  fi
}

# The socket a `workroom serve` listens on, read from its `--socket` argument, given the command
# line from the executable's name on (`workroom serve --socket … --handoff …`). Fails for anything
# that is not a serving daemon. The daemon is the one `workroom` binary in Contents/Resources since
# #681 (ADR 0078); `workroomd`, in Contents/MacOS, is one an earlier build started, and wr-agent
# one from before the rename (#525), each until it exits or is handed off.
served_socket() {
  case "$1" in
    "workroom serve "*"--socket "* | "workroomd serve "*"--socket "* \
      | "wr-agent serve "*"--socket "*) ;;
    *) return 1 ;;
  esac
  socket="${1#*--socket }"
  printf '%s\n' "${socket%% --*}"
}

# Whether a `workroom` command line (from the executable's name on) is one of the daemon's own
# subcommands (`vcs/crates/workroomd/src/cli/route.rs`): the daemon, a pane's attach client and
# what the daemon runs from its own file. Not a CLI command the app or a user ran (`workroom list`,
# `workroom events`), which is the same binary: those are no helper of the app's.
daemon_command() {
  case "$1" in
    "workroom serve "* | "workroom attach" | "workroom attach "* | "workroom relay "* \
      | "workroom run-supervisor "* | "workroom program-status "* | "workroom hand-off "* \
      | "workroom handoff-check "* | "workroom credential "* | "workroom run-script "*) return 0 ;;
    *) return 1 ;;
  esac
}
