# Host drivers share code by composing a `HostCLI` value, not by inheriting a base class

Status: accepted, not yet built. The code Boxd and ExeDev repeat (`cli`, `decode`, `CLIFailure`, `awaitIdentity` and the timeout) moves into a `HostCLI` value that each driver holds. `create` and `destroy` stay in each driver with no override hooks, because their policies genuinely differ: Boxd checks the organization and the account and, on destroy, removes the snapshots an older build's derive left, while exe.dev checks only the account. The two drivers already share `PendingMachines` and `HostSetup`, so "one pending journal" means moving the container driver's own journal onto `PendingMachines`. The generic SSH driver depends on the SSH transport seam only, never on a shared base.

Source: the maintainer's architecture cleanup plan (a private planning document, not in this repository), engineering review decision D11 (2026-10-10).
