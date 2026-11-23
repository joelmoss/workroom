//! The documentation under `docs-site/`, checked against the format contract in
//! `docs-site/README.md`: the nav, front matter, Markdown rules, links and heading anchors, and the
//! Nightly markers on what is new since the latest stable release. Codaset renders the pages; this
//! test makes a broken page fail here, before it can merge (`make docs-check`).
//!
//! The YAML in `nav.yml` and in front matter is read by a strict subset of YAML (`yaml` below):
//! plain, single- or double-quoted scalars, and nav's list of groups each with a list of pages.
//! Anything outside it is a problem to fix, not a document read some other way, so what this
//! accepts Codaset's YAML reads the same.
//!
//! `test-linux.sh` runs the test binaries in a container that holds `vcs/` alone, so with no
//! `docs-site/` these tests say so and pass.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs-site")
}

/// Whether `docs-site/` is here to check; says so when it isn't.
fn have_docs() -> bool {
    let present = root().join("nav.yml").is_file();
    if !present {
        eprintln!("no {}, so the docs aren't checked here", root().display());
    }
    present
}

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a valid pattern")
}

static NAME: LazyLock<Regex> = LazyLock::new(|| regex(r"^[a-z0-9-]+$"));
static HEADING: LazyLock<Regex> = LazyLock::new(|| regex(r"^(#{1,6})\s+(.*?)\s*#*\s*$"));
static FENCE: LazyLock<Regex> = LazyLock::new(|| regex(r"^\s{0,3}(```|~~~)"));
static CODE_SPAN: LazyLock<Regex> = LazyLock::new(|| regex(r"`+[^`]*`+"));
static LINK: LazyLock<Regex> =
    LazyLock::new(|| regex(r#"(!?)\[([^\]]*)\]\(([^)\s]*)(?:\s+"[^"]*")?\)"#));
static REF_LINK: LazyLock<Regex> = LazyLock::new(|| regex(r"\]\[[^\]]*\]"));
static HTML_TAG: LazyLock<Regex> = LazyLock::new(|| regex(r"</?([A-Za-z][A-Za-z0-9-]*)[^>]*>"));
/// CommonMark's autolinks: `<scheme:…>` or `<name@host>`, with no spaces. Anything else in angle
/// brackets is raw HTML, `<img src="https://…">` included.
static AUTOLINK: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|[^\s<>@]+@[^\s<>@]+)>$"));
static SETEXT: LazyLock<Regex> = LazyLock::new(|| regex(r"^\s{0,3}(=+|-{2,})\s*$"));
/// What a heading's anchor drops: everything but letters, marks, numbers, connector punctuation,
/// spaces and hyphens.
static NOT_IN_ANCHOR: LazyLock<Regex> = LazyLock::new(|| regex(r"[^\p{L}\p{M}\p{N}\p{Pc} -]"));
static TABLE_ROW: LazyLock<Regex> = LazyLock::new(|| regex(r"^\s{0,3}\|"));
static TABLE_SEPARATOR: LazyLock<Regex> = LazyLock::new(|| regex(r"^\s{0,3}\|[\s:|-]+$"));
static NIGHTLY_NOTE: LazyLock<Regex> = LazyLock::new(|| regex(r"\(?Nightly only\.?\)?"));

const IMAGE_TYPES: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];

/// A strict subset of YAML: what `nav.yml` and front matter are written in.
mod yaml {
    use std::collections::BTreeMap;

    /// A value: a scalar, or a list of mappings.
    #[derive(Debug)]
    pub enum Value {
        Scalar(String),
        List(Vec<Map>),
    }

    pub type Map = BTreeMap<String, Value>;

    /// One line that holds something, with its 1-based number and its indent.
    struct Line<'a> {
        number: usize,
        indent: usize,
        text: &'a str,
    }

    fn lines(src: &str) -> Result<Vec<Line<'_>>, String> {
        let mut lines = Vec::new();
        for (index, raw) in src.lines().enumerate() {
            let text = raw.trim_start_matches(' ');
            if text.trim().is_empty() || text.starts_with('#') {
                continue;
            }
            if text.starts_with('\t') {
                return Err(format!("line {}: indent with spaces, not tabs", index + 1));
            }
            lines.push(Line {
                number: index + 1,
                indent: raw.len() - text.len(),
                text: text.trim_end(),
            });
        }
        Ok(lines)
    }

    /// A mapping of scalars, one `key: value` per line: front matter.
    pub fn mapping(src: &str) -> Result<Map, String> {
        let lines = lines(src)?;
        let mut at = 0;
        let map = block_map(&lines, &mut at, 0, None)?;
        match lines.get(at) {
            Some(line) => Err(format!("line {}: not a `key: value` line", line.number)),
            None => Ok(map),
        }
    }

    /// A list of mappings: `nav.yml`.
    pub fn list(src: &str) -> Result<Vec<Map>, String> {
        let lines = lines(src)?;
        let mut at = 0;
        let list = block_list(&lines, &mut at, 0)?;
        match lines.get(at) {
            Some(line) => Err(format!("line {}: not part of the list", line.number)),
            None => Ok(list),
        }
    }

    /// The `- ` items at `indent`, each a mapping.
    fn block_list(lines: &[Line], at: &mut usize, indent: usize) -> Result<Vec<Map>, String> {
        let mut items = Vec::new();
        while let Some(line) = lines.get(*at) {
            if line.indent != indent {
                break;
            }
            let Some(first) = line.text.strip_prefix("- ") else {
                break;
            };
            let first = first.trim_start();
            let inner = indent + (line.text.len() - first.len());
            let number = line.number;
            *at += 1;
            items.push(block_map(lines, at, inner, Some((number, first)))?);
        }
        if items.is_empty() {
            let number = lines.get(*at).map_or(0, |line| line.number);
            return Err(format!("line {number}: expected a `- ` list item"));
        }
        Ok(items)
    }

    /// The `key: value` lines at `indent`, starting with `first` when a list item holds it.
    fn block_map(
        lines: &[Line],
        at: &mut usize,
        indent: usize,
        first: Option<(usize, &str)>,
    ) -> Result<Map, String> {
        let mut map = Map::new();
        let mut pending = first;
        loop {
            let (number, text) = match pending.take() {
                Some(entry) => entry,
                None => match lines.get(*at) {
                    Some(line) if line.indent == indent && !line.text.starts_with("- ") => {
                        *at += 1;
                        (line.number, line.text)
                    }
                    Some(line) if line.indent > indent => {
                        return Err(format!("line {}: indented more than its key", line.number));
                    }
                    _ => break,
                },
            };
            let (key, rest) = text
                .split_once(':')
                .filter(|(key, rest)| {
                    !key.is_empty()
                        && key
                            .chars()
                            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
                        && (rest.is_empty() || rest.starts_with(' '))
                })
                .ok_or_else(|| format!("line {number}: not a `key: value` line"))?;
            let rest = rest.trim();
            let value = if rest.is_empty() {
                match lines.get(*at) {
                    Some(line) if line.indent > indent => {
                        Value::List(block_list(lines, at, line.indent)?)
                    }
                    _ => return Err(format!("line {number}: {key} has no value")),
                }
            } else {
                Value::Scalar(scalar(rest).map_err(|why| format!("line {number}: {key}: {why}"))?)
            };
            if map.insert(key.to_string(), value).is_some() {
                return Err(format!("line {number}: {key} is given twice"));
            }
        }
        Ok(map)
    }

    /// One scalar: double-quoted (read as JSON, which YAML reads the same), single-quoted, or
    /// plain, where plain is text that can't be read as anything but itself.
    fn scalar(text: &str) -> Result<String, String> {
        if text.starts_with('"') {
            return serde_json::from_str::<String>(text).map_err(|_| {
                "a double-quoted value is one JSON string, with JSON's escapes".to_string()
            });
        }
        if let Some(inner) = text.strip_prefix('\'') {
            let inner = inner
                .strip_suffix('\'')
                .ok_or("a single-quoted value ends with '")?;
            if inner.replace("''", "").contains('\'') {
                return Err("write ' inside single quotes as ''".to_string());
            }
            return Ok(inner.replace("''", "'"));
        }
        let mut chars = text.chars();
        let first = chars.next().unwrap_or(' ');
        // `-`, `?` and `:` start something else only before a space; the rest always do.
        let indicator = "[]{}&*!|>%@`,".contains(first)
            || ("-?:".contains(first) && chars.next().is_none_or(|next| next == ' '));
        if indicator || text.contains(": ") || text.contains(" #") || text.ends_with(':') {
            return Err("quote this value: YAML reads it as more than text".to_string());
        }
        Ok(text.to_string())
    }
}

/// The scalar at `key`, if it is one.
fn text<'a>(map: &'a yaml::Map, key: &str) -> Option<&'a str> {
    match map.get(key) {
        Some(yaml::Value::Scalar(value)) => Some(value),
        _ => None,
    }
}

/// Every key of `map` that isn't one of `known`.
fn unknown_keys(map: &yaml::Map, known: &[&str]) -> Vec<String> {
    map.keys()
        .filter(|key| !known.contains(&key.as_str()))
        .cloned()
        .collect()
}

struct Link {
    image: bool,
    text: String,
    target: String,
}

struct Page {
    anchors: BTreeSet<String>,
    links: Vec<Link>,
}

/// The front matter's source and the body after it, with the file line the body starts on; None
/// when the page doesn't start with front matter.
fn split_front_matter(text: &str) -> Option<(&str, &str, usize)> {
    let rest = text.strip_prefix("---\n")?;
    let (front, body) = rest.split_once("\n---\n")?;
    Some((front, body, front.matches('\n').count() + 4))
}

/// A heading's id as docs-site/README.md "Heading anchors" pins it (commonmarker's
/// `header_ids`): plain text, lowercased, disallowed characters removed, spaces to hyphens.
fn anchor(heading: &str) -> String {
    let heading = heading.strip_suffix(" {nightly}").unwrap_or(heading);
    let heading = HTML_TAG.replace_all(heading, "");
    let heading = LINK.replace_all(&heading, "$2");
    let heading = heading.replace('`', "").to_lowercase();
    NOT_IN_ANCHOR.replace_all(&heading, "").replace(' ', "-")
}

/// Reads one page's front matter, headings and links, reporting what breaks the contract.
fn parse_page(src: &str, report: &mut dyn FnMut(String)) -> Page {
    let mut page = Page {
        anchors: BTreeSet::new(),
        links: Vec::new(),
    };
    let source = src.replace("\r\n", "\n");
    let (body, first) = match split_front_matter(&source) {
        None => {
            report("starts with YAML front matter between --- lines".to_string());
            (source.as_str(), 1)
        }
        Some((front, body, first)) => {
            match yaml::mapping(front) {
                Err(why) => report(format!("front matter: {why}")),
                Ok(map) => {
                    for key in unknown_keys(&map, &["title", "description", "nightly"]) {
                        report(format!(
                            "front matter: {key} is not a key; title, description and nightly are"
                        ));
                    }
                    if text(&map, "title").is_none_or(|title| title.trim().is_empty()) {
                        report("front matter needs a title".to_string());
                    }
                    if text(&map, "description").is_none_or(|value| value.trim().is_empty()) {
                        report("front matter needs a description".to_string());
                    }
                    if map.contains_key("nightly")
                        && !matches!(text(&map, "nightly"), Some("true" | "false"))
                    {
                        report("front matter: nightly is true or false".to_string());
                    }
                }
            }
            (body, first)
        }
    };

    let mut fence: Option<&str> = None;
    let mut previous_blank = true;
    for (index, line) in body.split('\n').enumerate() {
        let number = index + first;
        if let Some(found) = FENCE.captures(line) {
            let marker = found.get(1).expect("a fence").as_str();
            match fence {
                None => {
                    fence = Some(marker);
                    let rest = line.trim().trim_start_matches(&marker[..1]).trim();
                    if rest.is_empty() {
                        report(format!(
                            "line {number}: name the code block's language, for example ```sh or \
                             ```text"
                        ));
                    }
                }
                Some(open) if open == marker => fence = None,
                Some(_) => {}
            }
            previous_blank = false;
            continue;
        }
        if fence.is_some() {
            continue;
        }
        if !previous_blank && SETEXT.is_match(line) && !line.trim().starts_with("---") {
            report(format!(
                "line {number}: use ## headings, not underlined (setext) ones"
            ));
        }
        previous_blank = line.trim().is_empty();

        let outside = CODE_SPAN.replace_all(line, "");
        if REF_LINK.is_match(&outside) {
            report(format!(
                "line {number}: use inline links, not reference-style [text][ref] links"
            ));
        }
        for tag in HTML_TAG.captures_iter(&outside) {
            let name = &tag[1];
            if !AUTOLINK.is_match(&tag[0]) && !name.eq_ignore_ascii_case("kbd") {
                report(format!(
                    "line {number}: <{name}> is not allowed; <kbd> is the only raw HTML"
                ));
            }
        }
        if outside.contains("</kbd><kbd>") {
            report(format!(
                "line {number}: write a key combination as one <kbd>, such as <kbd>⌘D</kbd>"
            ));
        }
        for link in LINK.captures_iter(&outside) {
            page.links.push(Link {
                image: &link[1] == "!",
                text: link[2].to_string(),
                target: link[3].to_string(),
            });
        }

        let heading = HEADING.captures(line);
        let heading_text = heading
            .as_ref()
            .map(|h| h.get(2).expect("a heading").as_str());
        if outside.contains("{nightly}") && !heading_text.is_some_and(|h| h.ends_with(" {nightly}"))
        {
            report(format!(
                "line {number}: {{nightly}} goes only at the end of a heading; write \"Nightly \
                 only.\" in prose"
            ));
        }
        let (Some(heading), Some(heading_text)) = (heading.as_ref(), heading_text) else {
            continue;
        };
        let level = heading[1].len();
        if !(2..=4).contains(&level) {
            report(format!(
                "line {number}: headings are ## to ####; the title comes from front matter"
            ));
        }
        if CODE_SPAN.replace_all(heading_text, "").contains(['*', '_']) {
            report(format!(
                "line {number}: no emphasis in headings; put identifiers in `code`"
            ));
        }
        let base = anchor(heading_text);
        let mut id = base.clone();
        let mut n = 1;
        while page.anchors.contains(&id) {
            id = format!("{base}-{n}");
            n += 1;
        }
        page.anchors.insert(id);
    }
    if fence.is_some() {
        report("a code block is never closed".to_string());
    }
    page
}

/// `path` with `.` and `..` resolved, as Go's `path.Join` cleans it.
fn clean(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();
                } else {
                    parts.push("..");
                }
            }
            part => parts.push(part),
        }
    }
    parts.join("/")
}

/// Every way the docs under `dir` break the contract.
fn check(dir: &Path) -> Vec<String> {
    let mut problems = Vec::new();
    let pages_dir = dir.join("pages");
    let mut pages: BTreeMap<String, Page> = BTreeMap::new();
    let mut walk = vec![pages_dir.clone()];
    while let Some(folder) = walk.pop() {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(&folder)
            .unwrap_or_else(|error| panic!("read {}: {error}", folder.display()))
            .map(|entry| entry.expect("an entry").path())
            .collect();
        entries.sort();
        for path in entries {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            // .DS_Store, editor and tool folders: never pages.
            if name.starts_with('.') {
                continue;
            }
            let rel = path
                .strip_prefix(&pages_dir)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            let kind = std::fs::symlink_metadata(&path).expect("stat").file_type();
            if kind.is_dir() {
                if !NAME.is_match(&name) {
                    problems.push(format!(
                        "pages/{rel}: folder names use lowercase letters, digits and hyphens only"
                    ));
                }
                walk.push(path);
                continue;
            }
            let Some(page_name) = rel.strip_suffix(".md") else {
                problems.push(format!(
                    "pages/{rel}: only Markdown pages belong in pages/; images go in images/"
                ));
                continue;
            };
            let base = page_name.rsplit('/').next().unwrap_or(page_name);
            if !NAME.is_match(base) {
                problems.push(format!(
                    "pages/{rel}: file names use lowercase letters, digits and hyphens only"
                ));
            }
            let depth = page_name.matches('/').count();
            if (page_name == "index" && depth != 0) || (page_name != "index" && depth != 1) {
                problems.push(format!(
                    "pages/{rel}: every page except index.md sits exactly one folder deep"
                ));
            }
            let src = std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
            let page = parse_page(&src, &mut |problem| {
                problems.push(format!("pages/{rel}: {problem}"));
            });
            pages.insert(page_name.to_string(), page);
        }
    }
    if !pages.contains_key("index") {
        problems.push("pages/index.md is missing; it is the docs home".to_string());
    }

    // The nav: every entry names a real page, and every page but the home appears exactly once.
    let nav = std::fs::read_to_string(dir.join("nav.yml")).expect("read nav.yml");
    let mut seen: BTreeMap<String, usize> = BTreeMap::new();
    match yaml::list(&nav) {
        Err(why) => problems.push(format!("nav.yml: {why}")),
        Ok(groups) => {
            for group in &groups {
                let title = text(group, "title").unwrap_or_default();
                for key in unknown_keys(group, &["title", "pages"]) {
                    problems.push(format!(
                        "nav.yml: group {title:?} has {key}, which is not a key"
                    ));
                }
                if title.trim().is_empty() {
                    problems.push("nav.yml: a group has no title".to_string());
                }
                let entries = match group.get("pages") {
                    Some(yaml::Value::List(entries)) => entries.as_slice(),
                    _ => &[],
                };
                if entries.is_empty() {
                    problems.push(format!("nav.yml: group {title:?} has no pages"));
                }
                for entry in entries {
                    let page = text(entry, "page").unwrap_or_default();
                    for key in unknown_keys(entry, &["title", "page"]) {
                        problems.push(format!("nav.yml: {page:?} has {key}, which is not a key"));
                    }
                    if text(entry, "title").is_none_or(|title| title.trim().is_empty()) {
                        problems.push(format!("nav.yml: {page:?} has no title"));
                    }
                    *seen.entry(page.to_string()).or_default() += 1;
                    if !pages.contains_key(page) {
                        problems.push(format!("nav.yml: {page:?} has no page at pages/{page}.md"));
                    }
                }
            }
        }
    }
    for name in pages.keys() {
        let count = seen.get(name).copied().unwrap_or(0);
        if name == "index" && count > 0 {
            problems.push("nav.yml: index is the docs home and is not listed in the nav".into());
        } else if name != "index" && count == 0 {
            problems.push(format!("pages/{name}.md: not listed in nav.yml"));
        } else if count > 1 {
            problems.push(format!("nav.yml: {name:?} is listed {count} times"));
        }
    }

    // Links and images resolve, anchors included.
    for (name, page) in &pages {
        let page_dir = match format!("pages/{name}.md").rsplit_once('/') {
            Some((folder, _)) => folder.to_string(),
            None => String::new(),
        };
        for link in &page.links {
            let target = &link.target;
            let at = format!("pages/{name}.md: link {target:?}");
            if link.image && link.text.trim().is_empty() {
                problems.push(format!("{at}: an image needs alt text"));
            }
            if ["https://", "http://", "mailto:"]
                .iter()
                .any(|scheme| target.starts_with(scheme))
            {
                continue;
            }
            let (file, anchor) = target.split_once('#').unwrap_or((target, ""));
            if file.is_empty() {
                if !page.anchors.contains(anchor) {
                    problems.push(format!(
                        "{at}: no heading on this page has the anchor #{anchor}"
                    ));
                }
                continue;
            }
            let resolved = clean(&format!("{page_dir}/{file}"));
            if link.image {
                // Codaset serves only these types, and never a symlink (WorkroomDocs::Site).
                let extension = resolved
                    .rsplit_once('.')
                    .map(|(_, extension)| extension.to_ascii_lowercase())
                    .unwrap_or_default();
                if !resolved.starts_with("images/") {
                    problems.push(format!("{at}: images live in images/"));
                } else if !IMAGE_TYPES.contains(&extension.as_str()) {
                    problems.push(format!("{at}: images are .png, .jpg, .jpeg, .gif or .webp"));
                } else {
                    match std::fs::symlink_metadata(dir.join(&resolved)) {
                        Err(_) => problems.push(format!("{at}: no such image")),
                        Ok(meta) if meta.file_type().is_symlink() => {
                            problems.push(format!("{at}: an image can't be a symlink"));
                        }
                        Ok(_) => {}
                    }
                }
                continue;
            }
            let Some(other) = resolved
                .strip_prefix("pages/")
                .and_then(|rest| rest.strip_suffix(".md"))
            else {
                problems.push(format!(
                    "{at}: link to another page by its relative .md path"
                ));
                continue;
            };
            match pages.get(other) {
                None => problems.push(format!("{at}: no such page")),
                Some(target_page)
                    if !anchor.is_empty() && !target_page.anchors.contains(anchor) =>
                {
                    problems.push(format!(
                        "{at}: {resolved} has no heading with the anchor #{anchor}"
                    ));
                }
                Some(_) => {}
            }
        }
    }
    problems
}

/// Checks every page and the nav, reporting every problem rather than the first.
#[test]
fn the_docs_site_keeps_its_format() {
    if !have_docs() {
        return;
    }
    let problems = check(&root());
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn anchors_are_derived_as_commonmarker_derives_them() {
    for (heading, want) in [
        ("Open a pull request", "open-a-pull-request"),
        ("The `workrooms_dir` key", "the-workrooms_dir-key"),
        ("Run <kbd>⌘</kbd><kbd>R</kbd>", "run-r"),
        ("See [the CLI](../cli/workroom.md)", "see-the-cli"),
        ("Approve scripts {nightly}", "approve-scripts"),
        ("Ports & forwarding: 3000/tcp", "ports--forwarding-3000tcp"),
        ("Café über", "café-über"),
    ] {
        assert_eq!(anchor(heading), want, "{heading}");
    }
}

/// A directory of the test's own, removed when it ends: `create_dir` fails on a path that already
/// exists, so only what this call made is ever removed.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let parent = std::env::temp_dir();
        let pid = std::process::id();
        for attempt in 0u32.. {
            let dir = parent.join(format!("wr-docs-{name}-{pid}-{attempt}"));
            match std::fs::create_dir(&dir) {
                Ok(()) => return Scratch(dir),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create {}: {error}", dir.display()),
            }
        }
        unreachable!("u32 attempts ran out")
    }

    fn write(&self, name: &str, content: &str) {
        let path = self.0.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).expect("create folders");
        std::fs::write(path, content).expect("write");
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The check can fail: a small site with one of each mistake reports every one of them.
#[test]
fn the_check_finds_each_kind_of_breakage() {
    let site = Scratch::new("breakage");
    site.write(
        "nav.yml",
        "- title: Guides\n  pages:\n    - title: A\n      page: guides/a\n    - title: Gone\n      \
         page: guides/gone\n",
    );
    site.write(
        "pages/index.md",
        "---\ntitle: Home\ndescription: The home.\n---\n\nSee [A](guides/a.md#missing).\n",
    );
    site.write(
        "pages/guides/a.md",
        "---\ntitle: A\n---\n\n# Title again\n\n## Same\n\n## Same\n\n[ok](#same-1) [bad](#nope) \
         [page](b.md) ![](../../images/x.png) <div>\n\n```\ncode\n```\n\nPress \
         <kbd>⌘</kbd><kbd>D</kbd>.\n\n<img src=\"https://x.example/a.png\"> \
         <https://ok.example/> <me@ok.example>\n\n![icon](../../images/icon.svg) \
         ![shot](../../images/link.png)\n",
    );
    site.write("images/real.png", "x");
    std::os::unix::fs::symlink("real.png", site.0.join("images/link.png")).expect("symlink");
    site.write(
        "pages/guides/b.md",
        "---\ntitle: B\ndescription: B.\nweight: 3\n---\n\nText. {nightly}\n\n## Fine {nightly}\n",
    );
    site.write(
        "pages/guides/Bad_Name.md",
        "---\ntitle: X\ndescription: X.\n---\n",
    );
    site.write(
        "pages/guides/c.md",
        "---\ntitle: C: the third\ndescription: C.\n---\n",
    );

    let got = check(&site.0).join("\n");
    for want in [
        r#"pages/index.md: link "guides/a.md#missing": pages/guides/a.md has no heading with the anchor #missing"#,
        "pages/guides/a.md: front matter needs a description",
        "pages/guides/a.md: line 5: headings are ## to ####",
        r##"pages/guides/a.md: link "#nope": no heading on this page has the anchor #nope"##,
        r#"pages/guides/a.md: link "../../images/x.png": an image needs alt text"#,
        r#"pages/guides/a.md: link "../../images/x.png": no such image"#,
        "pages/guides/a.md: line 11: <div> is not allowed",
        "pages/guides/a.md: line 13: name the code block's language",
        "pages/guides/a.md: line 17: write a key combination as one <kbd>",
        "pages/guides/a.md: line 19: <img> is not allowed",
        r#"pages/guides/a.md: link "../../images/icon.svg": images are .png, .jpg, .jpeg, .gif or .webp"#,
        r#"pages/guides/a.md: link "../../images/link.png": an image can't be a symlink"#,
        "pages/guides/b.md: front matter: weight is not a key",
        "pages/guides/b.md: not listed in nav.yml",
        "pages/guides/b.md: line 7: {nightly} goes only at the end of a heading",
        "pages/guides/Bad_Name.md: file names use lowercase letters",
        "pages/guides/c.md: front matter: line 1: title: quote this value",
        r#"nav.yml: "guides/gone" has no page at pages/guides/gone.md"#,
    ] {
        assert!(got.contains(want), "missing problem {want:?} in:\n{got}");
    }
    assert!(
        !got.contains("line 19: <https>") && !got.contains("line 19: <me@"),
        "an autolink was reported as raw HTML:\n{got}"
    );
    assert!(
        !got.contains("#same-1"),
        "a duplicate heading's -1 anchor was reported missing:\n{got}"
    );
}

/// The YAML subset reads what the docs write, and refuses what YAML would read some other way.
#[test]
fn the_yaml_subset_reads_scalars_as_yaml_does() {
    let map = yaml::mapping(
        "title: workroom create\ndescription: \"Say: \\\"hi\\\"\"\nnightly: true\nother: 'it''s'\n",
    )
    .expect("a mapping");
    assert_eq!(text(&map, "title"), Some("workroom create"));
    assert_eq!(text(&map, "description"), Some("Say: \"hi\""));
    assert_eq!(text(&map, "nightly"), Some("true"));
    assert_eq!(text(&map, "other"), Some("it's"));
    for bad in [
        "title: a: b\n",
        "title: [a]\n",
        "title: x #y\n",
        "title: \"open\n",
        "title: a\ntitle: b\n",
        "title: a\n  more\n",
        "just text\n",
    ] {
        assert!(yaml::mapping(bad).is_err(), "{bad:?} was read");
    }
    let nav = yaml::list(
        "# The sidebar.\n- title: Get started\n  pages:\n    - title: Install\n      page: \
         get-started/install\n\n- title: Guides\n  pages:\n    - title: Review\n      page: \
         guides/review\n",
    )
    .expect("a list");
    assert_eq!(nav.len(), 2);
    let Some(yaml::Value::List(pages)) = nav[1].get("pages") else {
        panic!("no pages: {nav:?}");
    };
    assert_eq!(text(&pages[0], "page"), Some("guides/review"));
    assert!(yaml::list("- title: A\n  pages:\n").is_err());
    assert!(yaml::list("title: A\n").is_err());
}

// --- Nightly markers ---

/// Marks docs that describe stable behaviour although they were added since the latest stable
/// release (a fix to how a shipped feature is described). On a line of its own it covers the next
/// heading's section, or the whole page when no heading comes before it; in a table row it covers
/// that row.
const STABLE_MARKER: &str = "<!-- stable -->";

fn git(args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root())
        .args(args)
        .output()
        .map_err(|error| format!("git {}: {error}", args[0]))?;
    if !output.status.success() {
        return Err(format!(
            "git {}: {}",
            args[0],
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// What makes a heading or table row the same one across releases: its anchor, and a row's first
/// cell, ignoring any Nightly note, so rewording or dropping a badge isn't "new".
#[derive(Default)]
struct Keys {
    headings: BTreeSet<String>,
    rows: BTreeSet<String>,
}

fn row_key(line: &str) -> String {
    let cells: Vec<&str> = line.trim().split('|').collect();
    match cells.get(1) {
        Some(cell) => anchor(NIGHTLY_NOTE.replace_all(cell, "").trim()),
        None => String::new(),
    }
}

/// The page body's lines outside code blocks, with their file line numbers.
fn body_lines(src: &str) -> Vec<(usize, String)> {
    let text = src.replace("\r\n", "\n");
    let (body, first) = match split_front_matter(&text) {
        Some((_, body, first)) => (body.to_string(), first),
        None => (text.clone(), 1),
    };
    let mut fence: Option<String> = None;
    let mut lines = Vec::new();
    for (index, line) in body.split('\n').enumerate() {
        if let Some(found) = FENCE.captures(line) {
            let marker = found[1].to_string();
            match &fence {
                None => fence = Some(marker),
                Some(open) if *open == marker => fence = None,
                Some(_) => {}
            }
            continue;
        }
        if fence.is_none() {
            lines.push((index + first, line.to_string()));
        }
    }
    lines
}

fn keys_of(src: &str) -> Keys {
    let mut keys = Keys::default();
    for (_, line) in body_lines(src) {
        if let Some(heading) = HEADING.captures(&line) {
            keys.headings.insert(anchor(&heading[2]));
        } else if TABLE_ROW.is_match(&line) && !TABLE_SEPARATOR.is_match(&line) {
            keys.rows.insert(row_key(&line));
        }
    }
    keys
}

fn nightly_page(src: &str) -> bool {
    let text = src.replace("\r\n", "\n");
    split_front_matter(&text).is_some_and(|(front, _, _)| {
        front
            .lines()
            .any(|line| regex(r"^nightly:\s*true\s*$").is_match(line))
    })
}

/// The headings and table rows of `current` that are not in `old` (the page at the stable tag,
/// None when the page is new) and carry neither a Nightly marker nor [`STABLE_MARKER`].
fn unmarked_since(tag: &str, old: Option<&str>, current: &str) -> Vec<String> {
    if nightly_page(current) {
        return Vec::new();
    }
    let known = old.map(keys_of).unwrap_or_default();
    let mut problems = Vec::new();
    // Each open section's level and whether it is marked.
    let mut stack: Vec<(usize, bool)> = Vec::new();
    let (mut pending, mut page_covered, mut saw_heading) = (false, false, false);
    for (number, line) in body_lines(current) {
        let trimmed = line.trim();
        if trimmed == STABLE_MARKER {
            if saw_heading {
                pending = true;
            } else {
                page_covered = true;
            }
            continue;
        }
        if let Some(heading) = HEADING.captures(&line) {
            saw_heading = true;
            let level = heading[1].len();
            while stack.last().is_some_and(|(open, _)| *open >= level) {
                stack.pop();
            }
            let covered = page_covered || stack.iter().any(|(_, marked)| *marked);
            let text = &heading[2];
            let marked = text.ends_with(" {nightly}") || pending;
            pending = false;
            stack.push((level, marked));
            if old.is_some() && !covered && !marked && !known.headings.contains(&anchor(text)) {
                problems.push(format!(
                    "line {number}: heading {:?} is new since {tag}, the latest stable release, so \
                     it ships only in Nightly: end it with {{nightly}}, or put {STABLE_MARKER} on \
                     the line above if it describes stable behaviour",
                    text.trim()
                ));
            }
            continue;
        }
        let covered = page_covered || stack.iter().any(|(_, marked)| *marked);
        if !trimmed.is_empty() {
            pending = false;
        }
        if old.is_none()
            || covered
            || !TABLE_ROW.is_match(&line)
            || TABLE_SEPARATOR.is_match(&line)
            || NIGHTLY_NOTE.is_match(&line)
            || line.contains(STABLE_MARKER)
            || known.rows.contains(&row_key(&line))
        {
            continue;
        }
        let first_cell = trimmed.split('|').nth(1).unwrap_or_default().trim();
        problems.push(format!(
            "line {number}: table row {first_cell:?} is new since {tag}, the latest stable \
             release, so it ships only in Nightly: start its description with \"Nightly only.\", \
             or add {STABLE_MARKER} to the row if it describes stable behaviour"
        ));
    }
    if old.is_none() && !page_covered {
        problems.push(format!(
            "the page is new since {tag}, the latest stable release, so it ships only in Nightly: \
             set nightly: true in its front matter, or put {STABLE_MARKER} before its first \
             heading if it describes stable behaviour"
        ));
    }
    problems
}

/// Fails when a page, heading or table row added since the latest stable release has no Nightly
/// marker. Everything on master after a stable tag ships only in Nightly until the next stable
/// release, so docs for it are Nightly only until then (docs-site/README.md, "Nightly"). When the
/// release is cut its tag becomes the new baseline and the rule relaxes on its own.
///
/// It needs the tags, which a shallow checkout lacks: then it says so and passes, except where
/// `WORKROOM_DOCS_NIGHTLY_CHECK=1` says the checkout has them (CI's `rust` job, `make
/// docs-check`), where their absence fails it.
#[test]
fn whats_new_since_the_stable_release_is_marked_nightly() {
    if !have_docs() {
        return;
    }
    let tag = match git(&[
        "describe",
        "--tags",
        "--match",
        "v*",
        "--exclude",
        "*-*",
        "--abbrev=0",
        "HEAD",
    ]) {
        Ok(tag) => tag.trim().to_string(),
        Err(why) => {
            assert!(
                std::env::var_os("WORKROOM_DOCS_NIGHTLY_CHECK").is_none_or(|value| value != "1"),
                "no stable release tag to compare the docs with ({why}); check out with tags \
                 (fetch-depth: 0)"
            );
            eprintln!("no stable release tag to compare the docs with, so not checked: {why}");
            return;
        }
    };
    let pages_dir = root().join("pages");
    let mut problems = Vec::new();
    let mut walk = vec![pages_dir.clone()];
    while let Some(folder) = walk.pop() {
        for entry in std::fs::read_dir(&folder).expect("read pages") {
            let path = entry.expect("an entry").path();
            if path.is_dir() {
                walk.push(path);
                continue;
            }
            if path.extension().is_none_or(|extension| extension != "md") {
                continue;
            }
            let rel = path
                .strip_prefix(&pages_dir)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            let current = std::fs::read_to_string(&path).expect("read a page");
            let old = git(&["show", &format!("{tag}:docs-site/pages/{rel}")]).ok();
            for problem in unmarked_since(&tag, old.as_deref(), &current) {
                problems.push(format!("pages/{rel}: {problem}"));
            }
        }
    }
    problems.sort();
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn unmarked_since_finds_new_docs() {
    let front = "---\ntitle: T\ndescription: D.\n---\n\n";
    let old = format!(
        "{front}## Kept\n\n| Name | What |\n| --- | --- |\n| Old (Nightly only) | Was Nightly. |\n"
    );
    let cases: Vec<(&str, Option<&str>, String, Vec<&str>)> = vec![
        ("unchanged", Some(&old), old.clone(), vec![]),
        (
            "a badge dropped at release",
            Some(&old),
            old.replace("Old (Nightly only)", "Old"),
            vec![],
        ),
        (
            "new heading",
            Some(&old),
            format!("{old}\n## Fresh\n"),
            vec![r#"line 12: heading "Fresh""#],
        ),
        (
            "new nightly heading",
            Some(&old),
            format!("{old}\n## Fresh {{nightly}}\n"),
            vec![],
        ),
        (
            "stable escape on a heading",
            Some(&old),
            format!("{old}\n<!-- stable -->\n## Fresh\n"),
            vec![],
        ),
        (
            "escape kept for the next heading only",
            Some(&old),
            format!("{old}\n<!-- stable -->\n\n## Fresh\n\nText.\n\n## Later\n"),
            vec![r#"heading "Later""#],
        ),
        (
            "subsection of a nightly section",
            Some(&old),
            format!("{old}\n## Fresh {{nightly}}\n\n### Detail\n\n| New | x |\n"),
            vec![],
        ),
        (
            "the next sibling is not covered",
            Some(&old),
            format!("{old}\n### Fresh {{nightly}}\n\n## Next\n"),
            vec![r#"heading "Next""#],
        ),
        (
            "new row",
            Some(&old),
            format!("{old}| New | Thing. |\n"),
            vec![r#"line 11: table row "New""#],
        ),
        (
            "new nightly row",
            Some(&old),
            format!("{old}| New | Nightly only. Thing. |\n"),
            vec![],
        ),
        (
            "new stable row",
            Some(&old),
            format!("{old}| New | Thing. <!-- stable --> |\n"),
            vec![],
        ),
        (
            "code blocks are ignored",
            Some(&old),
            format!("{old}\n```md\n## Not a heading\n| no | row |\n```\n"),
            vec![],
        ),
        (
            "new page",
            None,
            format!("{front}## A\n"),
            vec!["the page is new"],
        ),
        (
            "new nightly page",
            None,
            "---\ntitle: T\ndescription: D.\nnightly: true\n---\n\n## A\n".to_string(),
            vec![],
        ),
        (
            "new stable page",
            None,
            format!("{front}<!-- stable -->\n\n## A\n"),
            vec![],
        ),
    ];
    for (name, old, current, want) in cases {
        let got = unmarked_since("v9.9.9", old, &current);
        assert_eq!(got.len(), want.len(), "{name}: {got:?}");
        for (problem, want) in got.iter().zip(want) {
            assert!(problem.contains(want), "{name}: {problem:?} lacks {want:?}");
        }
    }
}
