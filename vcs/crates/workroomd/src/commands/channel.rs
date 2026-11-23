//! Workroom's release channels, the rules that map a GitHub release tag to a channel, and a
//! channel to the set of channels it accepts (the nested "floor" model).
//!
//! Kept in lockstep with the shell installers' `macapp/Scripts/channel-helper.sh` and the macOS
//! app's `ReleaseChannel` enum: if you change a rule here, change both. The tests here read the
//! same fixture as the shell and Swift tests, `testdata/channel_cases.tsv`.
//!
//! # Channel model (floor / nested)
//!
//! A user on a channel is offered builds from that channel and every channel below it; the
//! newest wins. Stable users never see prereleases.
//!
//! ```text
//! stable  -> {stable}                  GA only
//! pre     -> {stable, pre}             prereleases + GA
//! nightly -> {stable, pre, nightly}    everything
//! ```
//!
//! # Tag to channel classification
//!
//! ```text
//! "appcast"     -> excluded   (Sparkle feed host, not a downloadable release)
//! "nightly"     -> nightly    (the fixed, rolling nightly release)
//! vX.Y.Z        -> stable     (no semver prerelease component)
//! vX.Y.Z-<pre>  -> pre        (any semver prerelease suffix: -beta.N, -rc, -alpha, ...)
//! anything else -> invalid    (not classifiable)
//! ```

/// The fixed GitHub release tag that hosts the rolling nightly build. Its assets and its single
/// appcast item are overwritten in place each night, so its tag never changes.
pub(crate) const NIGHTLY_TAG: &str = "nightly";

/// The fixed release that hosts the Sparkle appcast feed. It is never a downloadable channel
/// release and is always excluded from selection.
const APPCAST_TAG: &str = "appcast";

/// A release channel a user can subscribe to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Channel {
    Stable,
    Pre,
    Nightly,
}

impl Channel {
    /// The canonical name, as users and the appcast write it.
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Channel::Stable => "stable",
            Channel::Pre => "pre",
            Channel::Nightly => "nightly",
        }
    }

    /// Converts a user-supplied channel string. `None` for anything that is not exactly one of
    /// the three canonical names (case-sensitive).
    pub(crate) fn parse(s: &str) -> Option<Channel> {
        match s {
            "stable" => Some(Channel::Stable),
            "pre" => Some(Channel::Pre),
            "nightly" => Some(Channel::Nightly),
            _ => None,
        }
    }
}

/// Maps a GitHub release tag to the channel it belongs to. `None` for tags that are not part of
/// any channel (the appcast feed release, or a tag that isn't a recognizable version). See the
/// module doc for the full contract.
pub(crate) fn classify(tag: &str) -> Option<Channel> {
    match tag {
        APPCAST_TAG => return None,
        NIGHTLY_TAG => return Some(Channel::Nightly),
        _ => {}
    }
    let (_core, pre) = split_semver(tag)?;
    Some(if pre.is_empty() {
        Channel::Stable
    } else {
        Channel::Pre
    })
}

/// The channels a user on channel `c` is offered builds from, newest wins.
pub(crate) fn floor_set(c: Channel) -> &'static [Channel] {
    match c {
        Channel::Nightly => &[Channel::Stable, Channel::Pre, Channel::Nightly],
        Channel::Pre => &[Channel::Stable, Channel::Pre],
        Channel::Stable => &[Channel::Stable],
    }
}

/// Whether a user on channel `user` should be offered a release whose own channel is
/// `tag_channel`, per the floor model.
pub(crate) fn accepts(user: Channel, tag_channel: Channel) -> bool {
    floor_set(user).contains(&tag_channel)
}

/// Splits a version tag into its `MAJOR.MINOR.PATCH` core and its prerelease component (without
/// the leading `-`; empty when there is none), stripping one optional leading `v` and any
/// `+build` metadata. `None` if the core is not three dot-separated numeric fields, or if a `-`
/// is followed by nothing.
fn split_semver(tag: &str) -> Option<(&str, &str)> {
    let v = tag.strip_prefix('v').unwrap_or(tag);

    // Drop build metadata: it never affects channel or precedence.
    let v = v.split_once('+').map_or(v, |(before, _)| before);

    let (core, prerelease) = match v.split_once('-') {
        Some((_, "")) => return None,
        Some((before, after)) => (before, after),
        None => (v, ""),
    };

    valid_core(core).then_some((core, prerelease))
}

/// Whether `s` is exactly three dot-separated, non-empty, all-ASCII-digit fields.
fn valid_core(s: &str) -> bool {
    let mut parts = 0;
    for p in s.split('.') {
        parts += 1;
        if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
    }
    parts == 3
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shared tag -> channel fixture, parsed as the shell and Swift readers do: skip blank
    /// lines and `#` comments, split on tabs, exactly two fields per row.
    fn load_cases() -> Vec<(String, Option<Channel>)> {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../testdata/channel_cases.tsv"
        );
        let data = std::fs::read_to_string(path).expect("read channel_cases.tsv");
        let mut rows = Vec::new();
        for line in data.split('\n') {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split('\t').collect();
            assert_eq!(fields.len(), 2, "malformed line (want 2 fields): {line:?}");
            let want = if fields[1] == "EXCLUDED" {
                None
            } else {
                Some(
                    Channel::parse(fields[1])
                        .unwrap_or_else(|| panic!("unknown channel in row: {line:?}")),
                )
            };
            rows.push((fields[0].to_string(), want));
        }
        rows
    }

    #[test]
    fn classify_matches_the_shared_fixture() {
        let cases = load_cases();
        assert!(cases.len() >= 20, "fixture read only {} rows", cases.len());
        for (tag, want) in &cases {
            assert_eq!(classify(tag), *want, "row: tag {tag:?}, want {want:?}");
        }
    }

    #[test]
    fn floor_set_lists_the_channels_at_and_below() {
        assert_eq!(floor_set(Channel::Stable), &[Channel::Stable]);
        assert_eq!(floor_set(Channel::Pre), &[Channel::Stable, Channel::Pre]);
        assert_eq!(
            floor_set(Channel::Nightly),
            &[Channel::Stable, Channel::Pre, Channel::Nightly]
        );
    }

    #[test]
    fn accepts_follows_the_floor_model() {
        use Channel::{Nightly, Pre, Stable};
        let cases = [
            (Stable, Stable, true),
            (Stable, Pre, false), // stable never sees prereleases
            (Stable, Nightly, false),
            (Pre, Stable, true), // floor: pre gets stable too
            (Pre, Pre, true),
            (Pre, Nightly, false),
            (Nightly, Stable, true), // floor: nightly gets everything
            (Nightly, Pre, true),
            (Nightly, Nightly, true),
        ];
        for (user, tag, want) in cases {
            assert_eq!(accepts(user, tag), want, "accepts({user:?}, {tag:?})");
        }
    }

    #[test]
    fn parse_takes_exactly_the_three_names() {
        assert_eq!(Channel::parse("stable"), Some(Channel::Stable));
        assert_eq!(Channel::parse("pre"), Some(Channel::Pre));
        assert_eq!(Channel::parse("nightly"), Some(Channel::Nightly));
        assert_eq!(Channel::parse(""), None);
        assert_eq!(Channel::parse("Stable"), None); // case-sensitive
        assert_eq!(Channel::parse("beta"), None);
    }

    #[test]
    fn as_str_round_trips_through_parse() {
        for c in [Channel::Stable, Channel::Pre, Channel::Nightly] {
            assert_eq!(Channel::parse(c.as_str()), Some(c));
        }
        assert_eq!(NIGHTLY_TAG, Channel::Nightly.as_str());
    }
}
