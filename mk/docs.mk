# --- Docs site (docs-site/; the format contract is docs-site/README.md) ---

CODASET_PATH ?= $(HOME)/dev/codaset

# The CLI pages come from two generators: the Go CLI's cobra commands (cmd/docs_test.go), and the
# Rust binary's for the commands only it has, the terminal API's (vcs/crates/workroomd/src/
# commands/docs.rs, which cargo test also checks in CI's rust job).
DOCS_RUST_TEST = cargo_bin="$$(rustup which --toolchain $(VCS_RUST) cargo)" || { echo "the CLI pages need Rust $(VCS_RUST): rustup toolchain install $(VCS_RUST)" >&2; exit 1; }; \
	export PATH="$$(dirname "$$cargo_bin"):$$PATH"; \
	cargo test --manifest-path vcs/Cargo.toml -p workroom --lib commands::docs::

docs-check: ## Check docs-site/ (nav, front matter, links, anchors) and that the CLI pages are current
	go test ./internal/docsite ./cmd -run 'TestDocsSite|TestAnchor|TestCheckFindsBreakage|TestCLIDocs'
	@$(DOCS_RUST_TEST)

docs-cli: ## Regenerate docs-site/pages/cli from the CLI's commands
	go test ./cmd -run TestCLIDocs -update
	@export WORKROOM_DOCS_UPDATE=1; $(DOCS_RUST_TEST)

# Its own Caddy name and pidfile, so it runs beside Codaset's own dev server: with the defaults it
# would repoint that server's codaset.localhost route, then exit on its pidfile.
docs-preview: ## Serve this checkout's docs-site/ at https://workroom-docs.localhost/workroom/docs (CODASET_PATH, default ~/dev/codaset)
	@test -x "$(CODASET_PATH)/bin/dev" || { echo "No Codaset checkout at $(CODASET_PATH); set CODASET_PATH." >&2; exit 1; }
	@echo "Docs at https://workroom-docs.localhost/workroom/docs"
	cd "$(CODASET_PATH)" && RAILS_CADDY_DEV_DOMAIN=workroom-docs WORKROOM_DOCS_PATH="$(CURDIR)/docs-site" \
	  bin/dev server -P tmp/pids/workroom-docs.pid
