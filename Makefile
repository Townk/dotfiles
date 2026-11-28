.PHONY: test test-all test-one test-changed test-profile lint recob

# Two suites, and membership is decided PER EXAMPLE, not per file:
#
#   make test      FAST: every example except the ones marked complete-only.
#                  Budget: 60 s for the run, 0.1 s for any one example.
#   make test-all  COMPLETE: every example. Budget: 180 s. The gate, before a
#                  push and in CI.
#
# Both run every spec file. An example that needs a real scratch server, a
# real daemon, real restic/git work or other heavy tooling says so itself:
#     Skip if 'complete-only: <why>' spec_complete_only
# in the It, or in a Describe/Context to cover the group and its hooks
# (tests/spec_suite.sh). There is no list of slow files to keep honest: the
# wrapper measures every example on every run and names the ones over budget
# (tests/run-shellspec.sh; tests/spec-profile.sh for the whole table).
#
# SPEC_BUDGET says what a blown budget does: `warn` reports it, `fail` fails
# the run (exit 103). It is `warn` until the examples over 0.1 s have been
# marked; flip the default here then. `make test SPEC_BUDGET=fail` tries it.
#
# Plus test-one, which runs a single spec, and test-changed, which runs only
# the specs the branch's diff against master can reach (see below). Neither
# has a budget, and both run every example of the specs they pick.
#
# Every lane runs its spec files in parallel (shellspec --jobs), one job per
# performance core, in alphabetical order. shellspec schedules whole FILES, so
# a run cannot end before its longest file — but the longest is ~30 s of a
# ~120 s run, so the order hardly matters: starting the measured-heaviest
# files first took 118 s against 119 s (--jobs 6, 2026-11-27), and the old
# hand-kept HEAVY list was worth nothing at all. It is gone; `tests/spec-profile.sh
# files` shows each file's weight if one ever dominates again. (The old
# warning that --jobs "corrupts its own IPC" was raw US/RS bytes in two specs
# corrupting shellspec's report stream, fixed in 96d6a0da; it holds under
# --jobs too.) JOBS=1 runs one file at a time.
JOBS        ?= $(shell sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
export JOBS
SPEC_BUDGET ?= fail
export SPEC_BUDGET
# A fast example is MARKED at 0.1 s (the report lists those over it) and the
# run FAILS only past this: between two identical runs about one example in
# forty changes sides of 0.1 s, so a hard gate there would flake.
SPEC_EXAMPLE_FAIL ?= 0.25
export SPEC_EXAMPLE_FAIL
SPECS       := $(wildcard tests/*_spec.sh)

# shellspec 0.28.1 exits 0 on an aborted run, even one with failures; the
# wrapper fails it instead, and enforces the budgets. See tests/run-shellspec.sh.
SHELLSPEC   := tests/run-shellspec.sh
# Where each lane leaves its per-example times (tests/spec-profile.sh reads them).
PROFILE_DIR := $(patsubst %/,%,$(or $(TMPDIR),/tmp))

# The fast suite: the inner loop, and what test-changed falls back to. The
# complete-only examples are skipped, and those skips are not listed one by
# one (--skip-message quiet); the summary still counts them.
test: lint recob
	SPEC_SUITE=fast SPEC_PROFILE_KEEP=$(PROFILE_DIR)/spec-profile.fast.tsv \
	  $(SHELLSPEC) --jobs $(JOBS) --skip-message quiet $(SPECS)

# The gate: everything, before a push and in CI. Neither test-one nor
# test-changed stands in for it.
test-all: lint recob
	SPEC_SUITE=complete SPEC_PROFILE_KEEP=$(PROFILE_DIR)/spec-profile.complete.tsv \
	  $(SHELLSPEC) --jobs $(JOBS) $(SPECS)

# What the last `make test-all` (or SUITE=fast: `make test`) measured: the
# totals, the 30 slowest examples, and how to list every example over 0.1 s.
SUITE ?= complete
test-profile:
	@tests/spec-profile.sh summary $(PROFILE_DIR)/spec-profile.$(SUITE).tsv
	@tests/spec-profile.sh top $(PROFILE_DIR)/spec-profile.$(SUITE).tsv
	@echo 'every example over 0.1 s:  tests/spec-profile.sh over $(PROFILE_DIR)/spec-profile.$(SUITE).tsv'
	@echo 'each file, heaviest first: tests/spec-profile.sh files $(PROFILE_DIR)/spec-profile.$(SUITE).tsv'

# One spec, seconds instead of minutes: make test-one SPEC=tests/<name>_spec.sh.
# Builds recob first only when the spec pulls in tests/recob_helper.sh, and
# goes through the same wrapper as the other lanes. No lint: that is the
# lanes' job, not the inner loop's. To run whatever the branch touched rather
# than one named spec, use test-changed.
TEST_ONE_DEPS := $(if $(SPEC),$(if $(shell grep -ls 'tests/recob_helper\.sh' $(SPEC)),recob))
test-one: $(TEST_ONE_DEPS)
	@if [ -z '$(SPEC)' ]; then echo 'usage: make test-one SPEC=tests/<name>_spec.sh' >&2; exit 2; fi
	$(SHELLSPEC) $(SPEC)

# Only what the diff against master reaches — committed, staged, unstaged and
# untracked: every changed tests/*_spec.sh, plus every spec that textually
# references a changed home/dot_local/lib/**/*.zsh library (as dot_local/lib/…
# or .local/lib/…) or a changed tests/ helper. It prints the selected specs,
# then runs them through the same wrapper; an empty selection (docs only, say)
# runs nothing and passes. It falls back to the full `test` lane, saying why,
# when the Makefile, .shellspec or tests/spec_helper.sh changed — every spec
# depends on those — or when there is no master to diff against. The match is
# textual: a spec that reaches a library only through a script is not picked.
# See tests/test-changed.sh.
test-changed: lint recob
	@MAKE='$(MAKE)' tests/test-changed.sh

# Guard the single-source theme: no raw hex outside .chezmoidata/theme.yaml.
# The recob specs drive the repo's own build (custom-builds/recob/target), which
# git does not track: a fresh clone or worktree has none, and every spec that
# uses tests/recob_helper.sh fails. Cargo is incremental — ~1s when nothing
# changed, ~17s cold — and a change to recob is then tested against itself,
# never against a stale binary.
recob:
	@$(MAKE) --no-print-directory -C custom-builds/recob build >/dev/null

lint:
	@bash tests/lint-theme.sh
