#!/bin/sh
# Points a fresh exe.dev VM's git and gh at exe.dev's GitHub integration (`ExeDevHostDriver.create`
# runs it as root, with this script on stdin):
#
#   sudo sh -s -- <profile.d directory>  < exedev-github.sh
#
# exe.dev answers for a repository only at https://github.int.exe.xyz, injecting the user's GitHub
# credential at its edge, so the VM never holds a token (spike, 2026-10-12). A workroom clones its
# project's origin as it is, https or scp form, and a submodule or dependency may be written either
# ssh way, so system config rewrites all three to that host, for the agent's git and every shell's
# alike. gh takes the host from GH_HOST, which every login shell
# reads from profile.d. The integration itself is the user's: `ssh exe.dev integrations add github
# --name <name> --repository <owner/repo> --act-as-user --attach auto:all`.
#
# Safe to run again: it replaces the rewrite rather than adding to it.
set -eu
profile=$1

rewrite=url.https://github.int.exe.xyz/.insteadOf
git config --system --unset-all "$rewrite" || [ $? -eq 5 ]
git config --system --add "$rewrite" https://github.com/
git config --system --add "$rewrite" git@github.com:
git config --system --add "$rewrite" ssh://git@github.com/
echo 'export GH_HOST=github.int.exe.xyz' > "$profile/workroom-github.sh"
