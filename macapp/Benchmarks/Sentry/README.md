# Sentry SDK overhead probe

Run `make app-bench-sentry BENCH_OUT=/tmp/workroom-sentry-new-run` from the repository root.
The output directory must not exist. This first builds the app, then takes the exclusive GUI
lock. App Nap is prevented during the workload. The helper launches through LaunchServices, then
hides its window so every cost phase has the same inactive state. It restores foreground state for
the hang check. Do not build or run other benchmarks during the measurement.

The helper compiles with Swift 6, `-O`, no `DEBUG`, the exact SDK framework resolved for the app,
and the app's actual `SentryConfig.swift` and `LaunchSignposts.swift`. Its only channel shim is
`isNightlyBuild = false`; the helper overrides environment metadata. It is an optimized standalone
AppKit application, **not a Release build of the entire Workroom app**.

Three fresh-process arms rotate order across three rounds:

- `off`: never start the SDK.
- `no-profiling`: retain the app's tracing, crash and hang options, but set profile sampling to zero.
- `full`: use the app's full tracing and profile sampling settings.

Each process measures synchronous SDK initialization, idle before any root span, 10 Hz label
updates without a root span, the same updates under an explicit root span, and its immediate tail.
The long control also measures idle after a full profile chunk expires. A final intentional
three-second main-thread block verifies real hang detection
without a debugger. It is outside the steady-state CPU phases. Repeated comparisons use five
seconds per idle/UI phase and two seconds after the trace. A separate full-profile control waits
65 seconds after the trace to verify chunk delivery and shutdown. Profiling and tracing evidence
is verified through the SDK's start notification and envelopes received by a localhost collector.
The collector must receive hang events and transactions in both monitored arms, and profile chunks
only in the long full arm. Short runs verify the profile start notification; the separate long
control also requires a chunk with usable samples. This avoids repeating the minute-long tail in
every comparison. The make target runs both parts; the runner's `--verify-chunk` requests the control.
Invalid state produces an error report and a normal exit status 2; it does not deliberately crash
the helper. The runner stops so an invalid comparison cannot silently enter the results.

`python3 macapp/Scripts/benchmark-safety_test.py` checks the real failure functions headlessly:
invalid state must write an error report and exit with status 2. It also rejects crash-producing
Swift assertion calls throughout `macapp/Benchmarks/`. Run `make app-test-preflight` for this check
and the Makefile/workflow invariants. The full `make app-test-scripts` runs them before packaging
builds; CI also runs the preflight before toolchain setup.

Telemetry goes only to an ephemeral `127.0.0.1` HTTP server. Each process has an owned cache and
the helper uses a temporary user home. No production DSN, installed app, personal terminal,
project, saved session or daemon participates. Raw owned-fixture envelopes, per-process logs,
reports and the summary remain in the output directory for inspection.

Use process `getrusage` CPU time, context switches and `proc_pid_rusage` physical footprint.
Initialization wall time includes synchronous SDK startup only; this is not first-paint timing.
All arms link the same framework, so this excludes any binary-loading cost from removing Sentry.
The window is hidden during the cost phases; label updates still execute, but this does not measure
visible-window rendering cost. The active-root-span phase establishes the profiler's conditional
cost in this controlled inactive state. Neither the UI workload nor its trace duty cycle represents
a day of Workroom use. Local HTTP receipt
does not measure Internet transport latency, Sentry server processing, or a full release's hang
capture cost. Hang-and-recovery CPU includes recovery and sending; it is not isolated stack-walk
time. No profiler is attached while taking counters.

Before changing production policy, require consistent repeated evidence and a meaningful cost:
roughly one percentage point of a core while profiling, 10 MiB of extra footprint, or 20 ms of
initialization time. These are investigation thresholds, not timing assertions. A conditional
cost alone does not establish daily cost: a policy change still needs representative trace duty
and a decision about lost profiling coverage. Keep crash and hang reporting intact.

For a shorter diagnostic run, invoke the runner under the GUI lock directly after `make app-build`:

```sh
python3 macapp/Scripts/gui-lock.py exclusive --label 'Sentry SDK benchmark' -- \
  python3 macapp/Benchmarks/Sentry/run.py --out /tmp/workroom-sentry-short \
  --seconds 5 --tail 2 --rounds 3 --verify-chunk
```

Use `--seconds 2 --tail 2 --rounds 1` only to smoke-test the evidence and cleanup loop. It cannot
establish profile-chunk upload or return to baseline after the chunk expires.
