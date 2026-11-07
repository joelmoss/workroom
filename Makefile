# Repo-wide dev tasks, namespaced: `cli-*` = the Go CLI (the primary product), `app-*` = the
# macOS app under macapp/ (Xcode-based), `vcs-*` = the Rust workspace under vcs/. Run `make` with
# no target to list them. Each area's targets live in mk/<area>.mk, included below.
#
# App recipes run inside macapp/ and need its toolchain on PATH (xcodegen via Homebrew). The
# Xcode build also runs project.yml phases — a non-fatal swift-format lint and embedding the Go
# helper (macapp/Scripts/build-helper.sh). `cli-lint` needs golangci-lint installed (see AGENTS.md),
# `actions-lint` jactionlint (CONTRIBUTING).
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.DEFAULT_GOAL := help
.PHONY: help

help: ## List available targets
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

# Named, not globbed: `help` lists targets in MAKEFILE_LIST order, so this order is the listing's.
include mk/cli.mk mk/docs.mk mk/actions.mk mk/vcs.mk mk/app.mk
