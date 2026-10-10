# Security Policy

## Supported versions

Security fixes ship in the latest stable release and the latest Nightly build. Older releases are not
patched separately; update to the current release to get a fix. Release channels are described in
[CONTRIBUTING.md](CONTRIBUTING.md#release-channels).

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue or pull request for one.

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability**, or go straight to
<https://github.com/joelmoss/workroom/security/advisories/new>.

Include what you need for the maintainer to reproduce it:

- The Workroom version and release channel (stable, pre or Nightly), and your macOS version.
- Whether the problem involves the app, the `workroom` CLI, the `wr-agent` daemon, or a remote host.
- The steps to reproduce it, and what an attacker gains.

Once a fix has shipped, the advisory is published and credits the reporter unless they ask not to be
named.
