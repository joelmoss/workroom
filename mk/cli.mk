# --- Go CLI (repo root) ---
#
# `cli-lint` needs golangci-lint installed (see AGENTS.md).

# bin/ rather than the repo root, so a built binary never sits beside the sources (gitignored).
cli-build: ## Build the workroom binary (version injected)
	go build -ldflags "-X main.version=$(VERSION)" -o bin/workroom .

cli-test: ## Run the Go tests
	go test ./...

# The CLI's black-box contract suite (vcs/crates/workroomd/tests/commands_contract.rs, #669), run
# against the Go CLI this builds, or against the binary WORKROOM_BIN names. Its tests are ignored
# by a plain `cargo test`, so `--ignored` runs them.
contract-test: cli-build ## Run the CLI contract suite against bin/workroom (WORKROOM_BIN= for another binary)
	@cargo_bin="$$(rustup which --toolchain $(VCS_RUST) cargo)" || { echo "contract-test needs Rust $(VCS_RUST): rustup toolchain install $(VCS_RUST)" >&2; exit 1; }; \
	export PATH="$$(dirname "$$cargo_bin"):$$PATH"; \
	WORKROOM_BIN="$(or $(WORKROOM_BIN),$(CURDIR)/bin/workroom)" \
	  cargo test --manifest-path vcs/Cargo.toml -p workroom --test commands_contract -- --ignored

cli-install: ## Install the binary to $GOBIN
	go install -ldflags "-X main.version=$(VERSION)" .

cli-lint: ## Lint Go with golangci-lint (analyzers + formatters)
	golangci-lint run
	# golangci-lint v2 split formatters out of `run` — gofmt/goimports findings are NOT reported
	# by `run` any more (verified: a mangled file yields govet/unused hits and zero gofmt hits).
	# `fmt --diff` reports them without rewriting and exits non-zero, so the formatting gate v1
	# enforced via the gofmt/goimports linters stays enforced. Keep both here and in ci-go.yml.
	golangci-lint fmt --diff

cli-clean: ## Remove the built binary
	rm -f bin/workroom
