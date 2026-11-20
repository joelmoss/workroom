use super::*;

/// What Go's `base clear --global` (a read and an unchanged write) leaves of `input`, by the Go
/// CLI built from this tree: Ok with the file written, or Err with the read error.
fn rewrite(input: &[u8]) -> Result<String, String> {
    parse_config(input).map(|value| write_indented(&value))
}

fn golden(file: &str) -> String {
    let path = format!(
        "{}/../../../testdata/contracts/{file}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("read {path}: {error}"))
}

#[test]
fn the_round_trip_golden_is_what_go_writes() {
    let mut value = parse_config(golden("config-roundtrip-before.json").as_bytes()).unwrap();
    value
        .as_object_mut()
        .unwrap()
        .insert("base_branch".to_string(), Json::String("main".to_string()));
    assert_eq!(
        write_indented(&value),
        golden("config-roundtrip-after.json")
    );
}

#[test]
fn layout_is_go_marshal_indents() {
    assert_eq!(
        rewrite(br#"{"a" : [ 1 , 2 ] }"#).unwrap(),
        "{\n  \"a\": [\n    1,\n    2\n  ]\n}"
    );
    assert_eq!(
        rewrite(br#"{"a":{"b":{}},"c":[{}],"d":[1,[2]]}"#).unwrap(),
        "{\n  \"a\": {\n    \"b\": {}\n  },\n  \"c\": [\n    {}\n  ],\n  \"d\": [\n    1,\n    [\n      2\n    ]\n  ]\n}"
    );
    assert_eq!(rewrite(b"{}  \n").unwrap(), "{}");
}

#[test]
fn null_reads_as_a_nil_map_and_writes_back_as_null() {
    assert_eq!(rewrite(b"null").unwrap(), "null");
}

#[test]
fn a_repeated_key_keeps_its_last_value_whole() {
    assert_eq!(
        rewrite(br#"{"a":{"x":1},"a":{"y":2},"n":[1],"n":[2,3]}"#).unwrap(),
        "{\n  \"a\": {\n    \"y\": 2\n  },\n  \"n\": [\n    2,\n    3\n  ]\n}"
    );
}

#[test]
fn strings_decode_as_go_decodes_them() {
    // A lone surrogate, and one paired with something that isn't its other half, is U+FFFD.
    assert_eq!(
        rewrite(br#"{"a":"\ud800"}"#).unwrap(),
        "{\n  \"a\": \"\u{fffd}\"\n}"
    );
    assert_eq!(
        rewrite(br#"{"a":"\udc00\ud800x"}"#).unwrap(),
        "{\n  \"a\": \"\u{fffd}\u{fffd}x\"\n}"
    );
    assert_eq!(
        rewrite(br#"{"a":"\ud800\u0041"}"#).unwrap(),
        "{\n  \"a\": \"\u{fffd}A\"\n}"
    );
    assert_eq!(
        rewrite(br#"{"a":"\ud83d\ude00"}"#).unwrap(),
        "{\n  \"a\": \"\u{1f600}\"\n}"
    );
    // Each byte that isn't UTF-8 is its own U+FFFD, in a key too.
    assert_eq!(
        rewrite(b"{\"a\":\"\xe2\x80\",\"\xff\":1}").unwrap(),
        "{\n  \"a\": \"\u{fffd}\u{fffd}\",\n  \"\u{fffd}\": 1\n}"
    );
    // DEL is kept as it is; escapes come out in Go's spelling.
    assert_eq!(
        rewrite(b"{\"a\":\"\x7f\\u00e9\\/\\b\\f\\u0001\\u001f\"}").unwrap(),
        "{\n  \"a\": \"\u{7f}\u{e9}/\\b\\f\\u0001\\u001f\"\n}"
    );
    // json.Marshal's HTML escapes, and U+2028 always.
    assert_eq!(
        rewrite(br#"{"b":"<>&","a":"\u2028"}"#).unwrap(),
        "{\n  \"a\": \"\\u2028\",\n  \"b\": \"\\u003c\\u003e\\u0026\"\n}"
    );
}

#[test]
fn numbers_keep_their_text() {
    assert_eq!(
        rewrite(br#"{"n":[-0,2.50,1e3,1E-7,18446744073709551616,-12]}"#).unwrap(),
        "{\n  \"n\": [\n    -0,\n    2.50,\n    1e3,\n    1E-7,\n    18446744073709551616,\n    -12\n  ]\n}"
    );
    // Out of any float's range, and hundreds of digits long: still only text.
    let long = "9".repeat(400);
    let input = format!("{{\"n\":[1e999,-1E+400,{long}]}}");
    assert_eq!(
        rewrite(input.as_bytes()).unwrap(),
        format!("{{\n  \"n\": [\n    1e999,\n    -1E+400,\n    {long}\n  ]\n}}")
    );
    // Compact too, as list reports a host descriptor.
    let value = parse_config(input.as_bytes()).unwrap();
    assert_eq!(
        crate::commands::envelope::encode(&value, false),
        format!("{{\"n\":[1e999,-1E+400,{long}]}}")
    );
}

#[test]
fn bad_input_is_refused_with_gos_messages() {
    for (input, message) in [
        (&b""[..], "EOF"),
        (
            b"[]",
            "json: cannot unmarshal array into Go value of type map[string]interface {}",
        ),
        (
            b"\"x\"",
            "json: cannot unmarshal string into Go value of type map[string]interface {}",
        ),
        (b"{} x", "unexpected data after the config object"),
        (b"{}}", "unexpected data after the config object"),
        (b"{\"a\":\"\x01\"}", "invalid character '\\x01' in string"),
        (
            b"{\"a\":01}",
            "invalid character '1' after object key:value pair",
        ),
        (b"{\"a\":1.}", "invalid character '}' in numeric literal"),
        (b"{\"a\":-}", "invalid character '}' in numeric literal"),
        (b"{\"a\":1e}", "invalid character '}' in numeric literal"),
        (
            b"{\"a\":tru}",
            "invalid character '}' in literal true (expecting 'e')",
        ),
        (
            b"\xef\xbb\xbf{}",
            "invalid character '\\ufeff' looking for beginning of value",
        ),
        (b"{\"a\":", "unexpected EOF"),
        (
            b"{\"a\":\"\\q\"}",
            "invalid escape sequence `\\q` in string",
        ),
        (
            b"{\"a\":\"\\u00\"}",
            "invalid escape sequence `\\u00\"}` in string",
        ),
        (
            b"{1:2}",
            "invalid character '1' looking for beginning of object key string",
        ),
        (
            b"{\"a\":1 \"b\":2}",
            "invalid character '\"' after object key:value pair",
        ),
        (b"{\"a\" 1}", "invalid character '1' after object key"),
        (
            b"{\"a\":[1 2]}",
            "invalid character '2' after array element",
        ),
    ] {
        assert_eq!(
            rewrite(input),
            Err(message.to_string()),
            "{:?}",
            String::from_utf8_lossy(input)
        );
    }
}

/// On a test thread's 2 MiB stack, a quarter of the CLI's: the limit is reached long before the
/// stack is, reading and writing.
#[test]
fn nesting_past_the_limit_is_an_error_not_a_crash() {
    let nested =
        |depth: usize| format!("{{\"a\":{}{}}}", "[".repeat(depth), "]".repeat(depth)).into_bytes();
    assert!(rewrite(&nested(MAX_DEPTH - 1)).is_ok());
    assert_eq!(
        rewrite(&nested(MAX_DEPTH)),
        Err("exceeded max depth".to_string())
    );
}
