//! config.json's values, read and written as the Go CLI reads and writes them (ADR 0078), so a
//! file either binary writes is byte for byte what the other would have.
//!
//! Go decodes config.json into `map[string]any` with `UseNumber` and writes it with
//! `json.MarshalIndent(data, "", "  ")`. So here:
//!
//! - A number keeps its text exactly (`2.50`, `-0`, `1E-7`, an integer above 2^64), never a float.
//! - An object's keys come out sorted by their bytes, as Go sorts a map's; a repeated key keeps
//!   its last value, whole.
//! - Each byte of a string that isn't valid UTF-8 reads as its own U+FFFD, and so does a `\u`
//!   escape of a lone surrogate.
//! - Output is indented by two spaces, with `<`, `>`, `&`, U+2028 and U+2029 escaped as
//!   `json.Marshal` escapes them, and no trailing newline.
//!
//! serde_json's own `Value` keeps neither the number text nor Go's handling of bad input, and its
//! `arbitrary_precision` feature would change every other `Value` in the workspace, so the value
//! and its parser are this file's own.

use std::collections::BTreeMap;
use std::io::{self, Write};

use serde::Serialize;
use serde_json::ser::{Formatter, PrettyFormatter};
use serde_json::value::RawValue;

use crate::commands::envelope::GoFormatter;
use crate::commands::log::go_lossy;

/// An object: its members sorted by key, as Go writes a map.
pub(crate) type Object = BTreeMap<String, Json>;

/// One JSON value, as Go's `any` holds it after a `UseNumber` decode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Json {
    Null,
    Bool(bool),
    /// A number's text, exactly as it was written (Go's `json.Number`).
    Number(String),
    String(String),
    Array(Vec<Json>),
    Object(Object),
}

impl Json {
    /// The value as a string, when it is one.
    pub(crate) fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(text) => Some(text),
            _ => None,
        }
    }

    /// The value as an object, when it is one.
    pub(crate) fn as_object(&self) -> Option<&Object> {
        match self {
            Json::Object(object) => Some(object),
            _ => None,
        }
    }

    /// The value as an object to change, when it is one.
    pub(crate) fn as_object_mut(&mut self) -> Option<&mut Object> {
        match self {
            Json::Object(object) => Some(object),
            _ => None,
        }
    }

    /// Go's name for the kind of value, as its "cannot unmarshal" error names it.
    fn go_kind(&self) -> &'static str {
        match self {
            Json::Null => "null",
            Json::Bool(_) => "bool",
            Json::Number(_) => "number",
            Json::String(_) => "string",
            Json::Array(_) => "array",
            Json::Object(_) => "object",
        }
    }
}

impl Serialize for Json {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Json::Null => serializer.serialize_unit(),
            Json::Bool(value) => serializer.serialize_bool(*value),
            // Its own text, as Go writes a json.Number. The parser let only valid numbers in.
            Json::Number(text) => RawValue::from_string(text.clone())
                .map_err(serde::ser::Error::custom)?
                .serialize(serializer),
            Json::String(text) => serializer.serialize_str(text),
            Json::Array(items) => items.serialize(serializer),
            Json::Object(members) => members.serialize(serializer),
        }
    }
}

/// config.json's top level: an object, or `null`, which Go reads as a nil map. Go writes a nil map
/// back as `null`, so a write that changes nothing in it does too.
pub(crate) fn parse_config(bytes: &[u8]) -> Result<Json, String> {
    let mut parser = Parser { bytes, at: 0 };
    parser.skip_whitespace();
    if parser.at == bytes.len() {
        return Err("EOF".to_string());
    }
    let value = parser.value(0)?;
    // A second value must not follow, as the CLI's second Decode must hit EOF: `{}}` would
    // otherwise let the next write silently drop the tail.
    parser.skip_whitespace();
    if parser.at != bytes.len() {
        return Err("unexpected data after the config object".to_string());
    }
    match value {
        Json::Object(_) | Json::Null => Ok(value),
        other => Err(format!(
            "json: cannot unmarshal {} into Go value of type map[string]interface {{}}",
            other.go_kind()
        )),
    }
}

/// `value` as `json.MarshalIndent(value, "", "  ")` writes it.
pub(crate) fn write_indented(value: &Json) -> String {
    let mut out = Vec::new();
    let mut serializer = serde_json::Serializer::with_formatter(&mut out, IndentFormatter::new());
    value
        .serialize(&mut serializer)
        .expect("a parsed value always serializes");
    String::from_utf8(out).expect("serde_json writes UTF-8")
}

/// How deeply objects and arrays may nest: deeper input is an error, not a stack overflow. Go allows
/// 10,000 (an object holding 9,999 nested arrays reads; 10,000 fails), which this recursive parser (and serde's recursive writer) can't reach in a debug build's
/// 8 MiB main stack; a config nested a thousand deep is no config the app or a person writes, so
/// this one difference from Go is kept rather than parsing on a stack of its own.
const MAX_DEPTH: usize = 1_000;

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Parser<'_> {
    fn skip_whitespace(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.bytes.get(self.at) {
            self.at += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    /// Go's message for the character at the cursor, in `context`; "unexpected EOF" at the end.
    fn invalid(&self, context: &str) -> String {
        if self.at >= self.bytes.len() {
            return "unexpected EOF".to_string();
        }
        format!(
            "invalid character {} {context}",
            quote_char(&self.bytes[self.at..])
        )
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        self.skip_whitespace();
        match self.peek() {
            Some(b'{') => self.object(depth + 1),
            Some(b'[') => self.array(depth + 1),
            Some(b'"') => self.string().map(Json::String),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            _ => Err(self.invalid("looking for beginning of value")),
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err("exceeded max depth".to_string());
        }
        self.at += 1;
        let mut members = Object::new();
        self.skip_whitespace();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Ok(Json::Object(members));
        }
        loop {
            self.skip_whitespace();
            if self.peek() != Some(b'"') {
                return Err(self.invalid("looking for beginning of object key string"));
            }
            let key = self.string()?;
            self.skip_whitespace();
            if self.peek() != Some(b':') {
                return Err(self.invalid("after object key"));
            }
            self.at += 1;
            let value = self.value(depth)?;
            // A repeated key keeps its last value, whole, as Go's map assignment does.
            members.insert(key, value);
            self.skip_whitespace();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    return Ok(Json::Object(members));
                }
                _ => return Err(self.invalid("after object key:value pair")),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err("exceeded max depth".to_string());
        }
        self.at += 1;
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.value(depth)?);
            self.skip_whitespace();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    return Ok(Json::Array(items));
                }
                _ => return Err(self.invalid("after array element")),
            }
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Result<Json, String> {
        for (index, expected) in word.bytes().enumerate() {
            if self.peek() != Some(expected) {
                if index == 0 {
                    return Err(self.invalid("looking for beginning of value"));
                }
                return Err(self.invalid(&format!(
                    "in literal {word} (expecting {})",
                    quote_char(&[expected])
                )));
            }
            self.at += 1;
        }
        Ok(value)
    }

    /// A number, by JSON's grammar, kept as its text.
    fn number(&mut self) -> Result<Json, String> {
        let start = self.at;
        let digits = |parser: &mut Parser<'_>| {
            let from = parser.at;
            while let Some(b'0'..=b'9') = parser.peek() {
                parser.at += 1;
            }
            parser.at > from
        };
        if self.peek() == Some(b'-') {
            self.at += 1;
        }
        match self.peek() {
            Some(b'0') => self.at += 1,
            Some(b'1'..=b'9') => {
                digits(self);
            }
            _ => return Err(self.invalid("in numeric literal")),
        }
        if self.peek() == Some(b'.') {
            self.at += 1;
            if !digits(self) {
                return Err(self.invalid("in numeric literal"));
            }
        }
        if let Some(b'e' | b'E') = self.peek() {
            self.at += 1;
            if let Some(b'+' | b'-') = self.peek() {
                self.at += 1;
            }
            if !digits(self) {
                return Err(self.invalid("in numeric literal"));
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.at]).expect("ASCII digits");
        Ok(Json::Number(text.to_string()))
    }

    /// A string, its escapes decoded, as Go decodes one.
    fn string(&mut self) -> Result<String, String> {
        self.at += 1;
        let mut text = String::new();
        // Raw bytes since the last escape, decoded together so each bad byte is one U+FFFD.
        let mut run = self.at;
        loop {
            let Some(byte) = self.peek() else {
                return Err("unexpected EOF".to_string());
            };
            match byte {
                b'"' => {
                    text.push_str(&go_lossy(&self.bytes[run..self.at]));
                    self.at += 1;
                    return Ok(text);
                }
                b'\\' => {
                    text.push_str(&go_lossy(&self.bytes[run..self.at]));
                    self.escape(&mut text)?;
                    run = self.at;
                }
                0x00..=0x1f => return Err(self.invalid("in string")),
                _ => self.at += 1,
            }
        }
    }

    /// The escape at the cursor (its backslash), appended to `text`.
    fn escape(&mut self, text: &mut String) -> Result<(), String> {
        let decoded = match self.bytes.get(self.at + 1) {
            Some(b'"') => '"',
            Some(b'\\') => '\\',
            Some(b'/') => '/',
            Some(b'b') => '\u{8}',
            Some(b'f') => '\u{c}',
            Some(b'n') => '\n',
            Some(b'r') => '\r',
            Some(b't') => '\t',
            Some(b'u') => {
                let Some(unit) = self.hex4(self.at + 2) else {
                    return Err(self.bad_escape(6));
                };
                self.at += 6;
                text.push(self.code_point(unit));
                return Ok(());
            }
            None => return Err("unexpected EOF".to_string()),
            Some(_) => return Err(self.bad_escape(2)),
        };
        self.at += 2;
        text.push(decoded);
        Ok(())
    }

    /// The character a `\u` escape of `unit` means: a surrogate pairs with a `\u` escape right
    /// after it, which is then consumed too, and is U+FFFD without one.
    fn code_point(&mut self, unit: u32) -> char {
        if !(0xd800..0xe000).contains(&unit) {
            return char::from_u32(unit).expect("not a surrogate");
        }
        if (0xd800..0xdc00).contains(&unit)
            && self.bytes.get(self.at) == Some(&b'\\')
            && self.bytes.get(self.at + 1) == Some(&b'u')
            && let Some(low @ 0xdc00..0xe000) = self.hex4(self.at + 2)
        {
            self.at += 6;
            let combined = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
            return char::from_u32(combined).expect("a valid pair");
        }
        '\u{fffd}'
    }

    /// The four hex digits at `at`, when they are.
    fn hex4(&self, at: usize) -> Option<u32> {
        let digits = self.bytes.get(at..at + 4)?;
        let text = std::str::from_utf8(digits).ok()?;
        if !text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        u32::from_str_radix(text, 16).ok()
    }

    /// Go's message for a bad escape: the escape as written, up to `len` bytes.
    fn bad_escape(&self, len: usize) -> String {
        if self.at + 2 > self.bytes.len() {
            return "unexpected EOF".to_string();
        }
        let end = (self.at + len).min(self.bytes.len());
        format!(
            "invalid escape sequence `{}` in string",
            go_lossy(&self.bytes[self.at..end])
        )
    }
}

/// The character at the start of `bytes` quoted as Go's JSON errors quote one: `'x'`, or an
/// escape for a control or invisible character.
fn quote_char(bytes: &[u8]) -> String {
    let first = go_lossy(&bytes[..bytes.len().min(4)]);
    let ch = first.chars().next().unwrap_or('\u{fffd}');
    let quoted = match ch {
        '\'' => "\\'".to_string(),
        '\u{7}' => "\\a".to_string(),
        '\u{8}' => "\\b".to_string(),
        '\u{c}' => "\\f".to_string(),
        '\n' => "\\n".to_string(),
        '\r' => "\\r".to_string(),
        '\t' => "\\t".to_string(),
        '\u{b}' => "\\v".to_string(),
        '\u{0}'..='\u{1f}' | '\u{7f}' => format!("\\x{:02x}", ch as u32),
        '\u{80}'..='\u{9f}' | '\u{ad}' | '\u{200b}'..='\u{200f}' | '\u{2028}'..='\u{202e}' => {
            format!("\\u{:04x}", ch as u32)
        }
        '\u{2060}'..='\u{206f}' | '\u{feff}' | '\u{fff9}'..='\u{fffb}' => {
            format!("\\u{:04x}", ch as u32)
        }
        _ => ch.to_string(),
    };
    format!("'{quoted}'")
}

/// serde_json's two-space pretty output, which lays a value out as Go's `MarshalIndent` does,
/// with `json.Marshal`'s string escapes.
struct IndentFormatter {
    pretty: PrettyFormatter<'static>,
    escapes: GoFormatter,
}

impl IndentFormatter {
    fn new() -> IndentFormatter {
        IndentFormatter {
            pretty: PrettyFormatter::with_indent(b"  "),
            escapes: GoFormatter { escape_html: true },
        }
    }
}

impl Formatter for IndentFormatter {
    fn write_string_fragment<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        fragment: &str,
    ) -> io::Result<()> {
        self.escapes.write_string_fragment(writer, fragment)
    }

    fn begin_array<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.begin_array(writer)
    }

    fn end_array<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.end_array(writer)
    }

    fn begin_array_value<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.pretty.begin_array_value(writer, first)
    }

    fn end_array_value<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.end_array_value(writer)
    }

    fn begin_object<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.begin_object(writer)
    }

    fn end_object<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.end_object(writer)
    }

    fn begin_object_key<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.pretty.begin_object_key(writer, first)
    }

    fn begin_object_value<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.begin_object_value(writer)
    }

    fn end_object_value<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.pretty.end_object_value(writer)
    }
}

#[cfg(test)]
mod tests;
