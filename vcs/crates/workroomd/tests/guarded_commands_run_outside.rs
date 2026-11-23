//! Every test that runs a command only a person may run (`trust`, `delete`, `delete-project`, #793)
//! starts it outside its own process tree, through `tests/outside`. Under a coding agent those
//! commands refuse with NeedsTheUser before they do anything, so a test that starts one with
//! `Command::output` passes in CI and fails for an agent running the suite. This reads every file
//! under `tests/` and names each such start, with the fix.
//!
//! The guarded commands are read from the one list that guards them, `GUARDED` in
//! `src/commands/needs_the_user.rs`, which is private to the binary, so its source is read here.
//!
//! What counts as running a guarded command: its name as a string literal in a command's place, the
//! first word of an array (`&["delete", "calm-river"]`, `.args(["trust"])`) or a `.arg("trust")`.
//! A name anywhere else (an assertion, a message, the middle of a list, a comment) is not one, nor
//! is a subcommand no one guards (`["trust", "status"]`, from `trust --help`).
//! Where it goes is read from the code around it:
//!
//! - into `.arg`/`.args`, or a list a statement binds (`let args = [...]`, `for args in [...]`):
//!   the function it is in must start the binary through `outside::spawn`, itself or through a
//!   helper of the file's that does;
//! - into a call of a function the file (or the `common` module it uses) defines: that function
//!   must, when it starts a process at all;
//! - into a macro (`assert_eq!`, `format!`): nowhere;
//! - into a `const` or `static` table: each function that names the table and starts a process.
//!
//! A function starts a process when it calls `.output()`, `.status()` or `.spawn()`, or a helper
//! that does. A file is read as Rust tokens, so comments and the text of strings never count.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The binary under test, by `WORKROOMD_BIN` where the test runs on another machine than it was
/// built on (`test-linux.sh`), as `common::daemon_binary` finds it.
fn binary() -> PathBuf {
    match std::env::var_os("WORKROOMD_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_workroom")),
    }
}

// ---------------------------------------------------------------------------
// Tokens

#[derive(Debug, Clone, PartialEq)]
enum Kind {
    /// An identifier, keyword or number.
    Word(String),
    /// A string literal's text, escapes left as written.
    Str(String),
    /// One punctuation character.
    Punct(char),
}

#[derive(Debug, Clone)]
struct Token {
    kind: Kind,
    line: usize,
}

impl Token {
    fn is(&self, c: char) -> bool {
        self.kind == Kind::Punct(c)
    }

    fn word(&self) -> Option<&str> {
        match &self.kind {
            Kind::Word(word) => Some(word),
            _ => None,
        }
    }
}

/// Rust source as tokens, without its comments: enough of Rust's lexer to tell code from comments,
/// strings (raw and byte ones too), char literals and lifetimes.
fn tokens(source: &str) -> Vec<Token> {
    let chars: Vec<char> = source.chars().collect();
    let mut out = Vec::new();
    let mut line = 1;
    let mut i = 0;
    let at = |i: usize| chars.get(i).copied().unwrap_or('\0');
    while i < chars.len() {
        let c = chars[i];
        if c == '\n' {
            line += 1;
            i += 1;
        } else if c.is_whitespace() {
            i += 1;
        } else if c == '/' && at(i + 1) == '/' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
        } else if c == '/' && at(i + 1) == '*' {
            // Block comments nest.
            let mut depth = 0;
            loop {
                if i >= chars.len() {
                    break;
                }
                if chars[i] == '/' && at(i + 1) == '*' {
                    depth += 1;
                    i += 2;
                } else if chars[i] == '*' && at(i + 1) == '/' {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    if chars[i] == '\n' {
                        line += 1;
                    }
                    i += 1;
                }
            }
        } else if let Some((text, next, lines)) = string_at(&chars, i) {
            out.push(Token {
                kind: Kind::Str(text),
                line,
            });
            line += lines;
            i = next;
        } else if c == '\'' {
            // A char literal ('a', '\n', '\'') or a lifetime ('a, 'static).
            if at(i + 1) == '\\' {
                // Past the quote, the backslash and the character it escapes ('\'' too).
                i += 3;
                while i < chars.len() && chars[i] != '\'' {
                    i += 1;
                }
                i += 1;
            } else if at(i + 2) == '\'' {
                i += 3;
            } else {
                i += 1;
                while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
                    i += 1;
                }
            }
        } else if c.is_alphanumeric() || c == '_' {
            let start = i;
            // A raw identifier, r#name, is the name.
            if c == 'r' && at(i + 1) == '#' {
                i += 2;
            }
            let word_start = i;
            while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[word_start.max(start)..i].iter().collect();
            out.push(Token {
                kind: Kind::Word(word),
                line,
            });
        } else {
            out.push(Token {
                kind: Kind::Punct(c),
                line,
            });
            i += 1;
        }
    }
    out
}

/// The string literal starting at `i`, if one does: its text, the index after it and the newlines
/// in it. `"…"`, `b"…"`, `c"…"` and the raw `r#"…"#` kinds.
fn string_at(chars: &[char], i: usize) -> Option<(String, usize, usize)> {
    let at = |i: usize| chars.get(i).copied().unwrap_or('\0');
    let mut j = i;
    if (at(j) == 'b' || at(j) == 'c') && (at(j + 1) == '"' || at(j + 1) == 'r') {
        j += 1;
    }
    let raw = at(j) == 'r';
    if raw {
        j += 1;
    }
    let mut hashes = 0;
    while raw && at(j) == '#' {
        hashes += 1;
        j += 1;
    }
    if at(j) != '"' {
        return None;
    }
    // `r` alone, or `b`/`c` alone, is an identifier: only a quote makes these a string.
    if j > i && !raw && at(i + 1) != '"' {
        return None;
    }
    j += 1;
    let start = j;
    let mut lines = 0;
    loop {
        if j >= chars.len() {
            return None;
        }
        let c = chars[j];
        if c == '\n' {
            lines += 1;
        }
        if !raw && c == '\\' {
            // A line continuation escapes the newline itself.
            if at(j + 1) == '\n' {
                lines += 1;
            }
            j += 2;
            continue;
        }
        if c == '"' && (0..hashes).all(|k| at(j + 1 + k) == '#') {
            let text = chars[start..j].iter().collect();
            return Some((text, j + 1 + hashes, lines));
        }
        j += 1;
    }
}

// ---------------------------------------------------------------------------
// Functions

/// A function with a body: its name and the indices of its braces.
struct Function {
    name: String,
    open: usize,
    close: usize,
}

fn functions(tokens: &[Token]) -> Vec<Function> {
    let mut out = Vec::new();
    for i in 0..tokens.len() {
        if tokens[i].word() != Some("fn") {
            continue;
        }
        let Some(name) = tokens.get(i + 1).and_then(Token::word) else {
            continue;
        };
        // The body is the first `{` outside the signature's parentheses; a `;` first means none.
        let mut depth = 0i32;
        let mut open = None;
        for (j, token) in tokens.iter().enumerate().skip(i + 2) {
            match token.kind {
                Kind::Punct('(' | '[') => depth += 1,
                Kind::Punct(')' | ']') => depth -= 1,
                Kind::Punct('{') if depth == 0 => {
                    open = Some(j);
                    break;
                }
                Kind::Punct(';') if depth == 0 => break,
                _ => {}
            }
        }
        let Some(open) = open else { continue };
        if let Some(close) = matching(tokens, open) {
            out.push(Function {
                name: name.to_string(),
                open,
                close,
            });
        }
    }
    out
}

/// The index of the bracket closing the one at `open`.
fn matching(tokens: &[Token], open: usize) -> Option<usize> {
    let mut depth = 0i32;
    for (j, token) in tokens.iter().enumerate().skip(open) {
        match token.kind {
            Kind::Punct('(' | '[' | '{') => depth += 1,
            Kind::Punct(')' | ']' | '}') => {
                depth -= 1;
                if depth == 0 {
                    return Some(j);
                }
            }
            _ => {}
        }
    }
    None
}

/// What one function's body does, as far as this check cares.
#[derive(Default, Clone)]
struct Body {
    /// It calls `outside::spawn`.
    outside: bool,
    /// It calls `.output()`, `.status()` or `.spawn()`.
    spawns: bool,
    /// The names it calls.
    calls: BTreeSet<String>,
    /// The names it calls as functions, not methods: how the harness's `spawn` is called.
    free: BTreeSet<String>,
    /// The names it mentions, for the tables it reads.
    words: BTreeSet<String>,
}

fn body(tokens: &[Token], function: &Function) -> Body {
    let mut body = Body::default();
    let inside = &tokens[function.open + 1..function.close];
    for (k, token) in inside.iter().enumerate() {
        let Some(word) = token.word() else { continue };
        body.words.insert(word.to_string());
        let before = |back: usize| k.checked_sub(back).map(|at| &inside[at]);
        let called = inside.get(k + 1).is_some_and(|next| next.is('('));
        if !called {
            continue;
        }
        body.calls.insert(word.to_string());
        let method = before(1).is_some_and(|token| token.is('.'));
        if !method {
            body.free.insert(word.to_string());
        }
        if method && matches!(word, "output" | "status" | "spawn") {
            body.spawns = true;
        }
        let path = before(1).is_some_and(|token| token.is(':'))
            && before(2).is_some_and(|token| token.is(':'))
            && before(3).and_then(Token::word) == Some("outside");
        if word == "spawn" && path {
            body.outside = true;
        }
    }
    body
}

/// The functions a file can call by name, each with whether it starts the binary outside the
/// test's tree (`harnessed`) and whether it starts a process at all (`spawns`), each including the
/// helpers it calls.
#[derive(Default)]
struct Scope {
    harnessed: BTreeMap<String, bool>,
    spawns: BTreeMap<String, bool>,
}

impl Scope {
    /// `bodies` by name; a name two functions share (methods of two types) counts when either does.
    /// `harness` names the functions of `tests/outside`, which a file may call by their own name
    /// (`use outside::spawn`): only as a function, since `.spawn()` is `Command`'s own.
    fn new(bodies: &[(String, Body)], harness: &[String]) -> Scope {
        let mut scope = Scope::default();
        for (name, body) in bodies {
            let outside = body.outside || harness.iter().any(|name| body.free.contains(name));
            *scope.harnessed.entry(name.clone()).or_default() |= outside;
            *scope.spawns.entry(name.clone()).or_default() |= body.spawns || outside;
        }
        // Through helpers, until nothing changes.
        loop {
            let mut changed = false;
            for (name, body) in bodies {
                for callee in &body.calls {
                    if callee == name {
                        continue;
                    }
                    if scope.harnessed.get(callee) == Some(&true) && !scope.harnessed[name] {
                        scope.harnessed.insert(name.clone(), true);
                        changed = true;
                    }
                    if scope.spawns.get(callee) == Some(&true) && !scope.spawns[name] {
                        scope.spawns.insert(name.clone(), true);
                        changed = true;
                    }
                }
            }
            if !changed {
                return scope;
            }
        }
    }

    fn defines(&self, name: &str) -> bool {
        self.harnessed.contains_key(name)
    }

    /// Whether a function by this name starts a process other than through the harness.
    fn bypasses(&self, name: &str) -> bool {
        self.spawns.get(name) == Some(&true) && self.harnessed.get(name) != Some(&true)
    }
}

// ---------------------------------------------------------------------------
// The check

/// A file to check, with the modules it brings in (`mod common;`, `mod outside;`) already read.
struct Source {
    path: String,
    text: String,
}

/// Where a guarded command's name goes, read backwards from it.
enum Into {
    /// `.arg(…)` or `.args(…)`, so a `Command` the function builds.
    Command,
    /// A call of a function of the file's own.
    Helper(String),
    /// A macro's arguments.
    Macro,
    /// A statement: a binding, a loop, a struct field; or, outside any function, a table.
    Statement,
}

fn into(tokens: &[Token], at: usize, scope: &Scope) -> Into {
    let mut depth = 0i32;
    let mut j = at;
    while j > 0 {
        j -= 1;
        match tokens[j].kind {
            Kind::Punct(')' | ']' | '}') => depth += 1,
            Kind::Punct('(' | '[' | '{') if depth > 0 => depth -= 1,
            Kind::Punct('(') => {
                let before = j.checked_sub(1).map(|k| &tokens[k]);
                if before.is_some_and(|token| token.is('!')) {
                    return Into::Macro;
                }
                if let Some(name) = before.and_then(Token::word) {
                    let method = j >= 2 && tokens[j - 2].is('.');
                    if method && matches!(name, "arg" | "args") {
                        return Into::Command;
                    }
                    if scope.defines(name) {
                        return Into::Helper(name.to_string());
                    }
                }
                // Another call (`Some`, `OsStr::new`) or a group: what it is in decides.
            }
            Kind::Punct('{') => return Into::Statement,
            Kind::Punct(';') if depth == 0 => return Into::Statement,
            _ => {}
        }
    }
    Into::Statement
}

/// The name of the `const` or `static` item the token at `at` is in, outside any function: back
/// through the brackets it is in (and any it follows, struct literals' too) to the keyword, unless
/// the previous item ends first.
fn table(tokens: &[Token], at: usize) -> Option<String> {
    let mut depth = 0i32;
    let mut j = at;
    while j > 0 {
        j -= 1;
        match tokens[j].kind {
            Kind::Punct(')' | ']' | '}') => depth += 1,
            Kind::Punct('(' | '[' | '{') if depth > 0 => depth -= 1,
            Kind::Punct(';') if depth == 0 => return None,
            _ => {}
        }
        if depth == 0 && matches!(tokens[j].word(), Some("fn" | "impl" | "mod" | "struct")) {
            return None;
        }
        if depth == 0 && matches!(tokens[j].word(), Some("const" | "static")) {
            let mut k = j + 1;
            if tokens.get(k).and_then(Token::word) == Some("mut") {
                k += 1;
            }
            return tokens.get(k).and_then(Token::word).map(str::to_string);
        }
    }
    None
}

/// What the check found in some sources.
#[derive(Default, Debug)]
struct Report {
    /// One line per guarded command started other than through the harness.
    findings: Vec<String>,
    /// Guarded commands found starting through it, so a scan that reads nothing can't pass.
    harnessed: usize,
}

/// Checks `file` with the functions of `modules` (the `common` and `outside` modules it uses) in
/// scope.
fn check(file: &Source, modules: &[(&Source, bool)], guarded: &[Guarded], report: &mut Report) {
    let toks = tokens(&file.text);
    let own = functions(&toks);
    let mut bodies: Vec<(String, Body)> = own
        .iter()
        .map(|function| (function.name.clone(), body(&toks, function)))
        .collect();
    let mut harness = Vec::new();
    for (module, is_harness) in modules {
        let module_tokens = tokens(&module.text);
        for function in functions(&module_tokens) {
            if *is_harness {
                harness.push(function.name.clone());
            } else {
                bodies.push((function.name.clone(), body(&module_tokens, &function)));
            }
        }
    }
    let scope = Scope::new(&bodies, &harness);
    let own_bodies = &bodies[..own.len()];

    for (i, token) in toks.iter().enumerate() {
        let Kind::Str(text) = &token.kind else {
            continue;
        };
        let Some(command) = guarded.iter().find(|command| &command.name == text) else {
            continue;
        };
        // `trust status` is a subcommand of its own, which no one guards.
        let subcommand = toks.get(i + 1).is_some_and(|token| token.is(','))
            && toks.get(i + 2).is_some_and(|token| {
                matches!(&token.kind, Kind::Str(next) if command.subcommands.contains(next))
            });
        if subcommand {
            continue;
        }
        let first_of_array = i >= 1 && toks[i - 1].is('[');
        let arg = i >= 3
            && toks[i - 1].is('(')
            && toks[i - 2].word() == Some("arg")
            && toks[i - 3].is('.');
        if !first_of_array && !arg {
            continue;
        }
        let enclosing = own
            .iter()
            .enumerate()
            .filter(|(_, function)| function.open < i && i < function.close)
            .min_by_key(|(_, function)| function.close - function.open)
            .map(|(index, function)| (function, &own_bodies[index].1));
        let at = format!("{}:{}", file.path, token.line);
        // The functions that decide, by name: each must not start a process itself.
        let deciders: Vec<String> = match into(&toks, i, &scope) {
            Into::Macro => continue,
            Into::Helper(name) => vec![name],
            Into::Command | Into::Statement => match enclosing {
                Some((function, _)) => vec![function.name.clone()],
                None => match table(&toks, i) {
                    Some(table) => own_bodies
                        .iter()
                        .filter(|(_, body)| body.words.contains(&table))
                        .map(|(name, _)| name.clone())
                        .collect(),
                    None => continue,
                },
            },
        };
        for name in deciders {
            if scope.bypasses(&name) {
                report.findings.push(format!(
                    "{at}: `{text}` is started by `{name}`, which runs the binary itself: start it \
                     with `outside::spawn` (tests/outside), so a coding agent running the tests is \
                     none of its parents (#793)"
                ));
            } else if scope.harnessed.get(&name) == Some(&true) {
                report.harnessed += 1;
            }
        }
    }
}

/// A command only a person may run, and its subcommands, which anyone may.
struct Guarded {
    name: String,
    subcommands: Vec<String>,
}

/// The guarded commands, each with the subcommands its `--help` lists under "Available Commands:".
fn guarded() -> Vec<Guarded> {
    guarded_commands()
        .into_iter()
        .map(|name| {
            let help = help(&name);
            let subcommands = help
                .lines()
                .skip_while(|line| !line.starts_with("Available Commands:"))
                .skip(1)
                .take_while(|line| line.starts_with(' '))
                .filter_map(|line| line.split_whitespace().next().map(str::to_string))
                .collect();
            Guarded { name, subcommands }
        })
        .collect()
}

/// `workroom <command> --help`, which runs under a coding agent as anywhere else.
fn help(command: &str) -> String {
    let output = Command::new(binary())
        .args([command, "--help"])
        .output()
        .expect("run --help");
    assert!(output.status.success(), "`{command} --help`: {output:?}");
    String::from_utf8(output.stdout).expect("UTF-8")
}

/// The commands `GUARDED` in `src/commands/needs_the_user.rs` lists: each `command: "…"` between
/// `const GUARDED` and the `;` that ends it.
fn guarded_commands() -> Vec<String> {
    let path = crate_dir().join("src/commands/needs_the_user.rs");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let toks = tokens(&text);
    let start = toks
        .windows(2)
        .position(|pair| pair[0].word() == Some("const") && pair[1].word() == Some("GUARDED"))
        .unwrap_or_else(|| panic!("no `const GUARDED` in {}", path.display()));
    let mut out = Vec::new();
    for k in start..toks.len() {
        if toks[k].is(';') {
            break;
        }
        if toks[k].word() == Some("command")
            && toks.get(k + 1).is_some_and(|token| token.is(':'))
            && let Some(Kind::Str(name)) = toks.get(k + 2).map(|token| &token.kind)
        {
            out.push(name.clone());
        }
    }
    out
}

/// Every `.rs` file under `dir`, sorted.
fn rust_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|error| panic!("read {}: {error}", dir.display()))
        .map(|entry| entry.expect("a directory entry").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            out.extend(rust_files(&path));
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            out.push(path);
        }
    }
    out
}

/// Whether `text` declares `mod <name>;`.
fn uses_module(text: &str, name: &str) -> bool {
    tokens(text).windows(3).any(|three| {
        three[0].word() == Some("mod") && three[1].word() == Some(name) && three[2].is(';')
    })
}

/// Checks every file under `tests/`, each with the `common` and `outside` modules it uses.
fn check_tests() -> (Report, usize) {
    let tests = crate_dir().join("tests");
    let guarded = guarded();
    let read = |path: &Path| Source {
        path: path
            .strip_prefix(crate_dir())
            .unwrap_or(path)
            .display()
            .to_string(),
        text: std::fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("read {}: {error}", path.display())),
    };
    let common = read(&tests.join("common/mod.rs"));
    let outside = read(&tests.join("outside/mod.rs"));
    let files = rust_files(&tests);
    let mut report = Report::default();
    for path in &files {
        let file = read(path);
        let mut modules = Vec::new();
        if uses_module(&file.text, "common") {
            modules.push((&common, false));
        }
        if uses_module(&file.text, "outside") {
            modules.push((&outside, true));
        }
        check(&file, &modules, &guarded, &mut report);
    }
    (report, files.len())
}

// ---------------------------------------------------------------------------
// Tests

#[test]
fn every_guarded_command_a_test_runs_starts_outside_the_tests_process_tree() {
    let (report, files) = check_tests();
    assert!(
        report.findings.is_empty(),
        "{} guarded command(s) started other than through tests/outside:\n{}",
        report.findings.len(),
        report.findings.join("\n")
    );
    // A scan that read nothing, or recognised no start, would pass forever.
    assert!(files >= 10, "only {files} files under tests/");
    assert!(
        report.harnessed > 0,
        "no guarded command found starting through tests/outside: the scan reads nothing"
    );
}

/// The list read from `GUARDED` is the commands the binary guards: each one's `--help` says only a
/// person may run it, which `needs_the_user::says` adds to exactly those. And `trust status`, the
/// one subcommand of one, is read from `trust --help`.
#[test]
fn the_guarded_commands_are_the_ones_needs_the_user_guards() {
    let guarded = guarded();
    assert!(!guarded.is_empty(), "no command read from GUARDED");
    for command in &guarded {
        let help = help(&command.name);
        assert!(
            help.contains("Only a person may run it"),
            "`{} --help` doesn't say it is guarded:\n{help}",
            command.name
        );
    }
    let trust = guarded.iter().find(|command| command.name == "trust");
    assert_eq!(
        trust.map(|trust| trust.subcommands.clone()),
        Some(vec!["status".to_string()])
    );
}

/// The findings for one file of Rust.
fn findings_in(text: &str) -> Report {
    let guarded = [
        ("trust", &["status"][..]),
        ("delete", &[]),
        ("delete-project", &[]),
    ]
    .map(|(name, subcommands)| Guarded {
        name: name.into(),
        subcommands: subcommands.iter().map(|name| name.to_string()).collect(),
    });
    let source = Source {
        path: "tests/example.rs".into(),
        text: text.into(),
    };
    let outside = Source {
        path: "tests/outside/mod.rs".into(),
        text: "pub fn spawn(command: Command, input: Option<&[u8]>) -> Outside { command.spawn() }"
            .into(),
    };
    let mut report = Report::default();
    let modules = if uses_module(text, "outside") {
        vec![(&outside, true)]
    } else {
        vec![]
    };
    check(&source, &modules, &guarded, &mut report);
    report
}

#[test]
fn a_guarded_command_the_binary_starts_itself_is_found() {
    for (case, text) in [
        (
            "args on the command",
            r#"fn t() { Command::new(binary()).args(["delete", "x"]).output().unwrap(); }"#,
        ),
        (
            "arg on the command",
            r#"fn t() { let mut c = Command::new(binary()); c.arg("trust"); c.status().unwrap(); }"#,
        ),
        (
            "a helper that starts it",
            r#"
            fn run(args: &[&str]) -> Output { Command::new(binary()).args(args).output().unwrap() }
            fn t() { run(&["delete-project", "/x", "--confirm", "/x"]); }"#,
        ),
        (
            "a helper's helper",
            r#"
            fn run(args: &[&str]) -> Output { go(binary(), args) }
            fn go(p: PathBuf, args: &[&str]) -> Output { Command::new(p).args(args).output().unwrap() }
            fn t() { let home = Home::new(); home.run(&["trust"]); }"#,
        ),
        (
            "a bound list",
            r#"fn t() {
                let args = [
                    "delete", "calm-river",
                ];
                Command::new(binary()).args(args).spawn().unwrap();
            }"#,
        ),
        (
            "a table",
            r#"
            const CASES: &[&[&str]] = &[&["list"], &["delete", "--json"]];
            fn t() { for args in CASES { Command::new(binary()).args(*args).output().unwrap(); } }"#,
        ),
        (
            "Command's own spawn, in a file that uses the harness",
            r#"mod outside;
            fn t() { Command::new(binary()).args(["delete"]).spawn().unwrap(); }
            fn u() { let mut c = Command::new(binary()); c.arg("trust"); outside::spawn(c, None); }"#,
        ),
        (
            "after a char literal that is a quote",
            r#"fn t<'a>(x: &'a str) {
                let q = '"'; let e = '\'';
                Command::new(binary()).args(["delete"]).output().unwrap();
            }"#,
        ),
    ] {
        let report = findings_in(text);
        assert_eq!(report.findings.len(), 1, "{case}: {report:?}");
    }
    let report = findings_in(
        r#"fn t() {
            // a comment
            Command::new(binary()).args(["delete"]).output().unwrap();
        }"#,
    );
    assert!(
        report.findings[0].starts_with("tests/example.rs:3: `delete` is started by `t`"),
        "{report:?}"
    );
}

#[test]
fn a_guarded_command_started_through_the_harness_or_named_otherwise_is_not_found() {
    for (case, text) in [
        (
            "through the harness",
            r#"mod outside;
            fn t() {
                let mut c = Command::new(binary());
                c.args(["delete", "x"]);
                outside::spawn(c, None).wait_with_output();
            }"#,
        ),
        (
            "through a helper that uses the harness",
            r#"mod outside;
            fn run(args: &[&str]) -> Run { run_program(&binary(), args) }
            fn run_program(p: &Path, args: &[&str]) -> Run {
                let mut c = Command::new(p);
                c.args(args);
                Run::from(args, outside::spawn(c, None).wait_with_output())
            }
            fn t() { let args = ["trust"]; home.run(&args); home.run(&["delete", "x"]); }"#,
        ),
        (
            "the harness's spawn by its own name",
            r#"mod outside;
            use outside::spawn;
            fn t() { let mut c = Command::new(binary()); c.arg("trust"); spawn(c, None); }"#,
        ),
        (
            "in assertions and messages",
            r#"fn t() {
                let out = Command::new("git").arg("status").output().unwrap();
                assert_eq!(args, ["delete", "x"]);
                assert!(text.contains("delete"), "{}", format!("{:?}", ["trust"]));
            }"#,
        ),
        (
            "not a command's first word",
            r#"fn t() {
                for name in ["base", "create", "delete", "trust"] {
                    Command::new(binary()).arg("--help").output().unwrap();
                }
                Command::new(binary()).args(["list", "delete"]).output().unwrap();
            }"#,
        ),
        (
            "a subcommand no one guards",
            r#"fn t() { Command::new(binary()).args(["trust", "status", "--json"]).output(); }"#,
        ),
        (
            "a char literal and a lifetime before code",
            r#"fn t<'a>(x: &'a str) {
                let q = '\''; let b = '"';
                let mut c = Command::new(binary()); c.arg("trust"); outside::spawn(c, None);
            }"#,
        ),
        (
            "in comments and strings",
            r##"fn t() {
                // Command::new(binary()).args(["delete"]).output()
                /* Command::new(binary()).args(["trust"]).output() /* nested */ */
                let s = "[\"delete\"]";
                let r = r#"["delete"]"#;
                Command::new(binary()).arg("list").output().unwrap();
            }"##,
        ),
        (
            "to a function that starts nothing",
            r#"fn parse(args: &[&str]) -> Vec<String> { args.iter().map(|a| a.to_string()).collect() }
            fn t() { let parsed = parse(&["delete", "x"]); workroom::cli(&["trust"]); }"#,
        ),
    ] {
        let report = findings_in(text);
        assert!(report.findings.is_empty(), "{case}: {report:?}");
    }
}
