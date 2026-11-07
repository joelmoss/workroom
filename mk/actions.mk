# --- GitHub Actions ---
#
# `actions-lint` needs jactionlint installed (CONTRIBUTING).

# Named paths: with none, jactionlint also lints the vendored .github dirs under macapp/DerivedData.
actions-lint: ## Lint workflows, composite actions and dependabot.yml with jactionlint (shellcheck included)
	jactionlint .github/workflows/*.yml .github/actions/*/action.yml .github/dependabot.yml
