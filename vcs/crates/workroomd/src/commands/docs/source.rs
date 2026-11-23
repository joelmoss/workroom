//! Reading the daemon's own source, for the parts of the Reference pages no registry holds: the
//! requests a service dispatches, the fields of the types it reads and writes, the constants its
//! limits are, and the kinds a handler replies with. The pages are generated from these, or
//! tested against them, so a change there shows up here.
//!
//! These read Rust as text, not as a parser would, so they hold to the shapes the daemon is
//! written in; each panics, naming what it looked for, when the source no longer has it.

/// Every double-quoted string in `text`.
pub(super) fn literals(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('"') {
        let after = &rest[open + 1..];
        let Some(close) = after.find('"') else { break };
        out.push(after[..close].to_string());
        rest = &after[close + 1..];
    }
    out
}

/// The text of the first `fn name` in `source`: from its line to the `}` that closes it, the
/// next one indented as its line is.
pub(super) fn function<'a>(source: &'a str, name: &str) -> &'a str {
    let head = source
        .find(&format!("fn {name}("))
        .unwrap_or_else(|| panic!("no fn {name} in the source the docs read"));
    let start = source[..head].rfind('\n').map_or(0, |newline| newline + 1);
    let indent: String = source[start..].chars().take_while(|c| *c == ' ').collect();
    let end = source[start..]
        .find(&format!("\n{indent}}}\n"))
        .map_or(source.len(), |end| start + end);
    &source[start..end]
}

/// `source` with what is no code blanked out, byte for byte, so offsets and lines stay: the
/// insides of strings, raw strings and char literals, comments, and anything not ASCII.
pub(super) fn blanked(source: &str) -> Vec<u8> {
    let bytes = source.as_bytes();
    let mut out = bytes.to_vec();
    let blank = |out: &mut Vec<u8>, range: std::ops::Range<usize>| {
        for byte in &mut out[range] {
            if *byte != b'\n' {
                *byte = b' ';
            }
        }
    };
    let mut index = 0;
    while index < bytes.len() {
        let rest = &bytes[index..];
        if rest.starts_with(b"//") {
            let end = source[index..]
                .find('\n')
                .map_or(bytes.len(), |end| index + end);
            blank(&mut out, index..end);
            index = end;
        } else if rest.starts_with(b"r#\"") {
            let end = source[index + 3..]
                .find("\"#")
                .map_or(bytes.len(), |end| index + 3 + end);
            blank(&mut out, index + 3..end);
            index = end + 2;
        } else if rest[0] == b'"' {
            let mut end = index + 1;
            while end < bytes.len() && bytes[end] != b'"' {
                end += if bytes[end] == b'\\' { 2 } else { 1 };
            }
            blank(&mut out, index + 1..end.min(bytes.len()));
            index = end + 1;
        } else if rest[0] == b'\'' && rest.get(2) == Some(&b'\'') {
            blank(&mut out, index + 1..index + 2);
            index += 3;
        } else {
            if !rest[0].is_ascii() {
                out[index] = b' ';
            }
            index += 1;
        }
    }
    out
}

/// Where the brace at `open` in blanked `code` is closed.
fn closing(code: &[u8], open: usize) -> usize {
    let mut depth = 0usize;
    (open..code.len())
        .find(|&index| {
            match code[index] {
                b'{' => depth += 1,
                b'}' => depth -= 1,
                _ => return false,
            }
            depth == 0
        })
        .expect("a block that ends")
}

/// Each `match` on `scrutinee` in `source`: the text inside its braces.
pub(super) fn match_blocks<'a>(source: &'a str, scrutinee: &str) -> Vec<&'a str> {
    let code = blanked(source);
    let head = format!("match {scrutinee}");
    let mut blocks = Vec::new();
    let mut from = 0;
    while let Some(found) = source[from..].find(&head) {
        let at = from + found + head.len();
        from = at;
        // The scrutinee may go on (`.and_then(…)`): the block is the brace that ends its line.
        let line_end = source[at..].find('\n').map_or(source.len(), |end| at + end);
        let Some(open) = code[at..line_end]
            .iter()
            .rposition(|byte| *byte == b'{')
            .map(|brace| at + brace)
        else {
            continue;
        };
        blocks.push(&source[open + 1..closing(&code, open)]);
    }
    blocks
}

/// The strings an arm's pattern names, in each arm at the block's top level: the lines that
/// start at its depth and hold `=>` in code, without a guard (`"x" if working`).
pub(super) fn arm_methods(block: &str) -> Vec<String> {
    let code = blanked(block);
    let mut depth = 0i32;
    let mut methods = Vec::new();
    let mut start = 0;
    for line in block.split_inclusive('\n') {
        let line_code = &code[start..start + line.len()];
        start += line.len();
        let arrow = line_code.windows(2).position(|pair| pair == b"=>");
        if depth == 0
            && let Some(arrow) = arrow
        {
            let pattern = line_code[..arrow]
                .windows(4)
                .position(|word| word == b" if ")
                .unwrap_or(arrow);
            methods.extend(literals(&line[..pattern]));
        }
        for byte in line_code {
            match byte {
                b'{' | b'(' | b'[' => depth += 1,
                b'}' | b')' | b']' => depth -= 1,
                _ => {}
            }
        }
    }
    methods
}

/// The names `struct name`'s fields have on the wire: each field's own, or its serde `rename`.
pub(super) fn struct_fields(source: &str, name: &str) -> Vec<String> {
    let code = blanked(source);
    let head = source
        .find(&format!("struct {name} {{"))
        .or_else(|| source.find(&format!("struct {name}<'a> {{")))
        .unwrap_or_else(|| panic!("no struct {name} in the source the docs read"));
    let open = head + source[head..].find('{').expect("a brace");
    let body = &source[open + 1..closing(&code, open)];
    let mut fields = Vec::new();
    let mut rename: Option<String> = None;
    for line in body.lines().map(str::trim) {
        if line.starts_with("#[serde(") {
            if let Some(at) = line.find("rename = \"") {
                let rest = &line[at + "rename = \"".len()..];
                rename = rest.split('"').next().map(str::to_string);
            }
            continue;
        }
        if line.starts_with("//") || line.is_empty() {
            continue;
        }
        let line = line.strip_prefix("pub ").unwrap_or(line);
        if let Some((field, _)) = line.split_once(':')
            && field.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            fields.push(rename.take().unwrap_or_else(|| field.to_string()));
        }
    }
    fields
}

/// The value of `const name` in `source`, as a number: a literal (`10_000`), a product
/// (`16 * 1024 * 1024`), a shift (`1 << 20`), or `Duration::from_secs(n)` in seconds.
pub(super) fn constant(source: &str, name: &str) -> u64 {
    let head = format!("const {name}: ");
    let at = source
        .find(&head)
        .unwrap_or_else(|| panic!("no const {name} in the source the docs read"));
    let rest = &source[at..];
    let value = rest[rest.find('=').expect("a value") + 1..rest.find(';').expect("an end")].trim();
    evaluate(value).unwrap_or_else(|| panic!("const {name} = {value}: not a value the docs read"))
}

fn evaluate(expression: &str) -> Option<u64> {
    let expression = expression.trim();
    if let Some(inner) = expression
        .strip_prefix("Duration::from_secs(")
        .and_then(|rest| rest.strip_suffix(')'))
    {
        return evaluate(inner);
    }
    if let Some((left, right)) = expression.split_once("<<") {
        return Some(evaluate(left)? << evaluate(right)?);
    }
    if expression.contains('*') {
        return expression
            .split('*')
            .map(evaluate)
            .try_fold(1u64, |product, factor| Some(product * factor?));
    }
    expression.replace('_', "").parse().ok()
}

/// The keys of the `json!` object in `source` that holds `anchor`, such as `"event":
/// name::SNAPSHOT_COMPLETE`.
pub(super) fn json_keys(source: &str, anchor: &str) -> Vec<String> {
    let code = blanked(source);
    let at = source
        .find(anchor)
        .unwrap_or_else(|| panic!("no {anchor} in the source the docs read"));
    let open = source[..at].rfind("json!({").expect("a json! object") + "json!(".len();
    let object = &source[open + 1..closing(&code, open)];
    let object_code = blanked(object);
    let mut keys = Vec::new();
    let mut depth = 0i32;
    let mut index = 0;
    while index < object.len() {
        match object_code[index] {
            b'{' | b'[' | b'(' => depth += 1,
            b'}' | b']' | b')' => depth -= 1,
            b'"' if depth == 0 => {
                let end = index + 1 + object[index + 1..].find('"').expect("a string's end");
                if object[end + 1..].trim_start().starts_with(':') {
                    keys.push(object[index + 1..end].to_string());
                }
                index = end;
            }
            _ => {}
        }
        index += 1;
    }
    keys
}

/// The error codes `text` names as `kind::NAME`, as the registry spells them.
pub(super) fn kinds_in(text: &str) -> Vec<String> {
    let pattern = regex::Regex::new(r"\bkind::([A-Z][A-Z_]+)\b").expect("a pattern");
    let code = String::from_utf8(blanked(text)).expect("ASCII");
    pattern
        .captures_iter(&code)
        .map(|found| {
            found[1]
                .split('_')
                .map(|word| {
                    let mut letters = word.chars();
                    letters.next().map_or(String::new(), |first| {
                        first.to_string() + &letters.as_str().to_lowercase()
                    })
                })
                .collect()
        })
        .collect()
}

/// A command line split as a POSIX shell splits it: quotes and backslashes.
pub(super) fn shell_words(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_word = true;
                for c in chars.by_ref() {
                    if c == '\'' {
                        break;
                    }
                    word.push(c);
                }
            }
            '"' => {
                in_word = true;
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => word.extend(chars.next()),
                        c => word.push(c),
                    }
                }
            }
            '\\' => {
                in_word = true;
                word.extend(chars.next());
            }
            c if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            c => {
                in_word = true;
                word.push(c);
            }
        }
    }
    if in_word {
        words.push(word);
    }
    words
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arms_are_read_from_a_match() {
        let source = "fn f() {\n    match request.method.as_str() {\n        \"a\" => x,\n        \
                      \"b\" if y => {\n            match z { \"inner\" => 1 }\n        }\n        \
                      _ => return Err(r#\"{\"method\": \"no\"}\"#),\n    }\n}\n";
        let blocks = match_blocks(source, "request.method.as_str()");
        assert_eq!(blocks.len(), 1);
        assert_eq!(arm_methods(blocks[0]), ["a", "b"]);
    }

    #[test]
    fn the_source_is_read_as_written() {
        let source = "struct R {\n    version: u32,\n    #[serde(default, rename = \"shared_root\")]\n    \
                      _shared_root: Option<String>,\n    /// a: b\n    pub path: String,\n}\n\
                      const A: usize = 16 * 1024 * 1024;\nconst B: Duration = Duration::from_secs(60);\n\
                      const C: usize = 1 << 20;\nconst D: usize = 10_000;\n\
                      fn e() { json!({\"event\": \"x\", \"n\": {\"inner\": 1}, \"m\": f(\"y\")}) }\n";
        assert_eq!(
            struct_fields(source, "R"),
            ["version", "shared_root", "path"]
        );
        assert_eq!(
            [
                constant(source, "A"),
                constant(source, "B"),
                constant(source, "C"),
                constant(source, "D")
            ],
            [16 << 20, 60, 1 << 20, 10_000]
        );
        assert_eq!(json_keys(source, "\"event\": \"x\""), ["event", "n", "m"]);
        assert_eq!(
            kinds_in("kind::NOT_A_RUN, kind::TOO_LARGE // kind::BUSY"),
            ["NotARun", "TooLarge"]
        );
        assert_eq!(
            shell_words(r#"workroom wait "dev server" --regex 'ready in \d+ ms' a\ b"#),
            [
                "workroom",
                "wait",
                "dev server",
                "--regex",
                r"ready in \d+ ms",
                "a b"
            ]
        );
    }
}
