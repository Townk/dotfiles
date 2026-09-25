.PHONY: test test-mux test-all test-one lint recob

# Three lanes, because one lane cannot be both complete and quick here — plus
# test-one, which runs a single spec (see below).
#
# shellspec forks a subshell per example, and a zsh spawn is ~30ms: the floor
# is ~0.14s PER EXAMPLE regardless of what the example does, so the full
# suite's ~3,100 examples cost ~434s before a single assertion runs. The whole
# suite is ~9 minutes, which is exactly the kind of number that stops being
# run. (`shellspec --jobs` would parallelise it, but under this zsh it
# corrupts its own IPC — internals leak into the output and examples fail
# spuriously. Do not reach for it without re-testing that.)
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

# The one to run while working: ~5.5 minutes, everything that does not need a daemon.
test: lint recob
	$(SHELLSPEC) $(FAST_SPECS)

# The mux/tmux surface (~135s) — the lane the migration work lives in.
test-mux: lint recob
	$(SHELLSPEC) $(MUX_SPECS)

# The gate: everything, before a push and in CI. ~9 minutes.
test-all: lint recob
	$(SHELLSPEC)

# One spec, seconds instead of minutes: make test-one SPEC=tests/<name>_spec.sh.
# Builds recob first only when the spec pulls in tests/recob_helper.sh, and
# goes through the same wrapper as the other lanes. No lint: that is the
# lanes' job, not the inner loop's.
TEST_ONE_DEPS := $(if $(SPEC),$(if $(shell grep -ls 'tests/recob_helper\.sh' $(SPEC)),recob))
test-one: $(TEST_ONE_DEPS)
	@if [ -z '$(SPEC)' ]; then echo 'usage: make test-one SPEC=tests/<name>_spec.sh' >&2; exit 2; fi
	$(SHELLSPEC) $(SPEC)

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
