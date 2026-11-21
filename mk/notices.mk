# --- Third-party notices (third-party/; scripts/third_party_notices.py, #714) ---

# cargo-about reads the Rust half from the shipped binary's dependency graph. Pinned, as a newer one
# can word or order the same graph differently, which would fail the check with nothing changed.
# The install-cargo-about composite installs the same version (scripts/ci/test_tool_pins.py).
CARGO_ABOUT_VERSION := 0.9.3
CARGO_ABOUT ?= cargo-about
NOTICES_ARGS = --cargo-about "$(CARGO_ABOUT)" --cargo-about-version $(CARGO_ABOUT_VERSION)

notices: ## Regenerate the third-party notices the binary embeds and the app bundles
	python3 scripts/third_party_notices.py write $(NOTICES_ARGS)

notices-check: ## Fail when the third-party notices are stale or a dependency's licence is not allowed
	python3 scripts/third_party_notices.py check $(NOTICES_ARGS)
