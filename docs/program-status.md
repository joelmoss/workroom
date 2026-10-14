# Program status: seeing which terminal needs you

A program running in a Workroom terminal can say what it is doing: working, waiting on you, finished,
or failed. Workroom shows it beside the terminal and, when the program is waiting on you, can alert
you. This is the OSC 7501 [program status protocol](https://www.superlogical.com/rex/docs/build/program-status),
which Claude Code 2.1.295 and later speak. Issue #358; the design decision is
[ADR 0050](adr/0050-program-status-service.md).

## What you see

| Mark | Means | Where |
|---|---|---|
| ✋ (`hand.raised.fill`) | The program is waiting on you: a permission, a question, a sign-in | Terminal tab, sidebar terminal row, workroom row (with a count), collapsed project header, switcher rail |
| Red mark | The program failed | Where the error mark already shows |
| Spinner / sweep | The program is working | As before |
| ✓ (`checkmark.circle.fill`) | The program finished its turn | Terminal tab and sidebar terminal row only |

Only one mark shows per place, in this order: waiting, failed, working, finished. Hover a mark for
what the program said; the last line says it came from the program in that terminal.

- Clicking the ✋ on a workroom row, a project header or a rail card goes to the terminal that has
  waited longest. **Go ▸ Go to Terminal That Needs You** (⇧⌘M) does the same across every window,
  and repeating it steps through the others.
- A finished or failed mark clears when you move focus into that terminal. A finish you watched
  happen leaves no mark behind.
- A program that left a request behind (it crashed mid-question, say) can be cleared by hand:
  right-click the tab or the sidebar row, then **Clear status**.
- When the link to a host drops, its marks stay with a small clock beside them, and the tooltip says
  they may be out of date, until Workroom reconnects.

A terminal with no mark is **not reporting**, which is not the same as "not waiting". Programs other
than Claude Code mostly don't report yet. The tooltip's last line says so: "Program status: not
reported", or "unavailable on this host" for an agent too old to keep status.

### Alerts and the Dock badge

When a program starts waiting on you and you are not looking at its terminal, Workroom posts a
notification ("Terminal 2 needs you") and counts the request in the Dock badge and the menu bar. The
count goes down when the request is answered, here or on another Mac, or the program ends; reading
the notification does not lower it. The menu bar's list shows requests under **Waiting for you**
and other notifications under **Unread notifications**.

Claude Code also posts its own notification about 6 seconds after it starts waiting. Workroom folds
it into its own alert rather than showing two. If you answer within those 6 seconds, Claude never
alerts at all.

**Settings ▸ Notify when a terminal needs me** turns Workroom's alerts and their Dock count off. The
marks stay, and the requests still show in the menu bar list. Programs' own notifications still
arrive as before.

Only a program that asked whether the terminal supports the protocol (the probe, below) can alert
you. A report printed by anything else (`cat`ing a file, say) shows its mark but never alerts.

## Which terminals support it

Every terminal whose shell runs under `wr-agent`, which is every workroom terminal, on this Mac and
on remote hosts, once the host's agent speaks protocol 8 or later. The agent, not the terminal you
see, keeps the status, so it survives closing the window, relaunching Workroom, an app update and a
second Mac attaching to the same session.

## The protocol, for program authors

A program first checks for support, then reports. Everything is an OSC with `7501` and a body of
`key=value` pairs separated by colons, ended by ST (`ESC \`) or BEL.

```text
program:   ESC ] 7501 ; ? BEL
terminal:  ESC ] 7501 ; ?:states=idle,working,done,blocked,error:kinds=permission,question,auth BEL
program:   ESC ] 7501 ; state=working:app=my-tool ESC \
program:   ESC ] 7501 ; state=blocked:app=my-tool:kind=permission:msg=<base64> ESC \
program:   ESC ] 7501 ; state=done:app=my-tool ESC \
program:   ESC ] 7501 ; state=clear ESC \
```

The reply ends with the probe's own terminator. A program that gets no reply should treat the
protocol as unsupported; Claude Code reports nothing until it gets one.

| Key | Values |
|---|---|
| `state` | `idle`, `working`, `done`, `blocked`, `error`, or `clear` |
| `kind` | For `blocked`: `permission`, `question`, `auth` (otherwise none) |
| `id` | Which record; empty is the program itself. `a/b` is a child of `a` |
| `app` | The program's name; a record without one takes its nearest ancestor's |
| `title` | Base64. A label for the record |
| `msg` | Base64. One line for people: what it waits for or did |
| `progress` | 0-100. Accepted but not shown |

### Records and how long they last

- The terminal keeps one record per `id`. A report replaces its record completely.
- `state=clear` removes that record and everything beneath it (`a` removes `a/b`, not `ab`); with
  no `id` it removes all.
- When the shell's prompt comes back (Ghostty shell integration, OSC 133), `working`, `blocked` and
  `idle` records go. When the program's process group exits, its `working` and `blocked` records go
  too. `done` and `error` stay until you focus the terminal.
- A full reset (`ESC c`) removes every record.

### Limits

- At most 64 records per terminal; a 65th removes the one updated longest ago.
- `msg` and `title` are cut at 512 bytes. Invisible formatting characters (direction overrides,
  zero-width characters) are removed and control characters become spaces.
- `id` and `app` must be printable ASCII; a report with anything else there is ignored.
- libghostty-vt already refuses a report with an `id` over 128 bytes, an `app` over 32 or a `title`
  over 192.

### Try it

Paste this into a workroom terminal. Each step names the mark you should see.

```sh
b64() { printf %s "$1" | base64 | tr -d '\n'; }
old=$(stty -g); stty raw -echo min 0 time 10
printf '\033]7501;?\033\\'
reply=$(dd bs=1 count=128 2>/dev/null); stty "$old"
case "$reply" in *7501*) echo "supported";; *) echo "no reply: not supported here";; esac
printf '\033]7501;state=working:app=demo\033\\'; echo "spinner for 3 s"; sleep 3
printf '\033]7501;state=blocked:app=demo:kind=permission:msg=%s\033\\' "$(b64 'Apply?')"
printf '✋ "Waiting for your permission / Apply?". Press Enter: '; read _
printf '\033]7501;state=done:app=demo:msg=%s\033\\' "$(b64 'Applied')"; echo "✓ (focus moves it on)"
sleep 3; printf '\033]7501;state=clear\033\\'
```

To check the whole path without Claude Code (no account, no API turn), run
`sh testdata/program-status/mock-claude-code.sh` in a workroom terminal. It replays the sequence
below: it probes, waits for Enter as a prompt, then works, asks for permission (`--question` for a
question), posts Claude's own alert 6 s later, and finishes when you press Enter again. `--auto`
runs it unattended; the agent's tests use it that way.

## What Claude Code sends

Recorded with Claude Code 2.1.299 on 2026-10-14 (the evidence for #358):

```text
0.6 s   ESC]7501;?BEL  ESC[c                         probe, then a DA1 query
9.5 s   ESC]7501;state=idle:app=claude-code BEL      UI ready
18.7 s  ESC]7501;state=working:app=claude-code BEL   prompt submitted
22.9 s  ESC]7501;state=blocked:app=claude-code:kind=permission:msg=<"approve Fetch: https://example.com">
28.9 s  ESC]777;notify;Claude Code;Claude needs your permission BEL     its own alert, 6.0 s later
64.1 s  ESC]7501;state=working:app=claude-code BEL   answered
65.7 s  ESC]7501;state=done:app=claude-code BEL      turn finished; stays until the next turn
exit    ESC]7501;state=clear BEL
```

A question is `kind=question` with `msg` "answer: Do you prefer red or blue? (Red · Blue)". Claude
probes again whenever it redraws the whole screen, and every probe is answered. Without a reply it
sends only OSC 9;4.

## Signals, in one place

- The **mark** on a terminal is what the program in it reports now.
- The **unread dot** and the **Dock badge** count notifications, plus requests waiting on you.
- A finished turn never alerts.

## Troubleshooting

`wr-agent program-status` prints what the agent holds for every session: whether its program is
reporting, its records, whether this agent keeps terminal state at all, and how many probe replies
it could not deliver. `--json` prints the same with a `schema_version`. Run it on the host the
terminal runs on (on this Mac it is inside the app bundle, `Contents/MacOS/wr-agent`).

The agent logs subscribers, dropped replies, evictions and truncations to `agent.log` beside its
socket: on this Mac `~/Library/Application Support/<bundle id>/sessions/agent.log`, on a remote host
beside the agent's socket there. The app logs a host going stale and coming back under the `program-status`
category (`log stream --predicate 'category == "program-status"'`).

A mark that never clears on a **remote** host usually means the host has no shell integration
(OSC 133): Workroom pushes it on connect, and without it a request clears only on the next report,
on exit or when its program's process group ends. Clear status always works.
