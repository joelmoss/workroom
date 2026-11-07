# Review: Go CLI, cross-language contracts, repo organization

Status: research. Evidence for the [cleanup plan](../architecture-cleanup-2026-11.md), measured at
`65f01f1fa`; its paths and counts are not updated as the plan is built.

Read-only review, 2026-11-05, master at 65f01f1fa. Scope: Go (`cmd/`, `internal/`), cross-language duplication, repo-level layout.

## 1. Top complaints (ranked)

### 1. `internal/workroom/workroom.go` is a 976-line `Service` that owns create, list, delete, interactive delete, teardown and remote variants
- Evidence: 32 funcs on one `Service` (`grep -c "^func "`). `CreateNamed` starts at :218 and runs to ~:378 (about 160 lines of sequential steps). `Listing` :594, `Delete` :659, `InteractiveDelete` :775, `RunTeardown` :858, `deleteByName` :922, `forgetDestroyedRemote` :963. Interactive prompting is injected as `PromptFn`/`ConfirmFn` fields (:36-37), so UI flow control lives inside the domain service. Sibling files already split out `start.go`, `include.go`, `list_data.go`, `trust.go`, `add_project.go` and `delete_project.go`, so the split was begun but not finished for the two biggest workflows.
- Cost: two people changing create (remote create, start choice, include copy) and delete (remote refusal, non-git forget, destroyed-remote) hit the same file and the same struct. Reviewing a `CreateNamed` change needs the whole file in your head.
- Direction: split by use case in the same package: `create.go`, `delete.go`, `listing.go`, with a small `Service` holding only deps. Move `InteractiveDelete` (prompt orchestration) up into `cmd/` or behind a narrow `Picker` interface, so `internal/workroom` has no interactive concepts. The `ui` import there is only `ui.DisplayPath` (:247), a formatting helper that belongs in `errs` or a path helper.
- Size: M. Test churn: low if methods stay on `Service` (file moves only); moderate if `InteractiveDelete` moves.

### 2. The `--json` contract is hand-built `map[string]any` on the Go side and hand-decoded on the Swift side, kept in sync only by goldens
- Evidence: 24 `cmd/*.go` files use `map[string]any` (e.g. `cmd/json.go:15-31` `scriptJSON`/`localWorkJSON`, `jsonErrorExtra map[string]any`). `schemaVersion = 1` (`cmd/json.go:~40`). The goldens are good (see section 4): `cmd/contract_test.go` writes `testdata/contracts/*.json` and `macapp/WorkroomAppTests/CLIContractTests.swift` decodes the same files. The Swift types are hand-mirrored (`WorkroomDomain/Model.swift` and app-side payload structs).
- Cost: adding a field means editing a map literal in `cmd/`, the golden, the Swift struct and `docs-site/pages/reference/json-output.md`, with nothing forcing the fourth. Typos in map keys are invisible to the Go compiler. A key renamed in Go fails only if a golden covers that path; commands the app decodes only as a bare Envelope (`host`, `base`, `claim-provisioned`) are explicitly outside the goldens (`cmd/contract_test.go` header comment).
- Direction: ADR 0013 pins the contract, not the construction. Replace map literals with one typed struct per command payload in a `cmd/payload` (or `internal/contract`) file, marshalled by `writeJSONSuccess`. The goldens then become a regression check rather than the only type check. Optionally generate a JSON Schema from the structs and make the docs-site page and Swift decoders test against it.
- Size: M. Test churn: low, because the goldens are byte-for-byte and stay the oracle.

### 3. Config-file path and schema knowledge exists in Go and Swift, and the app reads the CLI's config directly
- Evidence: Go `internal/config/config.go:117` (`~/.config/workroom/config.json`); Swift `macapp/WorkroomApp/Core/WorkroomCLI.swift:390` (`NSHomeDirectory() + "/.config/workroom/config.json"`), plus comments or logic in `ProjectStore.swift:22`, `AppStore.swift:2379`, `WorkroomApp.swift:260`. ADR 0014 says the Go config is an untyped map with read-only typed views, so the Swift side is another reader of the same file.
- Cost: moving or renaming the config (XDG, profile support, a schema bump) needs a Go change and a Swift change that no test links. The path string appears in at least two runtime sites.
- Direction: let the CLI own the path: a `workroom config path --json` (or the existing `list --json`) already carries what the app needs. Failing that, one Swift constant in `WorkroomSystem` and a cross-language golden of a config file that both sides parse.
- Size: S to M. Test churn: low.

### 4. `.worktreeinclude` filename and its presence check are duplicated in the app
- Evidence: Go constant `IncludeFile = ".worktreeinclude"` at `internal/workroom/include.go:18`. Swift: `macapp/WorkroomApp/Core/AppStore+WorkroomCreation.swift:129` (`project.path + "/.worktreeinclude"`) decides whether to show the "Copy local files" row; `CreationRun.swift:232` documents the same rule.
- Cost: a rename or a second include file (for example a different name in a monorepo) needs two edits and the UI could silently disagree with the engine. Today the app re-implements engine logic (does this project have an include list?) that the CLI could report (`include-archive` already exists as a command, `cmd/include_archive.go`).
- Direction: put a `has_include` field on the project payload in `list --json`, and delete the Swift file check. Size: S. Test churn: one Swift test plus one golden.

### 5. Login-shell environment capture is implemented three times (Go, Swift, Rust)
- Evidence: Swift `WorkroomSystem/ShellEnvironment.swift:15,42-57` (`$SHELL -ilc`, `loginShellInvocation`, flag `-lic`/`-lc`). Go `internal/script/login_environment_unix.go:29-36,108-115` (`loginEnvironment`, `loginShellInvocation` with the same `-lic` rule). Rust `vcs/crates/workroomd/src/shell.rs` (login shell invoked with a leading dash, plus `run_script.rs` "loginReadTimeout matches workroomd run-script's"). The Go file's own comment says it does it "the way ShellEnvironment.probe" does, and a Go var comment says the timeout "matches workroomd run-script's". Parity is kept by comments alone.
- Cost: the exact class of bug #560 was (a shell flag or marker-parsing detail) must be fixed in up to three places with no shared fixture. Shells that differ (fish, csh, Apple bash) already have a branch in each.
- Direction: do not unify the code (three runtimes, ADR 0005's spirit), but add one shared fixture table (shell path to expected program/flag) read by the three test suites, as `internal/channel/testdata/channel_cases.tsv` already does for channels. Size: S. Test churn: low.

### 6. Release-channel classification: three implementations, only two share a fixture
- Evidence: Go `internal/channel/channel.go` (148 lines), shell `macapp/Scripts/channel-helper.sh` (59 lines, `wr_classify_channel`), Swift `macapp/WorkroomApp/Core/ReleaseChannel.swift` (68 lines). `.agents/skills/curate-release/SKILL.md:35-37` says "keep the three in lockstep". Go and shell share `internal/channel/testdata/channel_cases.tsv` (Go: `channel_test.go:20`, shell: `channel-helper_test.sh:16`). The Swift file does NOT classify tags (its header says "The app never classifies tags itself"); it maps subscription to Sparkle channel names, tested in `WorkroomAppTests/ReleaseChannelTests.swift` (9 asserts) with no fixture link. `appcast.sh` calls the shell helper (`appcast.sh:19,67`).
- Cost: the "lockstep" claim in the skill overstates the Swift side. What actually has to stay in sync is the raw strings `stable|pre|nightly` (Swift raw values vs the `<sparkle:channel>` names `appcast.sh` writes at :141-181). No test links those two.
- Direction: one line in the shared TSV header, or a test asserting `ReleaseChannel.allCases.map(\.rawValue)` equals the channel names in `channel_cases.tsv`. Reword the skill to "two classifiers (Go, shell) on one fixture, plus Swift raw-name parity". Size: S. Test churn: one added test.

### 7. Repo root and docs sprawl: a newcomer cannot tell what is source of truth
- Evidence (sizes via `wc -c`): `TODOS.md` 59 KB, `CONTRIBUTING.md` 48 KB (mixes architecture, local dev, testing, release and a troubleshooting section, 6 top-level sections), `Makefile` 30 KB, `docs/recently-done.md` 49 KB, `docs/performance-534.md` 83 KB, `docs/designs/remote-workrooms.md` 378 KB, `docs/designs/oq8-cross-machine-reattach.md` 114 KB, `docs/designs/boxd-first-time-setup.md` 62 KB. 96 tracked files under `docs/`; 12 under `docs/designs/`. Root also carries `AGENTS.md`, `CONTEXT.md`, `DESIGN.md`, `PRODUCT.md`, `README.md` (2 KB), `SECURITY.md`, `.gbrain-source`, `.mcp.json`, `buildServer.json`.
- Cost: README is 2 KB and points elsewhere; CONTRIBUTING at 48 KB is the real onboarding doc and is too long to be read. Design docs that are finished (shipped features) stay beside live ones, so a reader cannot tell a current spec from history. `docs/recently-done.md` header itself says "Entries are dated history: names in them may since have been renamed or removed" (a stale-by-design file).
- Direction: split CONTRIBUTING into `docs/contributing/{architecture,development,testing,releasing}.md` with a 100-line CONTRIBUTING index. Move shipped designs and the performance study to `docs/archive/` (or mark status in a front-matter line), and keep `docs/designs/` for open work. Cap TODOS.md by moving closed entries to recently-done (already the stated rule) and consider turning TODOS into GitHub issues since the repo already uses an issue tracker (`docs/agents/issue-tracker.md`).
- Size: M (mostly moves). Test churn: `docs-site` link checks only (`make docs-check`), plus anything that links these paths (AGENTS.md:67, CONTRIBUTING.md:210-211).

### 8. Three script directories with no stated rule, and the Makefile is a 52-target single file
- Evidence: `macapp/Scripts/` (about 45 files: release, appcast, build-daemon, channel-helper, gui-lock, red-proof, and a `_test.sh` beside each), `scripts/ci/` (6 files: download stats, `watch_pr_checks.py`, `test_linux_lint.py`), `vcs/scripts/` (linux lint/test, oq19, ssh-fixture). Release scripts (`release.sh` 18 KB, `appcast.sh` 11 KB, `build-daemon.sh` 12 KB) live under `macapp/` but serve the whole repo's release (Go CLI is bundled, the Rust daemon is built by them, workflows call them). `Makefile` has 52 targets in one 30 KB file with sections for Go, docs, Actions, Rust and app; `.PHONY` at :13 lists them on one long line, 12 of which are `app-bench-*`.
- Cost: to find "where does the release happen" you grep three trees. Tests live next to scripts, which is fine, but `app-test-scripts` (Makefile:377) lists each `_test.sh` by hand, so a new script test that is not added there is silently not run (the `test-invariants_test.sh` file may guard this; not verified).
- Direction: state the rule in CONTRIBUTING (macapp/Scripts = things that need Xcode, scripts/ = repo-wide release and CI, vcs/scripts = Linux/Rust). Move release and appcast to `scripts/release/`. Split the Makefile with `include mk/{cli,docs,vcs,app,bench}.mk`, keep `make help` unchanged. Replace the hand-listed `_test.sh` invocations with a glob.
- Size: M. Test churn: workflow paths and Makefile references; CI breaks loudly if one is missed.

### 9. CI is one 795-line `ci.yml` whose `app` job is about 315 lines
- Evidence: `.github/workflows/ci.yml` 795 lines (41 KB); jobs: workflows, cli, rust, daemon-terminal-state, daemon-linux (:229-343, about 115 lines), app-packages, app (:360-675), app-scripts, docs-deploy. `nightly.yml` 336 lines and `release.yml` 200 lines repeat build steps. `release.yml:11` already comments on needing to serialize with the nightly and appcast-notes workflows ("all three download-modify-upload the same ...").
- Cost: any build-step change (signing, daemon build, helper embed) touches `ci.yml`, `nightly.yml` and `release.yml`, and editing the 315-line `app` job conflicts with every other CI change.
- Direction: extract reusable workflows or composite actions (`.github/actions/build-app`, `build-daemon`) and split `ci.yml` by language (`ci-go.yml`, `ci-rust.yml`, `ci-app.yml`) with path filters. Size: M. Test churn: none, but needs a PR dry run per workflow.

### 10. `cmd/` reaches into `internal/vcs` and `internal/config` directly, and the config is an untyped map
- Evidence: package imports (grep of `internal/` imports): `cmd` imports `channel config errs ui updater vcs vcs/vcstest workroom`, 9 non-test `vcs.` references in `cmd/*.go`; `internal/workroom` imports `config errs namegen script ui vcs`. `internal/vcs` has `vcstest` imported from non-test code (`internal/vcs -> vcs/vcstest`; I did not confirm whether that is test-only files, so treat as a candidate).
- Cost: low today. `cmd` is meant to be thin (flags, JSON, exit codes) and mostly is, but the 9 `vcs.` uses (for example `localWorkJSON(w vcs.LocalWork)` in `cmd/json.go`) mean a VCS type change ripples into the JSON layer.
- Direction: have `workroom` return its own result types so `cmd` imports only `workroom`, `errs`, `ui` and `channel`. This is subsumed by item 2 (typed payloads). Size: S once item 2 lands.

### 11. A 12 MB `workroom` binary sits in the repo root
- Evidence: `ls -la` shows `workroom 12.2M` at root. `git check-ignore -v workroom` returns `.gitignore:7:/workroom`, so it is ignored and not committed. `tmp/` (6.3 MB, `tmp/showreel`) is ignored too (`.gitignore:52`). `dist/` is 37 MB and `macapp/DerivedData` is 9.0 GB (gitignored by `.golangci.yml:50` comment).
- Cost: not a repo defect, only local noise. A newcomer running `make cli-build` gets the same file at root, and it is easy to run a stale binary. `go build` output location is conventional (`bin/`).
- Direction: build to `bin/workroom` (ignored) so the root listing stays clean. Size: S.

### 12. Doc scaffolding for agents is mixed into the contributor path
- Evidence: `.agents/skills/` (2 skills), `docs/agents/` (issue-tracker, pr-watching, triage-labels, domain), `.out-of-scope/` (5 files such as `scrollback-size-setting.md`), `.claude/`, `.gstack/`, `.gbrain-source`, `.mcp.json` all at repo root; `AGENTS.md` (8.7 KB) and `macapp/AGENTS.md` add more.
- Cost: a human contributor sees a dozen hidden directories before `cmd/`. `.out-of-scope/` has no pointer in README (not checked in CONTRIBUTING either).
- Direction: one paragraph in CONTRIBUTING naming each dot-directory and who it is for. Size: S.

## 2. Dead code and duplication

Dead code (Go):
- `GOCACHE=<scratchpad>/gocache GOTOOLCHAIN=go1.25.7 golangci-lint run --enable unused ./...` printed `0 issues.` (unused is also in the default set). Proof: tool output, no unexported dead code in Go packages.
- `staticcheck`: failed to run in the sandbox (cache dir `~/Library/Caches/staticcheck` not writable, and with an overridden HOME it rejects the go1.25.7 toolchain string: `invalid Go version: "1.25.7"`). Not verified by staticcheck; golangci-lint's `unused` covers U1000.
- `deadcode@latest`: blocked, `proxy.golang.org` not in the sandbox's allowed domains. Not run. Exported-but-unused functions in `internal/` are therefore only checked by a heuristic: all 99 exported funcs/methods found by `grep -rhoE '^func (\([a-z]+ \*?[A-Za-z]+\) )?[A-Z][A-Za-z0-9]*' internal` have at least two non-test word matches in `cmd internal main.go`. That is weak (a name can match another symbol), so "no dead exports found" is a heuristic, not proof.
- `internal/docsite` is test-only by design (stated in the brief).

Duplication across languages (sites):
| Logic | Sites |
|---|---|
| Release-channel names and classification | Go `internal/channel/channel.go`; shell `macapp/Scripts/channel-helper.sh:20`; Swift `macapp/WorkroomApp/Core/ReleaseChannel.swift` (names only); `appcast.sh:141-181` writes the names. Go and shell share `internal/channel/testdata/channel_cases.tsv`; Swift has no fixture link |
| Login-shell invocation (`-lic`, fallbacks) | Swift `WorkroomSystem/ShellEnvironment.swift:42-57`; Go `internal/script/login_environment_unix.go:36,108-115`; Rust `vcs/crates/workroomd/src/shell.rs` and `cli/run_script.rs`. Parity by comment only |
| Config path `~/.config/workroom/config.json` | Go `internal/config/config.go:117`; Swift `WorkroomCLI.swift:390` (and mentions in `ProjectStore.swift:22`, `AppStore.swift:2379`) |
| `.worktreeinclude` name and presence check | Go `internal/workroom/include.go:18`; Swift `AppStore+WorkroomCreation.swift:129`, `CreationRun.swift:232` |
| `--json` payload shapes | Go map literals in `cmd/*.go` (24 files); Swift decoders; synced by `testdata/contracts` goldens |
| Name generation | Only Go `internal/namegen/namegen.go` has the word lists (grep `adjective` over `cmd internal macapp vcs`). Swift `SwitcherMark.swift` mentions it only in a comment, so not duplicated |
| Script trust (sha256) | Go `internal/workroom/trust.go` and `cmd/trust.go` hash scripts; Swift `DevContainerSetup.swift`/`DevContainerFeatures.swift` use sha256 for other purposes (not confirmed to duplicate script trust). The app goes through `trust-status` JSON (goldens `trust-status*.json`), so trust itself is not duplicated |

## 3. Proposed target structure (my area)

```
cmd/                      flags, --json writing, exit codes ONLY
  payload/ (or contract.go)  one typed struct per command payload, golden-tested
internal/
  workroom/               use cases, one file each: create.go, delete.go, listing.go, trust.go,
                          start.go, include.go, project.go; Service holds deps only; no prompts
  config/                 file IO, typed read views (ADR 0014 kept)
  vcs/                    git behind an interface; vcstest only in _test files
  script/                 hooks + login env (shared fixture with Swift/Rust)
  updater/, channel/      as now
  errs/, ui/, namegen/    leaf packages
```
Dependency direction stays `cmd -> workroom -> {config, vcs, script, namegen} -> errs`. Remove `cmd -> vcs` and `workroom -> ui` edges.

Repo level:
```
Makefile                  includes mk/{cli,docs,vcs,app,bench}.mk
scripts/{release,ci}/     repo-wide release and CI tooling (appcast, release, channel-helper)
macapp/Scripts/           only what needs Xcode
.github/workflows/        ci-go, ci-rust, ci-app, nightly, release; shared composite actions in .github/actions/
docs/{contributing,adr,designs,archive}/
```

## 4. What is good and should be kept

- Contract goldens: `cmd/contract_test.go` + `testdata/contracts/*` (byte-for-byte output of each command, shared with `macapp/WorkroomAppTests/CLIContractTests.swift`), with `-update` to rewrite. This is exemplary, better than most polyglot repos.
- `schema_version` discipline with a stated additive-change rule (`cmd/json.go`).
- Shared fixture for channel classification (`internal/channel/testdata/channel_cases.tsv`), whose header comment explains the drift it prevented. Reuse the pattern for item 5.
- Small, acyclic internal package graph: `errs`, `ui`, `channel`, `namegen` have no internal deps; `config`, `script`, `vcs` only depend on `errs`.
- Lint hygiene: `golangci-lint` reports 0 issues; `.golangci.yml` comments explain every non-default choice.
- Test-next-to-script convention for shell (`*_test.sh`) and docs checks (`make docs-check`, `cmd/docs_test.go`).
- Root binary and `tmp/` are gitignored (`.gitignore:7`, `:52`), so no stray artifacts are committed.

## 5. Open questions for the owner

1. Should the app stop reading `~/.config/workroom/config.json` itself and ask the CLI (item 3)? That reverses whatever made direct reads attractive (latency, offline CLI).
2. Is `Service.PromptFn/ConfirmFn` injection a deliberate seam for tests (`InteractiveDelete` tests)? If yes, keep it and only split the file.
3. Are the finished designs in `docs/designs/` (for example `remote-workrooms.md`, `oq8-cross-machine-reattach.md`) still edited, or are they history? Archiving depends on it.
4. Is `test-invariants_test.sh` meant to guarantee every `_test.sh` is wired into `app-test-scripts`? I did not verify that, so item 8's "silently not run" risk is unconfirmed.
5. Does `internal/vcs` import `vcs/vcstest` from production code or only from tests (item 10)? The grep excluded `_test.go` by suffix only; I did not open the files.
