//! `workroom version`: the bare version on stdout for scripts, and with `--json` the release
//! channel and config schema too, as the Go CLI reports them.

use serde::Serialize;

use super::config::{self, Config};
use super::{Args, Context, Outcome};

/// config.json's schema, which the Go CLI reports as 2 and the Rust one keeps (ADR 0078).
const CONFIG_SCHEMA_VERSION: u32 = 2;

/// The channel when config names none.
const DEFAULT_CHANNEL: &str = super::channel::Channel::Stable.as_str();

#[derive(Serialize)]
struct Payload<'a> {
    channel: &'a str,
    config_schema_version: u32,
    version: &'a str,
}

pub(super) fn run(context: &Context, _args: &Args) -> Outcome {
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
/// found, read or parsed counts as naming none: `version` never fails on config, as Go's doesn't.
fn configured_channel(context: &Context) -> String {
    let data = Config::new(context).and_then(|config| config.read());
    match data
        .as_ref()
        .ok()
        .and_then(|data| config::setting(data, "channel"))
    {
        Some(channel) if !channel.is_empty() => channel.to_string(),
        _ => DEFAULT_CHANNEL.to_string(),
    }
}
