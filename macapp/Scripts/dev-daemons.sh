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

# The socket a `workroomd serve` listens on, read from its `--socket` argument, given the command
# line from the executable's name on (`workroomd serve --socket … --handoff …`). Fails for anything
# that is not a serving daemon. wr-agent: a daemon a build from before the rename (#525) started,
# until it exits.
served_socket() {
  case "$1" in
    "workroomd serve "*"--socket "* | "wr-agent serve "*"--socket "*) ;;
    *) return 1 ;;
  esac
  socket="${1#*--socket }"
  printf '%s\n' "${socket%% --*}"
}
