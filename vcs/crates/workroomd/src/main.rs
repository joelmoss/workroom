//! `workroomd serve | attach`, mirroring today's shipped `workroom-session daemon | attach`.
//!
//! That shape is deliberate rather than inherited: `applyPersistentSession` sets libghostty's
//! `config.command` to a command LINE, so libghostty forks a *process* — meaning there has to be
//! a forked relay executable as well as the in-process client. One binary in both roles keeps the
//! frame codec in one language instead of duplicating it forever.

use std::path::PathBuf;
use std::process::ExitCode;

use workroomd::cli;

fn usage() -> &'static str {
    "usage:
  workroomd serve --socket <path> [--idle-timeout <secs>|never] [--screens <dir>]
        own ptys and services (the daemon role).
        --idle-timeout never is for a supervised remote daemon, which must keep running with no
        client attached.
        --screens <dir> keeps each session's screen in <dir>, so a pane reattaching after the
        host reboots is shown its last one. <dir> must survive a reboot: not the socket's.
  workroomd serve --stdio
        serve one connection over stdin/stdout, whose sessions die with it; a transport test
        entry point, not a persistent remote daemon (that is serve --idle-timeout never + relay)
  workroomd attach --socket <path> [--session <uuid>]
        relay stdio to a session; what libghostty forks
  workroomd relay --socket <path>
        copy bytes between stdio and a running daemon's socket, and nothing else;
        what a driver runs on the far side (`ssh host workroomd relay --socket <path>`)
  workroomd list --socket <path>
        print the daemon's live sessions
  workroomd program-status --socket <path> [--json]
        print what each session's program says it is doing (OSC 7501), as the app is told it
  workroomd hand-off --socket <path> --binary <path> [--force]
        replace the running daemon's program with <binary>, keeping every session and its pid.
        Prints `current` when the daemon is running that binary already, `handed off` when it was
        replaced. Refused, with the daemon left running, when <binary> cannot restore its sessions
        (exit 1) or the daemon predates hand-off (exit 3). --force hands off to the same binary.
  workroomd handoff-check <table>
        whether this build can restore the sessions a hand-off table describes; run by the daemon
        handing off, before it replaces itself
  workroomd credential <get|store|erase>
        git's credential helper for a local container workroom: answers github.com with what the
        Mac relays
  workroomd credential relay --port <port>
        have a local container workroom ask the Mac for git's credentials through <port> on this
        box's loopback, reading the relay's secret from stdin, and make `workroomd credential`
        git's helper for https://github.com
  workroomd run-script --dir <dir> --timeout <secs> [--env NAME=VALUE]... -- <script>
        run a remote workroom's setup or teardown script in <dir>, with the login shell's
        environment and each NAME=VALUE, streaming its output. Exits with the script's status,
        124 when <secs> ran out, 126 when it could not start; the whole tree is killed on a
        timeout or a SIGTERM, SIGHUP or SIGINT
  workroomd protocol
        print the protocol version this build speaks
"
}

fn main() -> ExitCode {
    // Before anything is started, so no session's shell inherits the port.
    #[cfg(target_os = "macos")]
    cli::drop_inherited_exception_ports();
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("protocol") => cli::protocol(),
        Some("serve") if args.iter().any(|a| a == "--stdio") => cli::serve::run_serve_stdio(),
        Some("serve") => match cli::flag(&args, "--socket") {
            Some(socket) => cli::serve::run_serve(
                PathBuf::from(socket),
                cli::flag(&args, "--idle-timeout"),
                cli::flag(&args, "--handoff").map(PathBuf::from),
                cli::flag(&args, "--screens").map(PathBuf::from),
            ),
            None => {
                eprintln!("error: serve needs --socket <path> or --stdio");
                ExitCode::FAILURE
            }
        },
        Some("attach") => cli::attach::run_attach(&args),
        Some("relay") => cli::relay::run_relay(&args),
        Some("list") => cli::list::run_list(&args),
        Some("program-status") => cli::program_status::run_program_status(&args),
        Some("hand-off") => cli::hand_off::run_hand_off(&args),
        Some("credential") => cli::credential::run_credential(&args),
        Some("run-script") => cli::run_script::run_run_script(&args),
        Some("handoff-check") => cli::hand_off::run_handoff_check(&args),
        _ => {
            eprint!("{}", usage());
            ExitCode::FAILURE
        }
    }
}
