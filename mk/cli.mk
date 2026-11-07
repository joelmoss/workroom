# --- Go CLI (repo root) ---

.PHONY: cli-build cli-test cli-install cli-lint cli-clean

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
