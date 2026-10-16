# A program that never probes may alert once it has shown it is running, and each request makes one notification

Decided 2026-10-16 (#481). Supersedes two rules in [ADR 0050](0050-program-status-service.md): "only a program run that answered the probe may notify", and "an `.osc` from the same session within 10 s of a single waiting request's start is merged into it".

Codex reports OSC 7501 without sending the support probe. The spec allows that ("Detection is optional. Terminals MUST ignore unknown OSCs, so a program MAY send reports without querying first", superlogical revision 0.4), and it does not tie notifications to the probe. Under ADR 0050's rule every Codex request had `notify=false`: it showed its mark but never alerted and never counted in the Dock badge. Codex also writes its own OSC 9 notification just before its report, which the old fold could not catch, since it only folded a notification that came after the alert.

**Alerts.** A `blocked` record whose owner did not probe becomes `notify=true` when the agent's screens tick (every 2 s) finds that at least `GRACE` (1 s) has passed since the request began, and its owner group is still alive, still the pty's foreground group, and not the session's interactive shell. So the alert lands 1 to 3 s after the program starts waiting. A `cat` of a recording has exited by then, or the shell's prompt has dropped the record. A report printed by the shell itself (a builtin `printf`) never qualifies, because a shell that sends no OSC 133 prompt would otherwise stay alive and in the foreground indefinitely. A repeated report of the same request from the same owner keeps its grace start and its promotion. The clock enters `Store` as a parameter (`apply_read`, `promote_unprobed`), so `Store` stays pure. A hand-off does not carry the start: a carried request starts its grace again at the next tick. A program that probes is unchanged: `notify=true` at once. As for a probed request, one that blocks while someone is looking at its terminal never alerts, even when the agent promotes it after they look away.

**One notification per request.** Workroom's "needs you" alert owns the request, and the program's own notification is folded into it whichever comes first (`ProgramStatusAlerts.programNotified`):

- While its session has an open request, the notification goes to the newest one, however late it comes. If Workroom has alerted that request, the notification is folded into the alert, and its text fills the alert only where the alert has none. If Workroom has not alerted it yet, the notification raises the alert at once, carrying its text, which is the request's detail when the report has no message (Codex sends none). If Workroom will not alert it, because its terminal is being looked at, the notification is shown as before.
- While its session reports program status but has no request, the notification is held for 500 ms. A request that appears in that time raises the alert at once, with the notification's text. Otherwise the notification is shown as it would have been.
- A session that reports no program status, or alerts turned off, shows it at once, as before.
- When an alert is raised, any ordinary notification Workroom showed for the same session in the previous 5 s is withdrawn, and its text carried into the alert.

The waiting count includes a request Workroom has alerted, as well as one with `notify=true`, so a request raised by its program's own notification counts before the agent promotes it.

Alternatives rejected:
- **Asking Codex to probe.** That is not ours to schedule, and the spec does not require it.
- **Trusting `app=codex` by name.** Any `printf` can name itself Codex.
- **Agent-side detection of a program's own notification.** It would duplicate what libghostty already decodes in the pane.
- **Holding every notification.** That delays programs that never report.

Accepted limits:
- A long-running foreground program that prints someone else's blocked report can alert: `tail -f` on a raw recording, or a `cat` of one inside a nested shell or over ssh (measured: `sh -c 'cat recording; sleep 20'` typed at a prompt is promoted). The rule cannot tell a replay from a relay (`ssh`, `mosh`, `tmux`), and relays are the case it has to serve.
- A raw recording holding both a program notification and a blocked report, `cat`ed in a pane nobody is looking at, raises a brief alert. It is withdrawn when the shell's next prompt drops the record. The same replay already showed an ordinary notification before this change.
- The guarantee is one notification in normal operation. On a lagging remote link, a banner and its sound may already have played before the backstop withdraws them. A program whose own notification comes before its first OSC 7501 report is not held. Codex and Claude Code both report `idle` at startup.
- An older agent never promotes. Codex on it alerts only through its own notification.

Source: [`vcs/crates/wr-agent/src/program_status.rs`](../../vcs/crates/wr-agent/src/program_status.rs) (`promote_unprobed`), [`vcs/crates/wr-agent/src/session.rs`](../../vcs/crates/wr-agent/src/session.rs) (`SessionStore::promote_unprobed`), [`macapp/WorkroomApp/Core/ProgramStatusAlerts.swift`](../../macapp/WorkroomApp/Core/ProgramStatusAlerts.swift) (`programNotified`).
