# Tests for the size humaniser in the term-quick-view bin
# (home/dot_local/bin/executable_term-quick-view). The file is a zsh viewer;
# sourced with TERM_QUICK_VIEW_LIB set it exposes just its helpers and runs no
# UI, so the pure size-formatting logic can be exercised in isolation.
Describe 'term-quick-view size formatting'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_term-quick-view"

  humanize() {
    TERM_QUICK_VIEW_LIB=1
    source "$SCRIPT"
    _tqv_humanize_size "$1"
  }

  It 'renders an exact 1 MiB as 1.0MB (not .9MB)'
    When call humanize 1048576
    The output should equal "1.0MB"
  End

  It 'renders an exact 2 MiB as 2.0MB'
    When call humanize 2097152
    The output should equal "2.0MB"
  End

  It 'renders 2300000 bytes as 2.1MB'
    When call humanize 2300000
    The output should equal "2.1MB"
  End

  It 'rounds sub-MiB sizes up to whole KiB'
    When call humanize 2048
    The output should equal "2KB"
  End

  It 'emits nothing for a non-numeric size'
    When call humanize "not-a-number"
    The output should equal ""
  End
End
