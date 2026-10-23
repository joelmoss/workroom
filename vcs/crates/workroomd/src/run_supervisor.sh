#!/bin/sh
# Workroom run-command supervisor (issues #7, #522).
#
# Runs as a run session's pty child, exec'd by `workroomd run-supervisor`, for as long as the
# session lasts. It runs the user's command as a child IN THE TTY FOREGROUND so interactive dev
# servers can read the keyboard (Vite r/q, binding.pry, rails console), and the app drives it by
# asking the daemon to signal THIS process (the session's child) and reading the status file, which
# the daemon publishes. start/stop/restart are serialized here, so a relaunch only happens after the
# previous child has fully exited — the port + pidfile are released before the next instance binds
# ("A server is already running" can't happen), and the session is NEVER replaced for a restart.
#
# The screen is CLEARED before each (re)launch, so every start/restart begins fresh.
#
# argv: $1 = status file (we write transitions here, atomically)
#       $2.. = the child command in argv form (e.g. zsh -lic '...'), run in the foreground.
#
# Signals (daemon -> our pid): USR1 = restart (relaunch in place), USR2 = stop (keep pane, park),
# TERM = quit (exit → the session ends). A typed Ctrl-C reaches the child via the foreground pgroup;
# we ignore INT so we survive it (the child's exit then reads as a user stop).

STATUS="$1"
shift 1

CHILD_PID=""
ACTION=""
# Ends each outcome line ("exited <code> <launch>", "stopped <launch>"): a restart that fails at once
# the same way is over before the daemon next reads the file, and the same line would publish nothing.
LAUNCH=0

write_status() {  # atomic: temp + rename, so a watcher never reads a half-written line
  __t="$STATUS.tmp.$$"
  printf '%s\n' "$1" >"$__t" 2>/dev/null && mv -f "$__t" "$STATUS" 2>/dev/null
}

# Signal our OWN process group (`kill -INT 0`) = exactly what a typed Ctrl-C does: it reaches the
# child AND its grandchildren (a server forked through a shell), whatever the exec/fork shape, as
# long as they're in our foreground pgroup (they are — job control is off). We survive because we
# ignore INT below. A truly forked-free leaf in another pgroup escapes; the app reaps it as a backstop.
on_restart() {
  ACTION=restart
  kill -INT 0 2>/dev/null
}
on_stop() {
  ACTION=stop
  kill -INT 0 2>/dev/null
}
on_quit() {
  ACTION=quit
  kill -INT 0 2>/dev/null
}
trap on_restart USR1
trap on_stop USR2
trap on_quit TERM
# SIGHUP = the session was killed without a graceful SIGTERM first (the daemon's Kill hangs up its
# processes). Treat it like quit: stop the child FIRST, then exit. Without this, SIGHUP's default
# action kills the supervisor untrapped and its server child orphans on the port → "A server is
# already running" next start.
trap on_quit HUP
trap '' INT

wait_child_dead() {  # poll until the launcher is gone; SIGKILL after ~6s for an INT-ignorer
  [ -z "$CHILD_PID" ] && return
  __i=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    __i=$((__i + 1))
    [ "$__i" -ge 60 ] && kill -KILL "$CHILD_PID" 2>/dev/null
    sleep 0.1
  done
}

start_child() {
  printf '\033[3J\033[H\033[2J'  # clear scrollback + screen so each (re)launch starts fresh
  LAUNCH=$((LAUNCH + 1))
  write_status "starting"
  # (a) job control is OFF (non-interactive /bin/sh), so `&` keeps the child in OUR pgroup = the tty
  #     foreground group (no SIGTTIN). (b) `< /dev/tty` overrides the POSIX async-stdin-from-/dev/null
  #     rule so the child actually receives keystrokes. BOTH are required for interactivity.
  "$@" </dev/tty &
  CHILD_PID=$!
  write_status "running $CHILD_PID"
}

while :; do
  # ---- run phase ----
  ACTION=""
  start_child "$@"
  wait "$CHILD_PID"  # blocks; a trapped control signal interrupts it
  code=$?
  wait_child_dead
  case "$ACTION" in
    restart)
      write_status "stopping"
      continue  # relaunch in place (start_child clears)
      ;;
    quit)
      write_status "exited 0 $LAUNCH"
      exit 0  # surface frees
      ;;
    stop)
      write_status "stopped $LAUNCH"
      ;;
    *)
      write_status "exited $code $LAUNCH"  # child self-exited (130 = a typed Ctrl-C)
      ;;
  esac

  # ---- parked phase (no child alive; supervisor stays so the pane stays + restart is in-place) ----
  # Show the familiar prompt. The supervisor itself stays alive (so restart is in-place + race-free);
  # the APP closes this tab when a key is pressed while stopped (GhosttySurfaceView.runStoppedAwaitingClose).
  printf '\r\nProcess exited. Press any key to close the terminal.\r\n'
  while :; do
    # Honor a pending control signal BEFORE clearing ACTION. A USR1/USR2/TERM delivered in the
    # window between entering the parked phase (the stop case + prompt print above) and this loop
    # would otherwise be wiped by `ACTION=""` and lost — the supervisor would then block in `wait`
    # forever, never relaunching on a restart. Checking at the top closes that race.
    case "$ACTION" in
      restart) break ;;  # leave parked -> relaunch via the outer loop (clears)
      quit)
        write_status "exited 0 $LAUNCH"
        exit 0
        ;;
      *) : ;;  # empty or already-stopped -> stay parked, wait for the next signal
    esac
    ACTION=""
    while [ -z "$ACTION" ]; do
      wait 2>/dev/null  # no child -> returns at once; a signal sets ACTION via its trap
      [ -z "$ACTION" ] && sleep 0.2
    done
  done
done
