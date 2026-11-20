//! `workroom version`: the bare version on stdout for scripts, and with `--json` the release
//! channel and config schema too, as the Go CLI reports them.

use serde::Serialize;

use super::channel::Channel;
use super::config::Config;
use super::{Args, Context, Outcome};

/// config.json's schema, which the Go CLI reports as 2 and the Rust one keeps (ADR 0078).
const CONFIG_SCHEMA_VERSION: u32 = 2;

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

/// [`Config::channel`]. A config that can't even be found counts as naming none too: `version`
/// never fails on config, as Go's doesn't.
fn configured_channel(context: &Context) -> String {
    Config::new(context).map_or_else(
        |_| Channel::Stable.as_str().to_string(),
        |config| config.channel(),
    )
}
