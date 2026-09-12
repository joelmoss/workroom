//! `wr-agent serve | attach`, mirroring today's shipped `workroom-session daemon | attach`.
//!
//! Phase 1 lands the wire first: the subcommands are recognised and report what they will own, so
//! the binary, its build targets and its CI wiring are real before the pty port begins. The pty
//! and the services follow; nothing in the app calls this yet.

use std::process::ExitCode;

use wr_agent::protocol::envelope::{Hello, MIN_SUPPORTED_VERSION, PROTOCOL_VERSION};

const BUILD: &str = concat!("wr-agent ", env!("CARGO_PKG_VERSION"));

fn usage() -> &'static str {
    "usage:
  wr-agent serve --socket <path>   own ptys and services (the daemon role)
  wr-agent attach                  relay stdio to a session (what libghostty forks)
  wr-agent protocol                print the protocol version this build speaks
"
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("protocol") => {
            let hello = Hello::current(BUILD);
            println!("protocol {PROTOCOL_VERSION} (minimum supported {MIN_SUPPORTED_VERSION})");
            println!(
                "greeting {} bytes: {:02x?}",
                hello.encode().len(),
                hello.encode()
            );
            ExitCode::SUCCESS
        }
        Some("serve") | Some("attach") => {
            eprintln!(
                "wr-agent {}: the protocol is in place; the pty and services are not yet ported.",
                args[0]
            );
            ExitCode::FAILURE
        }
        _ => {
            eprint!("{}", usage());
            ExitCode::FAILURE
        }
    }
}
