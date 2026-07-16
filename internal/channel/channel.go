// Package channel defines Workroom's release channels and the canonical rules
// that map a GitHub release tag to a channel, and a channel to the set of
// channels it accepts (the nested "floor" model).
//
// This is the single source of truth for channel semantics on the Go side. The
// macOS app (macapp Core/ReleaseChannel.swift) and the shell installers
// (install.sh / install.ps1 via Scripts/channel-helper.sh) mirror these exact
// rules — if you change the classification here, change all three.
//
// # Channel model (floor / nested)
//
// A user on a channel is offered builds from that channel and every channel
// below it; the newest wins. Stable users never see prereleases.
//
//	stable  → {stable}                  GA only
//	pre     → {stable, pre}             prereleases + GA
//	nightly → {stable, pre, nightly}    everything
//
// # Tag → channel classification
//
//	"appcast"     → excluded   (Sparkle feed host, not a downloadable release)
//	"nightly"     → nightly    (the fixed, rolling nightly release)
//	vX.Y.Z        → stable     (no semver prerelease component)
//	vX.Y.Z-<pre>  → pre        (any semver prerelease suffix: -beta.N, -rc, -alpha, …)
//	anything else → invalid    (not classifiable)
package channel

import (
	"slices"
	"strings"
)

// Channel is a release channel a user can subscribe to.
type Channel string

const (
	Stable  Channel = "stable"
	Pre     Channel = "pre"
	Nightly Channel = "nightly"
)

// NightlyTag is the fixed GitHub release tag that hosts the rolling nightly
// build. Its assets and its single appcast item are overwritten in place each
// night, so its tag never changes.
const NightlyTag = "nightly"

// appcastTag is the fixed release that hosts the Sparkle appcast feed. It is
// never a downloadable channel release and is always excluded from selection.
const appcastTag = "appcast"

// Parse converts a user-supplied channel string into a Channel. ok is false for
// anything that is not exactly one of the three canonical names.
func Parse(s string) (Channel, bool) {
	switch Channel(s) {
	case Stable, Pre, Nightly:
		return Channel(s), true
	default:
		return "", false
	}
}

// Valid reports whether c is one of the three canonical channels.
func Valid(c Channel) bool {
	_, ok := Parse(string(c))
	return ok
}

// Classify maps a GitHub release tag to the channel it belongs to. ok is false
// for tags that are not part of any channel (the appcast feed release, or a tag
// that isn't a recognizable version). See the package doc for the full contract.
func Classify(tag string) (Channel, bool) {
	switch tag {
	case appcastTag:
		return "", false
	case NightlyTag:
		return Nightly, true
	}

	core, pre, ok := splitSemver(tag)
	if !ok || core == "" {
		return "", false
	}
	if pre != "" {
		return Pre, true
	}
	return Stable, true
}

// FloorSet returns the channels a user on channel c is offered builds from,
// newest wins. Returns nil for an invalid channel.
func FloorSet(c Channel) []Channel {
	switch c {
	case Nightly:
		return []Channel{Stable, Pre, Nightly}
	case Pre:
		return []Channel{Stable, Pre}
	case Stable:
		return []Channel{Stable}
	default:
		return nil
	}
}

// Accepts reports whether a user on channel user should be offered a release
// whose own channel is tagCh, per the floor model.
func Accepts(user, tagCh Channel) bool {
	return slices.Contains(FloorSet(user), tagCh)
}

// splitSemver splits a version tag into its "MAJOR.MINOR.PATCH" core and its
// prerelease component (without the leading "-"), stripping an optional leading
// "v" and any "+build" metadata. ok is false if the core is not three
// dot-separated numeric fields.
func splitSemver(tag string) (core, prerelease string, ok bool) {
	v := strings.TrimPrefix(tag, "v")

	// Drop build metadata: it never affects channel or precedence.
	if before, _, found := strings.Cut(v, "+"); found {
		v = before
	}

	core = v
	if before, after, found := strings.Cut(v, "-"); found {
		core, prerelease = before, after
	}

	if !validCore(core) {
		return "", "", false
	}
	return core, prerelease, true
}

// validCore reports whether s is exactly three dot-separated, non-empty,
// all-digit fields (a semver MAJOR.MINOR.PATCH core).
func validCore(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}
