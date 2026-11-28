//! The docs site's CLI reference, `docs-site/pages/cli`: one page per public command and
//! subcommand, named after its command path (`workroom base set` is `workroom-base-set.md`), the
//! CLI's own page (`workroom.md`) and `help agents`', all from the commands table that `--help` and
//! shell completion read (#682). `nav.yml` lists each in its CLI group.
//!
//! `make docs-cli` rewrites them (`WORKROOM_DOCS_UPDATE=1`); without it, the test fails when they
//! are stale, so the reference can't drift from the commands. Every page carries [`HEADER`] under
//! its front matter, and the test removes only pages that do: a page without it is someone's own
//! file, which the test reports and leaves alone.
//!
//! It writes three Reference pages too ([`reference`]): the terminal API's (`terminal_api`), from
//! the methods and schemas `api.describe` serves; the internal APIs the app uses (`internal`), from
//! the daemon's services, frames and subcommands and the hidden commands; and the error kinds in
//! `json-output.md` (`kinds`), a marked region of a page otherwise written by hand.

mod internal;
mod kinds;
mod source;
mod terminal_api;

use std::collections::BTreeMap;
use std::path::PathBuf;

use super::agents::GUIDED;
use super::{ABOUT, COMMANDS, Command, Flag, global_flags, honours_pretend};

/// The line under a page's front matter that makes it this generator's.
const HEADER: &str = "<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->";

/// The CLI's one-line description, its page's and every link to it.
const SHORT: &str = "Manage development workrooms";

fn pages_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../docs-site/pages/cli")
}

/// Whether the top-level command `name` is one of the terminal API's, the commands `help agents`
/// guides: its pages link to `help agents` and the API's reference.
fn guided(name: &str) -> bool {
    GUIDED.iter().any(|guided| guided.command == name)
}

/// What `help agents` says of the top-level command `name`, for its page.
fn says(name: &str) -> Option<&'static str> {
    GUIDED
        .iter()
        .find(|guided| guided.command == name)
        .map(|guided| guided.says)
}

/// The commands a page lists: public ones only, as `--help` shows them. `help` has no page of its
/// own; its one topic, `agents`, does.
fn public(commands: &'static [Command]) -> impl Iterator<Item = &'static Command> {
    commands
        .iter()
        .filter(|command| !command.hidden && command.name != "help")
}

/// Every page, by file name.
fn pages() -> BTreeMap<String, String> {
    let mut pages = BTreeMap::new();
    pages.insert("workroom.md".to_string(), root());
    for command in public(COMMANDS) {
        add(&mut pages, command, &[]);
    }
    pages.insert(file_name("help agents"), help_agents());
    pages
}

/// `command`'s page, under `parents` (outermost first), and its subcommands'.
fn add(pages: &mut BTreeMap<String, String>, command: &Command, parents: &[&Command]) {
    pages.insert(
        file_name(&command_path(parents, command)),
        page(command, parents),
    );
    let mut path = parents.to_vec();
    path.push(command);
    for sub in public(command.subcommands) {
        add(pages, sub, &path);
    }
}

/// `base set` for `set` under `base`: the words after `workroom`.
fn command_path(parents: &[&Command], command: &Command) -> String {
    parents
        .iter()
        .chain(std::iter::once(&command))
        .map(|command| command.name)
        .collect::<Vec<_>>()
        .join(" ")
}

fn file_name(path: &str) -> String {
    format!("workroom-{}.md", path.replace(' ', "-"))
}

fn front_matter(title: &str, description: &str) -> String {
    // Quoted, as JSON quotes it, which YAML reads the same: a description can hold ": ".
    let description = serde_json::to_string(description).expect("a string is JSON");
    format!("---\ntitle: {title}\ndescription: {description}\n---\n\n{HEADER}\n\n")
}

/// A link to another page, in a "See also" list.
fn see(title: &str, file: &str, short: &str) -> String {
    format!("* [{title}]({file})\t - {short}\n")
}

/// The CLI's own page: what `workroom --help` says, its flags, and a link to every command.
fn root() -> String {
    let mut text = front_matter("workroom", &format!("{SHORT}."));
    text += "## Synopsis\n\n";
    text += &escaped(ABOUT);
    text += "\n\n```text\nworkroom [command]\n```\n\n## Options\n\n```text\n";
    text += &table(std::iter::once(help_row("workroom")).chain(global_flags(true).map(row)));
    text += "```\n\n## See also\n\n";
    let mut commands: Vec<&Command> = public(COMMANDS).collect();
    commands.sort_by_key(|command| command.name);
    for command in commands {
        text += &see(
            &format!("workroom {}", command.name),
            &file_name(command.name),
            command.short,
        );
    }
    text += &see(
        "workroom help agents",
        "workroom-help-agents.md",
        "The terminal API, for coding agents",
    );
    text
}

/// A command's page: its synopsis and usage, its own options, the global ones it takes, what
/// `help agents` says of it, and links to its parent, its subcommands and `help agents`.
fn page(command: &Command, parents: &[&Command]) -> String {
    let top = parents.first().copied().unwrap_or(command);
    let path = format!("workroom {}", command_path(parents, command));
    let mut text = front_matter(&path, &format!("{}.", command.short.trim_end_matches('.')));
    // A synopsis only when `--help` says more than the description does, as cobra wrote these
    // pages: a heading new to a stable command's page would need a Nightly marker.
    if let Some(long) = command.long {
        text += "## Synopsis\n\n";
        text += &escaped(long);
        text += "\n\n";
    }
    if command.mac_only {
        text += "Runs on a Mac only, and fails with `MacOnly` elsewhere.\n\n";
    }
    if parents.is_empty()
        && let Some(says) = super::needs_the_user::says(command.name)
    {
        text += &format!("{}\n\n", escaped(&says));
    }
    text += &format!("```text\nworkroom {}\n```\n\n", command.usage);
    text += "## Options\n\n```text\n";
    text += &table(
        std::iter::once(help_row(command.name))
            .chain(command.flags.iter().filter(|flag| !flag.hidden).map(row)),
    );
    text += "```\n\n## Options inherited from parent commands\n\n```text\n";
    text += &table(global_flags(honours_pretend(top.name)).map(row));
    text += "```\n\n";
    if parents.is_empty()
        && let Some(says) = says(command.name)
    {
        text += "## How to use it\n\n";
        text += &escaped(says);
        text += "\n\n";
    }
    text += "## See also\n\n";
    match parents.split_last() {
        Some((parent, above)) => {
            let parent_path = command_path(above, parent);
            text += &see(
                &format!("workroom {parent_path}"),
                &file_name(&parent_path),
                parent.short,
            );
        }
        None => text += &see("workroom", "workroom.md", SHORT),
    }
    let mut own = parents.to_vec();
    own.push(command);
    for sub in public(command.subcommands) {
        let sub_path = command_path(&own, sub);
        text += &see(
            &format!("workroom {sub_path}"),
            &file_name(&sub_path),
            sub.short,
        );
    }
    if guided(top.name) {
        text += &see(
            "workroom help agents",
            "workroom-help-agents.md",
            "The terminal API, for coding agents",
        );
        text += &see_reference();
    }
    text
}

/// The link from a terminal API page to the API's reference.
fn see_reference() -> String {
    see(
        "Terminal API reference",
        "../reference/terminal-api.md",
        "Every method, event and error of the terminal API",
    )
}

/// `help agents` as a page: its text below its own title, which the front matter carries.
fn help_agents() -> String {
    let text = super::agents::text();
    let body = text
        .split_once('\n')
        .map_or(text.as_str(), |(_, rest)| rest)
        .trim_start();
    let mut page = front_matter(
        "workroom help agents",
        "How a coding agent drives Workroom's terminals with the terminal API's commands, as \
         `workroom help agents` and the Workroom skill explain it.",
    );
    page += "## Synopsis\n\nWhat `workroom help agents` prints, and the Workroom skill for Claude \
             Code and Codex holds.\n\n```text\nworkroom help agents\n```\n\n";
    page += &escaped_markdown(body);
    page += "\n## See also\n\n";
    page += &see("workroom", "workroom.md", SHORT);
    page += &see_reference();
    page
}

/// The Reference pages this generator writes, by path under `docs-site/pages`: whole pages, which
/// carry [`HEADER`], and `json-output.md`, whose error kinds are a marked region (`kinds`) of a page
/// written by hand, read from `current` (the page on disk).
fn reference(current: &dyn Fn(&str) -> Option<String>) -> BTreeMap<&'static str, String> {
    let mut pages = BTreeMap::new();
    pages.insert(terminal_api::PAGE, terminal_api::page());
    pages.insert(internal::PAGE, internal::page());
    let json_output = current(kinds::PAGE)
        .unwrap_or_else(|| panic!("docs-site/pages/{} is missing", kinds::PAGE));
    // Refused before anything is written: the caller writes only once every page is made.
    let json_output = kinds::spliced(&json_output).unwrap_or_else(|why| panic!("{why}"));
    pages.insert(kinds::PAGE, json_output);
    pages
}

fn site_pages_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../docs-site/pages")
}

/// A table cell's text: Markdown escaped as [`escaped`] does, with `|` escaped so it can't end the
/// cell, a code span's included (GitHub's tables split on it there too).
fn cell(text: &str) -> String {
    escaped(text).replace('|', "\\|")
}

/// `--help`'s row, as cobra's docs list it.
fn help_row(name: &str) -> (String, String) {
    (
        "-h, --help[=true|false]".to_string(),
        format!("help for {name}"),
    )
}

/// A flag as cobra's docs list it: `-c, --check[=true|false]` or `    --lines string`.
fn row(flag: &Flag) -> (String, String) {
    let name = match flag.short {
        Some(short) => format!("-{short}, --{}", flag.name),
        None => format!("    --{}", flag.name),
    };
    let name = if flag.takes_value {
        name + " string"
    } else {
        name + "[=true|false]"
    };
    let usage = if flag.default.is_empty() {
        flag.usage.to_string()
    } else {
        format!("{} (default {:?})", flag.usage, flag.default)
    };
    (name, usage)
}

fn table(rows: impl Iterator<Item = (String, String)>) -> String {
    let rows: Vec<(String, String)> = rows.collect();
    let width = rows.iter().map(|(name, _)| name.len()).max().unwrap_or(0);
    rows.iter()
        .map(|(name, usage)| format!("  {name:width$}   {usage}\n"))
        .collect()
}

/// Markdown whose prose can't be read as raw HTML (docs-site/README.md): each `<` outside a code
/// span is written `&lt;`.
fn escaped(prose: &str) -> String {
    prose
        .split('`')
        .enumerate()
        .map(|(index, part)| {
            if index % 2 == 0 {
                part.replace('<', "&lt;")
            } else {
                part.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("`")
}

/// [`escaped`] for a whole document, leaving its fenced code blocks as they are.
fn escaped_markdown(text: &str) -> String {
    let mut fenced = false;
    let mut out = String::new();
    for line in text.split_inclusive('\n') {
        if line.starts_with("```") {
            fenced = !fenced;
            out += line;
        } else if fenced {
            out += line;
        } else {
            out += &escaped(line);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Markdown pages on disk, by file name, split into this generator's (those that carry
    /// its header) and any others.
    fn on_disk() -> (BTreeMap<String, String>, Vec<String>) {
        let mut ours = BTreeMap::new();
        let mut others = Vec::new();
        for entry in std::fs::read_dir(pages_dir()).expect("docs-site/pages/cli") {
            let path = entry.expect("an entry").path();
            if path.extension().is_none_or(|extension| extension != "md") {
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let text = std::fs::read_to_string(&path).expect("a page");
            if text.contains(HEADER) {
                ours.insert(name, text);
            } else {
                others.push(name);
            }
        }
        others.sort();
        (ours, others)
    }

    /// Fails when docs-site/pages/cli doesn't match the commands; `WORKROOM_DOCS_UPDATE=1` (`make
    /// docs-cli`) rewrites them instead. A page without [`HEADER`] fails it either way: this
    /// generator didn't write it, so it neither removes nor overwrites it.
    #[test]
    fn the_cli_reference_pages_are_current() {
        let want = pages();
        let dir = pages_dir();
        // `test-linux.sh` runs the test binaries in a container that holds `vcs/` alone; every
        // checkout, CI's included, has the folder.
        if !dir.is_dir() {
            eprintln!("no {}, so the CLI pages aren't checked here", dir.display());
            return;
        }
        let (have, others) = on_disk();
        assert!(
            others.is_empty(),
            "docs-site/pages/cli holds pages `make docs-cli` didn't write ({others:?}): the CLI \
             reference is generated from the commands, so remove them or move them elsewhere"
        );
        if std::env::var_os("WORKROOM_DOCS_UPDATE").is_some_and(|value| value == "1") {
            for name in have.keys() {
                std::fs::remove_file(dir.join(name)).expect("remove a page of ours");
            }
            for (name, text) in &want {
                std::fs::write(dir.join(name), text).expect("write a page");
            }
            return;
        }
        let mut stale: Vec<&String> = want
            .keys()
            .chain(have.keys())
            .filter(|name| want.get(*name) != have.get(*name))
            .collect();
        stale.sort();
        stale.dedup();
        assert!(
            stale.is_empty(),
            "docs-site/pages/cli is stale ({stale:?}); run `make docs-cli`"
        );
    }

    /// Fails when the Reference pages this generator writes are stale; `WORKROOM_DOCS_UPDATE=1`
    /// (`make docs-cli`) rewrites them instead. A whole page of its own that exists without
    /// [`HEADER`] is someone else's file, which it neither overwrites nor passes; in
    /// `json-output.md` it writes only between its markers.
    #[test]
    fn the_reference_pages_are_current() {
        let dir = site_pages_dir();
        // As for the CLI pages: `test-linux.sh`'s container holds `vcs/` alone.
        if !dir.is_dir() {
            eprintln!(
                "no {}, so the Reference pages aren't checked here",
                dir.display()
            );
            return;
        }
        let read = |name: &str| std::fs::read_to_string(dir.join(name)).ok();
        let update = std::env::var_os("WORKROOM_DOCS_UPDATE").is_some_and(|value| value == "1");
        let mut stale = Vec::new();
        for (name, text) in reference(&read) {
            let have = read(name);
            if name != kinds::PAGE
                && let Some(have) = &have
            {
                assert!(
                    have.contains(HEADER),
                    "docs-site/pages/{name} exists, and `make docs-cli` didn't write it: it \
                     writes that page, so move yours elsewhere"
                );
            }
            if have.as_deref() == Some(text.as_str()) {
                continue;
            }
            if update {
                std::fs::write(dir.join(name), text).expect("write a Reference page");
            } else {
                stale.push(name);
            }
        }
        assert!(
            stale.is_empty(),
            "docs-site/pages is stale ({stale:?}); run `make docs-cli`"
        );
    }

    /// Every `workroom …` command line a generated page quotes, in a code block or a code span,
    /// is one the CLI reads: its command and subcommand exist and it gives no flag they don't
    /// take. The daemon's own subcommands and shell completion's `__complete` are the binary's
    /// too. So a page can't document a command or a flag there is none of.
    #[test]
    fn every_quoted_command_line_parses() {
        use super::super::{find_in, parse};
        use source::shell_words;
        let mut pages: Vec<(String, String)> = pages().into_iter().collect();
        pages.push((terminal_api::PAGE.to_string(), terminal_api::page()));
        pages.push((internal::PAGE.to_string(), internal::page()));
        let daemon = internal::daemon_subcommands();
        let span = regex::Regex::new(r"`(workroom [^`]*)`").unwrap();
        let mut checked = 0;
        for (name, text) in &pages {
            let mut lines: Vec<String> = Vec::new();
            let mut fenced = false;
            for line in text.lines() {
                if line.starts_with("```") {
                    fenced = !fenced;
                } else if fenced {
                    if let Some(command) = line.trim_start().strip_prefix("workroom ") {
                        lines.push(format!("workroom {command}"));
                    }
                } else {
                    lines.extend(span.captures_iter(line).map(|found| found[1].to_string()));
                }
            }
            for line in lines {
                let words = shell_words(&line);
                let Some(first) = words.get(1) else { continue };
                // A usage line's placeholder (`workroom [command]`).
                if first.starts_with('[') {
                    continue;
                }
                checked += 1;
                if daemon.contains(first) || first.starts_with("__complete") {
                    continue;
                }
                // The CLI's own flags, with no command (`workroom --help`).
                if first.starts_with('-') {
                    let (_, error) = parse(&words[1..], &[]);
                    assert_eq!(error, None, "{name} quotes `{line}`, which the CLI refuses");
                    continue;
                }
                let mut command = find_in(COMMANDS, first)
                    .unwrap_or_else(|| panic!("{name} quotes `{line}`: there is no `{first}`"));
                let mut rest = &words[2..];
                if let Some(sub) = rest
                    .first()
                    .and_then(|word| find_in(command.subcommands, word))
                {
                    command = sub;
                    rest = &rest[1..];
                }
                let (_, error) = parse(rest, command.flags);
                assert_eq!(error, None, "{name} quotes `{line}`, which the CLI refuses");
            }
        }
        assert!(checked > 50, "{checked}");
    }

    /// One page per public command and subcommand, named after its command path, beside the CLI's
    /// own page and `help agents`'; none for `help`, a hidden command or a hidden subcommand.
    #[test]
    fn every_public_command_has_a_page() {
        fn expect(command: &Command, path: &str, names: &mut Vec<String>) {
            if command.hidden {
                return;
            }
            names.push(file_name(path));
            for sub in command.subcommands {
                expect(sub, &format!("{path} {}", sub.name), names);
            }
        }
        let mut names = vec!["workroom.md".to_string(), file_name("help agents")];
        for command in COMMANDS.iter().filter(|command| command.name != "help") {
            expect(command, command.name, &mut names);
        }
        names.sort();
        let generated: Vec<String> = pages().into_keys().collect();
        assert_eq!(generated, names);
        assert!(generated.contains(&"workroom-create.md".to_string()));
        assert!(!generated.contains(&"workroom-help.md".to_string()));
        assert!(!generated.contains(&"workroom-add-project.md".to_string()));
    }

    /// Every command is in a stable release (v3.2.0 has the terminal API), so no CLI page is
    /// marked Nightly, in its front matter or in its prose.
    #[test]
    fn no_cli_page_is_nightly() {
        for (name, page) in pages() {
            assert!(!page.contains("\nnightly: true\n"), "{name}");
            assert!(!page.contains("Nightly only"), "{name}");
        }
    }

    /// A Mac-only command's page says it is refused elsewhere. Every page of a Mac-only command or
    /// subcommand carries the line; no other does.
    #[test]
    fn a_mac_only_page_says_its_refusal_elsewhere() {
        fn walk(command: &Command, path: &str, mac_only: &mut Vec<String>, rest: &mut Vec<String>) {
            if command.hidden {
                return;
            }
            if command.mac_only {
                mac_only.push(file_name(path));
            } else {
                rest.push(file_name(path));
            }
            for sub in command.subcommands {
                walk(sub, &format!("{path} {}", sub.name), mac_only, rest);
            }
        }
        let (mut mac_only, mut rest) = (Vec::new(), Vec::new());
        for command in COMMANDS.iter().filter(|command| command.name != "help") {
            walk(command, command.name, &mut mac_only, &mut rest);
        }
        assert!(mac_only.contains(&"workroom-create.md".to_string()));
        let pages = pages();
        let line = "\nRuns on a Mac only, and fails with `MacOnly` elsewhere.\n";
        for name in &mac_only {
            assert!(pages[name].contains(line), "{name}:\n{}", pages[name]);
        }
        for name in &rest {
            assert!(!pages[name].contains("Mac only"), "{name}");
        }
    }

    /// The pages of the commands only a person may run (#793) say a coding agent is refused them,
    /// a subcommand's page (`trust status`) and every other command's don't.
    #[test]
    fn a_guarded_commands_page_says_a_coding_agent_is_refused_it() {
        let pages = pages();
        let line = "\nOnly a person may run it. Under a coding agent";
        for name in ["workroom-trust.md", "workroom-delete.md"] {
            assert!(pages[name].contains(line), "{name}:\n{}", pages[name]);
        }
        for (name, page) in &pages {
            if !["workroom-trust.md", "workroom-delete.md"].contains(&name.as_str()) {
                assert!(!page.contains("Only a person may run it"), "{name}");
            }
        }
    }

    #[test]
    fn prose_is_escaped_outside_code_spans() {
        assert_eq!(escaped("a <b> `c <d>` e"), "a &lt;b> `c <d>` e");
        assert_eq!(
            escaped_markdown("x <y>\n```sh\na <b>\n```\n"),
            "x &lt;y>\n```sh\na <b>\n```\n"
        );
    }
}
