#!/bin/sh
# Points a new Railway sandbox's git at the user's `gh` token (ADR 0072, #631). Run as root over
# the relay, the script on stdin:
#
#   sh -s -- <token file>
#
# Railway has no git integration for sandboxes, so the host holds the Mac's `gh` token in
# <token file>, readable only by root, which the app writes over stdin at create and rewrites on a
# connect when it changed. A credential helper answers github.com from it, and every GitHub remote
# form (scp and ssh://) is rewritten to https, as on exe.dev, so a repository's remote, a
# submodule's or a dependency's never needs an ssh key. System config, for the agent's git and
# every shell's alike.
#
# Safe to run again: it replaces the helper and the rewrites rather than adding to them.
set -eu
token=$1

helper=credential.https://github.com.helper
git config --system --unset-all "$helper" || [ $? -eq 5 ]
git config --system --add "$helper" \
  "!f() { test \"\$1\" = get || exit 0; t=\$(cat '$token' 2>/dev/null) || exit 0; printf 'username=x-access-token\\npassword=%s\\n' \"\$t\"; }; f"

rewrite=url.https://github.com/.insteadOf
git config --system --unset-all "$rewrite" || [ $? -eq 5 ]
git config --system --add "$rewrite" git@github.com:
git config --system --add "$rewrite" ssh://git@github.com/
