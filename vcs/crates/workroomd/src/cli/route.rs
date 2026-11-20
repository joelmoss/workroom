//! Which role a command line is (ADR 0078): the daemon's subcommands, which `main.rs` runs, or
//! the CLI's commands, which `crate::commands` runs.
//!
//! This decides it rather than the commands module because the daemon build hashes this and not
//! that (#680): every daemon start, `serve --handoff` and each child the daemon starts from its
//! own file (`run-supervisor`, `credential`, `run-script`) passes through here. A CLI-only change
//! keeps the daemon build, so it must not be able to send one of those to the CLI.

use std::ffi::OsString;

/// The daemon's own subcommands (ADR 0057 pins their names). `list` is the daemon's only with
/// `--socket`; without it, it is the CLI's workroom list.
const DAEMON_SUBCOMMANDS: &[&str] = &[
    "serve",
    "attach",
    "relay",
    "program-status",
    "hand-off",
    "handoff-check",
    "credential",
    "run-script",
    "run-supervisor",
    "protocol",
];

/// Whether `args` (the command line after the program) are one of the daemon's subcommands; the
/// rest, none at all among them, are the CLI's.
pub fn is_daemon(args: &[OsString]) -> bool {
    let socket = args.iter().any(|arg| {
        let arg = arg.to_string_lossy();
        arg == "--socket" || arg.starts_with("--socket=")
    });
    match args.first().and_then(|arg| arg.to_str()) {
        Some(name) if DAEMON_SUBCOMMANDS.contains(&name) => true,
        Some("list") => socket,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn the_daemons_subcommands_are_the_daemons() {
        for name in DAEMON_SUBCOMMANDS {
            assert!(is_daemon(&args(&[name])), "{name}");
        }
        assert!(is_daemon(&args(&["serve", "--socket", "/x"])));
        assert!(is_daemon(&args(&["list", "--socket", "/x"])));
        assert!(is_daemon(&args(&["list", "--socket=/x"])));
        assert!(is_daemon(&args(&["protocol"])));
    }

    #[test]
    fn everything_else_is_the_clis() {
        assert!(!is_daemon(&args(&[])));
        assert!(!is_daemon(&args(&["list"])));
        assert!(!is_daemon(&args(&["list", "--json"])));
        assert!(!is_daemon(&args(&["version", "--socket", "/x"])));
        assert!(!is_daemon(&args(&["--socket", "/x", "serve"])));
        assert!(!is_daemon(&args(&["bogus"])));
    }

    /// A first argument that is not UTF-8 names no daemon subcommand, so the CLI reports it.
    #[cfg(unix)]
    #[test]
    fn a_first_argument_that_is_not_utf8_is_the_clis() {
        use std::os::unix::ffi::OsStringExt;
        let args = vec![OsString::from_vec(b"serve\xff".to_vec())];
        assert!(!is_daemon(&args));
    }
}
