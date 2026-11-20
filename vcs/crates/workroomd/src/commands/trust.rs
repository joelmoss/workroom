//! `workroom trust`, `trust status` and `untrust` (#363): approving, checking and forgetting the
//! approval of the setup and teardown scripts a project's next create or delete would run, by
//! their exact bytes. The approvals are config's per-project `trusted_scripts` records
//! (`config`), the same ones Go writes.
//!
//! In a terminal `trust` shows each unapproved script and asks; with `--json`, `--stdin`, or no
//! terminal on stdin it approves without asking, as Go's does: the caller has shown the bytes, or
//! no one is there to ask. The refusal of an unapproved script is `create`'s and `delete`'s.
//!
//! The app's flags: `--stdin NAME` judges the bytes on stdin in place of the project's file (a
//! remote host's copy), `--base BRANCH` the setup script at the branch a remote create checks out,
//! and `--devcontainer` that start's devcontainer.json too.

use std::io::{BufRead, IsTerminal, Read, Write};

use serde::Serialize;

use super::config::{self, Config};
use super::kind::CliError;
use super::start::{LocalWork, LocalWorkPayload};
use super::trusted_script::{self, Judge, Script, ScriptPayload};
use super::{Args, Context, Outcome};

/// `trust`'s and `trust status`'s `--help`, after the short line.
pub(super) const LONG: &str = "Approve the setup and teardown scripts a create or delete would \
    run next, by their exact contents. In a terminal each one is shown first and you are asked. \
    A changed script needs approving again. A script git ignores in the project's root needs no \
    approval.";

pub(super) const STATUS_LONG: &str = "Say whether the setup and teardown scripts a create or \
    delete would run next are approved. Exits 0 when every script there is approved or ignored \
    by git, 1 when one is not, and 2 when it cannot tell.";

/// `trust`'s payload: the scripts judged, with what was approved.
#[derive(Serialize)]
struct TrustPayload {
    scripts: Vec<ScriptPayload>,
}

/// `trust status`'s. `local_work` is what a create from that start leaves out, for a remote create
/// to warn about, and `start` the commit `--base` names.
#[derive(Serialize)]
struct StatusPayload<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    local_work: Option<LocalWorkPayload>,
    scripts: Vec<ScriptPayload>,
    #[serde(skip_serializing_if = "str::is_empty")]
    start: &'a str,
    trusted: bool,
}

/// `untrust`'s.
#[derive(Serialize)]
struct UntrustPayload<'a> {
    project: &'a str,
}

/// `trust`, or with `status` as its argument, `trust status`.
pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    match args.positional.split_first() {
        Some((sub, rest)) if sub == "status" => match rest.first() {
            Some(extra) => Outcome::Usage(CliError::internal(format!(
                "unknown command {extra:?} for \"workroom trust status\""
            ))),
            None => status(context, args),
        },
        Some((extra, _)) => Outcome::Usage(CliError::internal(format!(
            "unknown command {extra:?} for \"workroom trust\""
        ))),
        None => trust(context, args),
    }
}

/// What the trust commands judged: the project, its config, its scripts, the local work a create
/// from that start leaves out, and the commit `--base` names.
struct Judged {
    config: Config,
    dir: String,
    scripts: Vec<Script>,
    work: LocalWork,
    start: String,
}

/// The project the trust commands name, judged: the one script read from stdin with `--stdin`,
/// else the scripts it would run next. Go's `judgedScripts`.
fn judged(context: &Context, args: &Args) -> Result<Judged, CliError> {
    let config = Config::new(context)?;
    let dir = project(context, &config, args)?;
    let say = |status: &str, message: &str| say(context, status, message);
    let judge = Judge {
        config: &config,
        dir: &dir,
        say: &say,
    };
    let mut work = LocalWork::default();
    let mut start = String::new();
    let stdin = args.value("stdin").unwrap_or_default();
    let scripts = if stdin.is_empty() {
        match args.value("base") {
            Some(base) => {
                let judged = judge.scripts_from(base, args.is_set("devcontainer"))?;
                (work, start) = (judged.1, judged.2);
                judged.0
            }
            None if args.is_set("devcontainer") => {
                return Err(CliError::internal(
                    "--devcontainer judges a container create's file, so it needs --base",
                ));
            }
            None => {
                let judged = judge.scripts()?;
                work = judged.1;
                judged.0
            }
        }
    } else {
        let Some(name) = trusted_script::known_name(stdin) else {
            return Err(CliError::internal(format!(
                "--stdin takes {}, {} or {}, not {stdin:?}",
                trusted_script::SETUP_SCRIPT,
                trusted_script::TEARDOWN_SCRIPT,
                trusted_script::DEV_CONTAINER
            )));
        };
        let mut text = Vec::new();
        std::io::stdin()
            .read_to_end(&mut text)
            .map_err(|error| CliError::internal(format!("read {}", config::os_error(&error))))?;
        vec![judge.judge(name, trusted_script::Origin::Stdin, text)?]
    };
    Ok(Judged {
        config,
        dir,
        scripts,
        work,
        start,
    })
}

/// The project the trust commands act on: `--project` or the current directory, or, inside one
/// of its workrooms (where every terminal pane opens), that workroom's project. Approvals are the
/// project's, so a workroom's path must never take them. Go's `trustedProject`.
fn project(context: &Context, config: &Config, args: &Args) -> Result<String, CliError> {
    let dir = config::resolve_project(args.value("project"), context)?;
    // A config that can't be read finds no project here; judging the scripts reports it.
    Ok(config
        .read()
        .ok()
        .and_then(|data| config::find_current_project(&data, &dir))
        .map_or(dir, |(project, _)| project))
}

/// Writes one `--verbose` status line, as Go's `Service.Status` prints one, straight to stdout:
/// before anything the command prints at its end.
fn say(context: &Context, status: &str, message: &str) {
    if context.verbose && !context.json {
        let mut stdout = std::io::stdout();
        let _ = writeln!(stdout, "{status:>12}  {message}");
        let _ = stdout.flush();
    }
}

/// `trust`: approves each script there that isn't yet.
fn trust(context: &Context, args: &Args) -> Outcome {
    let Judged {
        config,
        dir,
        mut scripts,
        ..
    } = match judged(context, args) {
        Ok(judged) => judged,
        Err(error) => return Outcome::Failed(error),
    };
    let from_stdin = !args.value("stdin").unwrap_or_default().is_empty();
    let paint = Paint(context.color);
    let mut lines = Vec::new();
    for sc in &mut scripts {
        if sc.exempt {
            lines.push(format!(
                "{} is ignored by git, so it needs no approval.",
                sc.file
            ));
            continue;
        }
        if sc.trusted {
            lines.push(format!("{} is already approved.", sc.file));
            continue;
        }
        // The bytes came on stdin from a caller that has shown them, or no one is here to ask.
        if !from_stdin && !context.json && std::io::stdin().is_terminal() {
            let mut stdout = std::io::stdout();
            let approved = approve_script(&mut stdout, &mut std::io::stdin().lock(), paint, sc);
            let _ = stdout.flush();
            match approved {
                Ok(true) => {}
                Ok(false) => {
                    lines.push(format!("{} was left unapproved.", sc.file));
                    continue;
                }
                Err(error) => return Outcome::Failed(error),
            }
        }
        if let Err(error) = record(context, &config, &dir, sc, from_stdin) {
            return Outcome::Failed(error);
        }
        sc.trusted = true;
        lines.push(paint.green(&format!("Approved {} {}.", sc.file, sc.origin.label())));
    }
    if context.json {
        let payload = TrustPayload {
            scripts: scripts.iter().map(Script::payload).collect(),
        };
        return Outcome::Success(super::envelope::success("trust", &payload));
    }
    if !from_stdin {
        lines.extend(absent(&scripts));
    }
    Outcome::Printed(lines.join("\n") + "\n")
}

/// Records `sc`'s bytes as approved for the project at `dir`, registering the project if it is
/// not yet: Go's `Service.Trust`. Bytes from stdin are the app's, for a project it has registered,
/// so one gone meanwhile is refused rather than registered again. `--pretend` records nothing.
fn record(
    context: &Context,
    config: &Config,
    dir: &str,
    sc: &Script,
    from_stdin: bool,
) -> Result<(), CliError> {
    if context.pretend {
        return Ok(());
    }
    if !from_stdin {
        config.add_project(dir, "git")?;
    }
    config.set_trusted_script(dir, sc.name, &sc.sha256)
}

/// `trust status`: whether each script there is approved, exiting 0 when all are, 1 when one is
/// not, and 2 when it can't tell, as Go's `exitStatus` ends it. A failure's envelope names
/// `trust status`.
fn status(context: &Context, args: &Args) -> Outcome {
    let judged = match judged(context, args) {
        Ok(judged) => judged,
        Err(error) => {
            return Outcome::Status(2, Box::new(Outcome::FailedIn("trust status", error)));
        }
    };
    let trusted = judged.scripts.iter().all(|sc| sc.trusted);
    let outcome = if context.json {
        let payload = StatusPayload {
            local_work: judged.work.any().then(|| judged.work.payload()),
            scripts: judged.scripts.iter().map(Script::payload).collect(),
            start: &judged.start,
            trusted,
        };
        Outcome::Success(super::envelope::success("trust status", &payload))
    } else {
        let paint = Paint(context.color);
        let mut text = String::new();
        for sc in &judged.scripts {
            let state = if sc.exempt {
                paint.green("ignored by git, needs no approval")
            } else if sc.trusted {
                paint.green("approved")
            } else {
                paint.red("not approved")
            };
            text += &format!("{} {}: {state}\n", sc.file, sc.origin.label());
        }
        if args.value("stdin").unwrap_or_default().is_empty() {
            for line in absent(&judged.scripts) {
                text += &line;
                text.push('\n');
            }
        }
        Outcome::Printed(text)
    };
    if trusted {
        outcome
    } else {
        Outcome::Status(1, Box::new(outcome))
    }
}

/// `untrust`: forgets every approval of the project's scripts and its devcontainer.json. The
/// project must be registered; `--pretend` forgets nothing and checks nothing.
pub(super) fn untrust(context: &Context, args: &Args) -> Outcome {
    let result = Config::new(context).and_then(|config| {
        let dir = project(context, &config, args)?;
        if !context.pretend {
            config.untrust(
                &dir,
                &[
                    trusted_script::SETUP_SCRIPT,
                    trusted_script::TEARDOWN_SCRIPT,
                    trusted_script::DEV_CONTAINER,
                ],
            )?;
        }
        Ok(dir)
    });
    match result {
        Ok(dir) if context.json => Outcome::Success(super::envelope::success(
            "untrust",
            &UntrustPayload { project: &dir },
        )),
        Ok(_) => Outcome::Printed("Forgot the approval of this project's scripts.\n".to_string()),
        Err(error) => Outcome::Failed(error),
    }
}

/// Which of the project's scripts it has none of.
fn absent(scripts: &[Script]) -> Vec<String> {
    [
        trusted_script::SETUP_SCRIPT,
        trusted_script::TEARDOWN_SCRIPT,
    ]
    .into_iter()
    .filter(|name| !scripts.iter().any(|sc| sc.name == *name))
    .map(|name| format!("No scripts/{name}."))
    .collect()
}

/// Human output's colours, as Go's `ui` helpers (fatih/color) write them, when stdout takes them.
#[derive(Clone, Copy)]
struct Paint(bool);

impl Paint {
    fn code(self, code: &str, text: &str) -> String {
        if self.0 {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    fn green(self, text: &str) -> String {
        self.code("32", text)
    }

    fn red(self, text: &str) -> String {
        self.code("31", text)
    }

    fn yellow(self, text: &str) -> String {
        self.code("33", text)
    }

    fn dim(self, text: &str) -> String {
        self.code("90", text)
    }

    fn bold_blue(self, text: &str) -> String {
        self.code("1", &self.code("34", text))
    }
}

/// The width of a panel's top and bottom rules, as Go's `ui.LogPanel` draws them.
const PANEL_WIDTH: usize = 60;

/// Shows `sc`, a script this Mac has not approved, on `out`, in a panel titled with its file, and
/// asks on `input` whether to approve and run it. Go's `approveScript`.
fn approve_script(
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

/// Asks `question` on `out` and reads the answer from `input`: yes for `y` or `yes`, in any case,
/// and no for anything else, an empty answer included. Input that ends before an answer is the
/// person giving up, which ends the command, as Go's prompt (charmbracelet/huh) reports Ctrl-C.
fn confirm(
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

/// Whether `ch` is in Unicode's Cf (format) category, as Go's `unicode.Cf` table (Unicode 15)
/// has it: invisible characters that change how text around them is shown.
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
             Mac.\x1b[0m\n\x1b[90m╭─\x1b[0m\x1b[1m\x1b[34m scripts/workroom_setup \x1b[0m\x1b[0m"
            ),
            "{out:?}"
        );
        assert!(out.contains("\x1b[90m│\x1b[0m x\n"), "{out:?}");
    }
}
