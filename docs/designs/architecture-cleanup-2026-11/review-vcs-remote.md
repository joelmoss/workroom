# Architecture review: Version control, Remote hosts, CLI bridge (macapp)

Status: research. Evidence for the [cleanup plan](../architecture-cleanup-2026-11.md), measured at
`65f01f1fa`; its paths and counts are not updated as the plan is built.

Scope: `macapp/WorkroomApp/Core` VCS and remote files, `Packages/{HostDrivers,WorkroomVCS,WorkroomDomain,DaemonConnection,SyntaxHighlighting}`, `Core/WorkroomCLI.swift`. Read-only. All line numbers are as of `65f01f1fa` (master, 2026-11-05).

How the "app-only symbol" claims were measured: I listed all 706 top-level type names declared under `WorkroomApp/` (`grep -ohE "^(…)(enum|struct|class|actor|protocol|typealias) Name"`), then for each file grepped which of those names it uses outside `//` comment lines. "No app references" below means that scan found none.

---

## 1. Top complaints (ranked)

### 1. Provider dispatch leaks out of `HostDrivers` into Core and Views. The driver protocols exist, and the app goes around them.

**Claim.** `HostDrivers` has a good capability stack (`HostDriver`, `ProvisioningHostDriver`, `HostTerminalDriver`, `DaemonPlacingDriver`, `HostDriver.swift:13–163`). But the app picks behaviour by downcasting to concrete drivers, and it keeps four parallel enums of the same provider list.

**Evidence.**
- 19 downcasts to concrete drivers in the app target (`grep -rnoE "as\?? *(Boxd|ExeDev|SSH|Container)HostDriver"`): Boxd 3, ExeDev 3, SSH 6, Container 7. The ones that pick behaviour:
  - `RemoteProvisioning.swift:69–78`: `Environment.made(with:by:)` is an `if let boxd = driver as? BoxdHostDriver … else if let exeDev = driver as? ExeDevHostDriver` chain. `create(options:)` is not on any protocol.
  - `RemoteWorkrooms.swift:1461`: `ensureConnected`, the generic connection policy, does `(driver as? ContainerHostDriver)?.startIfStopped`. At `:1540–1567` (`boxdPresence`) it asks boxd alone whether the host is asleep. At `:1580` it does `as? SSHHostDriver` for `invalidateConnection()`.
  - `RemoteWorkrooms.swift:1266`: `grantRepository: (driver as? ExeDevHostDriver).map {…}`.
  - `AppStore+WorkroomCreation.swift:776,807`: the create flow branches on `host.driver as? ContainerHostDriver` and `as? SSHHostDriver`.
  - `Views/HostOptionsFields.swift:108,116`: a SwiftUI view reaches through `RemoteHosts.shared.driver(.boxd(org:nil,account:nil)) as? BoxdHostDriver` and calls the provider CLI directly.
- Four enums over the same cases: `RemoteWorkrooms.Place` (`RemoteWorkrooms.swift:27`), `RemoteHosts.DriverKey` (`:813`), `CreationKind` (`CreationRun.swift:7`, which is `Place` plus `.local`), and `HostProvider` (`WorkroomDomain/HostOptions.swift:5`). Container runtime appears twice: `RemoteWorkrooms.Runtime {docker, apple}` (`:17`) and `ContainerHostDriver.Dialect {docker, apple}` (`ContainerHostDriver.swift:71`), hand-mapped at `RemoteWorkrooms.swift:1131` and `:1705`. `RemoteWorkrooms.sshDriver = "ssh"` (`:131`) copies `SSHHostDriver.driverName` (`SSHHostDriver.swift:75`), where the other three providers alias their driver's constant.
- Hand-written mappings between the enums: `CreationKind.init(Place)` (`CreationRun.swift:14`), the reverse switch in `retryCreation` (`AppStore+WorkroomCreation.swift:348–352`), `DriverKey.place` (`:889`), `Place.hostProvider` (`:44`), `driverName(_:)` (`:565`) and `hostKind(_:)` (`RemoteProvisioning.swift:329`).
- `Place.remoteProviders` says "A new provider is a case here and an entry in this list" (`RemoteWorkrooms.swift:85–87`). That is not true. exe.dev-specific code is in 11 app files (`grep -rlE "\.exeDev\b|ExeDev"`) and boxd-specific code in 23.

**Cost.** A fifth provider, or a change to how one provider wakes or starts, touches about 12 sites in 6 files: `Place`, `DriverKey` and its `init?`, `CreationKind` and its plan, `RemoteHosts.driver()` (`:993`), `key(for:)` (`:1225`), `environment()` (`:1256`), `hostKind()`, `driverName()`, `setupNeeded` (`AppStore+WorkroomCreation.swift:1053–1066`), `retryCreation`, `kindDescription` (`Models.swift:249`) and `HostOptionsFields.read`. Someone working on the boxd driver in the package cannot change its sleep behaviour without editing `RemoteHosts.ensureConnected`, which is also where the SSH and container connect policy lives, so two driver owners collide in one function.

**Direction.**
- Collapse the four enums onto one `HostKind` value type in `WorkroomDomain` (see complaint 2). It carries `displayName`, `icon`, `hostPhrase`, `credentialHint`, the `WORKROOM_HOST` value, the descriptor `driver` string and whether the kind takes host options.
- Move the per-provider behaviours onto optional capability protocols in `HostDrivers`, the same pattern as `DaemonPlacingDriver`:
  - `HostPresenceReporting.presence(_:)` for boxd.
  - `StartableHostDriver.startIfStopped(_:)` for containers.
  - `ReconnectingHostDriver.invalidateConnection()` for SSH.
  - `OptionedProvisioningDriver.create(options:)` for boxd and exe.dev.
  - `RepositoryGranting.grant(_:)` for exe.dev.
  - `HostRecording.record(of:)`, which fills the driver-owned fields of a descriptor.
- With those in place, `RemoteHosts` and `RemoteProvisioning` switch on capabilities rather than on brands. A view asks a `HostOptionsReader` capability rather than a concrete driver.

**Size and churn.** L. `RemoteHostsTests` (2417 lines), `CreationFlowTests` (1908) and `AppStoreCreateWorkroomTests` (1528) build `DriverKey` and `Place` values directly, so expect mechanical churn across about 4k test lines. Their behaviour assertions stay the same.

### 2. `HostDescriptor` is a flat bag with stringly-typed `driver` and `state`, in the domain package

**Claim.** The value that config stores and every remote decision reads is untyped at the two fields that matter most.

**Evidence.**
- `WorkroomDomain/Model.swift:85–186`. `driver: String?` and `state: String?` sit beside every driver's private fields as optionals: `container` (Docker and Apple), `org` and `account` (boxd), `account` (exe.dev), `sshDestination` and `sshHome` (SSH), `bases` (legacy), and `madeWith` (boxd and exe.dev).
- There are 13 `"creating"`, `"failed"` and `"destroyed"` literals across 4 app files (`RemoteWorkrooms.swift` 8, `Models.swift` 2, `AppStore+WorkroomCreation.swift` 2, `CreationRun.swift` 1).
- `driver` is compared against string constants at `Models.swift:181,187,249,267` and `RemoteWorkrooms.swift:669,822–837,1105,1309`. `DriverKey.init?(HostDescriptor)` (`:821–841`) is a chain of `if descriptor.driver == …` checks.
- The doc comment at `Model.swift:87–88` lists only `container`, `apple-container` and `boxd`. It is missing `exedev` and `ssh`.
- ADR 0020's title and body still say "Project and Workroom stay in the app for now", but they are in `WorkroomDomain/Model.swift` today. The ADR is stale, not wrong in intent.

**Cost.** Adding a host state (for example a `migrating` state) means grepping literals across 4 files, and the compiler finds none of them. Every new driver adds more optionals that are meaningless for the other drivers, so a reader cannot tell which fields a given host has.

**Direction.**
- Keep the lenient decode, which is deliberate per the comment at `Model.swift:82–84`.
- Expose typed views: `var kind: HostKind?` (nil means a driver this build doesn't know) and `var lifecycle: HostLifecycle {serving, creating, failed, destroyed, unknown(String)}`. This follows ADR 0014's untyped store with read-only typed views, applied on the Swift side.
- Optionally group the per-driver fields under a `DriverRecord` enum later. The typed views alone remove the string compares.
- Amend ADR 0020's text so it matches the code.

**Size and churn.** S for the typed views. Test churn is small: tests construct descriptors through the memberwise init, which stays.

### 3. `RemoteWorkrooms.swift` (1719 lines) holds two unrelated types, and SSH is a forked copy of the lifecycle rather than a variant of it

**Claim.** The file holds two types with different change rates and owners:
- `RemoteWorkrooms`, the create, delete and script sequencing (`:1–806`).
- `RemoteHosts`, a process-wide driver registry, connection, backoff, sleep, relay, selection and sweep state machine under one `NSLock` (`:807–1719`; ten mutable dictionaries and sets at `:900–926`).

Inside `RemoteWorkrooms`, SSH has its own copy of create and delete.

**Evidence (duplication).**
- Clone and checkout: `createSSH` `RemoteWorkrooms.swift:377–394` and `RemoteProvisioning.provision` `RemoteProvisioning.swift:194–210` both run `git clone --quiet --origin origin -- <url> <path>`, wrap the failure in `credentialHint`, then run `git switch --quiet --no-track --create <branch> <startCommit ?? refs/remotes/origin/<base>>`.
- Rollback on failure: `RemoteWorkrooms.swift:403–425` and `RemoteProvisioning.swift:211–224`. Both close the connection inside `Task {}`, undo, and on undo failure throw `rollbackIncomplete`.
- Teardown dispatch: `delete` `:691–708` and `deleteSSH` `:745–758` build the same `ScriptRequest(script: .teardown, …)` and the same four-case `switch` over `.failed`, `.notTrusted`, `.absent` and `.passed`.
- Dispatch is by string: `delete` begins `if host.driver == sshDriver { return try await deleteSSH(…) }` (`:669`).

ADR 0056 mandates the different *semantics* for SSH hosts: no destroy, a marker-guarded folder, the daemon is never stopped, and shared state goes only with the last workroom. It does not mandate copying the clone, checkout and teardown code.

**Seam leak.** `delete` takes `hosts: RemoteHosts = .shared` but calls `RemoteHosts.shared.forgetRelay(id)` directly at `:723`, while `deleteSSH` uses the injected `hosts.forgetRelay(id)` at `:785`. A test that injects a fake `RemoteHosts` still reaches the real one on the provider path.

**Cost.**
- A change to how a workroom is cloned, such as `--filter`, a submodule step or a new progress row, has to be made twice. Missing one copy gives the SSH-versus-provider parity drift that `docs/remote-host-states.md` "Parity with local" warns about.
- The create flow and the connection policy can't be owned separately. Anyone touching wake or backoff edits the same 1.7k-line file that the delete flow lives in, and `RemoteHostsTests` (2417 lines) is a single test file for both concerns.

**Direction.**
- Split the file into `RemoteWorkroomLifecycle` (create, delete, runScript) and `RemoteHosts`. Then split `RemoteHosts` again into `HostDriverRegistry` (`driver()`, `key(for:)`, `environment()`, adopt and sweep) and `HostReachability` (`ensureConnected`, `activate`, `select`, backoff, relay).
- Model the place a workroom lives as a protocol with two conformers:
  - `ProvisionedHostPlacement`, used by boxd, exe.dev and containers: reserve, make the host, checkpoint, unmake the host.
  - `SSHFolderPlacement`: check the host, resolve the parent, reserve in the parent, make the folder and marker, unmake the folder.
- Run one shared `cloneAndCheckOut(on:)` and one `runTeardown(_:)` over either placement.

**Size and churn.** M. The file split is mechanical. The placement protocol touches `RemoteProvisioningTests` (837), `SSHWorkroomTests`, `RemoteWorkroomDeletionTests` and `RemoteHostsTests`, mostly in their setup code.

### 4. The Version control context is spread over three modules with no single owner, and its wire contract is split in two

**Claim.** "Version control" (one context in `CONTEXT.md`) is spread across:
- `Packages/WorkroomVCS`: values only (`VCSModels`, `VCSWriteResults`, `WorkroomStatus`), `LocalVCSProviding`, `HostID` and `RepositoryRoutingError`. About 1.1k source lines and 112 test lines.
- `Packages/DaemonConnection`: the multiplexed daemon client and `DaemonVCSRequest` (`DaemonVCSConnection.swift:1043`).
- About 25 flat files in `WorkroomApp/Core`:
  - The service protocols themselves, `VCSProviding` and `VCSWriting` (`RepositoryServices.swift:6,19`).
  - The router and context (`RepositoryLocation.swift`).
  - The local engine (`GitProvider` and the four libgit2 files).
  - The git CLI writer (`VCSWriting.swift`, 1311 lines).
  - The daemon adapters (`DaemonVCSReader`, `HostRepositoryServices`, `LocalDaemonVCS`, `DaemonCommandRunner`, `DaemonVCSConnection+Services`).
  - The daemon VCS *reply* shapes (`DaemonCommit`, `DaemonStatus` and others, `DaemonVCSReader.swift:77–200`).
  - The GitHub resolution (`WorkroomStatusResolver`, `RepositoryGitHub`, `GitHubRepository`).
  - Presentation (`VCSSyncPresentation`, `RemoteStateModel`, `ChangeBadge`, `HistoryModel`).

**Smells with evidence.**
- **The wire is split across modules.** The VCS request type is in `DaemonConnection` and the reply types are in the app, so one daemon protocol change spans a package and the app. `DaemonVCSProtocolTests`, which tests the decode contract, has to be a hosted app test.
- **`DaemonVCSConnection` names the whole daemon connection.** It carries VCS, File, Control, Forward, ProgramStatus and session requests (`DaemonVCSConnection.swift:321–609`). It has 49 references. `CONTEXT.md` defines **Service** as one capability, so the "VCS" in the name misleads.
- **The host identity lives in the VCS package.** `HostID` is defined in `WorkroomVCS/RepositoryRouting.swift:4`, so `HostDrivers` imports the VCS package just to name a host (`HostDriver.swift:5`). It also borrows `RepositoryRoutingError.olderLayoutMessage` from there (`:202`).
- **`GitProvider` imports `SyntaxHighlighting` for one constant.** The VCS read layer depends on a view-layer limit (`SyntaxLanguage.byteCap`, `GitProvider.swift:3,226`).
- **A file name collides.** `Core/WorkroomStatus.swift` declares `VCSStatusPresentation` and `PRPresentation` (`:8,:110`), while `WorkroomVCS/WorkroomStatus.swift` declares `WorkroomStatus`. They are the only two non-boilerplate Swift files in the repo with the same basename (`find … | xargs -n1 basename | sort | uniq -d`).

**Cost.** A new read, for example "blame", touches 6 places:
1. The `VCSProviding` protocol (app).
2. `BoundLocalReader` (app).
3. `GitProvider` (app).
4. `DaemonVCSReader` and a new reply DTO (app).
5. `DaemonVCSRequest`, if fields change (package).
6. Possibly the `LocalVCSProviding` protocol (package).

Nobody can own "VCS" as one module, and its tests run under `make app-test`, which takes the shared GUI lock (`macapp/AGENTS.md`, Isolation).

**Direction.** See section 3, the `WorkroomVCS`, `WorkroomGit` and `WorkroomDaemonVCS` split.
- Move `VCSProviding`, `VCSWriting`, `RepositoryLocation` and `RepositoryContext` into `WorkroomVCS`. Keep the router-only construction of `RepositoryContext` with a `package` init, or keep the router in the same module.
- Move the daemon VCS reply DTOs beside `DaemonVCSRequest`.
- Rename `DaemonVCSConnection` to `DaemonConnection`, or `DaemonClient`.
- Move `HostID` to `WorkroomDomain`.

**Size and churn.** M. Moves only, so tests change only their `import` lines, but the move needs `public` annotations on about 40 types.

### 5. About 5k lines of pure, package-ready code sit in the app target, with about 7k lines of tests run hosted

**Claim.** ADR 0020's direction is "reusable app code lives in Packages". These clusters have no app-shell references (method in the header) and could move today.

| Cluster | Files (lines) | Only outside references | Hosted tests that would become `swift test` |
|---|---|---|---|
| Local git engine | `GitProvider` 517, `LibGit2` 93, `GitGraph` 149, `GitCommitDiff` 241, `GitDiffStats` 92, `UnifiedDiff` 236, `VCSWriting` (CLIVCSWriter) 1311, `RepositoryWriteGate` 113, `RepositoryDisk` 63 | `RepositoryLocation`; `WorkroomStatusResolver.gitHardening`, used 15× in `VCSWriting.swift` and nothing else from that type | `VCSWritingTests` 1008, `GitGraphTests`, `GitCommitDiffTests`, `UnifiedDiffTests`, `RepositoryWriteGateTests`, `GitProviderCoAuthorsTests` |
| VCS presentation | `VCSSyncPresentation` 834, `ChangeBadge`, `VCSToolVersions` | none (`SemanticVersion` only) | `VCSSyncPresentationTests` |
| Dev Containers spec | `DevContainerConfig` 495, `DevContainerFeatures` 650, `DevContainerSetup` 195 | `RemoteWorkrooms.Runtime` and `FileProviding`, one function each | `DevContainerConfigTests`, `DevContainerFeaturesTests`, `DevContainerSetupTests` |
| Port-forward pumps | `DaemonPortForwarding.swift:1–995` (`DaemonForwardService`, `PortForward`, `ReverseForward`, wire requests) | wire types only; the `@MainActor PortForwardingModel` is `:996–1321` | part of `DaemonPortForwardingTests` (1725) |

The 14 listed hosted test files total 6958 lines (`wc -l`).

ADR 0002 limits raw libgit2 to four named files, and that still holds: `grep -rln "^import libgit2"` returns exactly `LibGit2`, `GitGraph`, `GitCommitDiff` and `GitDiffStats`. Moving those four files keeps them the only four, so the decision stands. The ADR's paths would need updating.

**Cost.**
- Every edit to the git writer or the devcontainer parser is verified by `make app-test`: an app build plus the GUI lock. That makes it serial with every other workroom's UI run.
- A contributor who only knows git can't run the git writer's 1008 lines of tests with `swift test`.

**Direction.**
- `Packages/WorkroomGit` (SwiftGitX and libgit2 pins, depends on `WorkroomVCS` and `WorkroomSystem`), holding the libgit2 files, `GitProvider`, `UnifiedDiff`, `IntraLineDiff`, `DiffRunPairing`, `CLIVCSWriter`, `RepositoryWriteGate`, and `gitHardening` as a `GitCommand` constant.
- `Packages/DevContainer`, which depends on `HostDrivers` for `ContainerHostDriver.Dialect`, so `Runtime` folds into it.
- Move the port-forward pumps into `DaemonConnection`.

**Size and churn.** M per cluster. The tests move as they are, with `@testable import Workroom` replaced.

### 6. `HostDrivers` depends at runtime on the app bundle, so its own tests can't cover create

**Claim.** `HostSetup.script` (`HostDriver.swift:105–110`) reads `Bundle.main.url(forResource:…, subdirectory: "host-setup")`. `BoxdHostDriver.create` (`:149`) and `ExeDevHostDriver.create` (`:156,161`) call it. A package that only works when `Bundle.main` is Workroom.app contradicts what ADR 0020 means by "never depends on the app". It compiles, but the package cannot run its own create path under `swift test`.

**Evidence.** This is why the driver tests live in `WorkroomAppTests`:
- `BoxdHostDriverTests`: 747 lines, 26 tests. Its only app references are `RemoteWorkrooms.boxdDriver` (`:320,340`), which equals the package's `BoxdHostDriver.driverName`, and one comment.
- `ExeDevHostDriverTests`: 1009 lines, 38 tests. It mixes in `ExeDevSetup` (18 references).
- `HostStreamTests`: 738 lines.

`Packages/HostDrivers/Tests` totals 1305 lines and has no boxd or exe.dev tests.

**Contradicts ADR 0020 because** the package's create path reads resources that only the app bundle has.

**Cost.** Changing a provider driver means a full app build and a hosted test run to see the driver's own unit tests.

**Direction.**
- Put `host-setup/*.sh` in the package as SwiftPM resources (`Bundle.module`), or inject the script text through `Configuration`.
- Move `BoxdHostDriverTests` now: it is a 2-line change.
- Split `ExeDevHostDriverTests` into a driver part (package) and an `ExeDevSetup` part (app).

**Size and churn.** S. About 1.7k test lines move.

### 7. `WorkroomStatusResolver` is the app's git and GitHub utility belt, and creation planning depends on it

**Claim.** `WorkroomStatusResolver.swift` (791 lines) holds four things:
- Working status through the router (`:66–126`).
- All `gh` probing and classification (PR, CI rollup, checks, auth, about `:150–791`).
- 7 raw `git` shell-outs with their own argv: `originURL`, `remoteNames`, `originHasBranch` (`:186,193,203`) and `localBranch`, `localCICommit` (`:357,371`).
- The repository-wide `gitHardening` constant (`:62`).

**Evidence.**
- `AppStore+WorkroomCreation.planRemoteCreate` (`:1093–1135`) builds a create plan from `WorkroomStatusResolver().remoteNames/originHasBranch/originURL`.
- `VCSWriting.swift` reads `WorkroomStatusResolver.gitHardening` 15 times.
- `docs/macapp/vcs-and-sessions.md` says the resolver reads "through this layer — no CLI text parsing". The raw git calls are the exception.
- The hardening comment says the flags are "prepended to every `git` invocation", but `:186`, `:193` and `:203` don't prepend them. Those commands don't read the index, so `core.fsmonitor` cannot fire and there is no exploit. The claim is still wrong as written, which is the kind of comment that misleads a reviewer.

**Cost.**
- Two people can't work in parallel on the PR panel (gh) and the working-status sweep: one 791-line type and one 1069-line test file (`WorkroomStatusResolverTests`).
- A git-hardening change has to find call sites in two types.

**Direction.**
- Split it into `WorkingStatusResolver` (router reads), `GitHubStatusResolver` (gh), and a small `GitRepositoryProbe` (origin, remotes and branch, behind `VCSProviding` or `RepositoryGitHub`).
- Move `gitHardening` into the `WorkroomGit` package as the one place git argv starts.

**Size and churn.** M. `WorkroomStatusResolverTests` splits along the same seams.

### 8. Remote lifecycle code calls UI singletons, and drivers are built in six places

**Evidence.**
- `RemoteWorkrooms.delete` and `deleteSSH` call `PortForwardingModel.forgetHost` and `forgetWorkroom` (a `@MainActor ObservableObject`) and `ProgramStatusMonitor.shared.forget` (`:679–680`, `:778`, `:781`). The domain sequence knows about two UI-facing models.
- Singleton reach: `RemoteHosts.shared` has 28 references in 13 files, and `HostConnectionManager.shared` has 20 in 6 files (grep counts).
- Drivers are constructed outside the `RemoteHosts.driver()` factory at:
  - `AppStore+WorkroomCreation.swift:1059`
  - `BoxdSetup.swift:65`
  - `SSHHostSetup.swift:46`
  - `TerminalSessions.swift:3152`
  - `RemoteWorkrooms.swift:1234` and `:1242`

  These sites pass different `directory:` values. The factory and `SSHHostSetup` pass `RemoteHosts.hosts`. `BoxdSetup`, `key(for: .boxd)` and the `TerminalSessions` fallback pass `RemoteHosts.directory`, which is the parent folder. Whether that matters depends on what each throwaway driver writes. I did not prove a bug here; see the open questions.

**Cost.** A test of the delete flow needs the real `PortForwardingModel` and `ProgramStatusMonitor` singletons. A change to where a driver keeps its files, such as the pending journal, has to find six constructors.

**Direction.** The delete sequence takes an `onForgotten(host, workroom)` callback, and the app shell wires it to the two models. All driver construction goes through `HostDriverRegistry` (complaint 3), including "a throwaway driver for setup" (`registry.probeDriver(for: kind)`).

**Size and churn.** S.

### 9. ADR 0023 (`HostCLI` value) was accepted on 2026-10-10 and is still not built

This is drift against a recorded decision, not a new design point. The ADR says "Status: accepted, not yet built."
- Both provider drivers keep private copies:
  - `CLIFailure`: Boxd `BoxdHostDriver.swift:287–299`, ExeDev `ExeDevHostDriver.swift:720–724`.
  - `decode`: Boxd `:462–468`, ExeDev `:748–759`.
  - `cli`: Boxd `:479–503`, ExeDev `:762–773`.
- The ADR says to move the container driver's journal onto `PendingMachines`. `ContainerHostDriver` still keeps its own `pending-containers-*` file (`:683–705`), while Boxd and ExeDev use `PendingMachines` (`BoxdHostDriver.swift:202–231`, `ExeDevHostDriver.swift:240–267`).

**Cost.** A change to how the journal is swept (ADR 0038) has two implementations to keep in step.

**Size.** S.

### 10. `Core/SyntaxHighlighting/` is misnamed and mixes layers

`Core/SyntaxHighlighting/` holds four files and sits beside `Packages/SyntaxHighlighting`.
- `DiffHighlightMapper` and `FileHighlightMapper` import SwiftUI or AppKit and reference views (`DiffViewer`, `CodeTextView`, `PlainFileViewer`). They belong in the app, but they are view code under `Core/`.
- `IntraLineDiff` (99 lines) and `DiffRunPairing` (33 lines) are pure diff algorithms that reference only `UnifiedDiff`. They have nothing to do with syntax highlighting.

**Cost.** Someone looking for the diff model finds half of it in a folder named for highlighting.

**Direction.** Move the two pure files beside `UnifiedDiff` (into `WorkroomGit`). Move the mappers to `Views/Diff/`.

**Size.** S.

### 11. The CLI bridge: the contract is well pinned, but its error mapping and tests live in the app

- The good part: the `--json` envelopes are in `WorkroomDomain/Model.swift:274–541`, and `CLIContractTests` decodes the Go goldens in `testdata/contracts`, which `cmd/contract_test.go` checks byte for byte.
- `CLIContractTests` still has to run hosted, because it references `WorkroomCLIError`, `IncludeArchive` and `CreationRun`.
- `WorkroomCLIError(envelope:)` and its error-kind helpers (`WorkroomCLI.swift:6–87`) turn the envelope's `error.kind` strings into app errors. That mapping is part of the contract, but it lives next to process plumbing.

**Direction.** Move the envelope-to-error mapping (`WorkroomCLIError`) into `WorkroomDomain` next to `CLIErrorBody`, so the contract test is a `swift test` in that package. `WorkroomCLI.run` keeps its own `Process` runner (`:685–783`). That is justified: `StatusCommandRunner` has no line-streaming mode, and the CLI's NDJSON events need one.

**Size.** S.

---

## 2. Dead code and duplication

### Dead code

**Nothing provable.** Scan: for every `func`, `var`, `let`, `static` and `case` name of 5 or more characters declared in the 40 VCS, remote and CLI files, I counted whole-word occurrences across a corpus of every `.swift` file under `WorkroomApp`, `WorkroomAppTests`, `WorkroomAppUITests` and `Packages` (no `.build`). Names with 1 or fewer occurrences:
- `GitCommitDiff`: `GIT_DELTA_*`. These are C enum case labels, not dead.
- `DevContainerFeatures.urlSession`: the `URLSessionTaskDelegate` method (`:518`). Called by Foundation, not dead.
- `DaemonVCSReader`: `changeId`, `changeOffset`, `divergentSiblings`, `isWorkingCopy`. These are jj-era wire fields on `DaemonCommit` (`:144–158`). ADR 0007 keeps them *on the wire*. They are **candidate (grep) dead on the app side**: the app decodes them and never reads them.
  - `isWorkingCopy: Bool`, `isRoot: Bool` and `divergentSiblings: [DaemonCommit]` are non-optional. That makes this app one of the "older apps [that] decode the fields as non-optional" which ADR 0007 waits on before the daemon can prune them.
  - The comment at `:119–121` says they are "still decoded so an older daemon's replies keep parsing". That is wrong: `JSONDecoder` ignores keys a struct doesn't declare. Removing the five fields is safe against every daemon, and it lets a future daemon prune them sooner.
  - Keep `DaemonRefKind.ancestor`. Removing that enum case would fail decoding on an older daemon.

### Duplication (all sites)

| What | Sites |
|---|---|
| Clone and checkout on a new host | `RemoteWorkrooms.swift:377–394` and `RemoteProvisioning.swift:194–210` |
| Rollback after a failed create | `RemoteWorkrooms.swift:403–425` and `RemoteProvisioning.swift:211–224` |
| Teardown request and result switch | `RemoteWorkrooms.swift:691–708` and `:745–758` |
| Provider enum taxonomy | `Place` `RemoteWorkrooms.swift:27–112`, `DriverKey` `:813–897`, `CreationKind` `CreationRun.swift:7–31`, `HostProvider` `HostOptions.swift:5–22`; plus `Runtime` `RemoteWorkrooms.swift:17–24` and `ContainerHostDriver.Dialect` `ContainerHostDriver.swift:71–74`, mapped at `RemoteWorkrooms.swift:1131,1705` |
| SSH driver name | `RemoteWorkrooms.swift:131` and `SSHHostDriver.swift:75` |
| `CreationKind` to `Place` (both directions) | `CreationRun.swift:14–21` and `AppStore+WorkroomCreation.swift:347–353` |
| Provider CLI plumbing (ADR 0023, planned) | Boxd `:287–299,462–503` and ExeDev `:720–724,748–773` |
| Pending-host journal (ADR 0023, planned) | `ContainerHostDriver.swift:683–705` and `PendingMachines.swift` |
| Base-branch split, Go and Swift twins | `internal/vcs/git.go:148` and `RemoteWorkrooms.swift:198`. Each side is pinned by its own hand-copied table (`vcs_test.go:352`, `TerminalTargetTests.swift:88`), not a shared golden. The fallback-to-default policy around it is also reimplemented in Swift (`AppStore+WorkroomCreation.swift:1114–1128` against the Go `startPoint` fallback, `git.go:155+`). It is pinned on both sides, so this is low priority. A shared `testdata` table would make the twin explicit. |

---

## 3. Proposed target structure

The dependency direction is upward only, per ADR 0020.

```
WorkroomDomain     HostID (moved from WorkroomVCS), HostKind, HostLifecycle, HostDescriptor (typed views),
                   Project/Workroom, CLI envelopes + WorkroomCLIError mapping
   ↑
WorkroomVCS        values + protocols: VCSProviding, VCSWriting, LocalVCSProviding,
                   RepositoryLocation, RepositoryContext (package init), RepositoryRoutingError
   ↑
WorkroomGit        (new; SwiftGitX + libgit2 pins) GitProvider, LibGit2/GitGraph/GitCommitDiff/GitDiffStats
                   (still the only raw-libgit2 files, ADR 0002), UnifiedDiff, IntraLineDiff, DiffRunPairing,
                   CLIVCSWriter + its classifier (ADR 0034), RepositoryWriteGate, GitCommand (hardening)
DaemonConnection   DaemonConnection (renamed from DaemonVCSConnection), VCS request AND reply DTOs,
                   DaemonVCSReader, port-forward pumps (PortForward, ReverseForward, DaemonForwardService)
   ↑
HostDrivers        HostDriver + capability protocols (presence, start, invalidate, create(options:),
                   grant, record), HostCLI (ADR 0023), PendingMachines for all, host-setup scripts as
                   Bundle.module resources; all driver unit tests
DevContainer       (new) DevContainerConfig, DevContainerFeatures, DevContainerSetup
   ↑
App: Core/Remote/  HostDriverRegistry (the one constructor), HostReachability (ensureConnected/backoff/
                   relay), RemoteWorkroomLifecycle over a Placement (provisioned host | SSH folder),
                   CredentialRelay, ContainerCreate, provider setup flows (BoxdSetup/ExeDevSetup/SSHHostSetup)
App: Core/VCS/     RepositoryRouter (composition), WorkingStatusResolver, GitHubStatusResolver,
                   RemoteStateModel, VCSSyncPresentation (or a WorkroomVCSUI package)
App: Views/        never touches RemoteHosts.shared or a concrete driver; it asks the store
```

Ownership:
- **The VCS owner** owns `WorkroomVCS`, `WorkroomGit` and `Core/VCS`.
- **The host-driver owner** owns `HostDrivers` and `DevContainer`, and can add a provider by implementing capabilities, without editing `RemoteHosts`.
- **The remote-lifecycle owner** owns `Core/Remote`.
- **The daemon-protocol owner** owns `DaemonConnection`, including both directions of the VCS wire.

Each owner can run their tests with `swift test`, except for the `Core/*` composition.

---

## 4. Good, and worth keeping

- **The `HostDriver` protocol split.** A byte stream, not an ssh endpoint (ADR 0028). Provisioning is a separate protocol, so an SSH host *cannot* be destroyed by construction (ADR 0056, `HostDriver.swift:35–41`). `DaemonPlacingDriver` and `HostTerminalDriver` are capabilities rather than base classes. Extend this pattern, don't replace it.
- **`RepositoryLocation` and `RepositoryContext`.** Only validation produces a location, remote paths are validated without local filesystem access, contexts are router-built only (`fileprivate init`), and `BoundLocalWriter` refuses a remote context unless its writer names that host (`RepositoryServices.swift:83–92`). Preserve these when moving to a package.
- **`RepositoryWriteGate` and the one-classifier rule** for local and remote writes (ADR 0034). The duplication was avoided where it would have hurt most.
- **The `--json` contract goldens** in `testdata/contracts`, checked on both sides.
- **`RemoteSetup`.** One sheet shell for boxd, exe.dev and SSH setup, with per-provider steps (`RemoteSetup.swift`, `RemoteSetupSheet`).
- **The `docs/remote-host-states.md` table.** States, the call to make in each, and the meaning of exit statuses over ssh. It is the right artefact for this domain.
- **ADR 0002 still holds exactly.** Four raw libgit2 files, verified by grep.

---

## 5. Open questions for the owner

1. Is `DaemonVCSConnection` → `DaemonConnection` (or `DaemonClient`) an acceptable rename now, or does it wait with the other wire names under ADR 0006 or 0057?
2. Should provider-specific behaviour in `ensureConnected` (boxd presence, container start) move behind capability protocols, given that the semantics are tuned per provider (ADR 0017, ADR 0038, #380)? I'd keep the policy in the app and the facts in the driver, but you have more context on where they'll diverge.
3. The driver constructors pass `RemoteHosts.directory` in three places and `RemoteHosts.hosts` in the factory (complaint 8). Is that intended, for example because a setup-only driver never writes? I couldn't tell from the code alone, and a boxd driver built with `directory` would write `PendingMachines` entries one folder up if it ever created.
4. Moving the libgit2 files into a `WorkroomGit` package means rewording ADR 0002's file paths, not its decision. Is that fine, or do you want the four files kept in the app target on purpose?
5. For remote creates, should the CLI report the resolved base remote and branch and the default-not-used notice (it already resolves the start commit in `trust status --base`), so the Swift twin of the base-branch policy can go?

<!-- summary: provider dispatch leaks (19 downcasts, 4 parallel enums), stringly HostDescriptor, RemoteWorkrooms.swift two types + forked SSH lifecycle, VCS split across 3 modules with split wire, ~5k package-ready lines in app, HostDrivers reads Bundle.main -->
