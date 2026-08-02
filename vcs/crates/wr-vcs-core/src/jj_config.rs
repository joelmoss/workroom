//! The user's real jj configuration, instead of jj-lib's built-in defaults.
//!
//! **Why this exists.** Every entry point here used to build settings from
//! `StackedConfig::with_defaults()`, whose compiled-in `misc.toml` sets `user.name = ""`,
//! `user.email = ""` and `signing.backend = "none"`. That is not a cosmetic gap on the one code path
//! that *writes*:
//!
//! - `snapshot_working_copy` rewrites `@` whenever the working copy has moved, and jj-lib's
//!   `CommitBuilder::for_rewrite_from` unconditionally sets `commit.committer = settings.signature()`.
//!   With defaults-only settings that stamps an **empty committer name and email** onto the working
//!   copy commit — for every jj user, on every status refresh that finds a change. It is usually
//!   invisible (`jj log` shows the author) and self-heals on the next real `jj` command, but it does
//!   NOT heal if `@` is pushed as-is, which the app's own Push button does via `jj git push --change @`.
//! - `Signer::from_settings` reads `signing.backend` from the same settings, so `can_sign()` is false
//!   and `write_to_store` sets `secure_sig = None`. Under the default `behavior = "keep"` that means
//!   rewriting an already-signed `@` silently **drops its signature**.
//!
//! **jj-lib does no discovery.** It supplies the primitives (`ConfigLayer::load_from_file`,
//! `StackedConfig::add_layer`, the `ConfigSource` precedence order) and nothing else — locating the
//! files is jj-*cli*'s job, and jj-cli is not vendored. So the chain below is ours, and it mirrors
//! what `jj config path --user` reports.
//!
//! **Best-effort by design.** A layer that cannot be read or parsed is skipped rather than failing
//! the call. A malformed `~/.config/jj/config.toml` should cost the user their customisations, not
//! their Changes panel — degrading to jj's defaults is exactly what this module already did for
//! everyone before it existed.

use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::settings::UserSettings;

use wr_vcs_model as model;
use wr_vcs_model::VcsError;

/// The environment the config chain is resolved against.
///
/// A struct rather than direct `std::env` reads so the whole path policy is unit-testable: cargo
/// runs tests as parallel threads of ONE process, so a test that mutated the real environment would
/// be visible to — and racing with — every other test in the binary.
#[derive(Debug, Default, Clone)]
pub(crate) struct ConfigEnv {
    pub jj_config: Option<PathBuf>,
    pub home: Option<PathBuf>,
    pub xdg_config_home: Option<PathBuf>,
}

impl ConfigEnv {
    pub(crate) fn from_process() -> Self {
        Self {
            jj_config: std::env::var_os("JJ_CONFIG").map(PathBuf::from),
            home: std::env::var_os("HOME").map(PathBuf::from),
            xdg_config_home: std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from),
        }
    }
}

/// The config files to layer, **lowest precedence first**.
///
/// `JJ_CONFIG` REPLACES the default locations rather than adding to them — that is jj's own
/// behaviour, and it is what makes the variable usable for isolation (the integration fixtures here
/// rely on it). It may name a file or a directory of `*.toml`.
///
/// Otherwise the two documented user locations are both collected, in the order jj's own precedence
/// implies. Merging them rather than picking one is a deliberate simplification: in practice exactly
/// one exists, and if somebody has both, honouring both in a defined order is friendlier than
/// silently ignoring whichever we didn't guess.
///
/// Verified against `jj config path --user` on macOS with jj 0.43 — it answers
/// `~/.config/jj/config.toml`, i.e. the XDG location, NOT `~/Library/Application Support`.
pub(crate) fn config_paths(env: &ConfigEnv) -> Vec<PathBuf> {
    if let Some(explicit) = &env.jj_config {
        return toml_files_at(explicit);
    }
    let mut paths = Vec::new();
    if let Some(home) = &env.home {
        paths.extend(toml_files_at(&home.join(".jjconfig.toml")));
    }
    let config_home = env
        .xdg_config_home
        .clone()
        .or_else(|| env.home.as_ref().map(|h| h.join(".config")));
    if let Some(dir) = config_home {
        paths.extend(toml_files_at(&dir.join("jj").join("config.toml")));
        // `conf.d` is jj's drop-in directory, layered above the single file.
        paths.extend(toml_files_at(&dir.join("jj").join("conf.d")));
    }
    paths
}

/// The `*.toml` files at `path`: the file itself, or every `*.toml` directly inside it, sorted.
///
/// Sorted because a drop-in directory's precedence has to be reproducible — an unsorted `read_dir`
/// returns entries in filesystem order, so two machines with the same `conf.d` could resolve the
/// same key differently. Non-recursive, matching jj-lib's own (private) `load_from_dir`.
fn toml_files_at(path: &Path) -> Vec<PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    if !path.is_dir() {
        return Vec::new();
    }
    let Ok(entries) = std::fs::read_dir(path) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| p.is_file() && p.extension().is_some_and(|ext| ext == "toml"))
        .collect();
    files.sort();
    files
}

/// jj's built-in defaults with the user's own configuration layered on top.
pub(crate) fn user_settings_for(env: &ConfigEnv) -> model::Result<UserSettings> {
    let mut config = StackedConfig::with_defaults();
    for path in config_paths(env) {
        // Skipped, not propagated — see the module comment. A broken config file costs the user
        // their settings, never their ability to read the repo.
        if let Ok(layer) = ConfigLayer::load_from_file(ConfigSource::User, path) {
            config.add_layer(layer);
        }
    }
    UserSettings::from_config(config).map_err(|e| VcsError::Io(e.to_string()))
}

/// The settings every jj-lib entry point in this crate uses.
///
/// Deliberately NOT cached. The cost is a couple of small file reads per call, which is nothing
/// beside the tree snapshot they accompany, and caching would mean a user who fixes their
/// `user.email` has to relaunch the app before the app stops writing commits without one — which is
/// the exact failure this module exists to end.
pub(crate) fn user_settings() -> model::Result<UserSettings> {
    user_settings_for(&ConfigEnv::from_process())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wr-cfg-{}-{}", std::process::id(), tag));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, body: &str) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(path, body).unwrap();
    }

    /// `JJ_CONFIG` REPLACES the default locations. Anything else would make it useless for the
    /// isolation the integration fixtures depend on.
    #[test]
    fn jj_config_env_var_wins_outright() {
        let dir = temp_dir("env-wins");
        let explicit = dir.join("explicit.toml");
        write(&explicit, "[user]\nname = \"X\"\n");
        write(&dir.join(".jjconfig.toml"), "[user]\nname = \"home\"\n");

        let env = ConfigEnv {
            jj_config: Some(explicit.clone()),
            home: Some(dir.clone()),
            xdg_config_home: None,
        };
        assert_eq!(config_paths(&env), vec![explicit]);
    }

    /// It can also name a directory of drop-ins.
    #[test]
    fn jj_config_may_be_a_directory() {
        let dir = temp_dir("env-dir");
        let conf = dir.join("conf");
        write(&conf.join("b.toml"), "");
        write(&conf.join("a.toml"), "");
        write(&conf.join("ignored.txt"), "");

        let env = ConfigEnv {
            jj_config: Some(conf.clone()),
            ..Default::default()
        };
        // Sorted, and non-TOML ignored.
        assert_eq!(
            config_paths(&env),
            vec![conf.join("a.toml"), conf.join("b.toml")]
        );
    }

    /// The XDG location is what `jj config path --user` reports on macOS — verified against jj 0.43.
    #[test]
    fn xdg_config_home_is_honoured() {
        let dir = temp_dir("xdg");
        let xdg = dir.join("xdg");
        let config = xdg.join("jj").join("config.toml");
        write(&config, "[user]\nname = \"X\"\n");

        let env = ConfigEnv {
            jj_config: None,
            home: Some(dir.clone()),
            xdg_config_home: Some(xdg),
        };
        assert_eq!(config_paths(&env), vec![config]);
    }

    /// With no `XDG_CONFIG_HOME`, `~/.config` is the fallback — the location jj actually uses here.
    #[test]
    fn falls_back_to_dot_config_under_home() {
        let dir = temp_dir("home-config");
        let config = dir.join(".config").join("jj").join("config.toml");
        write(&config, "[user]\nname = \"X\"\n");

        let env = ConfigEnv {
            jj_config: None,
            home: Some(dir.clone()),
            xdg_config_home: None,
        };
        assert_eq!(config_paths(&env), vec![config]);
    }

    /// `conf.d` drop-ins layer ABOVE the single file, and are sorted so precedence is reproducible
    /// across machines rather than following filesystem order.
    #[test]
    fn conf_d_dropins_come_after_the_single_file_and_are_sorted() {
        let dir = temp_dir("confd");
        let jj_dir = dir.join(".config").join("jj");
        let config = jj_dir.join("config.toml");
        write(&config, "");
        write(&jj_dir.join("conf.d").join("20-b.toml"), "");
        write(&jj_dir.join("conf.d").join("10-a.toml"), "");

        let env = ConfigEnv {
            jj_config: None,
            home: Some(dir.clone()),
            xdg_config_home: None,
        };
        assert_eq!(
            config_paths(&env),
            vec![
                config,
                jj_dir.join("conf.d").join("10-a.toml"),
                jj_dir.join("conf.d").join("20-b.toml"),
            ]
        );
    }

    #[test]
    fn nothing_configured_yields_no_paths() {
        let env = ConfigEnv::default();
        assert!(config_paths(&env).is_empty());
    }

    /// The whole point: settings built from a real file carry the user's identity, where
    /// `with_defaults()` alone yields the empty strings that get stamped onto `@`.
    #[test]
    fn settings_carry_the_users_identity() {
        let dir = temp_dir("identity");
        let config = dir.join("jjconfig.toml");
        write(
            &config,
            "[user]\nname = \"Ada Lovelace\"\nemail = \"ada@example.com\"\n",
        );

        let env = ConfigEnv {
            jj_config: Some(config),
            ..Default::default()
        };
        let settings = user_settings_for(&env).expect("settings");
        assert_eq!(settings.user_name(), "Ada Lovelace");
        assert_eq!(settings.user_email(), "ada@example.com");

        let defaults = UserSettings::from_config(StackedConfig::with_defaults()).unwrap();
        assert_eq!(defaults.user_name(), "", "the bug this replaces");
        assert_eq!(defaults.user_email(), "");
    }

    /// A malformed config must not take out the read. It costs the user their settings, not their
    /// Changes panel.
    #[test]
    fn a_broken_config_degrades_to_defaults() {
        let dir = temp_dir("broken");
        let config = dir.join("jjconfig.toml");
        write(&config, "this is not [valid toml");

        let env = ConfigEnv {
            jj_config: Some(config),
            ..Default::default()
        };
        let settings = user_settings_for(&env).expect("must still produce settings");
        assert_eq!(settings.user_name(), "");
    }
}
