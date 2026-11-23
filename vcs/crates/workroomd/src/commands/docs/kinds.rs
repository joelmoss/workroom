//! The error kinds of `json-output.md`: one table of the kinds every command may end with, and
//! one of the terminal API's, each row a kind's code, exit code and meaning, read from the kind
//! registry (`Kind::documented`), so no kind can be missing from them again.
//!
//! The page is written by hand around them. Each table sits between a pair of markers, and only
//! what is between them is written.

use super::super::kind::{ALL, Table};
use super::{MAC_ONLY_IS_NIGHTLY, cell};

/// The page, under `docs-site/pages`.
pub(super) const PAGE: &str = "reference/json-output.md";

/// The line a table's region starts after, by table.
fn begin(table: Table) -> &'static str {
    match table {
        Table::Workroom => {
            "<!-- The kinds every command may end with: generated from the kind registry by `make docs-cli`. Don't edit by hand. -->"
        }
        Table::TerminalApi => {
            "<!-- The terminal API's kinds: generated from the kind registry by `make docs-cli`. Don't edit by hand. -->"
        }
    }
}

/// The line every region ends before.
const END: &str = "<!-- End of the generated kinds. -->";

/// `table`'s rows, in the registry's order, with their header.
fn rows(table: Table) -> String {
    let mut text = String::from("| `kind` | Exit | Meaning |\n| ------ | ---- | ------- |\n");
    for kind in ALL {
        let (in_table, meaning) = kind.documented();
        if in_table != table {
            continue;
        }
        // The docs' Nightly rule: a row new since the latest stable release says so.
        let mark = if MAC_ONLY_IS_NIGHTLY && kind.new_with_the_rust_binary() {
            "Nightly only. "
        } else {
            ""
        };
        text += &format!(
            "| `{}` | {} | {mark}{} |\n",
            kind.code(),
            kind.exit_code(),
            cell(meaning)
        );
    }
    text
}

/// `page` with each table's region written anew. Panics when a region's markers are missing, out
/// of order or there twice: the page is someone's, so this never guesses where a table goes.
pub(super) fn spliced(page: &str) -> String {
    let mut out = page.to_string();
    for table in [Table::Workroom, Table::TerminalApi] {
        let begin = begin(table);
        let starts: Vec<usize> = out.match_indices(begin).map(|(at, _)| at).collect();
        assert!(
            starts.len() == 1,
            "docs-site/pages/{PAGE} needs the line {begin:?} once, where its table goes, with \
             {END:?} after it"
        );
        let start = starts[0] + begin.len();
        let end = out[start..]
            .find(END)
            .map(|offset| start + offset)
            .unwrap_or_else(|| panic!("docs-site/pages/{PAGE}: no {END:?} after {begin:?}"));
        out.replace_range(start..end, &format!("\n\n{}\n", rows(table)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::super::super::agents::{KINDS, NOT_TERMINAL_API_KINDS};
    use super::super::super::kind::Kind;
    use super::*;

    fn page() -> String {
        format!(
            "---\ntitle: T\ndescription: D.\n---\n\nHand.\n\n{}\nold\n{END}\n\nMore.\n\n{}\n{END}\n",
            begin(Table::Workroom),
            begin(Table::TerminalApi)
        )
    }

    /// Every kind is a row of one table, the two the kind's: what `help agents` explains is the
    /// terminal API's, but for the two it shares with the rest.
    #[test]
    fn every_kind_is_a_row_of_its_table() {
        let page = spliced(&page());
        let (workroom, terminal) = page.split_once("More.").expect("two regions");
        for kind in ALL {
            let row = format!("| `{}` | {} | ", kind.code(), kind.exit_code());
            let (table, _) = kind.documented();
            let (here, there) = match table {
                Table::Workroom => (workroom, terminal),
                Table::TerminalApi => (terminal, workroom),
            };
            assert!(here.contains(&row), "{row}");
            assert!(!there.contains(&row), "{row}");
            let shared = matches!(kind, Kind::NotADirectory | Kind::InternalError);
            let explained = KINDS.iter().any(|(listed, _)| listed == kind);
            if !shared {
                assert_eq!(table == Table::TerminalApi, explained, "{}", kind.code());
                assert_eq!(
                    table == Table::Workroom,
                    NOT_TERMINAL_API_KINDS.contains(kind),
                    "{}",
                    kind.code()
                );
            }
        }
        assert!(!page.contains("\nold\n"));
        assert!(page.starts_with("---\ntitle: T\ndescription: D.\n---\n\nHand.\n\n"));
        assert!(page.ends_with(&format!("\n{END}\n")));
    }

    /// The Rust binary's own kinds are Nightly only while that binary is, as the docs' rule has a
    /// row new since the stable release say.
    #[test]
    fn the_rust_binarys_kinds_are_marked_nightly() {
        let page = spliced(&page());
        let mark = if MAC_ONLY_IS_NIGHTLY {
            "Nightly only. "
        } else {
            ""
        };
        for kind in [Kind::MacOnly, Kind::ManagedInstall] {
            assert!(
                page.contains(&format!("| `{}` | 3 | {mark}", kind.code())),
                "{}",
                kind.code()
            );
        }
        assert!(page.contains("| `InWorkroom` | 3 | The command ran"));
    }

    #[test]
    #[should_panic(expected = "needs the line")]
    fn a_page_without_the_markers_is_left_to_its_author() {
        spliced("---\ntitle: T\ndescription: D.\n---\n\nNo tables.\n");
    }
}
