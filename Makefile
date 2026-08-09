.PHONY: test test-mux test-all lint

# Three lanes, because one lane cannot be both complete and quick here.
#
# shellspec forks a subshell per example, and a zsh spawn is ~30ms: the floor
# is ~0.14s PER EXAMPLE regardless of what the example does, so the full
# suite's ~980 examples cost ~137s before a single assertion runs. The whole
# suite is ~10 minutes, which is exactly the kind of number that stops being
# run. (`shellspec --jobs` would parallelise it, but under this zsh it
# corrupts its own IPC — internals leak into the output and examples fail
# spuriously. Do not reach for it without re-testing that.)
SPECS      := $(wildcard tests/*_spec.sh)

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
              tests/pinentry_mux_spec.sh \
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

# The one to run while working: ~55s, everything that does not need a daemon.
test: lint
	shellspec $(FAST_SPECS)

# The mux/tmux surface (~135s) — the lane the migration work lives in.
test-mux: lint
	shellspec $(MUX_SPECS)

# The gate: everything, before a push and in CI. ~10 minutes.
test-all: lint
	shellspec

# Guard the single-source theme: no raw hex outside .chezmoidata/theme.yaml.
lint:
	@bash tests/lint-theme.sh
