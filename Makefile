# Repo-wide dev tasks, namespaced: `cli-*` = the Go CLI (the primary product), `app-*` = the
# macOS app under macapp/ (Xcode-based), `vcs-*` = the Rust workspace under vcs/, `docs-*` = the
# docs site under docs-site/, `actions-*` = the GitHub Actions under .github/. Run `make` with no
# target to list them. Each area's targets live in mk/<area>.mk, included below.
# Homebrew's dirs are a fallback for a shell that lacks them, so they go last: the caller's PATH
# order wins, and a version manager's tools (mise's go, golangci-lint, shellcheck) come before
# any Homebrew copy of the same tool.
export PATH := $(PATH):/opt/homebrew/bin:/usr/local/bin
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.DEFAULT_GOAL := help

help: ## List available targets
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

# Named, not globbed: `help` lists targets in MAKEFILE_LIST order, so this order is the listing's.
include mk/cli.mk mk/docs.mk mk/actions.mk mk/vcs.mk mk/app.mk

tools-check: ## Compare this machine's tools with the versions the repo pins (read-only)
	@python3 scripts/ci/tools_check.py

# Every target is a task, not a file, and every one has the `## ` line `help` lists, so the phony
# list is read the same way and a new target can't be left off it.
.PHONY: $(shell sed -nE 's/^([a-z][a-zA-Z0-9_-]*):.*\#\# .*/\1/p' $(MAKEFILE_LIST))

# `make print-VAR` prints VAR as make has it, for the tests that pin a value
# (macapp/Scripts/test-invariants_test.sh, scripts/ci/): they ask make rather than grep the file
# that sets it, so moving the line between files breaks none of them. Not listed by `help`.
print-%:
	@:$(info $($*))
