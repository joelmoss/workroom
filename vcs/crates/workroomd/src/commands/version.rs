//! `workroom version`: the bare version on stdout for scripts, and with `--json` the release
//! channel and config schema too, as the Go CLI reports them.

use std::path::PathBuf;

use serde::Serialize;

use super::{Context, Outcome};

/// config.json's schema, which the Go CLI reports as 2 and the Rust one keeps (ADR 0078).
const CONFIG_SCHEMA_VERSION: u32 = 2;

/// The channel when config names none.
const DEFAULT_CHANNEL: &str = "stable";

#[derive(Serialize)]
struct Payload<'a> {
    channel: &'a str,
    config_schema_version: u32,
    version: &'a str,
}

pub(super) fn run(context: &Context) -> Outcome {
    if !context.json {
        return Outcome::Printed(format!("{}\n", super::VERSION));
    }
    // A nightly build reports its fixed identity; any other its configured channel.
    let channel = match super::BAKED_CHANNEL {
        Some(baked) => baked.to_string(),
        None => configured_channel(context),
    };
    Outcome::Success(super::envelope::success(
        "version",
        &Payload {
            channel: &channel,
            config_schema_version: CONFIG_SCHEMA_VERSION,
            version: super::VERSION,
        },
    ))
}

/// config.json's `channel` when it is a non-empty string, else `stable`. A config that can't be
/// read or parsed counts as naming none: `version` never fails on config, as Go's doesn't.
fn configured_channel(context: &Context) -> String {
    let Some(path) = config_path(context) else {
        return DEFAULT_CHANNEL.to_string();
    };
    let channel = std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|config| config.get("channel")?.as_str().map(str::to_string));
    match channel {
        Some(channel) if !channel.is_empty() => channel,
        _ => DEFAULT_CHANNEL.to_string(),
    }
}

/// `$WORKROOM_CONFIG` when set, else `~/.config/workroom/config.json`, as Go's `config.New("")`
/// finds it.
fn config_path(context: &Context) -> Option<PathBuf> {
    if let Some(path) = context
        .env("WORKROOM_CONFIG")
        .filter(|path| !path.is_empty())
    {
        return Some(PathBuf::from(path));
    }
    let home = context.env("HOME").filter(|home| !home.is_empty())?;
    Some(PathBuf::from(home).join(".config/workroom/config.json"))
}
