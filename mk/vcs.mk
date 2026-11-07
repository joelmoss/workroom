# --- Rust workspace (vcs/) ---

# The toolchain ci-rust.yml pins for its Rust lint gates. rustfmt's layout and clippy's lints
# change between releases, so another toolchain can pass here and fail there; the root Makefile's
# PATH puts Homebrew's cargo first, so the recipe puts this one ahead of it. ci-rust.yml writes it
# out again; scripts/ci/test_tool_pins.py fails when the two differ.
VCS_RUST := 1.96.1

vcs-lint-linux: ## Run the pinned Rust lint gate inside Linux (container, Docker or Podman on macOS)
	bash vcs/scripts/lint-linux.sh "$(VCS_RUST)"

vcs-lint: ## Lint the Rust workspace: rustfmt, clippy and rustdoc, each with and without terminal-state
	@cargo_bin="$$(rustup which --toolchain $(VCS_RUST) cargo)" && \
	rustup which --toolchain $(VCS_RUST) cargo-fmt >/dev/null && \
	rustup which --toolchain $(VCS_RUST) cargo-clippy >/dev/null || { echo "vcs-lint needs Rust $(VCS_RUST) with rustfmt and clippy: rustup toolchain install $(VCS_RUST) --component rustfmt,clippy" >&2; exit 1; }; \
	export PATH="$$(dirname "$$cargo_bin"):$$PATH"; \
	cargo fmt --manifest-path vcs/Cargo.toml --all -- --check && \
	cargo clippy --manifest-path vcs/Cargo.toml --workspace --all-targets -- -D warnings && \
	cargo clippy --manifest-path vcs/Cargo.toml -p workroomd --features terminal-state --all-targets -- -D warnings && \
	RUSTDOCFLAGS="-D warnings" cargo doc --manifest-path vcs/Cargo.toml --workspace --no-deps && \
	RUSTDOCFLAGS="-D warnings" cargo doc --manifest-path vcs/Cargo.toml -p workroomd --features terminal-state --no-deps

# Extra `cargo test` arguments for vcs-test, given to both runs: a package, a test target or a name
# filter, e.g. `make vcs-test VCS_TEST_FLAGS="-p workroomd --test attach_survives_detach"`.
VCS_TEST_FLAGS ?=

# ci-rust.yml's two Rust test steps, on its pinned toolchain: the whole workspace (`rust`), then workroomd
# with terminal-state (`daemon-terminal-state`). WORKROOMD_HAS_TERMINAL_STATE makes the repaint and
# scrollback tests run instead of skipping. The second run needs Zig, which build-ghostty-vt.sh
# gets from mise.
#
# The feature build gets its own target dir (one extra full build the first time, cached after):
# in the shared one the feature flip rebuilt workroomd in place on every run, 286s against 109s
# (measured 2026-10-18). Not concurrently, as CI's two jobs run: on one machine the doubled load
# failed tests that wait a fixed time for a shell or checker (2 of 6 runs, 0 of 3 serially).
vcs-test: ## Test the Rust workspace, then workroomd with terminal-state, as CI does (VCS_TEST_FLAGS=)
	@cargo_bin="$$(rustup which --toolchain $(VCS_RUST) cargo)" || { echo "vcs-test needs Rust $(VCS_RUST): rustup toolchain install $(VCS_RUST)" >&2; exit 1; }; \
	export PATH="$$(dirname "$$cargo_bin"):$$PATH"; \
	cargo test --manifest-path vcs/Cargo.toml $(VCS_TEST_FLAGS) && \
	CARGO_TARGET_DIR=vcs/target/terminal-state WORKROOMD_HAS_TERMINAL_STATE=1 \
	  cargo test --manifest-path vcs/Cargo.toml -p workroomd --features terminal-state $(VCS_TEST_FLAGS)

# What an idle daemon costs (vcs/scripts/daemon-idle-bench.sh): a release workroomd on its own
# socket with DAEMON_BENCH_SESSIONS idle shells for DAEMON_BENCH_SECS, its CPU time and context
# switches read from outside. Compare a run before a daemon change with one after. macOS only.
# DAEMON_OLD=<binary> also runs vcs/scripts/daemon-handoff-check.sh from that build to this one.
DAEMON_BENCH_SECS ?= 60
DAEMON_BENCH_SESSIONS ?= 4
DAEMON_BENCH_KIND ?= shell
DAEMON_BENCH_SCOPE ?= daemon
vcs-bench-daemon: ## Measure idle daemon CPU/wakeups [DAEMON_BENCH_SECS= DAEMON_BENCH_SESSIONS= DAEMON_BENCH_KIND=shell|parked DAEMON_BENCH_SCOPE=daemon|supervisor DAEMON_OLD=]
	@cargo_bin="$$(rustup which --toolchain $(VCS_RUST) cargo)" || { echo "vcs-bench-daemon needs Rust $(VCS_RUST): rustup toolchain install $(VCS_RUST)" >&2; exit 1; }; \
	export PATH="$$(dirname "$$cargo_bin"):$$PATH"; \
	cargo build --manifest-path vcs/Cargo.toml --release -p workroomd && \
	vcs/scripts/daemon-idle-bench.sh vcs/target/release/workroomd $(DAEMON_BENCH_SECS) $(DAEMON_BENCH_SESSIONS) $(DAEMON_BENCH_KIND) $(DAEMON_BENCH_SCOPE) && \
	if [ -n "$(DAEMON_OLD)" ]; then vcs/scripts/daemon-handoff-check.sh "$(DAEMON_OLD)" vcs/target/release/workroomd; fi
