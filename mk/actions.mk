# --- GitHub Actions ---
#
# `actions-lint` needs jactionlint installed (CONTRIBUTING).

# Named paths: with none, jactionlint also lints the vendored .github dirs under macapp/DerivedData.
actions-lint: ## Lint workflows, composite actions and dependabot.yml with jactionlint (shellcheck included)
	jactionlint .github/workflows/*.yml .github/actions/*/action.yml .github/dependabot.yml

# The scripts/ci suites ci-actions.yml runs on every change, there by name. Here by glob, each file
# on its own, so a new suite runs with nothing to add, and an empty glob fails rather than passing
# with nothing tested. In pre-push: CI's actions job failed on a launcher test that no local gate
# ran (#833).
ci-scripts-test: ## Run the scripts/ci test suites that CI's actions job runs
	@set -- scripts/ci/test_*.py; \
	[ -e "$$1" ] || { echo "ci-scripts-test: no scripts/ci/test_*.py to run" >&2; exit 1; }; \
	failed=""; \
	for suite in "$$@"; do \
	  out=$$(python3 "$$suite" 2>&1) || { printf '%s\n' "$$out"; failed="$$failed $$suite"; }; \
	done; \
	if [ -n "$$failed" ]; then echo "ci-scripts-test: FAILED:$$failed"; exit 1; fi; \
	echo "ci-scripts-test: $$# suites passed"
