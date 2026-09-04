//! SPIKE — prices open question 1 of `docs/designs/remote-workrooms.md`.
//!
//! Question: can gix produce the same history page the app gets today from
//! `GitProvider.log` (SwiftGitX over libgit2)? The two risks the design doc names are **page
//! ordering** (libgit2's default `GIT_SORT_NONE`, documented there as matching git's date-ordered
//! default rather than `--topo-order`) and field parity.
//!
//! Usage: `gix-log-spike <repo-path> <limit>` — prints one JSON object per line, newest first,
//! carrying the fields `GitProvider.map` fills in. Compare against `git log` for the same range.
//! Push state and ref decorations are deliberately out of scope: those come from `GitGraph` and
//! `GitProvider.decorations`, which are separate libgit2 uses and separate questions.

use std::collections::HashSet;

use gix::bstr::ByteSlice;

#[derive(serde::Serialize)]
struct Author {
    name: String,
    email: String,
}

#[derive(serde::Serialize)]
struct Row {
    commit_id: String,
    short_id: String,
    summary: String,
    body: String,
    authors: Vec<Author>,
    timestamp_ms: i64,
    tz_offset_secs: i32,
    parent_ids: Vec<String>,
}

/// Mirrors `GitProvider.messageBody`: everything after the first line, trimmed. Empty for a
/// single-line message.
fn message_body(message: &str) -> String {
    match message.split_once('\n') {
        None => String::new(),
        Some((_, rest)) => rest.trim().to_string(),
    }
}

/// Mirrors `GitProvider.coAuthors`: `Co-authored-by:` trailers, case-insensitive, using the LAST
/// angle-bracket pair, deduped by lowercased email against the primary author and each other, with
/// the email standing in for an empty name.
fn co_authors(message: &str, primary_email: &str) -> Vec<Author> {
    let mut seen: HashSet<String> = HashSet::new();
    seen.insert(primary_email.to_lowercase());
    const PREFIX: &str = "co-authored-by:";
    let mut out = Vec::new();
    for raw in message.lines() {
        let line = raw.trim();
        // `line.get(..n)` rather than `line[..n]`: Rust slices BYTES and panics mid-codepoint, where
        // the Swift original slices characters. A real commit in this repo starts a message line
        // with `→`, which panicked the first run of this spike.
        let Some(head) = line.get(..PREFIX.len()) else {
            continue;
        };
        if !head.eq_ignore_ascii_case(PREFIX) {
            continue;
        }
        let value = line[PREFIX.len()..].trim();
        let (Some(open), Some(close)) = (value.rfind('<'), value.rfind('>')) else {
            continue;
        };
        if open >= close {
            continue;
        }
        let name = value[..open].trim();
        let email = value[open + 1..close].trim();
        if email.is_empty() || !seen.insert(email.to_lowercase()) {
            continue;
        }
        out.push(Author {
            name: if name.is_empty() {
                email.to_string()
            } else {
                name.to_string()
            },
            email: email.to_string(),
        });
    }
    out
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let root = args
        .next()
        .ok_or("usage: gix-log-spike <repo-path> <limit>")?;
    let limit: usize = args.next().unwrap_or_else(|| "10".into()).parse()?;

    let repo = gix::open(&root)?;

    // An unborn HEAD is an empty history, not a failure — same as `GitProvider.log`'s
    // `repo.isHEADUnborn` early return.
    let Ok(head) = repo.head_id() else {
        println!(
            "{}",
            serde_json::json!({ "commits": [], "reached_end": true })
        );
        return Ok(());
    };

    // The ordering question, stated in code: git's default is date-order, so ask gix for the same
    // rather than taking its BreadthFirst default.
    let walk = repo
        .rev_walk([head])
        .sorting(gix::revision::walk::Sorting::ByCommitTime(
            gix::traverse::commit::simple::CommitTimeOrder::NewestFirst,
        ))
        .all()?;

    // One extra to learn whether more history exists past the page, exactly as GitProvider does.
    let mut rows = Vec::new();
    let mut seen_beyond = false;
    for (i, info) in walk.enumerate() {
        if i >= limit {
            seen_beyond = true;
            break;
        }
        let info = info?;
        let commit = info.object()?;
        let message_raw = commit.message_raw()?.to_str_lossy().to_string();
        let author = commit.author()?;
        let time = author.time()?;
        let primary_email = author.email.to_str_lossy().to_string();

        let mut authors = vec![Author {
            name: author.name.to_str_lossy().to_string(),
            email: primary_email.clone(),
        }];
        authors.extend(co_authors(&message_raw, &primary_email));

        rows.push(Row {
            commit_id: info.id().to_hex().to_string(),
            short_id: info.id().shorten()?.to_string(),
            summary: commit.message()?.summary().to_str_lossy().to_string(),
            body: message_body(&message_raw),
            authors,
            timestamp_ms: time.seconds * 1000,
            tz_offset_secs: time.offset,
            parent_ids: commit
                .parent_ids()
                .map(|p| p.to_hex().to_string())
                .collect(),
        });
    }

    for row in &rows {
        println!("{}", serde_json::to_string(row)?);
    }
    eprintln!("spike: {} rows, reached_end={}", rows.len(), !seen_beyond);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parsers_match_the_swift_original() {
        // messageBody: everything after line one, trimmed; empty for a one-liner.
        assert_eq!(message_body("just a summary"), "");
        assert_eq!(message_body("summary\n\n  body here \n\n"), "body here");

        // Multibyte lines must not panic — this is what the first spike run hit, on a real commit
        // in this repo whose message contains `→`.
        assert!(co_authors("summary\n→ a note\n", "me@example.com").is_empty());
        assert_eq!(message_body("summary\n→ a note"), "→ a note");

        // Co-authors: case-insensitive, LAST angle pair, primary deduped, email fallback for name.
        let m = "s\n\nCo-Authored-By: Ada <ada@example.com>\nco-authored-by: <bob@example.com>\n\
                 Co-authored-by: Dup <ADA@example.com>\nCo-authored-by: Me <me@example.com>\n";
        let got = co_authors(m, "me@example.com");
        assert_eq!(
            got.len(),
            2,
            "primary and duplicate emails must both be dropped"
        );
        assert_eq!(
            (got[0].name.as_str(), got[0].email.as_str()),
            ("Ada", "ada@example.com")
        );
        assert_eq!(
            (got[1].name.as_str(), got[1].email.as_str()),
            ("bob@example.com", "bob@example.com"),
            "an empty name falls back to the email"
        );

        // Malformed trailers are skipped, not fatal.
        assert!(co_authors("s\nCo-authored-by: no brackets\n", "me@x").is_empty());
        assert!(co_authors("s\nCo-authored-by: > < backwards\n", "me@x").is_empty());
    }
}
