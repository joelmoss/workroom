//! A `settings.json` rewritten as its user wrote it, but for its `hooks` (#828). serde_json's
//! `Value` keeps no key order (the workspace has no `preserve_order`, which would change every
//! other JSON Workroom writes), so the file is not written from one. Instead its top level is read
//! in order, each member's value as the raw text it was (`RawValue`), and only the `hooks` value
//! is put in its place: replaced, added after the last member, or taken out with its comma.
//! Every other byte stays as it was, and an install then a remove gives back the file's own bytes.
//! The `hooks` value itself is written from a `Value`, in the file's indent (a one-line file stays
//! on one line), so the keys inside it come out sorted.

use std::ops::Range;

use serde::Serialize;
use serde::de::{Deserialize, Deserializer, MapAccess, Visitor};
use serde_json::Value;
use serde_json::ser::{PrettyFormatter, Serializer};
use serde_json::value::RawValue;

/// The key this rewrites.
const HOOKS: &str = "hooks";

/// One member of the top-level object: where its key starts and its value's span, in the text.
struct Member {
    key: String,
    start: usize,
    value: Range<usize>,
}

/// The top-level object's members, in the order written, each value as its raw text.
struct Members<'a>(Vec<(String, &'a RawValue)>);

impl<'de> Deserialize<'de> for Members<'de> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Ordered;
        impl<'de> Visitor<'de> for Ordered {
            type Value = Members<'de>;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a JSON object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut members = Vec::new();
                while let Some(member) = map.next_entry::<String, &'de RawValue>()? {
                    members.push(member);
                }
                Ok(Members(members))
            }
        }
        deserializer.deserialize_map(Ordered)
    }
}

fn is_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r')
}

/// The leading spaces and tabs of the line `at` is on.
fn line_indent(text: &str, at: usize) -> &str {
    let start = text[..at].rfind('\n').map_or(0, |newline| newline + 1);
    let line = &text[start..at];
    &line[..line.len() - line.trim_start_matches([' ', '\t']).len()]
}

/// The top-level object's span in `text` and its members, from text that parsed as an object.
fn read(text: &str) -> Option<(Range<usize>, Vec<Member>)> {
    let bytes = text.as_bytes();
    let open = bytes.iter().position(|byte| !is_space(*byte))?;
    let close = bytes.iter().rposition(|byte| !is_space(*byte))?;
    if bytes[open] != b'{' || bytes[close] != b'}' {
        return None;
    }
    let object = &text[open..=close];
    let Members(raw) = serde_json::from_str(object).ok()?;
    let base = text.as_ptr() as usize;
    let mut members = Vec::with_capacity(raw.len());
    let mut after = open + 1;
    for (key, value) in raw {
        let value_start = value.get().as_ptr() as usize - base;
        let value = value_start..value_start + value.get().len();
        // The key starts at the first quote past the last value (or `{`), its comma and spaces.
        let start = after + text[after..value.start].find('"')?;
        after = value.end;
        members.push(Member { key, start, value });
    }
    Some((open..close + 1, members))
}

/// Where the key string that starts at `start` ends, past its closing quote.
fn key_end(text: &str, start: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut at = start + 1;
    while *bytes.get(at)? != b'"' {
        at += if bytes[at] == b'\\' { 2 } else { 1 };
    }
    Some(at + 1)
}

/// `value` as JSON: on one line with no `unit`, else indented by `unit` with each line after the
/// first starting with `indent`, the indent of the line it starts on.
fn render(value: &Value, unit: Option<&str>, indent: &str) -> Option<String> {
    let Some(unit) = unit else {
        return serde_json::to_string(value).ok();
    };
    let mut bytes = Vec::new();
    let mut serializer =
        Serializer::with_formatter(&mut bytes, PrettyFormatter::with_indent(unit.as_bytes()));
    value.serialize(&mut serializer).ok()?;
    // A newline in a string is escaped, so each one here is between two lines.
    Some(
        String::from_utf8(bytes)
            .ok()?
            .replace('\n', &format!("\n{indent}")),
    )
}

/// `text`, a JSON object, with its `hooks` member's value made `hooks` (`None`: taken out),
/// everything else as it was. `None` when it can't be read as one.
pub(super) fn with_hooks(text: &str, hooks: Option<&Value>) -> Option<String> {
    let (object, members) = read(text)?;
    let open = object.start;
    let close = object.end - 1;
    // The file's own style, from the space before its first key: on one line, or a line each.
    let style = members.first().map(|first| {
        let lead = &text[open + 1..first.start];
        lead.rfind('\n').map(|newline| {
            let indent = &lead[newline + 1..];
            let unit = indent
                .strip_prefix(line_indent(text, open))
                .unwrap_or(indent);
            (unit, indent)
        })
    });
    let found = members.iter().rposition(|member| member.key == HOOKS);
    let (span, new) = match (found, hooks) {
        (Some(at), Some(hooks)) => {
            let value = members[at].value.clone();
            let unit = style.flatten().map(|(unit, _)| unit);
            let indent = line_indent(text, members[at].start);
            (value, render(hooks, unit, indent)?)
        }
        (Some(at), None) => {
            let span = if members.len() == 1 {
                open..close + 1
            } else if at + 1 == members.len() {
                members[at - 1].value.end..members[at].value.end
            } else {
                members[at].start..members[at + 1].start
            };
            let new = if members.len() == 1 { "{}" } else { "" };
            (span, new.to_string())
        }
        (None, Some(hooks)) => match (members.last(), style) {
            (Some(last), Some(style)) => {
                // After the last member, as the one before it is after its own.
                let separator = if members.len() > 1 {
                    text[members[members.len() - 2].value.end..last.start].to_string()
                } else {
                    format!(",{}", &text[open + 1..last.start])
                };
                let colon = &text[key_end(text, last.start)?..last.value.start];
                let (unit, indent) = style.unzip();
                let indent = indent.unwrap_or("");
                let value = render(hooks, unit, indent)?;
                let end = last.value.end;
                (end..end, format!("{separator}\"{HOOKS}\"{colon}{value}"))
            }
            // An empty object: written as Claude writes one, two spaces a level.
            _ => {
                let indent = line_indent(text, open);
                let value = render(hooks, Some("  "), &format!("{indent}  "))?;
                (
                    open..close + 1,
                    format!("{{\n{indent}  \"{HOOKS}\": {value}\n{indent}}}"),
                )
            }
        },
        (None, None) => return Some(text.to_string()),
    };
    Some(format!("{}{new}{}", &text[..span.start], &text[span.end..]))
}
