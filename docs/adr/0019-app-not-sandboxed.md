# The app is not sandboxed

The app is distributed with Developer ID and the hardened runtime, with `ENABLE_APP_SANDBOX: NO`. It spawns `git` and the bundled `workroom` binary and opens terminals in arbitrary project directories, which a sandbox does not allow. Terminal children inherit the app as their responsible process, so a TCC prompt for another app's data is attributed to Workroom and cannot be suppressed by an entitlement. The `ghostty` CLI is a relative symlink to the app binary, dispatching on `argv[0]`, rather than a second binary to keep in lockstep on architecture, signing and engine version.

Source: [`macapp/project.yml`](../../macapp/project.yml) (the sandbox comment and the `ghostty` symlink phase), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("The app binary is also the `ghostty` CLI").
