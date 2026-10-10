# Host drivers share code by composing a `HostCLI` value, not by inheriting a base class

Status: accepted, not yet built. The code Boxd and ExeDev repeat (`cli`, `decode`, `CLIFailure`, `awaitIdentity` and the timeout) moves into a `HostCLI` value that each driver holds. `create` and `destroy` stay in each driver with no override hooks, because their policies genuinely differ: Boxd checks the organization and account and removes legacy snapshots, and exe.dev's `cp` is a cold copy. The two drivers already share `PendingMachines` and `HostSetup`, so "one pending journal" means moving the container driver's own journal onto `PendingMachines`. The generic SSH driver depends on the SSH transport seam only, never on a shared base.

Source: [Workroom architecture cleanup plan](https://claude.ai/code/artifact/7c4e90b9-19c7-4283-b5c6-846f6919e17e), engineering review decision D11 (2026-10-10).
