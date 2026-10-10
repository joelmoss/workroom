//! `wr-agent serve | attach`, mirroring today's shipped `workroom-session daemon | attach`.
//!
//! That shape is deliberate rather than inherited: `applyPersistentSession` sets libghostty's
//! `config.command` to a command LINE, so libghostty forks a *process* — meaning there has to be
//! a forked relay executable as well as the in-process client. One binary in both roles keeps the
//! frame codec in one language instead of duplicating it forever.

use std::path::PathBuf;
use std::process::ExitCode;

use wr_agent::cli;

fn usage() -> &'static str {
    "usage:
  wr-agent serve --socket <path> [--idle-timeout <secs>|never] [--screens <dir>]
        own ptys and services (the daemon role).
        --idle-timeout never is for a supervised remote agent, which must keep running with no
        client attached.
        --screens <dir> keeps each session's screen in <dir>, so a pane reattaching after the
        host reboots is shown its last one. <dir> must survive a reboot: not the socket's.
  wr-agent serve --stdio
        serve one connection over stdin/stdout, whose sessions die with it; a transport test
        entry point, not a persistent remote agent (that is serve --idle-timeout never + relay)
  wr-agent attach --socket <path> [--session <uuid>]
        relay stdio to a session; what libghostty forks
  wr-agent relay --socket <path>
        copy bytes between stdio and a running agent's socket, and nothing else;
        what a driver runs on the far side (`ssh host wr-agent relay --socket <path>`)
  wr-agent list --socket <path>
        print the agent's live sessions
  wr-agent hand-off --socket <path> --binary <path> [--force]
        replace the running agent's program with <binary>, keeping every session and its pid.
        Prints `current` when the agent is running that binary already, `handed off` when it was
        replaced. Refused, with the agent left running, when <binary> cannot restore its sessions
        (exit 1) or the agent predates hand-off (exit 3). --force hands off to the same binary.
  wr-agent handoff-check <table>
        whether this build can restore the sessions a hand-off table describes; run by the agent
        handing off, before it replaces itself
  wr-agent enrol --workroom <id> --broker <url>
        enrol this remote workroom with the Workroom credential broker, reading the one-time code
        from stdin, and make `wr-agent credential` git's helper for https://github.com
  wr-agent credential <get|store|erase>
        git's credential helper: answers github.com with an installation token from the broker,
        or for a workroom that never enrolled, with what the Mac relays
  wr-agent credential relay --port <port>
        have a workroom that never enrolled ask the Mac for git's credentials through <port> on
        this box's loopback, reading the relay's secret from stdin, and make `wr-agent credential`
        git's helper for https://github.com
  wr-agent protocol
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
        Some("hand-off") => cli::hand_off::run_hand_off(&args),
        Some("enrol") => cli::broker::run_enrol(&args),
        Some("credential") => cli::broker::run_credential(&args),
        Some("handoff-check") => cli::hand_off::run_handoff_check(&args),
        _ => {
            eprint!("{}", usage());
            ExitCode::FAILURE
        }
    }
}
