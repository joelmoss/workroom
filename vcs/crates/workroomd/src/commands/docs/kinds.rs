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
pub(super) fn spliced(page: &str) -> Result<String, String> {
    // Every marker, where it is: each table's begin once, then an end after each, nothing else
    // between them, so no hand-written text is ever inside a region the generator writes.
    let mut markers: Vec<(usize, Option<Table>)> =
        page.match_indices(END).map(|(at, _)| (at, None)).collect();
    for table in TABLES {
        let found: Vec<usize> = page.match_indices(begin(table)).map(|(at, _)| at).collect();
        if found.len() != 1 {
            return Err(format!(
                "docs-site/pages/{PAGE} needs the line {:?} once, where its table goes, with \
                 {END:?} after it; it has it {} times",
                begin(table),
                found.len()
            ));
        }
        markers.push((found[0], Some(table)));
    }
    markers.sort_by_key(|(at, _)| *at);
    let want: Vec<Option<Table>> = TABLES
        .iter()
        .flat_map(|table| [Some(*table), None])
        .collect();
    let have: Vec<Option<Table>> = markers.iter().map(|(_, table)| *table).collect();
    if have != want {
        return Err(format!(
            "docs-site/pages/{PAGE}: its markers are out of order or doubled; each table's \
             begin line needs one {END:?} after it, before the next table's"
        ));
    }
    let mut out = String::new();
    let mut from = 0;
    for pair in markers.chunks(2) {
        let (at, Some(table)) = pair[0] else {
            unreachable!("checked above")
        };
        let start = at + begin(table).len();
        out += &page[from..start];
        out += &format!("\n\n{}\n", rows(table));
        from = pair[1].0;
    }
    out += &page[from..];
    Ok(out)
}

/// The tables, in the order the page has them.
const TABLES: [Table; 2] = [Table::Workroom, Table::TerminalApi];

/// The anchor of the heading `table` is under in the page, which links to a kind's row use.
pub(super) fn anchor(table: Table) -> &'static str {
    match table {
        Table::Workroom => "error-kinds",
        Table::TerminalApi => "the-terminal-apis-kinds",
    }
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
        let page = spliced(&page()).unwrap();
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
        let page = spliced(&page()).unwrap();
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

    /// Markers missing, doubled or out of order are refused, and nothing is written: the page is
    /// someone's, so this never guesses which text is a region.
    #[test]
    fn markers_out_of_place_are_refused() {
        let (a, b) = (begin(Table::Workroom), begin(Table::TerminalApi));
        for broken in [
            "No tables.\n".to_string(),
            format!("{a}\nmine\n\n{b}\n{END}\n"),
            format!("{a}\n{END}\n{END}\n{b}\n{END}\n"),
            format!("{b}\n{END}\n{a}\n{END}\n"),
            format!("{a}\n{END}\n{a}\n{END}\n{b}\n{END}\n"),
        ] {
            assert!(spliced(&broken).is_err(), "{broken}");
        }
        let fine = format!("x\n{a}\nold\n{END}\ny\n{b}\n{END}\nz\n");
        let out = spliced(&fine).expect("in order");
        assert!(out.starts_with("x\n") && out.contains(&format!("{END}\ny\n{b}")));
        assert!(out.ends_with(&format!("{END}\nz\n")) && !out.contains("\nold\n"));
    }

    #[test]
    #[should_panic(expected = "needs the line")]
    fn a_page_without_the_markers_is_left_to_its_author() {
        spliced("---\ntitle: T\ndescription: D.\n---\n\nNo tables.\n").unwrap();
    }
}
