//! Asking a person at the CLI: a yes or no ([`confirm`], [`ask`]) and the approval of a script this
//! Mac hasn't approved ([`approve_script`], [`approve`]). `trust`, `delete` and `create` ask with
//! these (`create` asks where to start with a numbered choice of its own). Each is a plain line
//! prompt (`[y/N]`), where Go's prompts are a full-screen form (charmbracelet/huh).

use std::io::{BufRead, BufReader, IsTerminal, Write};

use super::config;
use super::kind::CliError;
use super::panel::{PANEL_WIDTH, Paint};
use super::trusted_script::Script;

/// The terminal a person is asked on: where the question goes and where the answer comes from.
pub(super) struct Terminal {
    pub(super) out: Box<dyn Write>,
    pub(super) input: Box<dyn BufRead>,
}

/// Stdin and stdout when stdin is a terminal, else the controlling terminal, which Go's prompts
/// (charmbracelet/huh) open too. No terminal is an error, in huh's words, so nothing is done on an
/// answer no one gave.
pub(super) fn terminal() -> Result<Terminal, CliError> {
    if std::io::stdin().is_terminal() {
        return Ok(Terminal {
            out: Box::new(std::io::stdout()),
            input: Box::new(std::io::stdin().lock()),
        });
    }
    let no_tty = |error: std::io::Error| {
        CliError::internal(format!(
            "huh: could not open a new TTY: open /dev/tty: {}",
            config::os_error(&error)
        ))
    };
    let tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .map_err(no_tty)?;
    let input = tty.try_clone().map_err(no_tty)?;
    Ok(Terminal {
        out: Box::new(tty),
        input: Box::new(BufReader::new(input)),
    })
}

/// Asks a person `question`, yes or no, on the [`terminal`].
pub(super) fn ask(question: &str) -> Result<bool, CliError> {
    let mut terminal = terminal()?;
    confirm(&mut terminal.out, &mut terminal.input, question)
}

/// Asks `question` on `out` and reads the answer from `input`: yes for `y` or `yes`, in any case,
/// and no for anything else, an empty answer included. Input that ends before an answer is the
/// person giving up, which ends the command, as Go's prompt (charmbracelet/huh) reports Ctrl-C.
pub(super) fn confirm(
    out: &mut impl Write,
    input: &mut impl BufRead,
    question: &str,
) -> Result<bool, CliError> {
    let _ = write!(out, "{question} [y/N] ");
    let _ = out.flush();
    let mut answer = String::new();
    match input.read_line(&mut answer) {
        Ok(0) => Err(CliError::internal("user aborted")),
        Ok(_) => Ok(matches!(
            answer.trim().to_ascii_lowercase().as_str(),
            "y" | "yes"
        )),
        Err(error) => Err(CliError::internal(format!(
            "read the answer: {}",
            config::os_error(&error)
        ))),
    }
}

/// [`approve_script`] on stdout and stdin, for a person at the terminal stdin is. Only a person
/// there can read a script and approve it: a caller asks this only when stdin is a terminal.
pub(super) fn approve(paint: Paint, sc: &Script) -> Result<bool, CliError> {
    let mut stdout = std::io::stdout();
    let approved = approve_script(&mut stdout, &mut std::io::stdin().lock(), paint, sc);
    let _ = stdout.flush();
    approved
}

/// Shows `sc`, a script this Mac has not approved, on `out`, in a panel titled with its file, and
/// asks on `input` whether to approve and run it. Go's `approveScript`.
pub(super) fn approve_script(
    out: &mut impl Write,
    input: &mut impl BufRead,
    paint: Paint,
    sc: &Script,
) -> Result<bool, CliError> {
    let mut shown = paint.yellow(&format!(
        "{} {} has not been approved on this Mac.",
        sc.file,
        sc.origin.label()
    ));
    shown.push('\n');
    let title = format!(" {} ", sc.file);
    let rule = PANEL_WIDTH.saturating_sub(2 + title.chars().count());
    shown += &format!(
        "{}{}{}\n",
        paint.dim("╭─"),
        paint.bold_blue(&title),
        paint.dim(&"─".repeat(rule))
    );
    let text = visible_text(&sc.text);
    let mut lines: Vec<&str> = text.split('\n').collect();
    // The text's last newline ends its last line rather than starting another.
    if lines.last() == Some(&"") {
        lines.pop();
    }
    for line in lines {
        shown += &format!("{} {line}\n", paint.dim("│"));
    }
    shown += &paint.dim(&format!("╰{}", "─".repeat(PANEL_WIDTH - 1)));
    shown.push('\n');
    let _ = out.write_all(shown.as_bytes());
    confirm(out, input, &format!("Approve {} and run it?", sc.file))
}

/// `text` as a person must read it before approving it: every character the terminal would act
/// on or hide (escape sequences, a carriage return that overwrites a line, bidi overrides,
/// zero-width characters, bytes that are not UTF-8) is written out as an escape, so the script
/// cannot show one thing and run another. Newlines and tabs stay. Go's `visibleText`.
fn visible_text(text: &[u8]) -> String {
    let mut out = String::new();
    for chunk in text.utf8_chunks() {
        for ch in chunk.valid().chars() {
            match ch {
                '\n' | '\t' => out.push(ch),
                ch if ch.is_control() || is_format(ch) => {
                    out += &format!("\\u{{{:04x}}}", u32::from(ch));
                }
                ch => out.push(ch),
            }
        }
        for byte in chunk.invalid() {
            out += &format!("\\x{byte:02x}");
        }
    }
    out
}

/// Whether `ch` is one a terminal would act on or a reader can't see: a control character (C0,
/// DEL, C1: escapes, a carriage return, a newline) or a format one (bidi overrides, zero-width
/// characters). What a session's label and `new`'s title never hold (#694).
pub(crate) fn is_hidden(ch: char) -> bool {
    ch.is_control() || is_format(ch)
}

/// `text` on one line, as `visible_text` shows it but with its newlines and tabs written out too:
/// for a cell of a table, such as `workroom sessions`' label and live title, which a program sets.
pub(crate) fn one_line(text: &str) -> String {
    text.chars()
        .map(|ch| {
            if is_hidden(ch) {
                format!("\\u{{{:04x}}}", u32::from(ch))
            } else {
                ch.to_string()
            }
        })
        .collect()
}

/// Whether `ch` is in Unicode's Cf (format) category, as Go 1.27.4's `unicode.Cf` table has it
/// (Unicode 17.0.0), the Go the retired Go CLI last built with: invisible characters that change
/// how text around them is shown. A newer Unicode's Cf ranges are added here by hand.
fn is_format(ch: char) -> bool {
    const CF: &[(u32, u32)] = &[
        (0x00ad, 0x00ad),
        (0x0600, 0x0605),
        (0x061c, 0x061c),
        (0x06dd, 0x06dd),
        (0x070f, 0x070f),
        (0x0890, 0x0891),
        (0x08e2, 0x08e2),
        (0x180e, 0x180e),
        (0x200b, 0x200f),
        (0x202a, 0x202e),
        (0x2060, 0x2064),
        (0x2066, 0x206f),
        (0xfeff, 0xfeff),
        (0xfff9, 0xfffb),
        (0x110bd, 0x110bd),
        (0x110cd, 0x110cd),
        (0x13430, 0x1343f),
        (0x1bca0, 0x1bca3),
        (0x1d173, 0x1d17a),
        (0xe0001, 0xe0001),
        (0xe0020, 0xe007f),
    ];
    let code = u32::from(ch);
    CF.iter().any(|&(low, high)| (low..=high).contains(&code))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::trusted_script;

    /// Go's `TestTheApprovalPromptShowsWhatTheTerminalWouldHide`, its vector byte for byte.
    #[test]
    fn the_approval_prompt_shows_what_the_terminal_would_hide() {
        let mut text = b"echo safe\x1b[1A\x1b[2K\rrm -rf x".to_vec();
        text.extend("\u{202e}\u{200b}".as_bytes());
        text.extend(b"\xff\n\tok\n");
        assert_eq!(
            visible_text(&text),
            "echo safe\\u{001b}[1A\\u{001b}[2K\\u{000d}rm -rf x\\u{202e}\\u{200b}\\xff\n\tok\n"
        );
        // A C1 control and a tag character, past the BMP.
        assert_eq!(
            visible_text("a\u{85}b\u{e0041}".as_bytes()),
            "a\\u{0085}b\\u{e0041}"
        );
    }

    /// A table cell (#694) writes out every hidden character, its newlines and tabs too, and
    /// leaves the rest.
    #[test]
    fn one_line_writes_out_every_hidden_character() {
        assert_eq!(
            one_line("a\x1b]0;x\x07\r\n\tb\u{202e}\u{200b}\u{85}é"),
            "a\\u{001b}]0;x\\u{0007}\\u{000d}\\u{000a}\\u{0009}b\\u{202e}\\u{200b}\\u{0085}é"
        );
    }

    /// Each range of Go 1.27.4's `unicode.Cf` (Unicode 17.0.0), its ends and the code points just
    /// outside them, so a range that drifts from Go's shows here.
    #[test]
    fn is_format_is_gos_unicode_17_cf_table() {
        for (low, high) in [
            (0x00ad, 0x00ad),
            (0x0600, 0x0605),
            (0x061c, 0x061c),
            (0x06dd, 0x06dd),
            (0x070f, 0x070f),
            (0x0890, 0x0891),
            (0x08e2, 0x08e2),
            (0x180e, 0x180e),
            (0x200b, 0x200f),
            (0x202a, 0x202e),
            (0x2060, 0x2064),
            (0x2066, 0x206f),
            (0xfeff, 0xfeff),
            (0xfff9, 0xfffb),
            (0x110bd, 0x110bd),
            (0x110cd, 0x110cd),
            (0x13430, 0x1343f),
            (0x1bca0, 0x1bca3),
            (0x1d173, 0x1d17a),
            (0xe0001, 0xe0001),
            (0xe0020, 0xe007f),
        ] {
            let at = |code: u32| char::from_u32(code).is_some_and(is_format);
            assert!(at(low) && at(high), "U+{low:04X}..U+{high:04X} is Cf");
            assert!(!at(low - 1), "U+{:04X} is not Cf", low - 1);
            assert!(!at(high + 1), "U+{:04X} is not Cf", high + 1);
        }
        // Gaps inside Go's strided ranges: U+2065 is unassigned, U+E0000 too.
        assert!(!is_format('\u{2065}'));
        assert!(!is_format('\u{e0000}'));
        // Other categories a terminal also hides are not Cf: a combining mark, a line separator.
        assert!(!is_format('\u{0301}'));
        assert!(!is_format('\u{2028}'));
    }

    fn script(text: &[u8]) -> Script {
        Script {
            name: trusted_script::SETUP_SCRIPT,
            file: "scripts/workroom_setup".to_string(),
            origin: trusted_script::Origin::Base,
            text: text.to_vec(),
            sha256: String::new(),
            exempt: false,
            trusted: false,
        }
    }

    /// The prompt shows the script in Go's panel, then asks; only a yes approves, and input that
    /// ends first gives up.
    #[test]
    fn the_approval_prompt_shows_the_script_and_takes_only_a_yes() {
        let sc = script(b"echo hi\nlast");
        let mut out = Vec::new();
        let approved = approve_script(&mut out, &mut &b"Y\n"[..], Paint(false), &sc);
        assert!(approved.expect("answered"));
        let rule = "─".repeat(34);
        assert_eq!(
            String::from_utf8(out).expect("UTF-8"),
            format!(
                "scripts/workroom_setup from the base commit has not been approved on this Mac.\n\
                 ╭─ scripts/workroom_setup {rule}\n│ echo hi\n│ last\n╰{}\n\
                 Approve scripts/workroom_setup and run it? [y/N] ",
                "─".repeat(59)
            )
        );
        for (answer, want) in [
            (&b"yes\n"[..], true),
            (b"n\n", false),
            (b"\n", false),
            (b"sure\n", false),
        ] {
            let mut out = Vec::new();
            let approved = approve_script(&mut out, &mut &answer[..], Paint(false), &sc);
            assert_eq!(approved.expect("answered"), want, "{answer:?}");
        }
        let mut out = Vec::new();
        let error =
            approve_script(&mut out, &mut &b""[..], Paint(false), &sc).expect_err("no answer");
        assert_eq!(error.message, "user aborted");
    }

    /// In colour, as Go's helpers paint it.
    #[test]
    fn the_approval_panel_is_painted_as_go_paints_it() {
        let sc = script(b"x\n");
        let mut out = Vec::new();
        approve_script(&mut out, &mut &b"n\n"[..], Paint(true), &sc).expect("answered");
        let out = String::from_utf8(out).expect("UTF-8");
        assert!(
            out.starts_with(
                "\x1b[33mscripts/workroom_setup from the base commit has not been approved on this \
             Mac.\x1b[0m\n\x1b[90m╭─\x1b[0m\x1b[1m\x1b[34m scripts/workroom_setup \x1b[0m\x1b[22m"
            ),
            "{out:?}"
        );
        assert!(out.contains("\x1b[90m│\x1b[0m x\n"), "{out:?}");
    }
}
