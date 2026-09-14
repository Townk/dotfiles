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
  }
  cleanup() { rm -rf "$STAGE"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # drifted <stamp value or ""> <snapshot rows or ""> — prints yes|no
  drifted() {
    zsh -f -c '
      export SYSTEM_PACKAGE_UV_NO_RUN=1
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
