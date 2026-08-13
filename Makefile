# Repo-wide dev tasks, namespaced: `cli-*` = the Go CLI (the primary product), `app-*` = the
# macOS app under macapp/ (Xcode-based). Run `make` with no target to list them.
#
# App recipes run inside macapp/ and need its toolchain on PATH (xcodegen via Homebrew). The
# Xcode build also runs project.yml phases — a non-fatal swift-format lint and embedding the Go
# helper (macapp/Scripts/build-helper.sh). `cli-lint` needs golangci-lint installed (see CLAUDE.md).
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.DEFAULT_GOAL := help
.PHONY: help \
        cli-build cli-test cli-install cli-lint cli-clean \
        app-vcs app-run app-build app-test app-uitest app-test-supervisor app-test-scripts app-generate app-format app-lint app-release app-icon app-clean

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

cli-lint: ## Lint Go with golangci-lint
	golangci-lint run

cli-clean: ## Remove the built binary
	rm -f workroom

# --- macOS app (macapp/) ---

# The Debug product is "Workroom Dev" (distinct bundle id + name) so it runs alongside the
# installed release "Workroom" without conflict — see macapp/project.yml.
APP_PROJECT := WorkroomApp.xcodeproj
APP_NAME    := Workroom Dev
APP_BUNDLE  := DerivedData/Build/Products/Debug/$(APP_NAME).app
APP_XCODEBUILD := xcodebuild -project $(APP_PROJECT) -scheme WorkroomApp -configuration Debug \
  -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages

# Extra xcodebuild build-setting overrides, appended to app-build/app-test. Empty locally so
# ⌘R-style automatic signing is used; CI sets this to ad-hoc / no-team signing because hosted
# runners have no signing cert or DEVELOPMENT_TEAM (e.g.
# `make app-test APP_SIGN_FLAGS="CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="`).
APP_SIGN_FLAGS ?=

# Extra xcodebuild options for app-test. Parallel execution by default: the suite is dominated by a
# few slow integration classes (Markdown WebView renders, real git/jj repos), so spreading classes
# across worker processes cuts the run ~40% (48s -> ~29s). Each worker gets its own host-app process
# but they share one UserDefaults domain, so a test mutating a `Defaults` key another class reads
# would race — override with `make app-test APP_TEST_FLAGS=` to bisect a suspected parallel-only
# failure. Test dirs are already UUID-scoped under NSTemporaryDirectory, so those don't collide.
APP_TEST_FLAGS ?= -parallel-testing-enabled YES

# Extra xcodebuild options for app-uitest. Skips the 3 most expensive/flaky cases by default (each
# does a real quit+relaunch or a hard timing budget), since XCUITest never runs in CI and a routine
# `make app-uitest` was paying ~4-5 min for tests that are only load-bearing right before a release.
# The isolation-tripwire tests those two classes carried (proving discovery/session-restore no-op
# without a seeded path — a guard the REST of this suite depends on) were extracted to
# `AgentSessionIsolationTripwireUITests` first, so the routine sweep keeps that safety net. Run the
# full suite (pre-release, or after touching any of these) with `make app-uitest APP_UITEST_FLAGS=`.
APP_UITEST_FLAGS ?= -skip-testing:WorkroomAppUITests/AgentResumeUITests -skip-testing:WorkroomAppUITests/SessionRestoreUITests -skip-testing:WorkroomAppUITests/HistoryStressUITests/testLargeHistoryStaysInteractive -skip-testing:WorkroomAppUITests/WindowDragUITests/testDraggingWorkroomTabReordersTwoChips

# The Rust VCS core (jj-lib via UniFFI) the app links, built into the local WrVcs SwiftPM package
# (vcs/swift/WrVcs). Must run before xcodegen so the package's xcframework + generated Swift exist.
# arm64 by default; release/distribution sets VCS_APPLE_FLAGS=--universal (needs rustup stable >=
# 1.93 + both darwin targets, and `protoc` on PATH for jj-lib's build).
VCS_APPLE_FLAGS ?=
app-vcs: ## Build the Rust VCS core (xcframework + Swift bindings) the app links
	vcs/scripts/build-apple.sh $(VCS_APPLE_FLAGS)

app-run: app-build ## Build (Debug) and launch the dev app, replacing any running dev instance
	cd macapp || exit 1; \
	pkill -x "$(APP_NAME)" 2>/dev/null || true; \
	i=0; \
	while pgrep -x "$(APP_NAME)" >/dev/null 2>&1 && [ $$i -lt 40 ]; do \
	  sleep 0.2; i=$$((i + 1)); \
	done; \
	echo "Launching $(APP_BUNDLE)"; \
	open "$(APP_BUNDLE)"

app-build: app-vcs ## Build the app (Debug)
	cd macapp && xcodegen generate && $(APP_XCODEBUILD) build $(APP_SIGN_FLAGS)

app-test: app-vcs ## Run the app's unit tests
	cd macapp && xcodegen generate && $(APP_XCODEBUILD) -destination 'platform=macOS' $(APP_TEST_FLAGS) test $(APP_SIGN_FLAGS)

app-uitest: app-vcs ## Run the app's UI tests (XCUITest — needs a real GUI login session, not headless)
	cd macapp && xcodegen generate && xcodebuild -project $(APP_PROJECT) -scheme WorkroomAppUITests -configuration Debug -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages -destination 'platform=macOS' $(APP_UITEST_FLAGS) test $(APP_SIGN_FLAGS)

app-test-supervisor: ## Run the run-command supervisor PTY integration test (real shell + fake server)
	python3 macapp/Tests/run-supervisor/test_supervisor.py

app-test-scripts: ## Run the dependency-free shell-script tests (build-helper archs, channel classify)
	sh macapp/Scripts/build-helper_test.sh
	sh macapp/Scripts/channel-helper_test.sh
	sh macapp/Scripts/test-invariants_test.sh

app-generate: app-vcs ## Force-regenerate the (gitignored) .xcodeproj from project.yml
	cd macapp && xcodegen generate

app-format: ## Format Swift sources in place (swift-format)
	cd macapp && xcrun swift-format format --in-place --parallel --recursive WorkroomApp WorkroomAppTests WorkroomAppUITests WorkroomSessionProtocol WorkroomSession

app-lint: ## Lint Swift with swift-format (--strict)
	cd macapp && xcrun swift-format lint --strict --parallel --recursive WorkroomApp WorkroomAppTests WorkroomAppUITests WorkroomSessionProtocol WorkroomSession

app-release: VCS_APPLE_FLAGS := --universal
# `app-test-scripts` gates the release because it is the cheap half that catches an ARTIFACT bug
# (the universal-arch cases) and needs no toolchain, no keychain and no Xcode.
#
# `app-test` is deliberately NOT a prerequisite here. It builds Debug, and Debug pins
# `CODE_SIGN_STYLE: Automatic` + `CODE_SIGN_IDENTITY: "Apple Development"` (project.yml). The
# release and nightly runners import a Developer ID certificate ONLY, and pass no APP_SIGN_FLAGS —
# so making it a prerequisite fails provisioning on a fresh runner before anything is archived.
# The xcodebuild suite runs as an explicit gate step in release.yml / nightly.yml instead, with the
# same ad-hoc overrides ci.yml uses.
app-release: app-vcs app-test-scripts ## Build, notarize, staple + package a DMG installer (macapp/Scripts/release.sh)
	cd macapp && Scripts/release.sh

app-icon: ## Regenerate release, dev + nightly AppIcon PNGs (macapp/Scripts/make-icon.swift)
	cd macapp && swift Scripts/make-icon.swift

app-clean: ## Remove the app's DerivedData + .xcodeproj
	cd macapp && rm -rf DerivedData $(APP_PROJECT)
