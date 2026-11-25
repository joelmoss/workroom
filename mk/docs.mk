# --- Docs site (docs-site/; the format contract is docs-site/README.md) ---

CODASET_PATH ?= $(HOME)/dev/codaset

# Both are Rust tests, which cargo test also runs in CI's rust job: the CLI pages come from the
# workroom binary's commands (vcs/crates/workroomd/src/commands/docs.rs), and the site's format and
# Nightly markers are checked by vcs/crates/workroomd/tests/docs_site.rs. The Nightly check compares
# with the latest stable tag, so here a checkout without it fails rather than skipping.
DOCS_CARGO = cargo_bin="$$(rustup which --toolchain $(VCS_RUST) cargo)" || { echo "the docs checks need Rust $(VCS_RUST): rustup toolchain install $(VCS_RUST)" >&2; exit 1; }; \
	export PATH="$$(dirname "$$cargo_bin"):$$PATH"; \
	cargo test --manifest-path vcs/Cargo.toml -p workroom

docs-check: ## Check docs-site/ (nav, front matter, links, anchors, Nightly markers) and that the generated pages are current
	@$(DOCS_CARGO) --lib commands::docs::
	@export WORKROOM_DOCS_NIGHTLY_CHECK=1; $(DOCS_CARGO) --test docs_site

# CI's docs-site check (scripts/ci/docs_site_check.py) on this branch: what it changes since its
# merge-base with origin/master, committed or not. NO_DOCS=1 stands in for the PR's 'no-docs' label,
# for a change users can't see.
docs-site-check: ## Fail when the branch changes a user-facing settings/defaults/shortcuts file without docs-site/ (NO_DOCS=1 waives)
	@base=$$(git merge-base origin/master HEAD) || { echo "docs-site-check: no merge-base with origin/master (git fetch origin master)" >&2; exit 1; }; \
	paths=$$(git diff --name-only --no-renames "$$base") && untracked=$$(git ls-files --others --exclude-standard) \
	  || { echo "docs-site-check: couldn't list the branch's changes" >&2; exit 1; }; \
	printf '%s\n%s\n' "$$paths" "$$untracked" | sort -u \
	  | PR_LABELS='$(if $(NO_DOCS),["no-docs"],[])' python3 scripts/ci/docs_site_check.py

docs-cli: ## Regenerate docs-site/pages/cli and the generated Reference pages from the workroom binary
	@export WORKROOM_DOCS_UPDATE=1; $(DOCS_CARGO) --lib commands::docs::

# Its own Caddy name and pidfile, so it runs beside Codaset's own dev server: with the defaults it
# would repoint that server's codaset.localhost route, then exit on its pidfile.
docs-preview: ## Serve this checkout's docs-site/ at https://workroom-docs.localhost/workroom/docs (CODASET_PATH, default ~/dev/codaset)
	@test -x "$(CODASET_PATH)/bin/dev" || { echo "No Codaset checkout at $(CODASET_PATH); set CODASET_PATH." >&2; exit 1; }
	@echo "Docs at https://workroom-docs.localhost/workroom/docs"
	cd "$(CODASET_PATH)" && RAILS_CADDY_DEV_DOMAIN=workroom-docs WORKROOM_DOCS_PATH="$(CURDIR)/docs-site" \
	  bin/dev server -P tmp/pids/workroom-docs.pid
