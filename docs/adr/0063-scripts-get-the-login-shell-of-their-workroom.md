# Scripts get the login shell of their workroom

Decided 2026-10-31 (owner, triage of #560). Amends the environment row of [ADR 0053](0053-setup-and-teardown-scripts-run-on-every-kind-of-workroom.md).

A setup or teardown script runs as if the user had started it from a terminal opened in the workroom. Just before it starts, and only once it has passed the trust check, the user's login and interactive shell is read in the workroom, and the script gets that environment. Locally that is `script.Run`, covering the app and the CLI; on a host it is `workroomd run-script`, reading in `--dir`. The app's cached read and remote git's read stay at home, because they run unattended and could otherwise read an unread clone's local tool config.

Why: read from home, a version manager puts its global tools ahead of its shims, so a script in a project pinned to Ruby 3.4.11 ran Ruby 4.0.9 and failed in Bundler.

The rc now runs with the clone's directory-local config active. That's accepted: the script has been trusted and is about to run in that clone anyway. A version manager's own trust step can't be counted on: mise applied a `.mise.toml` from a new directory without asking.

Rejected: running the script through the shell (`$SHELL -lic 'exec "$0"'`), so that it is a real child of it. An rc that ends in `exec` or `exit` then skips the script and still reports success, which for a teardown means skipped cleanup with no error; the rc's output lands in the script's log; and a script that can't start stops being reported as one. The read has none of these and falls back to the environment it had, saying why. It gives up only state outside the environment, such as an rc's `umask` or `ulimit`, which a script can set itself.

The local read starts its shell in a new session, not just a new process group: under a real terminal, interactive zsh in a background group is stopped by SIGTTOU, which would hang `workroom create`. `workroomd run-script` has no terminal (`RequestTTY no`), so it keeps its process group.

Source: [`internal/script/login_environment_unix.go`](../../internal/script/login_environment_unix.go), [`vcs/crates/workroomd/src/cli/run_script.rs`](../../vcs/crates/workroomd/src/cli/run_script.rs), #560.
