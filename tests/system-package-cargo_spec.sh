# system-package-cargo — cargo-binstall resolves releases through the GitHub
# API; without a token a fresh box's first sync burns the anonymous 60/hour
# budget, times out every fetcher and falls back to source builds. The worker
# hands binstall the token mise already carries (MISE_GITHUB_TOKEN) unless an
# explicit GITHUB_TOKEN is set. cargo is a stub that prints what it received.
Describe 'system-package-cargo: binstall GitHub token'
  # The worker sources its lib from $HOME/.local/lib, so HOME points at a stage
  # that links the WORKTREE lib: the deployed copy may predate the worker.
  setup() {
    export WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-cargo"
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-cargo.XXXXXX")"
    export STAGE
    mkdir -p "$STAGE/home/.local"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"
  }
  BeforeEach 'setup'

  provision() {   # provision <GITHUB_TOKEN> <MISE_GITHUB_TOKEN>
    zsh -f -c '
      export SYSTEM_PACKAGE_CARGO_NO_RUN=1 HOME="$STAGE/home"
      unset GITHUB_TOKEN MISE_GITHUB_TOKEN   # the ambient shell may carry either
      source "$WORKER"
      HAVE_BINSTALL=1
      cargo() { [[ "$1" == binstall ]] && print -r -- "token=${GITHUB_TOKEN:-unset}" }
      [[ -n "$1" ]] && export GITHUB_TOKEN="$1"
      [[ -n "$2" ]] && export MISE_GITHUB_TOKEN="$2"
      cargo_provision kdl-lsp
    ' _ "$@"
  }

  It 'hands binstall the mise token when no GITHUB_TOKEN is set'
    When call provision "" mise-tok
    The output should equal "token=mise-tok"
  End

  It 'lets an explicit GITHUB_TOKEN win'
    When call provision explicit-tok mise-tok
    The output should equal "token=explicit-tok"
  End

  It 'passes nothing when neither token exists'
    When call provision "" ""
    The output should equal "token=unset"
  End
End

# A failed INSTALL of a declared-but-missing crate must fail the sync (the
# dispatcher then reports it and system-update stops), exactly as the snap
# worker does — but only after the rest of the sync has run. Upgrade failures
# keep warning only. cargo is a stub binary on PATH; cargo-binstall is absent,
# so both the install and the upgrade pass go through `cargo install <crate>`.
Describe 'system-package-cargo: sync exit status'
  Skip if 'complete-only: runs a whole system-package-cargo sync against stub tools (dozens of forks)' spec_complete_only
  WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-cargo"

  setup() {
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-cargo-sync.XXXXXX")"
    mkdir -p "$STAGE/home/.local" "$STAGE/bin" "$STAGE/packages"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"

    # `cargo install --list` prints the state file; `cargo install <crate>`
    # logs the attempt, fails for $STUB_FAIL, otherwise records the crate.
    cat >"$STAGE/bin/cargo" <<'SH'
#!/bin/sh
if [ "$1 $2" = "install --list" ]; then
  cat "$STUB_STATE" 2>/dev/null
  exit 0
fi
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  install)
    if [ "$2" = "${STUB_FAIL:-}" ]; then
      echo "error: could not compile $2" >&2
      exit 101
    fi
    grep -q "^$2 " "$STUB_STATE" 2>/dev/null ||
      printf '%s v1.0.0:\n    %s\n' "$2" "$2" >>"$STUB_STATE"
    ;;
esac
exit 0
SH
    chmod +x "$STAGE/bin/cargo"
    printf 'present v1.0.0:\n    present\n' >"$STAGE/state"
    : >"$STAGE/cargo.log"
  }
  # The worker's spinner naps 0.1 s per tick beside each install
  # (spin::nap -> common::sleep): on the virtual clock the ticks cost nothing.
  # The stubs' pooled inodes are exec'd once here, not inside an example.
  Include tests/exec_warm_helper.sh
  once() { spec_clock_set && spec_exec_pool_warm 2; }
  BeforeAll 'once'
  BeforeEach 'setup'

  run_sync() {   # run_sync <crate whose `cargo install` fails, or "">
    env -i HOME="$STAGE/home" TMPDIR="$TMPDIR" COMMON_CLOCK_FILE="$COMMON_CLOCK_FILE" \
      PATH="$STAGE/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      PKG_DIR="$STAGE/packages" \
      STUB_STATE="$STAGE/state" STUB_LOG="$STAGE/cargo.log" STUB_FAIL="$1" \
      zsh -f "$WORKER" sync
  }

  It 'fails when a declared-but-missing crate cannot be installed, after finishing the sync'
    printf 'missing\npresent\n' >"$STAGE/packages/Cargofile"
    When call run_sync missing
    The status should be failure
    The stderr should include "failed to install missing"
    # The upgrade pass and the changes report still ran.
    The contents of file "$STAGE/cargo.log" should include "install present"
    The stdout should include "1 crate already up to date"
    The path "$STAGE/packages/.state/cargo.manifest" should not be exist
  End

  It 'succeeds when the missing crate installs'
    printf 'missing\npresent\n' >"$STAGE/packages/Cargofile"
    When call run_sync ""
    The status should be success
    The stdout should include "missing installed: 1.0.0"
    The path "$STAGE/packages/.state/cargo.manifest" should be exist
  End

  It 'succeeds when only an upgrade fails'
    printf 'present\n' >"$STAGE/packages/Cargofile"
    When call run_sync present
    The status should be success
    The stdout should include "Syncing cargo crates"
    The stderr should include "failed to upgrade present"
    The stderr should not include "failed to install"
  End
End
