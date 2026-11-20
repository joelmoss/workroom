//! The hidden `workroom __complete <args…> <word>` (and `__completeNoDesc`): what every
//! completion script asks on each Tab, the scripts `completion` writes and any a user saved from
//! the Go CLI alike. It answers as cobra (v1.10.2) answers, byte for byte, so a saved script keeps
//! working: one candidate per line (`name<TAB>description`, or `name` alone for `NoDesc`), then a
//! `:<directive>` line on stdout, and `Completion ended with directive: <name>` on stderr.
//!
//! The candidates come from [`COMMANDS`], the table `--help` uses: the commands and subcommands
//! (hidden ones left out, aliases not offered but understood), and their flags (hidden ones left
//! out, required ones first). The Go CLI defines no completions of its own, so there is nothing
//! else; `help` offers command names, and `completion`'s shells offer nothing, not even files.
//!
//! How cobra finds the command a line names, and how pflag reads its flags, is ported here as
//! cobra does it, quirks included, since a script relies on the answers rather than the reasons.

use std::io::Write;

use super::{COMMANDS, Command, Context, Flag, Operands, Output, PERSISTENT_FLAGS, find_in};

/// cobra's `ShellCompDirective` bits this CLI's answers use, by the names its stderr line gives.
const DIRECTIVES: &[(u32, &str)] = &[
    (1, "ShellCompDirectiveError"),
    (2, "ShellCompDirectiveNoSpace"),
    (4, "ShellCompDirectiveNoFileComp"),
    (8, "ShellCompDirectiveFilterFileExt"),
    (16, "ShellCompDirectiveFilterDirs"),
    (32, "ShellCompDirectiveKeepOrder"),
];

/// No file names: what a list of subcommands or flags, `help`, and `completion` answer.
const NO_FILE_COMP: u32 = 4;

/// Answers `__complete` for `line`, the command line after the program with `__complete` taken
/// out: its last word is the one being completed. `no_descriptions` is `__completeNoDesc`.
pub(super) fn run(line: &[String], no_descriptions: bool, context: &Context) -> Output {
    let Some((word, before)) = line.split_last() else {
        return Output {
            stdout: String::new(),
            stderr: "Error: requires at least 1 arg(s), only received 0\n".to_string(),
            code: 1,
        };
    };
    let answer = complete(before, word);
    let no_descriptions = no_descriptions || descriptions_off(context);
    let mut stdout = String::new();
    for candidate in &answer.candidates {
        let candidate = match no_descriptions {
            true => candidate.split('\t').next().unwrap_or_default(),
            false => candidate,
        };
        // Only a description's first line, so a newline in one can't read as another candidate.
        stdout += candidate.split('\n').next().unwrap_or_default().trim();
        stdout.push('\n');
    }
    stdout += &format!(":{}\n", answer.directive);
    let mut stderr = String::new();
    if let Some(error) = answer.error {
        let message = format!("[Debug] [Error] {error}\n");
        // cobra logs it to the file the scripts log to as well.
        if let Some(path) = context
            .env("BASH_COMP_DEBUG_FILE")
            .filter(|path| !path.is_empty())
        {
            let file = std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(path);
            if let Ok(mut file) = file {
                let _ = file.write_all(message.as_bytes());
            }
        }
        stderr += &message;
    }
    stderr += &format!(
        "Completion ended with directive: {}\n",
        directive_names(answer.directive)
    );
    Output {
        stdout,
        stderr,
        code: 0,
    }
}

/// Whether `WORKROOM_COMPLETION_DESCRIPTIONS` (else `COBRA_COMPLETION_DESCRIPTIONS`) turns
/// descriptions off: a value Go reads as false.
fn descriptions_off(context: &Context) -> bool {
    let value = context
        .env("WORKROOM_COMPLETION_DESCRIPTIONS")
        .filter(|value| !value.is_empty())
        .or_else(|| context.env("COBRA_COMPLETION_DESCRIPTIONS"))
        .unwrap_or_default();
    super::parse_bool(&value) == Some(false)
}

/// `directive` as cobra names it.
fn directive_names(directive: u32) -> String {
    let names: Vec<&str> = DIRECTIVES
        .iter()
        .filter(|(bit, _)| directive & bit != 0)
        .map(|(_, name)| *name)
        .collect();
    match names.is_empty() {
        true => "ShellCompDirectiveDefault".to_string(),
        false => names.join(", "),
    }
}

/// What `__complete` answers.
struct Answer {
    candidates: Vec<String>,
    directive: u32,
    /// What went wrong, for stderr; the candidates and directive are still printed.
    error: Option<String>,
}

impl Answer {
    fn error(error: String) -> Answer {
        Answer {
            candidates: Vec::new(),
            directive: 0,
            error: Some(error),
        }
    }
}

/// A command, or the root (`None`), which has no `Command` of its own.
type Node = Option<&'static Command>;

fn children(node: Node) -> &'static [Command] {
    node.map_or(COMMANDS, |command| command.subcommands)
}

/// cobra's `getCompletions`: the candidates for `word` after the words `before`.
fn complete(before: &[String], word: &str) -> Answer {
    let Some((node, args)) = find(before) else {
        return Answer::error(format!(
            "unable to find a command for arguments: {}",
            go_list(before)
        ));
    };
    let flags = flag_set(node);
    let name = node.map_or("workroom", |command| command.name);
    let target = flag_target(&flags, name, args, word);
    let args = target.args;
    let word = target.word.as_str();
    let parsed = match parse(&args, &flags) {
        Ok(parsed) => parsed,
        Err(error) => {
            return Answer::error(format!(
                "Error while parsing flags from args {}: {error}",
                go_list(&args)
            ));
        }
    };
    // After `--` every word is an argument, so no flag is completed.
    let dashed = parse(&[&args[..], &["--".to_string()]].concat(), &flags)
        .is_ok_and(|with_dash| with_dash.positional.len() > parsed.positional.len());
    let flag_completion = !dashed;
    if let Some(error) = target.error.filter(|_| flag_completion) {
        return Answer::error(error);
    }
    if parsed.is_changed("help") {
        return Answer {
            candidates: Vec::new(),
            directive: NO_FILE_COMP,
            error: None,
        };
    }
    let flag = target.flag;

    // A flag's name.
    if flag.is_none() && word.starts_with('-') && !word.contains('=') && flag_completion {
        let mut candidates = required(&flags, &parsed, word);
        if candidates.is_empty() {
            for flag in flags.iter().filter(|flag| !parsed.is_changed(flag.name)) {
                candidates.extend(name_candidates(flag, word));
            }
        }
        return Answer {
            candidates,
            directive: NO_FILE_COMP,
            error: None,
        };
    }

    let mut candidates = Vec::new();
    let mut directive = 0;
    if flag.is_none() {
        // Subcommands, unless an argument or one of the command's own flags came first.
        let own_flag_set = flags
            .iter()
            .any(|flag| !flag.persistent && parsed.is_changed(flag.name));
        if parsed.positional.is_empty() && !own_flag_set {
            let mut subcommands: Vec<&Command> =
                children(node).iter().filter(|sub| !sub.hidden).collect();
            subcommands.sort_by_key(|sub| sub.name);
            for sub in subcommands {
                if sub.name.starts_with(word) {
                    candidates.push(format!("{}\t{}", sub.name, sub.short));
                }
                directive = NO_FILE_COMP;
            }
        }
        candidates.extend(required(&flags, &parsed, word));
    }
    // A flag's value has nothing to offer; a command's arguments may.
    if flag.is_none() || !flag_completion {
        match node.map_or(Operands::Files, |command| command.operands) {
            Operands::Files => {}
            Operands::Nothing => directive = NO_FILE_COMP,
            Operands::Commands => {
                candidates.extend(help_topics(&parsed.positional, word));
                directive = NO_FILE_COMP;
            }
        }
    }
    Answer {
        candidates,
        directive,
        error: None,
    }
}

/// What `help <args…> <word>` offers: the subcommands of the command `args` name.
fn help_topics(args: &[String], word: &str) -> Vec<String> {
    let Some((node, _)) = find(args) else {
        return Vec::new();
    };
    let mut subcommands: Vec<&Command> = children(node).iter().filter(|sub| !sub.hidden).collect();
    subcommands.sort_by_key(|sub| sub.name);
    subcommands
        .into_iter()
        .filter(|sub| sub.name.starts_with(word))
        .map(|sub| format!("{}\t{}", sub.name, sub.short))
        .collect()
}

/// `args` as Go's `%v` prints a list of strings.
fn go_list(args: &[String]) -> String {
    format!("[{}]", args.join(" "))
}

/// cobra's `Find`: the command `args` name from the root, and the arguments left once its name
/// and its parents' are taken out. None when the root is left with an argument it doesn't know as
/// a command.
fn find(args: &[String]) -> Option<(Node, Vec<String>)> {
    let (node, rest) = walk(None, args.to_vec());
    match node.is_none() && !strip_flags(&rest, None).is_empty() {
        true => None,
        false => Some((node, rest)),
    }
}

/// The subcommand of `command` that `args` (the arguments after its name) name, as cobra finds it,
/// else `command` itself, and the arguments left once the subcommand's name is taken out.
pub(super) fn descend(
    command: &'static Command,
    args: Vec<String>,
) -> (&'static Command, Vec<String>) {
    let (node, rest) = walk(Some(command), args);
    (node.unwrap_or(command), rest)
}

/// From `node`, each word that names a subcommand, skipping flags and what they take.
fn walk(mut node: Node, mut args: Vec<String>) -> (Node, Vec<String>) {
    loop {
        let words = strip_flags(&args, node);
        let Some(next) = words.first() else {
            return (node, args);
        };
        let Some(child) = find_in(children(node), next) else {
            return (node, args);
        };
        args = without_first(&args, next, node);
        node = Some(child);
    }
}

/// The flags cobra knows while it looks for a command at `node`: the root's, and the command's
/// own. Not `--help`, which it adds only once it has found the command.
fn lookup_flags(node: Node) -> impl Iterator<Item = &'static Flag> {
    PERSISTENT_FLAGS
        .iter()
        .chain(node.map_or(&[][..], |command| command.flags))
}

/// Whether the word `arg` is a flag that takes the next word as its value, as cobra judges it
/// while it looks for a command: a long flag without `=` or a lone shorthand, unless it is a
/// boolean it knows. An unknown flag takes a value, so `-h list` names no command.
fn takes_next(arg: &str, node: Node) -> bool {
    if arg.contains('=') {
        return false;
    }
    if let Some(name) = arg.strip_prefix("--") {
        return !lookup_flags(node).any(|flag| flag.name == name && !flag.takes_value);
    }
    match arg.strip_prefix('-') {
        Some(short) if arg.len() == 2 => {
            let short = short.chars().next();
            !lookup_flags(node).any(|flag| flag.short == short && !flag.takes_value)
        }
        _ => false,
    }
}

/// cobra's `stripFlags`: the words of `args` that aren't flags or their values, up to `--`.
fn strip_flags(args: &[String], node: Node) -> Vec<String> {
    let mut words = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        if arg == "--" {
            break;
        }
        if takes_next(arg, node) {
            rest.next();
        } else if !arg.is_empty() && !arg.starts_with('-') {
            words.push(arg.clone());
        }
    }
    words
}

/// cobra's `argsMinusFirstX`: `args` without the first word `name` that isn't a flag's value.
fn without_first(args: &[String], name: &str, node: Node) -> Vec<String> {
    let mut at = 0;
    while at < args.len() {
        let arg = &args[at];
        if arg == "--" {
            break;
        }
        if takes_next(arg, node) {
            at += 2;
            continue;
        }
        if arg == name {
            return [&args[..at], &args[at + 1..]].concat();
        }
        at += 1;
    }
    args.to_vec()
}

/// One flag a found command takes, as completion sees it.
struct Known {
    name: &'static str,
    shorthand: Option<char>,
    takes_value: bool,
    usage: String,
    hidden: bool,
    required: bool,
    /// One of the root's, which every command takes.
    persistent: bool,
}

impl Known {
    fn new(flag: &Flag, persistent: bool) -> Known {
        Known {
            name: flag.name,
            shorthand: flag.short,
            takes_value: flag.takes_value,
            usage: flag.usage.to_string(),
            hidden: flag.hidden,
            required: flag.required,
            persistent,
        }
    }
}

/// The flags of `node` in the order cobra offers them: the inherited (the root's, for a command),
/// then its own with `--help` among them, each sorted by name. At the root every flag is its own.
fn flag_set(node: Node) -> Vec<Known> {
    let name = node.map_or("workroom", |command| command.name);
    let mut inherited = Vec::new();
    let mut own: Vec<Known> = Vec::new();
    match node {
        Some(command) => {
            inherited.extend(PERSISTENT_FLAGS.iter().map(|flag| Known::new(flag, true)));
            own.extend(command.flags.iter().map(|flag| Known::new(flag, false)));
        }
        None => own.extend(PERSISTENT_FLAGS.iter().map(|flag| Known::new(flag, true))),
    }
    own.push(Known {
        usage: format!("help for {name}"),
        ..Known::new(&super::HELP_FLAG, false)
    });
    inherited.sort_by_key(|flag| flag.name);
    own.sort_by_key(|flag| flag.name);
    inherited.extend(own);
    inherited
}

/// Which flag's value `word` is, if it is one: `--flag=<word>`, or the word after a flag that
/// takes a value. cobra's `checkIfFlagCompletion`.
struct Target<'a> {
    flag: Option<&'a Known>,
    /// The arguments, without that flag when it came before `word`.
    args: Vec<String>,
    /// `word`, or what follows its `=`.
    word: String,
    /// A flag `word` names that the command doesn't take.
    error: Option<String>,
}

fn flag_target<'a>(flags: &'a [Known], command: &str, args: Vec<String>, word: &str) -> Target<'a> {
    let unchanged = |args: Vec<String>| Target {
        flag: None,
        args,
        word: word.to_string(),
        error: None,
    };
    // `--long` names `long`; `-abc` names its last shorthand, `c`.
    let flag_name = |flag: &str| match flag.strip_prefix("--") {
        Some(long) => long.to_string(),
        None => flag.chars().last().map(String::from).unwrap_or_default(),
    };
    let mut name = String::new();
    let mut value = word;
    let mut trimmed = None;
    let with_equals = word.starts_with('-') && word.contains('=');
    if word.starts_with('-') {
        let Some((flag, after)) = word.split_once('=') else {
            return unchanged(args);
        };
        name = flag_name(flag);
        value = after;
    }
    let previous = args
        .last()
        .filter(|arg| is_flag_arg(arg) && !arg.contains('='));
    if let Some(previous) = previous.filter(|_| name.is_empty()) {
        name = flag_name(previous);
        trimmed = Some(args[..args.len() - 1].to_vec());
    }
    if name.is_empty() {
        return Target {
            word: value.to_string(),
            ..unchanged(args)
        };
    }
    let flag = match name.chars().count() {
        1 => flags
            .iter()
            .find(|flag| flag.shorthand == name.chars().next()),
        _ => flags.iter().find(|flag| flag.name == name),
    };
    let Some(flag) = flag else {
        return Target {
            error: Some(format!(
                "Subcommand '{command}' does not support flag '{name}'"
            )),
            ..unchanged(args)
        };
    };
    // A boolean after which `word` is an argument, not its value.
    if !with_equals && !flag.takes_value {
        return unchanged(args);
    }
    Target {
        flag: Some(flag),
        args: trimmed.unwrap_or(args),
        word: value.to_string(),
        error: None,
    }
}

/// cobra's `isFlagArg`: `--x` or `-x`, not `--` or `-`.
fn is_flag_arg(arg: &str) -> bool {
    let bytes = arg.as_bytes();
    (bytes.len() >= 3 && arg.starts_with("--"))
        || (bytes.len() >= 2 && bytes[0] == b'-' && bytes[1] != b'-')
}

/// The flags `--name` or `-n` for `flag` that start with `word`, unless it is hidden.
fn name_candidates(flag: &Known, word: &str) -> Vec<String> {
    if flag.hidden {
        return Vec::new();
    }
    let long = format!("--{}", flag.name);
    let short = flag.shorthand.map(|short| format!("-{short}"));
    std::iter::once(long)
        .chain(short)
        .filter(|name| name.starts_with(word))
        .map(|name| format!("{name}\t{}", flag.usage))
        .collect()
}

/// The required flags not yet given that start with `word`.
fn required(flags: &[Known], parsed: &Parsed, word: &str) -> Vec<String> {
    flags
        .iter()
        .filter(|flag| flag.required && !parsed.is_changed(flag.name))
        .flat_map(|flag| name_candidates(flag, word))
        .collect()
}

/// What pflag makes of a command's arguments.
#[derive(Default)]
struct Parsed {
    /// The flags given, by name.
    changed: Vec<&'static str>,
    positional: Vec<String>,
}

impl Parsed {
    fn is_changed(&self, name: &str) -> bool {
        self.changed.contains(&name)
    }
}

/// pflag's `Parse`, with its errors word for word: flags anywhere among the arguments, up to `--`.
fn parse(args: &[String], flags: &[Known]) -> Result<Parsed, String> {
    let mut parsed = Parsed::default();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        if arg.len() < 2 || !arg.starts_with('-') {
            parsed.positional.push(arg.clone());
        } else if arg == "--" {
            parsed.positional.extend(rest.by_ref().cloned());
        } else if let Some(long) = arg.strip_prefix("--") {
            if long.starts_with('-') || long.starts_with('=') {
                return Err(format!("bad flag syntax: {arg}"));
            }
            let (name, value) = match long.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (long, None),
            };
            let Some(flag) = flags.iter().find(|flag| flag.name == name) else {
                return Err(format!("unknown flag: --{name}"));
            };
            let value = match value {
                Some(value) => value.to_string(),
                None if !flag.takes_value => "true".to_string(),
                None => rest
                    .next()
                    .cloned()
                    .ok_or_else(|| format!("flag needs an argument: --{name}"))?,
            };
            set(flag, &value)?;
            parsed.changed.push(flag.name);
        } else {
            let mut shorthands = &arg[1..];
            while let Some(short) = shorthands.chars().next() {
                let Some(flag) = flags.iter().find(|flag| flag.shorthand == Some(short)) else {
                    return Err(format!(
                        "unknown shorthand flag: {short:?} in -{shorthands}"
                    ));
                };
                let after = &shorthands[short.len_utf8()..];
                let value;
                if after.len() > 1 && after.starts_with('=') {
                    value = after[1..].to_string();
                    shorthands = "";
                } else if !flag.takes_value {
                    value = "true".to_string();
                    shorthands = after;
                } else if !after.is_empty() {
                    value = after.to_string();
                    shorthands = "";
                } else if let Some(next) = rest.next() {
                    value = next.clone();
                    shorthands = "";
                } else {
                    return Err(format!(
                        "flag needs an argument: {short:?} in -{shorthands}"
                    ));
                }
                set(flag, &value)?;
                parsed.changed.push(flag.name);
            }
        }
    }
    Ok(parsed)
}

/// Sets `flag` to `value`: a boolean takes only what Go's `strconv.ParseBool` reads.
fn set(flag: &Known, value: &str) -> Result<(), String> {
    if flag.takes_value || super::parse_bool(value).is_some() {
        return Ok(());
    }
    let name = match flag.shorthand {
        Some(short) => format!("-{short}, --{}", flag.name),
        None => format!("--{}", flag.name),
    };
    Err(format!(
        "invalid argument {value:?} for {name:?} flag: must be true or false"
    ))
}
