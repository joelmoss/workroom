//! The docs site's CLI reference pages for the commands only this binary has, the terminal API's
//! (#697), and `help agents`. The Go CLI's cobra commands generate the rest (`cmd/docs_test.go`);
//! the two split `docs-site/pages/cli` by the line under each page's front matter: these carry
//! [`HEADER`], and each generator writes, checks and removes only its own pages.
//!
//! `make docs-cli` rewrites them (`WORKROOM_DOCS_UPDATE=1`); without it, the test fails when they
//! are stale, so the reference can't drift from the commands. Each is marked Nightly: no stable
//! release has the terminal API yet. Cutting one that does drops the mark here, as the Go side's
//! `cliNightly` is.

use std::collections::BTreeMap;
use std::path::PathBuf;

use super::agents::GUIDED;
use super::{Command, Flag, find, global_flags, honours_pretend};

/// The line under a page's front matter that makes it this generator's.
const HEADER: &str = "<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->";

/// Whether no stable release has the terminal API yet, so every page is Nightly.
const NIGHTLY: bool = true;

fn pages_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../docs-site/pages/cli")
}

/// Every page, by file name.
fn pages() -> BTreeMap<String, String> {
    let mut pages = BTreeMap::new();
    for guided in GUIDED {
        let command = find(guided.command).expect("a guided command");
        pages.insert(
            file_name(command.name),
            page(command, None, Some(guided.says)),
        );
        for sub in command.subcommands.iter().filter(|sub| !sub.hidden) {
            let path = format!("{} {}", command.name, sub.name);
            pages.insert(file_name(&path), page(sub, Some(command), None));
        }
    }
    pages.insert(file_name("help agents"), help_agents());
    pages
}

fn file_name(path: &str) -> String {
    format!("workroom-{}.md", path.replace(' ', "-"))
}

fn front_matter(title: &str, description: &str) -> String {
    let nightly = if NIGHTLY { "nightly: true\n" } else { "" };
    // Quoted, as JSON quotes it, which YAML reads the same: a description can hold ": ".
    let description = serde_json::to_string(description).expect("a string is JSON");
    format!("---\ntitle: {title}\ndescription: {description}\n{nightly}---\n\n{HEADER}\n\n")
}

/// A command's page, laid out as cobra's are on the Go side: its synopsis, usage, options,
/// inherited options and links, then what `help agents` says of it.
fn page(command: &Command, parent: Option<&Command>, says: Option<&str>) -> String {
    let path = match parent {
        Some(parent) => format!("workroom {} {}", parent.name, command.name),
        None => format!("workroom {}", command.name),
    };
    let mut text = front_matter(&path, &format!("{}.", command.short.trim_end_matches('.')));
    text += "## Synopsis\n\n";
    text += &escaped(command.long.unwrap_or(command.short));
    text += &format!("\n\n```text\nworkroom {}\n```\n\n", command.usage);
    let own: Vec<&Flag> = command.flags.iter().filter(|flag| !flag.hidden).collect();
    text += "## Options\n\n```text\n";
    text += &table(
        std::iter::once((
            "-h, --help[=true|false]".to_string(),
            format!("help for {}", command.name),
        ))
        .chain(own.iter().map(|flag| row(flag))),
    );
    text += "```\n\n## Options inherited from parent commands\n\n```text\n";
    let top = parent.unwrap_or(command).name;
    text += &table(global_flags(honours_pretend(top)).map(row));
    text += "```\n\n";
    if let Some(says) = says {
        text += "## How to use it\n\n";
        text += &escaped(says);
        text += "\n\n";
    }
    text += "## See also\n\n";
    match parent {
        Some(parent) => {
            text += &format!(
                "* [workroom {}]({})\t - {}\n",
                parent.name,
                file_name(parent.name),
                parent.short
            );
        }
        None => text += "* [workroom](workroom.md)\t - Manage development workrooms\n",
    }
    for sub in command.subcommands.iter().filter(|sub| !sub.hidden) {
        text += &format!(
            "* [workroom {} {}]({})\t - {}\n",
            command.name,
            sub.name,
            file_name(&format!("{} {}", command.name, sub.name)),
            sub.short
        );
    }
    text += "* [workroom help agents](workroom-help-agents.md)\t - The terminal API, for coding agents\n";
    text
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
    page += "\n## See also\n\n* [workroom](workroom.md)\t - Manage development workrooms\n";
    page
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
/// span is written `&lt;`, as the Go side writes it.
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

    /// The pages this generator owns, by file name: those that carry its header.
    fn ours_on_disk() -> BTreeMap<String, String> {
        let mut ours = BTreeMap::new();
        for entry in std::fs::read_dir(pages_dir()).expect("docs-site/pages/cli") {
            let path = entry.expect("an entry").path();
            if path.extension().is_none_or(|extension| extension != "md") {
                continue;
            }
            let text = std::fs::read_to_string(&path).expect("a page");
            if text.contains(HEADER) {
                ours.insert(
                    path.file_name().unwrap().to_string_lossy().into_owned(),
                    text,
                );
            }
        }
        ours
    }

    /// Fails when docs-site/pages/cli doesn't match the commands; `WORKROOM_DOCS_UPDATE=1` (`make
    /// docs-cli`) rewrites them instead.
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
        if std::env::var_os("WORKROOM_DOCS_UPDATE").is_some_and(|value| value == "1") {
            for name in ours_on_disk().keys() {
                std::fs::remove_file(dir.join(name)).expect("remove a page of ours");
            }
            for (name, text) in &want {
                let path = dir.join(name);
                assert!(
                    !path.exists(),
                    "{name} is the Go CLI's page, and a command here has its name"
                );
                std::fs::write(path, text).expect("write a page");
            }
            return;
        }
        let have = ours_on_disk();
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

    #[test]
    fn prose_is_escaped_outside_code_spans() {
        assert_eq!(escaped("a <b> `c <d>` e"), "a &lt;b> `c <d>` e");
        assert_eq!(
            escaped_markdown("x <y>\n```sh\na <b>\n```\n"),
            "x &lt;y>\n```sh\na <b>\n```\n"
        );
    }
}
