.PHONY: test test-mux test-all test-one test-changed lint recob

# Three lanes, because one lane cannot be both complete and quick here — plus
# test-one, which runs a single spec, and test-changed, which runs only the
# specs the branch's diff against master can reach (see below).
#
# Every lane runs its spec files in parallel (shellspec --jobs), one job per
# performance core. The framework itself is cheap (~4.5ms per example, ~8ms per
# file, measured 2026-09-25); the time is what the examples do, ~10 minutes of
# it for the whole suite, so parallel files are the lever. shellspec schedules
# whole FILES, so a run cannot end before its longest file: HEAVY lists the
# longest ones, measured, and every lane starts them first. Keep it honest when
# a spec grows or shrinks. (The old warning that --jobs "corrupts its own IPC"
# was raw US/RS bytes in two specs corrupting shellspec's report stream, fixed
# in 96d6a0da; it holds under --jobs too.) JOBS=1 runs one file at a time.
JOBS       ?= $(shell sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
export JOBS
HEAVY      := tests/rip-audiobook_spec.sh tests/profile-traits_spec.sh \
              tests/pbpaste-files_spec.sh tests/backup_tm_spec.sh \
              tests/rip-push_spec.sh tests/backup_spec.sh \
              tests/clipboard-mount_spec.sh tests/mux_click_spec.sh \
              tests/pick-clipboard-files_spec.sh tests/job_spec.sh \
              tests/mux_select_spec.sh tests/ssh-prepare-mount_spec.sh \
              tests/mux_spec.sh tests/mux_stack_spec.sh
# $(call heavy_first,LIST): LIST with its HEAVY files first, longest first.
heavy_first = $(foreach h,$(HEAVY),$(filter $(h),$(1))) $(filter-out $(HEAVY),$(1))
SPECS      := $(wildcard tests/*_spec.sh)

# shellspec 0.28.1 exits 0 on an aborted run, even one with failures; the
# wrapper fails it instead. See tests/run-shellspec.sh.
SHELLSPEC  := tests/run-shellspec.sh

# Specs that cost more than ~5s each, measured. They are the ones that drive
# real filesystems, mounts, restic, or tmux servers — worth running, not
# worth running on every save. Keep this list honest: if a spec grows past a
# few seconds it belongs here, and if one gets cheaper it should come out.
SLOW_SPECS := tests/backup_spec.sh tests/backup_changes_spec.sh \
              tests/backup_tm_spec.sh tests/chezmoi-reverse_spec.sh \
              tests/clipboard-files-ops_spec.sh \
              tests/clipboard-mount_spec.sh \
              tests/input-common_spec.sh tests/mux_search_spec.sh \
              tests/mux_spec.sh tests/mux_stack_spec.sh \
              tests/mux_whichkey_dispatch_spec.sh tests/mux_whichkey_spec.sh \
              tests/pbcopy-files_spec.sh tests/pbpaste-files_spec.sh \
              tests/pinentry_float_spec.sh \
              tests/pick-clipboard-feedback_spec.sh tests/pick-clipboard-files_spec.sh \
              tests/platform_spec.sh tests/preview_spec.sh \
              tests/quick_launch_tmux_spec.sh tests/ssh-prepare-mount_spec.sh \
              tests/system-onboard_spec.sh tests/system-service-launchd_spec.sh \
              tests/theme_apply_tmux_spec.sh tests/tmux_status_right_spec.sh \
              tests/zellij_spec.sh

FAST_SPECS := $(filter-out $(SLOW_SPECS),$(SPECS))
# tests/mux_spec.sh is named explicitly: `mux_*_spec.sh` needs a middle
# segment, so the shim's OWN spec was missing from this lane.
MUX_SPECS  := tests/mux_spec.sh tests/zellij_spec.sh \
              tests/pick_adapter_spec.sh tests/pick_zellij_adapters_spec.sh \
              $(wildcard tests/mux_*_spec.sh) $(wildcard tests/tmux_*_spec.sh) \
              tests/quick_launch_tmux_spec.sh tests/theme_apply_tmux_spec.sh

# Everything that does not need a daemon. test-changed is the quicker inner
# loop; this is the lane to trust before landing.
test: lint recob
	$(SHELLSPEC) --jobs $(JOBS) $(call heavy_first,$(FAST_SPECS))

# The mux/tmux surface (~135s) — the lane the migration work lives in. Not
# diff-driven: test-changed only picks a mux spec if the diff reaches it.
test-mux: lint recob
	$(SHELLSPEC) --jobs $(JOBS) $(call heavy_first,$(MUX_SPECS))

# The gate: everything, before a push and in CI. Neither test-one nor
# test-changed stands in for it.
test-all: lint recob
	$(SHELLSPEC) --jobs $(JOBS) $(call heavy_first,$(SPECS))

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
