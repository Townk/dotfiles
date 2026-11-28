# Tests for the shared Python card renderer
# (home/dot_local/lib/card_render.py) and the three viewers that import it.
#
# sqlite-view and disk-image-view take their CardRenderer, Style tokens and
# text helpers from the module; ics-view takes only the palette binding, the
# SGR helpers and the Style tokens (its own CardRenderer has diverged). The
# module sits beside theme_palette.py and is found the same way: the viewer
# puts $THEME_PYLIB_DIR (default ~/.local/lib) on sys.path.
#
# THEME_PYLIB_DIR points at the repo copy of the lib dir, as in
# theme-palette-py_spec.sh.

LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib"
LIBEXEC="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec"

# Run a python snippet with the shared module importable, the way a viewer
# sets it up.
card_py() {
  python3 -c 'import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["THEME_PYLIB_DIR"])
import card_render
'"$1"
}

# The multi-line snippets live here: shellspec's translator does not carry a
# multi-line argument through `When run`.
card_names() {
  card_py 'print(all(hasattr(card_render, n) for n in (
    "CTP", "Style", "CardRenderer", "_fg", "_bg", "_bold", "_dim", "_reset",
    "_ANSI_RE", "visual_width", "truncate_visual", "wrap_ansi", "human_bytes")))'
}

card_error() {
  card_py 'out = card_render.CardRenderer(50).error_card("Thing", "it broke")
print(sorted({card_render.visual_width(line) for line in out.splitlines()}))
print(out)'
}

card_subclass() {
  card_py 'class S(card_render.Style):
    ICON_X = "x"
class R(card_render.CardRenderer):
    style_class = S
r = R(60)
print(r.s.ICON_X, r.s.ICON_WARN == card_render.Style.ICON_WARN, r.s.primary == card_render.Style.primary)'
}

# A small database built with python's sqlite3 (no sqlite3 CLI needed).
make_db() {
  python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
INSERT INTO widgets (name) VALUES (\"sprocket\"), (\"flange\");
CREATE VIEW v_widgets AS SELECT name FROM widgets;
""")
c.commit()' "$1"
}

Describe 'card_render.py + the viewers that use it'
  ICS="$LIBEXEC/executable_ics-view"
  DMG="$LIBEXEC/executable_disk-image-view"
  SQL="$LIBEXEC/executable_sqlite-view"

  setup() {
    export THEME_PYLIB_DIR="$LIB"
    # Keep CPython from writing __pycache__ into the SOURCE tree (chezmoi
    # deploys from disk, so stray bytecode would ship to every machine).
    export PYTHONDONTWRITEBYTECODE=1
    ROOT="$SHELLSPEC_TMPBASE/cr"
    export HOME="$ROOT/home"
    export XDG_CACHE_HOME="$ROOT/cache"
    export XDG_CONFIG_HOME="$ROOT/config"
    rm -rf "$ROOT"
    mkdir -p "$HOME"
    # No palette JSON anywhere: the built-in Catppuccin Mocha values apply, so
    # the lavender border SGR below is stable.
    unset THEME_PALETTE_JSON
  }
  BeforeEach 'setup'

  Describe 'the module'
    It 'imports cleanly and exposes the shared pieces'
      When run card_names
      The status should be success
      The output should equal "True"
      The error should equal ""
    End

    It 'draws an error card at the requested width'
      When run card_error
      The status should be success
      The line 1 of output should equal "[50]"
      The output should include "Thing"
      The output should include "it broke"
      The output should include "38;2;180;190;254m╭"   # lavender top-left corner
    End

    It 'clamps the card to a minimum width of 44'
      When run card_py 'print(card_render.CardRenderer(10).w)'
      The output should equal "44"
    End

    It 'human_bytes tolerates None and formats sizes'
      When run card_py 'print(card_render.human_bytes(None), card_render.human_bytes(512), card_render.human_bytes(1536), sep="|")'
      The output should equal "?|512 B|1.5 KiB"
    End

    It 'lets a viewer add icons by subclassing Style'
      When run card_subclass
      The output should equal "x True True"
    End
  End

  Describe 'sqlite-view'
    It 'renders the overview card for a small database'
      db="$SHELLSPEC_TMPBASE/cr/tiny.db"
      make_db "$db"
      When run python3 "$SQL" -W 60 "$db"
      The status should be success
      The output should include "SQLite Database"
      The output should include "widgets"
      The output should include "2 rows"
      The line 1 of output should start with "$(printf '\033[38;2;180;190;254m╭')"
    End

    It 'renders a table card with sample rows'
      db="$SHELLSPEC_TMPBASE/cr/tiny.db"
      make_db "$db"
      When run python3 "$SQL" -W 60 --table widgets "$db"
      The status should be success
      The output should include "sprocket"
      The output should include "not null"
    End

    It 'reports a missing file as an error card on stderr'
      When run python3 "$SQL" -W 60 "$SHELLSPEC_TMPBASE/cr/nope.db"
      The status should be failure
      The error should include "SQLite"
      The error should include "found:"   # wrapped rows re-open the colour per word
    End
  End

  Describe 'disk-image-view'
    # Rendering a real image needs hdiutil; the error card is drawn by the same
    # shared renderer and needs nothing but the script.
    It 'reports a missing file as an error card on stderr'
      When run python3 "$DMG" -W 60 "$SHELLSPEC_TMPBASE/cr/nope.dmg"
      The status should be failure
      The error should include "Disk Image"
      The error should include "found:"   # wrapped rows re-open the colour per word
      The line 1 of error should start with "$(printf '\033[38;2;180;190;254m╭')"
    End
  End

  Describe 'ics-view'
    It 'renders an event card with its status pill'
      Data
        #|BEGIN:VCALENDAR
        #|BEGIN:VEVENT
        #|SUMMARY:Standup
        #|STATUS:CONFIRMED
        #|END:VEVENT
        #|END:VCALENDAR
      End
      When run python3 "$ICS" -W 50
      The status should be success
      The output should include "Standup"
      The output should include "Confirmed"
      The line 1 of output should start with "$(printf '\033[38;2;180;190;254m╭')"
    End
  End

  Describe 'a half-applied tree (card_render.py missing)'
    # Same failure a missing theme_palette.py gives: python's own
    # ModuleNotFoundError naming the module, exit status 1.
    half_lib() {
      mkdir -p "$SHELLSPEC_TMPBASE/cr/halflib"
      cp "$LIB/theme_palette.py" "$SHELLSPEC_TMPBASE/cr/halflib/"
      export THEME_PYLIB_DIR="$SHELLSPEC_TMPBASE/cr/halflib"
    }
    BeforeEach 'half_lib'

    Parameters
      "$SQL"
      "$DMG"
      "$ICS"
    End

    It "fails naming the missing module: $1"
      When run python3 "$1" --help
      The status should equal 1
      The error should include "ModuleNotFoundError: No module named 'card_render'"
    End
  End
End
