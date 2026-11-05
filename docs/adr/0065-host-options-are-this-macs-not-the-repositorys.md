# A boxd or exe.dev host's options are this Mac's settings, not the repository's

Decided 2026-11-04 (owner, grilling `docs/designs/remote-create-options.md`). Status: accepted, not built.

A boxd or exe.dev workroom can be created with host options: a host image (an exe.dev container image or a boxd snapshot) and a size. They are set in Settings for every project, in Project Settings for one project, or for a single create, and the most specific choice wins key by key. They are kept in this Mac's app settings, beside run commands. No file in the repository names them.

This is the opposite of ADR 0060, where a container workroom's image is the repository's to name in devcontainer.json and there is no per-Mac setting. That held because devcontainer.json already exists to name an image, and the container runs on this Mac. A provider host has no equivalent repository file. A boxd snapshot exists only in one account, so a repository naming one would break for everyone else. A repository file that chose an image would also decide what runs with this Mac's provider credentials, which under ADR 0054 makes it a script, needing Approve and Continue Without on every change.

Considered and rejected: a repository file such as `.workroom/host.json` (needs ADR 0054's approval, and snapshot names don't travel between accounts); reusing devcontainer.json's `image` for exe.dev (a devcontainer image is made to run as a container, while a provider host's setup needs one that boots systemd); a raw argument string (it can't be merged level by level, and the app can't show or check what it means). An extra-arguments field beside the typed options was dropped by the eng review of 2026-11-04: a `--team` restores a snapshot without the restart a snapshot host needs, exe.dev parses the words a second time, `--registry-auth` and `--env` would put secrets in config.json, and the list of flags Workroom refuses would have to follow two CLIs. A typed option is added when a real need shows up.

Source: [`docs/designs/remote-create-options.md`](../designs/remote-create-options.md).
