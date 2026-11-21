//! A new workroom's friendly random name, `<adjective>-<noun>`, from Go's `internal/namegen` word
//! lists (a test holds these to Go's, word for word).

/// The first word of a name.
const ADJECTIVES: [&str; 120] = [
    "agile", "amber", "apt", "azure", "bold", "brave", "bright", "brisk", "calm", "cedar", "clear",
    "cold", "cool", "coral", "crisp", "cyan", "damp", "dark", "dawn", "deep", "deft", "dry",
    "dusk", "dusty", "easy", "even", "fair", "fast", "firm", "flat", "fond", "free", "fresh",
    "full", "glad", "gold", "good", "gray", "green", "hale", "happy", "hazy", "high", "idle",
    "jade", "keen", "kind", "lark", "last", "lean", "left", "light", "lime", "long", "lost",
    "loud", "lush", "mild", "mint", "misty", "mossy", "neat", "nice", "noble", "north", "novel",
    "oak", "odd", "opal", "open", "pale", "peak", "pine", "pink", "plum", "proud", "pure", "quick",
    "quiet", "rapid", "rare", "red", "rich", "ripe", "rosy", "ruby", "safe", "sage", "salt",
    "sharp", "shy", "silk", "slim", "slow", "smart", "snowy", "soft", "solid", "south", "stark",
    "steel", "still", "stout", "sunny", "sure", "swift", "tall", "tame", "teal", "thin", "tidy",
    "trim", "true", "vivid", "warm", "west", "wide", "wild", "wise", "young",
];

/// The second word of a name.
const NOUNS: [&str; 210] = [
    "acre", "arch", "aspen", "badge", "bank", "bark", "basin", "bay", "beach", "bear", "birch",
    "blade", "blaze", "bloom", "bolt", "bone", "bow", "brace", "brass", "breeze", "brick",
    "bridge", "brook", "brush", "canopy", "cape", "cave", "cedar", "chain", "chime", "cliff",
    "cloud", "clover", "colt", "coop", "coral", "core", "cove", "crane", "creek", "crest", "crow",
    "curve", "dale", "dawn", "deer", "delta", "dew", "dock", "dove", "drake", "drift", "dune",
    "dusk", "eagle", "edge", "elm", "ember", "fawn", "feather", "fern", "field", "finch", "fjord",
    "flame", "flask", "flint", "float", "flora", "flute", "fog", "font", "forge", "fox", "frost",
    "gate", "glade", "glen", "globe", "gorge", "grain", "grove", "gulf", "gust", "hare", "haven",
    "hawk", "hazel", "heath", "hedge", "heron", "hill", "hollow", "horn", "inlet", "isle", "ivy",
    "jade", "jewel", "knoll", "lake", "larch", "lark", "latch", "laurel", "leaf", "ledge", "light",
    "lilac", "lily", "linen", "lodge", "loft", "lynx", "maple", "marsh", "meadow", "mesa", "mint",
    "mirror", "mist", "moon", "moss", "mound", "nest", "north", "oak", "opal", "orbit", "orion",
    "otter", "palm", "pass", "path", "peak", "pearl", "pebble", "perch", "petal", "pine", "pixel",
    "plume", "pond", "pool", "porch", "prism", "quail", "quarry", "quartz", "rail", "rain",
    "raven", "reef", "ridge", "river", "robin", "rock", "root", "rose", "ruby", "sage", "sand",
    "scope", "seal", "seed", "shade", "shell", "shore", "silk", "sky", "slate", "slope", "smoke",
    "snow", "south", "spark", "spire", "spoke", "spring", "spruce", "star", "stem", "stone",
    "stork", "storm", "strand", "surf", "swift", "tern", "thyme", "tide", "timber", "tower",
    "trail", "tree", "vale", "vault", "vine", "vista", "wand", "ward", "wave", "west", "wheat",
    "willow", "wind", "wing", "wolf", "wren", "yard",
];

/// A random name, such as `calm-river`.
pub(super) fn generate() -> String {
    format!(
        "{}-{}",
        ADJECTIVES[below(ADJECTIVES.len())],
        NOUNS[below(NOUNS.len())]
    )
}

/// A random number below `n`, which needn't be cryptographic: names are checked against the
/// workrooms that exist before one is used.
pub(super) fn below(n: usize) -> usize {
    use std::hash::{BuildHasher, RandomState};
    // Each RandomState is seeded afresh, so one hash of nothing is a new random number.
    let random = RandomState::new().hash_one(std::time::Instant::now());
    (random % n as u64) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The quoted words of Go's `var <name> = []string{…}`.
    fn go_list(source: &str, name: &str) -> Vec<String> {
        let start = source
            .find(&format!("var {name} = []string{{"))
            .unwrap_or_else(|| panic!("no {name} in namegen.go"));
        let body = &source[start..];
        let body = &body[..body.find('}').expect("end of list")];
        body.split('"')
            .skip(1)
            .step_by(2)
            .map(str::to_string)
            .collect()
    }

    #[test]
    fn the_word_lists_are_gos() {
        let source = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../internal/namegen/namegen.go"
        ))
        .expect("read namegen.go");
        assert_eq!(go_list(&source, "adjectives"), ADJECTIVES);
        assert_eq!(go_list(&source, "nouns"), NOUNS);
    }

    #[test]
    fn a_name_is_an_adjective_and_a_noun() {
        let name = generate();
        let (adjective, noun) = name.split_once('-').expect("two words");
        assert!(ADJECTIVES.contains(&adjective), "{name}");
        assert!(NOUNS.contains(&noun), "{name}");
    }
}
