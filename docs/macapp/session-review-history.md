# Session/VCS review history

The current requirements live in [the app instructions](../../macapp/AGENTS.md#session-and-vcs-changes).
These failures explain why source-backed premises, neighbouring-property tests and an independent
reviewer are required for those changes.

## False premises

- *"Guessing the Swift helper fails loudly, so an unanswered ownership probe should resolve there."*
  `SessionDaemon.handleAttach` ends in `create(request:connection:)` for an id it does not hold —
  it creates on attach exactly as the daemon does. Both guesses silently fork a second shell. The
  rule was wrong and a test asserted it, which kept it wrong.
- *"`WRITE_TIMEOUT` bounds the repaint."* It is a **no-progress** bound, reset per `write` call
  (`transport.rs`). Reused as a total-transfer budget it became a throughput floor, so a healthy
  peer on a slow link was permanently unattachable.
- *"`CLIVCSWriter` is untouched, so daemon-routed and native writes classify identically by
  construction."* Both halves of the premise were true and the conclusion was false. The classifier
  really was untouched; it reached opposite verdicts because the two paths fed it different INPUT —
  a stale child environment, a different exit code for a missing tool, and transport failures
  reported as "the command never ran". One classifier fed divergent input is harder to catch than
  two classifiers, because nothing looks out of sync. Generalised: when a claim is "X is unchanged,
  therefore behaviour is unchanged", the thing to verify is everything that reaches X.

## Fixes that broke a neighbouring property

Three rounds of this on one branch (#188): chunking a repaint fixed a panic and turned one write
timeout into N; bounding that with a `break` left the client's parser stranded mid-escape-sequence;
the bound itself became the throughput floor above. Each fix was correct about its target.

The same shape again on #205's review fixes, three times in two rounds: replacing an env allowlist
with `env_clear()` + the app's own environment fixed a stale-identity bug and silently dropped the
`GIT_DIR`/`GIT_WORK_TREE` scrub, so a commit requested in one repository landed in another and
reported success; putting a cancellation shield in the command runner protected the jj flock (removed with jj, #266) and
stranded connection slots on every superseded read; gating the resulting SIGKILL on `timed_out`
stopped it firing after normal exits and opened a path where it never fired at all. Each fix was
correct about its target. Each was caught by a reviewer that had not written it.
