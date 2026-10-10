# Repo-wide dev tasks, namespaced: `cli-*` = the Go CLI (the primary product), `app-*` = the
# macOS app under macapp/ (Xcode-based). Run `make` with no target to list them.
#
# App recipes run inside macapp/ and need its toolchain on PATH (xcodegen via Homebrew). The
# Xcode build also runs project.yml phases — a non-fatal swift-format lint and embedding the Go
# helper (macapp/Scripts/build-helper.sh). `cli-lint` needs golangci-lint installed (see AGENTS.md),
# `actions-lint` actionlint (CONTRIBUTING).
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.DEFAULT_GOAL := help
.PHONY: help \
        cli-build cli-test cli-install cli-lint cli-clean \
        app-run app-build app-test app-package-test app-uitest app-identity app-test-supervisor app-test-scripts app-generate app-format app-lint app-release app-icon app-tool-logos app-clean \
        remote-host-image remote-host-image-test actions-lint

help: ## List available targets
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

# --- Go CLI (repo root) ---

cli-build: ## Build the workroom binary (version injected)
	go build -ldflags "-X main.version=$(VERSION)" -o workroom .

cli-test: ## Run the Go tests
	go test ./...

cli-install: ## Install the binary to $GOBIN
	go install -ldflags "-X main.version=$(VERSION)" .

cli-lint: ## Lint Go with golangci-lint (analyzers + formatters)
	golangci-lint run
	# golangci-lint v2 split formatters out of `run` — gofmt/goimports findings are NOT reported
	# by `run` any more (verified: a mangled file yields govet/unused hits and zero gofmt hits).
	# `fmt --diff` reports them without rewriting and exits non-zero, so the formatting gate v1
	# enforced via the gofmt/goimports linters stays enforced. Keep both here and in ci.yml.
	golangci-lint fmt --diff

cli-clean: ## Remove the built binary
	rm -f workroom

# --- GitHub Actions ---

actions-lint: ## Lint .github/workflows with actionlint (shellcheck included)
	actionlint

# --- macOS app (macapp/) ---

# The Debug product is "Workroom Dev" (distinct bundle id + name) so it runs alongside the
# installed release "Workroom" without conflict — see macapp/project.yml.
APP_PROJECT := WorkroomApp.xcodeproj
APP_NAME    := Workroom Dev
APP_BUNDLE  := DerivedData/Build/Products/Debug/$(APP_NAME).app
APP_XCODEBUILD := xcodebuild -project $(APP_PROJECT) -scheme WorkroomApp -configuration Debug \
  -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages
APP_UITEST_XCODEBUILD := xcodebuild -project $(APP_PROJECT) -scheme WorkroomAppUITests \
  -configuration Debug -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages

# Each workroom of this repo builds its own Debug identity, so several can build, test and run the
# dev app at once. Everything a running "Workroom Dev" owns is keyed by its bundle id — preferences,
# its session helper's socket (and so which wr-agent it hands off to), its saved session, and what
# LaunchServices and XCUITest treat as "that app is already running" — so two workrooms building one
# id shared all of it. A workroom (a linked git worktree) gets
# `com.developwithstyle.workroom.dev.wr-<name>-<hash>`; the project's own checkout keeps the plain
# id, so its preferences, TCC grants and sessions are unchanged. Computed once, from
# macapp/Scripts/dev-identity.sh; `make … APP_DEV_ID_SUFFIX=` forces the plain id. Xcode-driven
# builds (⌘R/⌘U) don't go through here and always build the plain id. `make app-identity` prints it.
# See docs/designs/parallel-workroom-testing.md.
ifeq ($(origin APP_DEV_ID_SUFFIX),undefined)
APP_DEV_ID_SUFFIX := $(shell sh macapp/Scripts/dev-identity.sh 2>/dev/null)
endif
# Appended to every xcodebuild that BUILDS the app; project.yml appends it to the Debug bundle id.
APP_ID_FLAGS := WORKROOM_DEV_ID_SUFFIX=$(APP_DEV_ID_SUFFIX)

# $(call gui_lock,shared|exclusive,<what>) prefixes a command so it runs holding this Mac's GUI
# session (macapp/Scripts/gui-lock.py). Workrooms no longer share an app identity, but they still
# share the screen: XCUITest drives the real pointer and keyboard, and a hosted unit run boots the
# app, window and all. So XCUITest takes it exclusively and unit runs share it — any number of
# workrooms' unit runs at once, UI-test runs one at a time with nothing else on screen, and a run
# that has to wait says who it is waiting for. Only test EXECUTION is locked; builds never wait.
# `WR_GUI_LOCK=off` skips it (a run inside a VM, or when you know the screen is free).
gui_lock = $(if $(filter off 0 no false,$(WR_GUI_LOCK)),,python3 "$(CURDIR)/macapp/Scripts/gui-lock.py" $(1) --label "$(2) $(CURDIR)" --)

# Extra xcodebuild build-setting overrides, appended to app-build/app-test. Empty locally so
# ⌘R-style automatic signing is used; CI sets this to ad-hoc / no-team signing because hosted
# runners have no signing cert or DEVELOPMENT_TEAM (e.g.
# `make app-test APP_SIGN_FLAGS="CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="`).
APP_SIGN_FLAGS ?=

# Extra xcodebuild options for app-test. Parallel execution by default: the suite is dominated by a
# few slow integration classes (Markdown WebView renders, real git repos), so spreading classes
# across worker processes cuts the run ~40% (48s -> ~29s). Each worker gets its own host-app process
# but they share one UserDefaults domain, so a test mutating a `Defaults` key another class reads
# would race — override with `make app-test APP_TEST_FLAGS=` to bisect a suspected parallel-only
# failure. Test dirs are already UUID-scoped under NSTemporaryDirectory, so those don't collide.
# This and APP_UITEST_FLAGS reach only the TEST step (`test-without-building`); an option that
# changes what gets built, such as `-enableCodeCoverage YES`, has to reach the build step too, and
# APP_SIGN_FLAGS is what reaches it.
APP_TEST_FLAGS ?= -parallel-testing-enabled YES

# Extra xcodebuild options for app-uitest. Skips the 3 most expensive/flaky cases by default (each
# does a real quit+relaunch or a hard timing budget), since XCUITest never runs in CI and a routine
# `make app-uitest` was paying ~4-5 min for tests that are only load-bearing right before a release.
# The isolation guard the REST of this suite depends on (no session read or write without a seeded
# path) has its decision logic pinned by unit tests, in `SessionStoreTests` (`forEnvironment`); the
# launch wiring that feeds it is covered only by the skipped `SessionRestoreUITests`. Run the full suite
# (pre-release, or after touching any of these) with `make app-uitest APP_UITEST_FLAGS=`.
APP_UITEST_FLAGS ?= -skip-testing:WorkroomAppUITests/AgentResumeUITests -skip-testing:WorkroomAppUITests/SessionRestoreUITests -skip-testing:WorkroomAppUITests/HistoryStressUITests/testLargeHistoryStaysInteractive -skip-testing:WorkroomAppUITests/WindowDragUITests/testDraggingWorkroomTabReordersTwoChips

# Stops every running copy of THIS build's identity first (Scripts/stop-dev-app.sh), and its
# persisted session helpers, whose panes come back empty. By bundle id, never by process name: every
# workroom's dev app, unit-test host and XCUITest app is called "Workroom Dev", and the
# `pkill -x "Workroom Dev"` this used to be killed all of them. Stop and relaunch both wait out a
# UI-test run in progress anywhere on this Mac, which a new window taking focus would otherwise
# break — together, so the wait never leaves the app down, and giving up on it leaves it running.
app-run: app-build ## Build (Debug) and launch this checkout's dev app, replacing any running copy of it
	cd macapp && $(call gui_lock,shared,app-run) \
	  sh -c 'sh Scripts/stop-dev-app.sh "$$1" && echo "Launching $$1" && open "$$1"' app-run \
	  "$(APP_BUNDLE)"

app-build: ## Build the app (Debug)
	cd macapp && xcodegen generate && $(APP_XCODEBUILD) build $(APP_SIGN_FLAGS) $(APP_ID_FLAGS)

# Built, then run in two steps, so only the run holds the GUI session: a build never waits on
# another workroom's tests, and never makes another workroom's tests wait on it.
app-test: ## Run the app's unit tests (other workrooms' unit runs can overlap)
	cd macapp && xcodegen generate && \
	  $(APP_XCODEBUILD) -destination 'platform=macOS' build-for-testing $(APP_SIGN_FLAGS) $(APP_ID_FLAGS) && \
	  $(call gui_lock,shared,app-test) \
	  $(APP_XCODEBUILD) -destination 'platform=macOS' $(APP_TEST_FLAGS) test-without-building

# Each local package's tests (macapp/Packages), with plain `swift test`: no app host, so no GUI lock,
# and seconds rather than the app build. CI runs it before `make app-test`. SwiftPM's build service
# cannot write under Claude Code's command sandbox, so run it with the sandbox off there.
app-package-test: ## Run the local Swift packages' tests (swift test, no app host or GUI lock)
	@set -e; for pkg in macapp/Packages/*/; do \
	  echo "swift test --package-path $$pkg"; swift test --package-path "$$pkg"; \
	done

app-uitest: ## Run the app's UI tests (XCUITest — needs the GUI session; queues behind other runs)
	cd macapp && xcodegen generate && \
	  $(APP_UITEST_XCODEBUILD) -destination 'platform=macOS' build-for-testing $(APP_SIGN_FLAGS) $(APP_ID_FLAGS) && \
	  $(call gui_lock,exclusive,app-uitest) \
	  $(APP_UITEST_XCODEBUILD) -destination 'platform=macOS' $(APP_UITEST_FLAGS) test-without-building

app-identity: ## Print the bundle id this checkout's Debug build gets (one per workroom)
	@echo "com.developwithstyle.workroom.dev$(APP_DEV_ID_SUFFIX)"

remote-host-image: ## Build the `workroom-host` image an app's remote workrooms run on (Docker, #253)
	docker build --tag workroom-host vcs/scripts/ssh-fixture

remote-host-image-test: ## Build the `workroom-host` image, without its tag, and smoke-test it: sshd serves and is hardened, no fixture pieces, a pushed agent starts (#288)
	vcs/scripts/ssh-fixture/host-image-test.sh

app-test-supervisor: ## Run the run-command supervisor PTY integration test (real shell + fake server)
	python3 macapp/Tests/run-supervisor/test_supervisor.py

app-test-scripts: ## Run the script tests (build-helper/build-agent archs, channel classify, dev identity, GUI lock, agent protocol)
	sh macapp/Scripts/build-helper_test.sh
	sh macapp/Scripts/build-agent_test.sh
	sh macapp/Scripts/channel-helper_test.sh
	sh macapp/Scripts/appcast-feed_test.sh
	sh macapp/Scripts/test-invariants_test.sh
	sh macapp/Scripts/agent-protocol_test.sh
	sh macapp/Scripts/dev-identity_test.sh
	sh macapp/Scripts/stop-dev-app_test.sh
	python3 macapp/Scripts/gui-lock_test.py

app-generate: ## Force-regenerate the (gitignored) .xcodeproj from project.yml
	cd macapp && xcodegen generate

# The Swift that app-format and app-lint cover, relative to macapp/. Each package's manifest, Sources
# and Tests, never its .build: that holds its dependencies' checkouts.
APP_SWIFT_PATHS := WorkroomApp WorkroomAppTests WorkroomAppUITests WorkroomSessionProtocol \
  WorkroomSession $(patsubst macapp/%,%,$(wildcard macapp/Packages/*/Package.swift \
  macapp/Packages/*/Sources macapp/Packages/*/Tests))

app-format: ## Format Swift sources in place (swift-format)
	cd macapp && xcrun swift-format format --in-place --parallel --recursive $(APP_SWIFT_PATHS)

app-lint: ## Lint Swift with swift-format (--strict)
	cd macapp && xcrun swift-format lint --strict --parallel --recursive $(APP_SWIFT_PATHS)

# `app-test-scripts` gates the release because it is the cheap half that catches an ARTIFACT bug
# (the universal-arch cases) and needs no toolchain, no keychain and no Xcode.
#
# `app-test` is deliberately NOT a prerequisite here. It builds Debug, and Debug pins
# `CODE_SIGN_STYLE: Automatic` + `CODE_SIGN_IDENTITY: "Apple Development"` (project.yml). The
# release and nightly runners import a Developer ID certificate ONLY, and pass no APP_SIGN_FLAGS —
# so making it a prerequisite fails provisioning on a fresh runner before anything is archived.
# The xcodebuild suite runs as an explicit gate step in release.yml / nightly.yml instead, with the
# same ad-hoc overrides ci.yml uses.
app-release: app-test-scripts ## Build, notarize, staple + package a DMG installer (macapp/Scripts/release.sh)
	cd macapp && Scripts/release.sh

app-icon: ## Regenerate release, dev + nightly AppIcon PNGs (macapp/Scripts/make-icon.swift)
	cd macapp && swift Scripts/make-icon.swift

app-tool-logos: ## Fetch/refresh curated tool-logo assets (macapp/Scripts/fetch-tool-logos.sh)
	cd macapp && Scripts/fetch-tool-logos.sh

app-clean: ## Remove the app's DerivedData + .xcodeproj
	cd macapp && rm -rf DerivedData $(APP_PROJECT)
