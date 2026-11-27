---
title: Make your own program resume after a restart
description: Have a program or script you run in a Workroom terminal come back where it was after your Mac restarts, by reporting how to start it again over the Program Resume Protocol (OSC 7577).
nightly: true
---

When your Mac restarts, or Workroom's background helper stops unexpectedly, a terminal whose program said how to start itself again gets that program back, in its folder, instead of an empty shell. Claude Code does this through a hook Workroom installs. Any program of yours can do it too, by sending the terminal a short report over the [Program Resume Protocol](https://www.superlogical.com/rex/docs/build/program-resume) (OSC 7577).

This page shows how to send that report from a shell script, what it contains, and what Workroom does with it. To see which terminals resume and when, see [Programs that resume after a restart](../app/terminals-and-tabs.md#programs-that-resume-after-a-restart).

## How it works

Every terminal Workroom opens has its own secret, a random token in the `OSC7577_TOKEN` environment variable. Your program sends the terminal a report: the command that starts it again, the folder to start it in, and a signature made with the token. Workroom keeps the newest report as the terminal's resume record and saves it with the terminal's tab.

If the terminal's session is later lost to a restart, Workroom opens the terminal again, starts its shell, and then runs the recorded command as the shell's first job, as if you had typed it. When you quit the program, you're left at a shell prompt in its folder.

Nothing is resumed when you close the terminal yourself, or type `exit`, or when the program ends on its own: a record goes about two seconds after the program that sent it exits.

## Report from a shell script

Save these two functions somewhere your scripts can source, for example `~/.local/share/osc7577.sh`:

```sh
# Tell the terminal how to start this program again: osc7577_report <command> [arguments...]
osc7577_report() {
  [ -n "${OSC7577_TOKEN-}" ] || return 0
  argv=""
  for word in "$@"; do
    argv="${argv:+$argv,}$(printf '%s' "$word" | base64 | tr -d '\n')"
  done
  body="pid=$$:time=$(date +%s):argv=$argv:cwd=$(printf '%s' "$PWD" | base64 | tr -d '\n')"
  if command -v sha256sum >/dev/null 2>&1; then
    mac=$(printf '%s:%s' "$body" "$OSC7577_TOKEN" | sha256sum | cut -d' ' -f1)
  else
    mac=$(printf '%s:%s' "$body" "$OSC7577_TOKEN" | shasum -a 256 | cut -d' ' -f1)
  fi
  printf '\033]7577;%s:mac=%s\007' "$body" "$mac" > /dev/tty
}

# Stop being resumed, while this program keeps running.
osc7577_clear() {
  [ -n "${OSC7577_TOKEN-}" ] || return 0
  body="pid=$$:time=$(date +%s):clear=1"
  if command -v sha256sum >/dev/null 2>&1; then
    mac=$(printf '%s:%s' "$body" "$OSC7577_TOKEN" | sha256sum | cut -d' ' -f1)
  else
    mac=$(printf '%s:%s' "$body" "$OSC7577_TOKEN" | shasum -a 256 | cut -d' ' -f1)
  fi
  printf '\033]7577;%s:mac=%s\007' "$body" "$mac" > /dev/tty
}
```

Outside a Workroom terminal, or with resume turned off, there's no token, and both functions do nothing.

The report names its sender by process ID (`$$`), and the record lasts only as long as that process does. So send it from the process that keeps running. In a wrapper script, report and then `exec` the real program, which keeps the same process ID:

```sh
#!/bin/sh
# devserver: run the dev server, and bring it back after a restart.
. ~/.local/share/osc7577.sh
osc7577_report devserver "$@"
exec npm run dev -- "$@"
```

Here the report asks for `devserver` itself to run again, found on your `PATH`, so it reports again when it resumes. A command must be an absolute path, or a bare name on `PATH`: a relative path such as `./devserver` is refused. A bare name is found as your shell would find it in the command's folder, so a relative `PATH` entry such as `./bin` or `node_modules/.bin` is that folder's.

A program that saves its own state can report the command that restores it. For example, Neovim can report `nvim -S <session file>` each time it writes a session.

## What a report contains

A report is the escape sequence `ESC ] 7577 ; <body> BEL` (or ending in `ESC \`), written to the terminal. Its body is `key=value` fields joined by `:`:

| Field | Value |
| ----- | ----- |
| `pid` | The process the report is for, as a decimal number. Workroom accepts it only from a process running under the terminal's shell, as your user. |
| `time` | When the report was made, in seconds since the Unix epoch. A report more than 60 seconds from Workroom's clock, or older than the last one it accepted from that process, is ignored. |
| `argv` | The command and its arguments, each one base64-encoded, joined by commas. Each word is passed to the command exactly, never through a shell. At most 64 words. |
| `cwd` | Optional. The folder to start the command in, base64-encoded, as an absolute path. Without it, Workroom uses the folder your program was in when it reported. |
| `clear` | `clear=1` in place of `argv`: forget the record, so the program isn't resumed. |
| `mac` | Last. The SHA-256, in lowercase hex, of the body before `:mac=`, then `:`, then the token. |

The whole sequence must be under 8 KiB. Newer reports from the same process replace older ones.

## Check it worked

Run `workroom sessions --json` in any terminal. A terminal with a record lists it as `resume`, with the program's name, its folder and when it reported. The command's arguments never appear there, since they can hold secrets. See [workroom sessions](../cli/workroom-sessions.md).

A report that Workroom doesn't accept changes nothing. The background helper's log says why, naming the program but never its arguments.

## Keep the token secret

- Never print the token, log it, or send it anywhere. Anyone who knows it can make records for that terminal.
- If your program runs other commands with fewer rights than itself, for example tools in a sandbox, remove `OSC7577_TOKEN` from their environment.
- Don't pass the token on over `ssh` or into a container. A remote workroom's terminals get tokens of their own.

## Limits

- Programs resume only in zsh, and in bash with Workroom's shell integration. In other shells, such as fish, and in macOS's own `/bin/bash`, the terminal opens a new shell instead.
- A run tab never resumes. It comes back stopped, and ⌘R starts it again.
- A background helper running as root accepts no reports, so a container whose image runs as root doesn't resume.
- A record lives with the terminal's tab, so closing the tab forgets it.
- In a remote workroom, a program resumes after its host restarts, as it does on your Mac. A hidden tab you haven't opened since waits until you open it. See [Reconnecting](../remote/reconnecting.md#programs-that-resume-after-the-host-restarts).
- If the folder a report named is gone when the terminal comes back, it opens a new shell instead.
- Resume can be turned off: see [Resume programs after a restart](../app/settings.md#resume-programs-after-a-restart).

Other terminals that support the Program Resume Protocol, such as Rex and Herdr, read the same reports, so a program that reports this way resumes in those terminals too.
