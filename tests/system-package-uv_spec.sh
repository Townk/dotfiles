# system-package-uv — Python drift detection. The stamp records the interpreter
# version at the last sync. With NO stamp the worker used to report "Python
# version changed since last sync" and rebuild every venv — including on a
# brand-new box that has no tools at all. No stamp + no tools is a first sync;
# no stamp + tools present (installed before the stamp existed) still rebuilds.
Describe 'system-package-uv: python drift'
  setup() {
    export WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-uv"
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-uv.XXXXXX")"
    export STAGE
    # The worker sources its lib from $HOME/.local/lib, so HOME points at a
    # stage that links the WORKTREE lib: the deployed copy may predate the worker.
    mkdir -p "$STAGE/home/.local"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"
  }
  cleanup() { rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # drifted <stamp value or ""> <snapshot rows or ""> — prints yes|no
  drifted() {
    zsh -f -c '
      export SYSTEM_PACKAGE_UV_NO_RUN=1 HOME="$STAGE/home"
      source "$WORKER"
      PYTHON_STAMP="$STAGE/uv.python"
      uv_current_python() { print -r -- "3.13.2" }
      [[ -n "$1" ]] && print -r -- "$1" >"$PYTHON_STAMP"
      snap="$STAGE/before"; : >"$snap"
      [[ -n "$2" ]] && print -r -- "$2" >"$snap"
      if uv_python_drifted "$snap"; then print yes; else print no; fi
    ' _ "$@"
  }

  It 'treats no stamp and no tools as a first sync, not a drift'
    When call drifted "" ""
    The output should equal no
  End

  It 'still rebuilds when there is no stamp but tools already exist'
    When call drifted "" "ruff	0.6.0"
    The output should equal yes
  End

  It 'is quiet when the stamp matches the current interpreter'
    When call drifted "3.13.2" "ruff	0.6.0"
    The output should equal no
  End

  It 'detects a changed interpreter'
    When call drifted "3.12.4" "ruff	0.6.0"
    The output should equal yes
  End
End

# A failed INSTALL of a declared-but-missing tool must fail the sync (the
# dispatcher then reports it and system-update stops), exactly as the snap
# worker does — but only after the rest of the sync has run. Upgrade and
# uninstall failures keep warning only. uv and python are stub binaries on PATH.
Describe 'system-package-uv: sync exit status'
  WORKER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_system-package-uv"

  setup() {
    STAGE="$(mktemp -d "$SHELLSPEC_TMPBASE/pkg-uv-sync.XXXXXX")"
    mkdir -p "$STAGE/home/.local" "$STAGE/bin" "$STAGE/packages/.state"
    ln -s "$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib" "$STAGE/home/.local/lib"

    # `uv tool list` prints the state file; everything else is logged.
    # `uv tool install <tool>` fails for $STUB_FAIL_INSTALL, otherwise records
    # the tool; `uv tool upgrade` / `uv tool uninstall` exit with their knobs.
    cat >"$STAGE/bin/uv" <<'SH'
#!/bin/sh
if [ "$1 $2" = "tool list" ]; then
  cat "$STUB_STATE" 2>/dev/null
  exit 0
fi
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
  "tool install")
    if [ "$3" = "${STUB_FAIL_INSTALL:-}" ]; then
      echo "error: failed to resolve $3" >&2
      exit 1
    fi
    printf '%s v1.0.0\n- %s\n' "$3" "$3" >>"$STUB_STATE"
    ;;
  "tool upgrade") exit "${STUB_UPGRADE_RC:-0}" ;;
  "tool uninstall") exit "${STUB_UNINSTALL_RC:-0}" ;;
esac
exit 0
SH
    printf '#!/bin/sh\necho "Python 3.13.2"\n' >"$STAGE/bin/python"
    chmod +x "$STAGE/bin/uv" "$STAGE/bin/python"
    # Stamp matches the interpreter: no drift rebuild in these examples.
    print -r -- '3.13.2' >"$STAGE/packages/.state/uv.python"
    printf 'present v1.0.0\n- present\n' >"$STAGE/state"
    : >"$STAGE/uv.log"
  }
  cleanup() { rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_sync() {   # run_sync <tool whose install fails> <upgrade rc> <uninstall rc>
    env -i HOME="$STAGE/home" \
      PATH="$STAGE/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      PKG_DIR="$STAGE/packages" \
      STUB_STATE="$STAGE/state" STUB_LOG="$STAGE/uv.log" \
      STUB_FAIL_INSTALL="$1" STUB_UPGRADE_RC="${2:-0}" STUB_UNINSTALL_RC="${3:-0}" \
      zsh "$WORKER" sync
  }

  It 'fails when a declared-but-missing tool cannot be installed, after finishing the sync'
    printf 'missing\npresent\n' >"$STAGE/packages/Uvfile"
    When call run_sync missing
    The status should be failure
    The stderr should include "failed to install missing"
    # The upgrade step and the changes report still ran.
    The contents of file "$STAGE/uv.log" should include "tool upgrade --all"
    The stdout should include "1 tool already up to date"
  End

  It 'does not stamp the manifest as applied when an install failed'
    printf 'missing\npresent\n' >"$STAGE/packages/Uvfile"
    When call run_sync missing
    The status should be failure
    The stdout should include "Syncing uv tools"
    The stderr should include "failed to install missing"
    The path "$STAGE/packages/.state/uv.manifest" should not be exist
  End

  It 'succeeds when the missing tools install'
    printf 'missing\nother --with extra\npresent\n' >"$STAGE/packages/Uvfile"
    When call run_sync ""
    The status should be success
    The stdout should include "missing installed: 1.0.0"
    The stdout should include "other installed: 1.0.0"
    The stdout should not include "="
    The contents of file "$STAGE/uv.log" should include "tool install other --with extra"
    The path "$STAGE/packages/.state/uv.manifest" should be exist
  End

  It 'succeeds when only the upgrade and an uninstall fail'
    printf 'extra v1.0.0\n- extra\n' >>"$STAGE/state"
    printf 'present\n' >"$STAGE/packages/Uvfile"
    When call run_sync "" 1 1
    The status should be success
    The stdout should include "Syncing uv tools"
    The stderr should include "failed to uninstall extra"
    The stderr should not include "failed to install"
    The contents of file "$STAGE/uv.log" should include "tool upgrade --all"
  End
End
