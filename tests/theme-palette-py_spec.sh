# Tests for the shared Python palette loader
# (home/dot_local/lib/theme_palette.py) and the three viewers that import it.
#
# The module resolves the palette JSON in the SAME order as theme::json_path
# in theme-common.zsh: $THEME_PALETTE_JSON, then the effective cache copy if
# readable, then the canonical config copy. The cache tier is the fix for the
# split-palette bug the viewers used to carry — their private _load_palette
# skipped the cache and jumped straight to config whenever THEME_PALETTE_JSON
# was unset.
#
# THEME_PYLIB_DIR points python3's import path at the repo copy of the module
# (it is not installed to ~/.local/lib in the test environment). The viewers
# honour the same override for their `sys.path.insert`.

LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"

# Emit a minimal palette JSON with a distinctive `lavender` at $2 into $1.
write_palette() {
  mkdir -p "$(dirname "$1")"
  printf '{"palette":{"lavender":"%s"}}\n' "$2" > "$1"
}

# One-liner that prints one palette key's RGB triple via the shared module.
load_key() {
  python3 -c 'import os, sys
sys.path.insert(0, os.environ["THEME_PYLIB_DIR"])
from theme_palette import load_palette
print(load_palette()[sys.argv[1]])' "$1"
}

Describe 'theme_palette.py: resolution order'
  setup() {
    export THEME_PYLIB_DIR="$LIB"
    ROOT="$SHELLSPEC_TMPBASE/tp"
    export HOME="$ROOT/home"
    export XDG_CACHE_HOME="$ROOT/cache"
    export XDG_CONFIG_HOME="$ROOT/config"
    rm -rf "$ROOT"
    mkdir -p "$HOME"
    unset THEME_PALETTE_JSON
    # Cache tier gets #010203 -> (1, 2, 3); config tier gets #040506 -> (4, 5, 6).
    write_palette "$XDG_CACHE_HOME/theme/chezmoi-system.json" "#010203"
    write_palette "$XDG_CONFIG_HOME/theme/chezmoi-system.json" "#040506"
  }
  BeforeEach 'setup'

  It 'reads $THEME_PALETTE_JSON when it is set (override tier)'
    write_palette "$SHELLSPEC_TMPBASE/tp/env.json" "#0a0b0c"
    export THEME_PALETTE_JSON="$SHELLSPEC_TMPBASE/tp/env.json"
    When run load_key LAVENDER
    The output should equal "(10, 11, 12)"
    The status should be success
  End

  It 'falls to the cache tier (not config) when the env is unset'
    # The bug was reading config here; a readable cache copy must win.
    When run load_key LAVENDER
    The output should equal "(1, 2, 3)"
    The status should be success
  End

  It 'falls to the config tier when the env is unset and no cache exists'
    rm -rf "$XDG_CACHE_HOME"
    When run load_key LAVENDER
    The output should equal "(4, 5, 6)"
    The status should be success
  End

  It 'tolerates an invalid palette file, returning the built-in palette'
    printf 'not json at all\n' > "$SHELLSPEC_TMPBASE/tp/bad.json"
    export THEME_PALETTE_JSON="$SHELLSPEC_TMPBASE/tp/bad.json"
    When run load_key LAVENDER
    The output should equal "(180, 190, 254)"
    The status should be success
  End

  It 'tolerates a missing palette file, returning the built-in palette'
    export THEME_PALETTE_JSON="$SHELLSPEC_TMPBASE/tp/does-not-exist.json"
    When run load_key BASE
    The output should equal "(30, 30, 46)"
    The status should be success
  End
End

Describe 'viewers: shared module + cache-tier fix'
  ICS="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_ics-view"
  DMG="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_disk-image-view"
  SQL="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_sqlite-view"

  setup() {
    export THEME_PYLIB_DIR="$LIB"
    ROOT="$SHELLSPEC_TMPBASE/vw"
    export HOME="$ROOT/home"
    export XDG_CACHE_HOME="$ROOT/cache"
    export XDG_CONFIG_HOME="$ROOT/config"
    rm -rf "$ROOT"
    mkdir -p "$HOME"
    unset THEME_PALETTE_JSON
    # Distinctive lavender in the cache tier; ics-view's primary/border SGR is
    # _fg(*CTP.LAVENDER), so the resolved value shows up in the rendered card.
    write_palette "$XDG_CACHE_HOME/theme/chezmoi-system.json" "#010203"
    write_palette "$XDG_CONFIG_HOME/theme/chezmoi-system.json" "#040506"
  }
  BeforeEach 'setup'

  # -- the split-palette characterization (RED before migration) -------------
  It 'ics-view honours the cache tier when THEME_PALETTE_JSON is unset'
    Data
      #|BEGIN:VCALENDAR
      #|BEGIN:VEVENT
      #|SUMMARY:Standup
      #|END:VEVENT
      #|END:VCALENDAR
    End
    When run python3 "$ICS" -W 40
    The status should be success
    The output should include "38;2;1;2;3"      # cache lavender
    The output should not include "38;2;4;5;6"   # config lavender (the bug)
  End

  # -- smoke: each migrated viewer imports the module cleanly and starts ------
  It 'ics-view starts and imports the shared module cleanly'
    When run python3 "$ICS" --help
    The status should be success
    The output should include "usage"
  End

  It 'ics-view renders a card from a tiny fixture'
    Data
      #|BEGIN:VCALENDAR
      #|BEGIN:VEVENT
      #|SUMMARY:Standup
      #|END:VEVENT
      #|END:VCALENDAR
    End
    When run python3 "$ICS" -W 40
    The status should be success
    The output should include "Standup"
  End

  It 'disk-image-view starts and imports the shared module cleanly'
    When run python3 "$DMG" --help
    The status should be success
    The output should include "usage"
  End

  It 'sqlite-view starts and imports the shared module cleanly'
    When run python3 "$SQL" --help
    The status should be success
    The output should include "usage"
  End

  It 'sqlite-view renders a card from a tiny database'
    db="$SHELLSPEC_TMPBASE/vw/tiny.db"
    sqlite3 "$db" 'CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT);'
    When run python3 "$SQL" -W 60 "$db"
    The status should be success
    The output should include "widgets"
  End
End
