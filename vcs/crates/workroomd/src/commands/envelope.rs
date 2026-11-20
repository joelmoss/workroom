//! ADR 0013's `--json` contract: exactly one envelope on stdout, encoded byte for byte as the Go
//! CLI encodes it, so the app's decoders and users' scripts see no difference (ADR 0078).
//!
//! Go's `encoding/json` and serde_json agree on most of a string's escapes. Where they differ, this
//! follows Go: U+2028 and U+2029 are always escaped, and with HTML escaping on (`json.Marshal`,
//! which the NDJSON logs and config.json use) `<`, `>` and `&` are too. The envelope's encoder turns
//! HTML escaping off, as Go's `encodeJSON` does.

use std::io::{self, Write};

use serde::Serialize;
use serde_json::value::RawValue;

use super::kind::CliError;
use super::trusted_script::ScriptPayload;

/// The `--json` contract's version. Bumped only for a breaking change (ADR 0013); a new field or a
/// new `kind` is additive.
pub(crate) const SCHEMA_VERSION: u32 = 1;

/// serde_json's compact output, with Go's escapes where they differ (see the module docs).
#[derive(Clone, Copy)]
pub(crate) struct GoFormatter {
    /// Escape `<`, `>` and `&` too, as `json.Marshal` does and Go's envelope encoder doesn't.
    pub(crate) escape_html: bool,
}

impl serde_json::ser::Formatter for GoFormatter {
    fn write_string_fragment<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        fragment: &str,
    ) -> io::Result<()> {
        let mut start = 0;
        for (index, ch) in fragment.char_indices() {
            let escape = match ch {
                '\u{2028}' => "\\u2028",
                '\u{2029}' => "\\u2029",
                '<' if self.escape_html => "\\u003c",
                '>' if self.escape_html => "\\u003e",
                '&' if self.escape_html => "\\u0026",
                _ => continue,
            };
            writer.write_all(&fragment.as_bytes()[start..index])?;
            writer.write_all(escape.as_bytes())?;
            start = index + ch.len_utf8();
        }
        writer.write_all(&fragment.as_bytes()[start..])
    }
}

/// `value` as one line of JSON, encoded as Go does, without the newline.
pub(crate) fn encode<T: Serialize + ?Sized>(value: &T, escape_html: bool) -> String {
    let mut out = Vec::new();
    let mut serializer =
        serde_json::Serializer::with_formatter(&mut out, GoFormatter { escape_html });
    value
        .serialize(&mut serializer)
        .expect("a command's payload always serializes");
    String::from_utf8(out).expect("serde_json writes UTF-8")
}

/// The success envelope for `command`: `ok`, `schema_version`, `cli_version` and `command`, then
/// the payload's own fields, every key sorted as Go's map encoding sorts them. Each field's value
/// keeps the payload's own encoding, so a nested object keeps its declared key order.
pub(crate) fn success<T: Serialize>(command: &str, payload: &T) -> String {
    let fields: std::collections::BTreeMap<String, Box<RawValue>> =
        serde_json::from_str(&encode(payload, false)).expect("a payload is a JSON object");
    let mut envelope = fields;
    for (key, value) in [
        ("ok", "true".to_string()),
        ("schema_version", SCHEMA_VERSION.to_string()),
        ("cli_version", encode(super::VERSION, false)),
        ("command", encode(command, false)),
    ] {
        envelope.insert(
            key.to_string(),
            RawValue::from_string(value).expect("an envelope field is JSON"),
        );
    }
    let mut line = encode(&envelope, false);
    line.push('\n');
    line
}

/// The error envelope: `error`'s `kind` and `message`, and `command` when the failure happened in
/// one (Go leaves it out for a failure parsing the command line).
pub(crate) fn failure(command: Option<&str>, error: &CliError) -> String {
    #[derive(Serialize)]
    struct Body<'a> {
        kind: &'a str,
        message: &'a str,
        /// An ambiguous terminal API target's matches; left out otherwise, as Go has no such field.
        #[serde(skip_serializing_if = "<[_]>::is_empty")]
        matches: &'a [serde_json::Value],
    }
    #[derive(Serialize)]
    struct Envelope<'a> {
        cli_version: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        command: Option<&'a str>,
        error: Body<'a>,
        ok: bool,
        schema_version: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        script: Option<&'a ScriptPayload>,
    }
    let mut line = encode(
        &Envelope {
            cli_version: super::VERSION,
            command,
            error: Body {
                kind: error.kind.code(),
                message: &error.message,
                matches: &error.matches,
            },
            ok: false,
            schema_version: SCHEMA_VERSION,
            script: error.script.as_deref(),
        },
        false,
    );
    line.push('\n');
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_are_escaped_as_go_escapes_them() {
        let text = "<&>\u{2028}\u{2029}\u{1}\u{8}\u{c}\n\r\t\u{1f}\u{7f}\"\\/é";
        // What Go 1.27's encoder (SetEscapeHTML(false)) writes for it.
        let go = concat!(
            r#""<&>"#,
            "\\u2028\\u2029\\u0001\\b\\f\\n\\r\\t\\u001f",
            "\u{7f}",
            r#"\"\\/é""#
        );
        assert_eq!(encode(text, false), go);
        // json.Marshal also escapes HTML.
        assert_eq!(encode("<a>&", true), "\"\\u003ca\\u003e\\u0026\"");
    }

    #[test]
    fn a_success_envelope_sorts_its_keys_but_not_a_nested_objects() {
        #[derive(Serialize)]
        struct Nested {
            zebra: u8,
            apple: u8,
        }
        #[derive(Serialize)]
        struct Payload {
            version: &'static str,
            nested: Nested,
        }
        let line = success(
            "test",
            &Payload {
                version: "x",
                nested: Nested { zebra: 1, apple: 2 },
            },
        );
        assert_eq!(
            line,
            format!(
                "{{\"cli_version\":{},\"command\":\"test\",\"nested\":{{\"zebra\":1,\"apple\":2}},\
                 \"ok\":true,\"schema_version\":1,\"version\":\"x\"}}\n",
                encode(super::super::VERSION, false)
            )
        );
    }

    #[test]
    fn an_error_envelope_leaves_out_a_missing_command() {
        let error = CliError::internal("bad");
        let without = failure(None, &error);
        assert!(!without.contains("\"command\""), "{without}");
        let with = failure(Some("list"), &error);
        assert!(
            with.contains(
                r#""command":"list","error":{"kind":"InternalError","message":"bad"},"ok":false"#
            ),
            "{with}"
        );
    }
}
