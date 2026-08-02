# Tests for mux/dialog.zsh — the tmux search/rename popup chrome.
#
# C1 consolidation: mux_dialog::_fg/_bg used zsh slices ${1[2,3]} that REQUIRE
# a leading '#' and silently mis-parse a bare hex. They now route through the
# canonical theme::sgr_fg/theme::sgr_bg (which strip an optional '#'), so
# mux_dialog::init builds the correct escape from both hex forms.
Describe 'mux/dialog.zsh — init colors (C1)'
  Include home/dot_local/lib/mux/dialog.zsh

  setup() {
    MD_TMP=$(mktemp -d)
    export THEME_JSON="$MD_TMP/theme.json"
  }
  cleanup() { rm -rf "$MD_TMP"; unset THEME_JSON; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # accent = .extended.dialog.search_accent = #89b4fa -> 137;180;250
  accent_fg() { printf '\033[38;2;137;180;250m'; }
  accent_bg() { printf '\033[48;2;137;180;250m'; }

  It 'builds the accent escapes from a #-prefixed palette (unchanged)'
    cat > "$THEME_JSON" <<'EOS'
{"extended":{"tab":{"bg":"#282c41"},"dialog":{"search_accent":"#89b4fa"}},
 "roles":{"ui":{"bg":"#1e1e2e","dialog_bg":"#313244","border_inactive":"#585b70"},
          "action":{"attention":"#f9e2af"}},
 "palette":{"white":"#ffffff"}}
EOS
    check() { mux_dialog::init && print -rn -- "$MD_ACCENT_FG$MD_ACCENT_BG"; }
    When call check
    The output should equal "$(accent_fg)$(accent_bg)"
  End

  # Regression (latent bug fixed): a bare (no-#) hex used to mis-parse through
  # the ${1[2,3]} slice; the canonical strips the optional '#', so this now
  # yields the identical escape.
  It 'builds the same accent escapes from a bare (no-#) palette'
    cat > "$THEME_JSON" <<'EOS'
{"extended":{"tab":{"bg":"282c41"},"dialog":{"search_accent":"89b4fa"}},
 "roles":{"ui":{"bg":"1e1e2e","dialog_bg":"313244","border_inactive":"585b70"},
          "action":{"attention":"f9e2af"}},
 "palette":{"white":"ffffff"}}
EOS
    check() { mux_dialog::init && print -rn -- "$MD_ACCENT_FG$MD_ACCENT_BG"; }
    When call check
    The output should equal "$(accent_fg)$(accent_bg)"
  End
End
