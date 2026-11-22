//! `workroom completion bash|zsh|fish|powershell`: the shell completion script, which a user
//! sources at shell start or saves into the shell's completion folder (`docs-site/pages/cli/
//! workroom-completion*.md`). Each script asks the binary on every Tab, through `__complete`
//! (`complete`), so it never changes as commands do.
//!
//! The scripts are the ones the Go CLI's cobra (v1.10.2) generates for `workroom`, byte for byte,
//! so a script saved from either binary works with the other. Cobra's templates are Copyright
//! 2013-2023 The Cobra Authors and licensed under the Apache License 2.0, a copy of which is
//! `completion/LICENSE`; the only change is that each is cobra's output for `workroom`, and
//! `--no-descriptions` asks `__completeNoDesc` in place of `__complete`, as cobra's does.

use super::kind::CliError;
use super::{Args, Context, Outcome};

const BASH: &str = include_str!("completion/workroom.bash");
const ZSH: &str = include_str!("completion/workroom.zsh");
const FISH: &str = include_str!("completion/workroom.fish");
const POWERSHELL: &str = include_str!("completion/workroom.ps1");

/// `completion bash --help`, as cobra words it.
pub(super) const BASH_HELP: &str = "Generate the autocompletion script for the bash shell.

This script depends on the 'bash-completion' package.
If it is not installed already, you can install it via your OS's package manager.

To load completions in your current shell session:

\tsource <(workroom completion bash)

To load completions for every new session, execute once:

#### Linux:

\tworkroom completion bash > /etc/bash_completion.d/workroom

#### macOS:

\tworkroom completion bash > $(brew --prefix)/etc/bash_completion.d/workroom

You will need to start a new shell for this setup to take effect.";

/// `completion zsh --help`, as cobra words it.
pub(super) const ZSH_HELP: &str = "Generate the autocompletion script for the zsh shell.

If shell completion is not already enabled in your environment you will need
to enable it.  You can execute the following once:

\techo \"autoload -U compinit; compinit\" >> ~/.zshrc

To load completions in your current shell session:

\tsource <(workroom completion zsh)

To load completions for every new session, execute once:

#### Linux:

\tworkroom completion zsh > \"${fpath[1]}/_workroom\"

#### macOS:

\tworkroom completion zsh > $(brew --prefix)/share/zsh/site-functions/_workroom

You will need to start a new shell for this setup to take effect.";

/// `completion fish --help`, as cobra words it.
pub(super) const FISH_HELP: &str = "Generate the autocompletion script for the fish shell.

To load completions in your current shell session:

\tworkroom completion fish | source

To load completions for every new session, execute once:

\tworkroom completion fish > ~/.config/fish/completions/workroom.fish

You will need to start a new shell for this setup to take effect.";

/// `completion powershell --help`, as cobra words it.
pub(super) const POWERSHELL_HELP: &str = "Generate the autocompletion script for powershell.

To load completions in your current shell session:

\tworkroom completion powershell | Out-String | Invoke-Expression

To load completions for every new session, add the output of the above command
to your powershell profile.";

pub(super) fn run(_: &Context, args: &Args) -> Outcome {
    let script = match args.positional.first().map(String::as_str) {
        Some("bash") => BASH,
        Some("zsh") => ZSH,
        Some("fish") => FISH,
        Some("powershell") => POWERSHELL,
        // `completion` alone, or with a shell it doesn't know, is its help, as cobra shows it.
        _ => return Outcome::Printed(super::command_help("completion")),
    };
    if let Some(extra) = args.positional.get(1) {
        return Outcome::Usage(CliError::internal(format!(
            "unknown command {extra:?} for \"workroom completion {}\"",
            args.positional[0]
        )));
    }
    if args.is_set("no-descriptions") {
        // Each script names `__complete` once: the request it makes on every Tab.
        Outcome::Printed(script.replacen(" __complete ", " __completeNoDesc ", 1))
    } else {
        Outcome::Printed(script.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_script_makes_its_request_once() {
        for script in [BASH, ZSH, FISH, POWERSHELL] {
            assert_eq!(script.matches(" __complete ").count(), 1);
            assert!(!script.contains("__completeNoDesc"));
        }
    }
}
