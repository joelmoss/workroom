#!/bin/sh
# Plays back what Claude Code 2.1.299 sends about itself (OSC 7501 program status, #358), as
# recorded live in Step 0 (docs/program-status.md, "What Claude Code sends"), so the agent and the
# app can be checked without Claude, an account or an API turn.
#
# Like Claude, it asks first (`ESC ] 7501 ; ? BEL`) and reports nothing unless the terminal answers:
# then it only sends OSC 9;4 progress. With an answer it goes idle, working, blocked, sends its own
# OSC 777 alert some seconds later, then working, done, and `state=clear` when it exits.
#
#   mock-claude-code.sh               wait for Enter at the prompt and at the request, as Claude does
#   mock-claude-code.sh --auto        no input: each step after MOCK_STEP seconds (tests)
#   mock-claude-code.sh --question    a question instead of a permission request
#
# MOCK_STEP (default 1) is the pause between automatic steps; MOCK_ALERT_DELAY (default 6, as
# measured) is how long after blocking its own alert follows. Paste-able into any Workroom pane:
#   sh testdata/program-status/mock-claude-code.sh
set -u

auto=0
kind=permission
message="approve Fetch: https://example.com"
alert="Claude needs your permission"
for arg in "$@"; do
  case "$arg" in
    --auto) auto=1 ;;
    --question)
      kind=question
      message="answer: Do you prefer red or blue? (Red · Blue)"
      ;;
    *) echo "usage: $0 [--auto] [--question]" >&2; exit 2 ;;
  esac
done
step=${MOCK_STEP:-1}
alert_delay=${MOCK_ALERT_DELAY:-6}

b64() { printf %s "$1" | base64 | tr -d '\n'; }
report() { printf '\033]7501;%s\007' "$1"; }
progress() { printf '\033]9;4;%s\007' "$1"; }
# Enter in interactive mode; the next step's pause in --auto.
wait_for_user() {
  if [ "$auto" = 1 ]; then sleep "$step"; else printf '%s' "$1"; read -r _; fi
}

# Ask, then read whatever arrives in the next second with the echo off.
saved=$(stty -g)
stty -echo -icanon min 0 time 10
printf '\033]7501;?\007'
answer=$(dd bs=256 count=1 2>/dev/null)
stty "$saved"

case "$answer" in
  *'7501;?'*) ;;
  *)
    echo "mock: no answer to the probe; reporting OSC 9;4 only, as Claude does"
    progress '3;'; sleep "$step"; progress '0;'
    exit 0
    ;;
esac

trap 'report "state=clear"' EXIT
report "state=idle:app=claude-code"
wait_for_user "mock> (Enter to submit a prompt) "
report "state=working:app=claude-code"; progress '3;'
sleep "$step"
report "state=working:app=claude-code:msg=$(b64 "Fetching example.com and showing its title")"
sleep "$step"
report "state=blocked:app=claude-code:kind=$kind:msg=$(b64 "$message")"
# Claude's own alert follows its report, in the background so an early answer still works.
( sleep "$alert_delay"; printf '\033]777;notify;Claude Code;%s\007' "$alert" ) &
alerter=$!
wait_for_user "mock: $message (Enter to answer) "
kill "$alerter" 2>/dev/null
report "state=working:app=claude-code"
sleep "$step"
report "state=done:app=claude-code"; progress '0;'
wait_for_user "mock: turn finished (Enter to exit) "
