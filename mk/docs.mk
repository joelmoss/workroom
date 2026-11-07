# --- Docs site (docs-site/; the format contract is docs-site/README.md) ---

CODASET_PATH ?= $(HOME)/dev/codaset

docs-check: ## Check docs-site/ (nav, front matter, links, anchors) and that the CLI pages are current
	go test ./internal/docsite ./cmd -run 'TestDocsSite|TestAnchor|TestCheckFindsBreakage|TestCLIDocs'

docs-cli: ## Regenerate docs-site/pages/cli from the CLI's commands
	go test ./cmd -run TestCLIDocs -update

# Its own Caddy name and pidfile, so it runs beside Codaset's own dev server: with the defaults it
# would repoint that server's codaset.localhost route, then exit on its pidfile.
docs-preview: ## Serve this checkout's docs-site/ at https://workroom-docs.localhost/workroom/docs (CODASET_PATH, default ~/dev/codaset)
	@test -x "$(CODASET_PATH)/bin/dev" || { echo "No Codaset checkout at $(CODASET_PATH); set CODASET_PATH." >&2; exit 1; }
	@echo "Docs at https://workroom-docs.localhost/workroom/docs"
	cd "$(CODASET_PATH)" && RAILS_CADDY_DEV_DOMAIN=workroom-docs WORKROOM_DOCS_PATH="$(CURDIR)/docs-site" \
	  bin/dev server -P tmp/pids/workroom-docs.pid
