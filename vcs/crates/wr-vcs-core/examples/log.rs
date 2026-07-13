//! Phase-0 read proof: `cargo run -p wr-vcs-core --example log -- <repo-root> [limit]`
//! Prints a real history page from jj-lib (or reports the backend gap).

fn main() {
    let root = std::env::args().nth(1).expect("usage: log <repo-root> [limit]");
    let limit: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);

    println!("repo kind: {:?}", wr_vcs_core::probe_repo(std::path::Path::new(&root)));
    match wr_vcs_core::log_page(std::path::Path::new(&root), limit) {
        Ok(page) => {
            println!("commits={} reached_end={}", page.commits.len(), page.reached_end);
            for c in &page.commits {
                println!(
                    "{}  change={}  {}  wc={}  refs={:?}  | {}",
                    c.short_id,
                    c.change_id.as_deref().unwrap_or("-"),
                    c.authors.first().map(|a| a.name.as_str()).unwrap_or("?"),
                    c.is_working_copy,
                    c.refs,
                    c.summary,
                );
            }
        }
        Err(e) => {
            eprintln!("ERROR: {e}");
            std::process::exit(1);
        }
    }
}
