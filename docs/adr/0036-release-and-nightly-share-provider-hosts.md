# Release and Nightly share boxd and exe.dev hosts, and each build owns its own container hosts

**Superseded in part by ADR 0060 (2026-10-24):** a container host no longer takes an ssh key; only its Docker labels tie it to the build that made it.

**Extended by [ADR 0071](0071-railway-hosts-never-idle-out-and-each-mac-has-its-own-environment.md) (2026-11-13):** Release and Nightly share Railway hosts too, with one ssh key and environment per Mac, though each build signs in to Railway itself ([ADR 0073](0073-login-with-railway-is-the-first-provider-credential-workroom-keeps.md)); a Dev build has its own.

Every host descriptor records its `provisioner`, the bundle id of the build that made it. A container host takes its build's ssh key and Docker labels, so only the build that made it adopts, sweeps or opens it, and one build's sweep cannot remove another's containers. Hosts on boxd and exe.dev are different: they are reached through the provider's CLI and a key the provider or the user owns (boxd's CLI key, the user's own ssh on exe.dev), so nothing on them belongs to a build. Release and Nightly, which share one config (they are separate products, see ADR 0015), therefore open and delete each other's provider hosts. A Dev build keeps its own config and hosts. The consequence is that a host holds the newest workroomd either build pushed, so the two builds must stay compatible (see ADR 0037).

Source: [`docs/designs/remote-workrooms.md`](../designs/remote-workrooms.md) (Phase 4, "Each build owns its hosts"), [`macapp/WorkroomApp/Core/RemoteHosts/RemoteWorkrooms.swift`](../../macapp/WorkroomApp/Core/RemoteHosts/RemoteWorkrooms.swift) (`ownsHost`, `sharedHostBuilds`), [`cmd/claim.go`](../../cmd/claim.go) (`claim-provisioned`).
