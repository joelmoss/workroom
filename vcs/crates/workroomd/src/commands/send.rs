//! `workroom send TARGET [TEXT]` (#689): types into a terminal session without attaching to it,
//! from the terminal API's `terminal.send`. TEXT goes in exactly as given (as a bracketed paste
//! when the program has turned that on), or with `--stdin` as stdin holds it; then each `--key`,
//! in order, encoded for the session's keyboard modes; then Enter with `--enter`. Nothing is
//! printed, but for `--json`'s envelope with the API's result. More than 1 MiB of text exits 2
//! (`TooLarge`) before any daemon is looked for, and the caller's own session exits 3
//! (`RefusedSelf`) without `--allow-self`.

use std::io::Read;

use serde_json::{Map, Value, json};

use super::kind::{CliError, Kind};
use super::{Args, Context, Flag, Outcome, terminal_api};
use crate::terminal::api::SEND_MAX_BYTES;

pub(super) const FLAGS: &[Flag] = &[
    Flag {
        name: "allow-self",
        usage: "Type into the session this command runs in, which is otherwise refused",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "enter",
        usage: "Press Enter last, after the text and the keys",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "key",
        usage: "A key to press after the text, repeated for more: Enter, Tab, Escape, Backspace, \
                Space, Up, Down, Left, Right, Home, End, Insert, Delete, PageUp, PageDown, F1-F12 \
                or a character, after any of Ctrl+, Alt+, Shift+ and Super+ (Ctrl+C)",
        hidden: false,
        ..Flag::VALUE
    },
    Flag {
        name: "stdin",
        usage: "Type stdin's text, exactly as it comes, in place of TEXT",
        hidden: false,
        ..Flag::BOOL
    },
];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let params = match params(args) {
        Ok(params) => params,
        // Go checks the command line before the command runs, so the envelope names no command.
        Err(Refused::Usage(message)) => return Outcome::Usage(CliError::internal(message)),
        Err(Refused::Input(error)) => return Outcome::Failed(error),
    };
    match terminal_api::call(context, "terminal.send", Value::Object(params)) {
        Err(error) => Outcome::Failed(error),
        Ok(result) if context.json => Outcome::Success(super::envelope::success("send", &result)),
        Ok(_) => Outcome::Printed(String::new()),
    }
}

/// Why the command line makes no request.
#[derive(Debug, PartialEq)]
enum Refused {
    /// A malformed command line: 1, as for every command.
    Usage(String),
    /// Input no request may carry: text over the limit, or stdin that isn't UTF-8.
    Input(CliError),
}

/// The request the command line makes, reading stdin's text with `--stdin`.
fn params(args: &Args) -> Result<Map<String, Value>, Refused> {
    let text = |stdin: bool| -> Result<Option<String>, Refused> {
        if !stdin {
            return Ok(None);
        }
        read_text(&mut std::io::stdin().lock()).map(Some)
    };
    request(args, text)
}

/// [`params`], with `stdin` reading the text when `--stdin` asks for it.
fn request(
    args: &Args,
    stdin: impl FnOnce(bool) -> Result<Option<String>, Refused>,
) -> Result<Map<String, Value>, Refused> {
    let from_stdin = args.is_set("stdin");
    let (target, given) = match (args.positional.as_slice(), from_stdin) {
        ([], _) => {
            return Err(Refused::Usage(
                "`workroom send` needs a TARGET: the session to type into".into(),
            ));
        }
        ([target], _) => (target, None),
        ([target, text], false) => (target, Some(text.clone())),
        ([_, _], true) => {
            return Err(Refused::Usage(
                "`workroom send` takes TEXT or --stdin, not both".into(),
            ));
        }
        ([_, _, extra, ..], _) => {
            return Err(Refused::Usage(format!(
                "unknown command {extra:?} for \"workroom send\": TEXT is one argument, so quote \
                 it"
            )));
        }
    };
    let keys: Vec<&str> = args
        .values
        .iter()
        .filter(|(flag, _)| *flag == "key")
        .map(|(_, key)| key.as_str())
        .collect();
    let enter = args.is_set("enter");
    let text = match given {
        Some(text) => Some(text),
        None => stdin(from_stdin)?,
    };
    if text.is_none() && keys.is_empty() && !enter {
        return Err(Refused::Usage(
            "`workroom send` has nothing to type: give it TEXT, --stdin, --key or --enter".into(),
        ));
    }
    if let Some(text) = &text
        && text.len() > SEND_MAX_BYTES
    {
        return Err(Refused::Input(too_large(text.len())));
    }
    let mut params = Map::new();
    params.insert("target".into(), json!(target));
    if let Some(text) = text {
        params.insert("text".into(), json!(text));
    }
    if !keys.is_empty() {
        params.insert("keys".into(), json!(keys));
    }
    if enter {
        params.insert("enter".into(), json!(true));
    }
    if args.is_set("allow-self") {
        params.insert("allow_self".into(), json!(true));
    }
    Ok(params)
}

fn too_large(bytes: usize) -> CliError {
    CliError::new(
        Kind::TooLarge,
        format!(
            "the text is {bytes} bytes, more than the {SEND_MAX_BYTES} one send types; it is \
             refused whole, not typed in parts"
        ),
    )
}

/// The text `reader` holds, read no further than one byte past the limit, so an endless stdin
/// ends: more is `TooLarge`, and text that isn't UTF-8 `InvalidRequest`.
fn read_text(reader: &mut dyn Read) -> Result<String, Refused> {
    let mut bytes = Vec::new();
    Read::take(reader, SEND_MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            Refused::Input(CliError::new(
                Kind::InvalidRequest,
                format!("can't read the text from stdin: {error}"),
            ))
        })?;
    if bytes.len() > SEND_MAX_BYTES {
        return Err(Refused::Input(CliError::new(
            Kind::TooLarge,
            format!(
                "stdin holds more than the {SEND_MAX_BYTES} bytes one send types; it is refused \
                 whole, not typed in parts"
            ),
        )));
    }
    String::from_utf8(bytes).map_err(|error| {
        Refused::Input(CliError::new(
            Kind::InvalidRequest,
            format!("the text from stdin isn't UTF-8: {error}"),
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(argv: &[&str]) -> Args {
        let argv: Vec<String> = argv.iter().map(|arg| (*arg).to_string()).collect();
        let (parsed, error) = super::super::parse(&argv, FLAGS);
        assert_eq!(error, None, "{argv:?}");
        Args {
            positional: parsed.positional,
            values: parsed.values,
            flags: FLAGS,
        }
    }

    fn requested(argv: &[&str]) -> Result<Value, Refused> {
        request(&parsed(argv), |stdin| {
            Ok(stdin.then(|| "from stdin\n".to_string()))
        })
        .map(Value::Object)
    }

    /// The text as given, the keys in order and repeated, Enter and `allow_self` only when asked;
    /// a text after `--` may start with a dash.
    #[test]
    fn the_command_line_is_the_request() {
        assert_eq!(
            requested(&["tests", "ls -la\n"]),
            Ok(json!({"target": "tests", "text": "ls -la\n"}))
        );
        assert_eq!(
            requested(&[
                "tests",
                "--key",
                "Ctrl+C",
                "--key",
                "Up",
                "--enter",
                "--allow-self"
            ]),
            Ok(json!({
                "target": "tests",
                "keys": ["Ctrl+C", "Up"],
                "enter": true,
                "allow_self": true,
            }))
        );
        assert_eq!(
            requested(&["tests", "--", "-n"]),
            Ok(json!({"target": "tests", "text": "-n"}))
        );
        assert_eq!(
            requested(&["tests", "--stdin", "--enter"]),
            Ok(json!({"target": "tests", "text": "from stdin\n", "enter": true}))
        );
        assert_eq!(
            requested(&["tests", ""]),
            Ok(json!({"target": "tests", "text": ""})),
            "the daemon says an empty text types nothing"
        );
    }

    /// A malformed command line is a usage error, found before anything is read or sent.
    #[test]
    fn a_command_line_with_nothing_to_type_or_too_much_is_a_usage_error() {
        for (argv, says) in [
            (&[][..], "needs a TARGET"),
            (&["tests"][..], "nothing to type"),
            (&["tests", "a", "b"][..], "unknown command \"b\""),
            (&["tests", "a", "--stdin"][..], "TEXT or --stdin"),
        ] {
            match requested(argv) {
                Err(Refused::Usage(message)) => assert!(message.contains(says), "{message}"),
                other => panic!("{argv:?}: {other:?}"),
            }
        }
    }

    /// Stdin is read no further than a byte past the limit, which is `TooLarge`; text that isn't
    /// UTF-8 is `InvalidRequest`.
    #[test]
    fn stdin_over_the_limit_or_not_utf8_is_refused() {
        let at = vec![b'x'; SEND_MAX_BYTES];
        assert_eq!(
            read_text(&mut at.as_slice()).map(|t| t.len()),
            Ok(SEND_MAX_BYTES)
        );
        let mut endless = std::io::repeat(b'x');
        match read_text(&mut endless) {
            Err(Refused::Input(error)) => assert_eq!(error.kind, Kind::TooLarge),
            other => panic!("{other:?}"),
        }
        match read_text(&mut [0xff, 0xfe].as_slice()) {
            Err(Refused::Input(error)) => assert_eq!(error.kind, Kind::InvalidRequest),
            other => panic!("{other:?}"),
        }
    }
}
